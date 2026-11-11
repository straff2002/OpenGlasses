import Foundation

// Plan KT §2 — the card kinds, one pure rule each over `CardInputs`. A rule returns zero or one
// card per occurrence. Every time, duration and count on a card is formatted here from the source
// rows (§1 rule 3); every recipient is chosen here (rule 1); every action is chosen here (rule 2).
//
// The rules build the card; `PreparedCardJoiner` then adds the weather and location chips each
// rule asks for (`RuledCard`), applies the wearer's state, ranks and caps.

/// A rule's card, with what the joiner may still add to it.
struct RuledCard: Equatable {
    var card: PreparedCard
    /// The time to check the destination's forecast over, and the forecast.
    var weatherWindow: DateInterval?
    var weatherHours: [CardWeatherHour] = []
    /// Where the wearer is, for the "You're in…" chip.
    var place: CardPlace?
}

struct PreparedCardRules {
    // The boundaries the plan names, as constants so the tests can stand on them.

    /// Leave by appears this long before leave-by.
    static let leaveByLead: TimeInterval = 90 * 60
    /// Running late: arriving later than this before the start.
    static let runningLateMargin: TimeInterval = 2 * 60
    /// …and further than this from the place.
    static let notThereDistance: Double = 300
    /// On my way: leave-by for the job is within this.
    static let jobOnMyWayLead: TimeInterval = 30 * 60
    /// A job's window after its scheduled time, which has no end of its own.
    static let jobWindow: TimeInterval = 2 * 3600
    /// Report not sent: the job ended more than this long ago.
    static let reportOwedDelay: TimeInterval = 15 * 60
    /// Meeting follow-up: the summary was saved no later than this after the event ended.
    static let followUpWindow: TimeInterval = 2 * 3600
    /// Meeting follow-up: at most this many action items on the card.
    static let followUpItemLimit = 3
    /// Fit it in: a gap at least this long…
    static let fitItInGap: TimeInterval = 30 * 60
    /// …starting within this.
    static let fitItInStartsWithin: TimeInterval = 60 * 60
    /// Short night: 1–3 other people at the meeting.
    static let shortNightPeople = 1...3
    /// Running late rounds the minutes up to this step.
    static let lateRoundingMinutes = 5

    let calendar: Calendar
    /// The app's locale, for headlines, chips and facts.
    let locale: Locale
    let templates: DraftTemplateSource

    init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
         templates: DraftTemplateSource = CatalogDraftTemplates()) {
        self.calendar = calendar
        self.locale = locale
        self.templates = templates
    }

    /// Every card the inputs make, unranked.
    func cards(from inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> [RuledCard] {
        var result: [RuledCard] = []
        func add(_ kind: PreparedCardKind, _ build: () -> [RuledCard]) {
            guard settings.isEnabled(kind) else { return }
            result += build()
        }
        add(.runningLate) { [runningLate(inputs, now: now, settings: settings)].compactMap { $0 } }
        add(.leaveBy) { [leaveBy(inputs, now: now, settings: settings)].compactMap { $0 } }
        add(.shortNight) { [shortNight(inputs, now: now, settings: settings)].compactMap { $0 } }
        add(.meetingFollowUp) { [meetingFollowUp(inputs, now: now, settings: settings)].compactMap { $0 } }
        add(.fitItIn) { [fitItIn(inputs, now: now, settings: settings)].compactMap { $0 } }
        if inputs.jobs != nil {
            add(.jobRunningLate) { [jobRunningLate(inputs, now: now, settings: settings)].compactMap { $0 } }
            add(.jobOnMyWay) { [jobOnMyWay(inputs, now: now, settings: settings)].compactMap { $0 } }
            add(.jobReportOwed) { jobReportOwed(inputs, now: now) }
            add(.jobPartsOwed) { jobPartsOwed(inputs, now: now) }
            add(.jobSignOffOwed) { jobSignOffOwed(inputs, now: now) }
        }
        return result
    }

    // MARK: - Personal

    /// From 90 min before leave-by until the event starts, for an event with a place. Gives way to
    /// running late for the same event.
    func leaveBy(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        guard let travel = inputs.myDay.travel,
              let event = inputs.myDay.events.first(where: { $0.id == travel.eventID }),
              !event.isAllDay,
              now >= travel.leaveAt.addingTimeInterval(-Self.leaveByLead),
              now < travel.eventStart,
              !isRunningLate(arrival: now.addingTimeInterval(travel.travelDuration),
                             start: travel.eventStart, distance: inputs.travelDistanceMeters)
        else { return nil }

        let leaveText = time(travel.leaveAt)
        let arriveBy = travel.leaveAt.addingTimeInterval(travel.travelDuration)
        let draftArrival = max(now, travel.leaveAt).addingTimeInterval(travel.travelDuration)
        let draft = oneOtherPersonDraft(for: event, inputs: inputs, settings: settings) { language in
            let arrival = DraftTemplates.time(draftArrival, language: language, timeZone: calendar.timeZone)
            return (DraftTemplates.text(.onMyWay, ["arrival": arrival], language: language, source: templates),
                    ["arrival": arrival])
        }

        let id = PreparedCardID(kind: .leaveBy, occurrence: "\(event.id):\(dayKey(event.startDate))")
        let headline = travel.leaveAt > now
            ? String(localized: "Leave by \(leaveText)")
            : String(localized: "Leave now")
        var secondary: [PreparedAction] = []
        if let draft { secondary.append(.handOff(.init(channel: draft.channel))) }
        secondary.append(.later)

        let card = PreparedCard(
            id: id,
            headline: headline,
            subject: event.title,
            signals: [CardSignal(source: .calendar, text: time(event.startDate))],
            facts: [
                CardFact(label: String(localized: "Leave by"), value: leaveText),
                CardFact(label: String(localized: "Travel"),
                         value: "\(minutesText(travel.travelDuration)) · \(travel.mode.displayName)"),
                CardFact(label: String(localized: "Arrive by"), value: time(arriveBy)),
            ],
            primary: .directions(destination: travel.destination, mode: CardTravelMode(travel.mode)),
            secondary: secondary,
            draft: draft,
            urgency: urgency(dueAt: travel.leaveAt, now: now),
            dueAt: travel.leaveAt,
            validUntil: travel.eventStart,
            absorbs: [eventRow(event), leaveByRow(event)])
        return RuledCard(card: card,
                         weatherWindow: DateInterval(start: event.startDate, end: max(event.startDate, event.endDate)),
                         weatherHours: inputs.destinationWeather,
                         place: inputs.here)
    }

    /// Now + travel time is later than the start − 2 min, and the wearer is more than 300 m from
    /// the place. Without a location there is no running late: "not there" is never guessed.
    func runningLate(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        guard let travel = inputs.myDay.travel,
              let event = inputs.myDay.events.first(where: { $0.id == travel.eventID }),
              !event.isAllDay,
              now < event.endDate
        else { return nil }
        let arrival = now.addingTimeInterval(travel.travelDuration)
        guard isRunningLate(arrival: arrival, start: travel.eventStart,
                            distance: inputs.travelDistanceMeters) else { return nil }

        let late = Self.lateMinutes(arrival: arrival, start: travel.eventStart)
        let draft = oneOtherPersonDraft(for: event, inputs: inputs, settings: settings) { language in
            let values = ["minutes": DraftTemplates.number(late, language: language),
                          "arrival": DraftTemplates.time(arrival, language: language, timeZone: calendar.timeZone)]
            return (DraftTemplates.text(.runningLate, values, language: language, source: templates), values)
        }
        let directions = PreparedAction.directions(destination: travel.destination,
                                                   mode: CardTravelMode(travel.mode))
        let primary: PreparedAction = draft.map { .handOff(.init(channel: $0.channel)) } ?? directions
        let secondary: [PreparedAction] = draft == nil ? [.dismiss] : [directions, .dismiss]

        let card = PreparedCard(
            id: PreparedCardID(kind: .runningLate, occurrence: "\(event.id):\(dayKey(event.startDate))"),
            headline: String(localized: "Running about \(late) min late"),
            subject: event.title,
            signals: [
                CardSignal(source: .calendar, text: String(localized: "Starts \(time(travel.eventStart))")),
                CardSignal(source: .travel, text: String(localized: "\(minutesText(travel.travelDuration)) away")),
            ],
            facts: [
                CardFact(label: String(localized: "Starts"), value: time(travel.eventStart)),
                CardFact(label: String(localized: "Arrive about"), value: time(arrival)),
                CardFact(label: String(localized: "Late by"), value: String(localized: "\(late) min")),
            ],
            primary: primary,
            secondary: secondary,
            draft: draft,
            urgency: .immediate,
            dueAt: travel.eventStart,
            validUntil: event.endDate,
            absorbs: [eventRow(event), leaveByRow(event)])
        return RuledCard(card: card,
                         weatherWindow: DateInterval(start: event.startDate, end: max(event.startDate, event.endDate)),
                         weatherHours: inputs.destinationWeather)
    }

    /// Opt-in. Last night's sleep under the threshold, a meeting this morning before the cut-off
    /// that someone else organised with 1–3 other people, and a free slot of the same length later
    /// today. The draft asks to move it and never mentions sleep.
    func shortNight(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        let today = calendar.startOfDay(for: now)
        guard let sleep = inputs.sleep, let asleep = sleep.asleep,
              calendar.isDate(sleep.morning, inSameDayAs: today),
              asleep < settings.shortNightThreshold,
              let cutoff = timeOfDay(settings.earlyMeetingBefore, on: today),
              let dayEnd = timeOfDay(settings.dayEndsAt, on: today)
        else { return nil }

        let meeting = inputs.myDay.events
            .filter { !$0.isAllDay && $0.startDate > now && $0.startDate < cutoff }
            .filter { event in
                guard let organizer = event.organizer, !organizer.isSelf, organizer.email != nil else { return false }
                return Self.shortNightPeople.contains(Self.distinctOthers(event).count)
            }
            .min { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
        guard let meeting, let organizer = meeting.organizer, let address = organizer.email else { return nil }

        let duration = meeting.endDate.timeIntervalSince(meeting.startDate)
        guard duration > 0,
              let slot = freeSlot(lasting: duration, from: meeting.endDate, until: dayEnd,
                                  events: inputs.myDay.events, ignoring: meeting.id)
        else { return nil }

        let name = organizer.name ?? address
        let recipient = DraftRecipient(name: name, addresses: [address], source: .calendarOrganiser)
        let language = settings.draftLanguage
        let slotText = DraftTemplates.time(slot, language: language, timeZone: calendar.timeZone)
        let body = DraftTemplates.text(.askToMove, ["meeting": meeting.title, "slot": slotText],
                                       language: language, source: templates)
        let text = DraftTemplates.email(greetingName: organizer.name.flatMap(Self.firstName), body: body,
                                        signOff: inputs.wearer.name, language: language, source: templates)
        let draft = validatedDraft(PreparedDraft(channel: .email, recipient: recipient, subject: meeting.title,
                                                 text: text, language: language),
                                   trusted: [meeting.title, slotText, name, inputs.wearer.name ?? ""])
        guard let draft else { return nil }

        let card = PreparedCard(
            id: PreparedCardID(kind: .shortNight, occurrence: "\(meeting.id):\(dayKey(meeting.startDate))"),
            headline: String(localized: "Ask to move \(meeting.title)"),
            subject: "\(meeting.title) · \(time(meeting.startDate))",
            signals: [
                CardSignal(source: .sleep, text: String(localized: "Slept \(durationText(asleep))"),
                           sensitivity: .health),
                CardSignal(source: .calendar, text: String(localized: "Free from \(time(slot))")),
            ],
            facts: [
                CardFact(label: String(localized: "Meeting"), value: time(meeting.startDate)),
                CardFact(label: String(localized: "Proposed"), value: time(slot)),
            ],
            primary: .handOff(.init(channel: .email)),
            secondary: [.openEvent(id: meeting.id), .dismiss],
            draft: draft,
            urgency: urgency(dueAt: meeting.startDate, now: now),
            dueAt: meeting.startDate,
            validUntil: meeting.startDate,
            sensitivity: .health,
            absorbs: [eventRow(meeting)])
        return RuledCard(card: card)
    }

    /// A meeting summary with action items, saved no later than 2 h after a calendar event that
    /// overlaps the conversation and has other people with addresses. Lasts the day.
    func meetingFollowUp(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        guard let meeting = inputs.meeting, !meeting.actionItems.isEmpty, now >= meeting.savedAt,
              let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: meeting.savedAt)),
              now < endOfDay
        else { return nil }

        let spoken = DateInterval(start: meeting.startedAt, end: max(meeting.startedAt, meeting.endedAt))
        let candidates = inputs.myDay.events.filter { event in
            guard !event.isAllDay, event.endDate > event.startDate else { return false }
            let overlaps = event.startDate <= spoken.end && event.endDate >= spoken.start
            let savedInTime = meeting.savedAt <= event.endDate.addingTimeInterval(Self.followUpWindow)
            return overlaps && savedInTime && Self.distinctOthers(event).contains { $0.email != nil }
        }
        func overlap(_ event: MyDayCalendarEvent) -> TimeInterval {
            min(event.endDate, spoken.end).timeIntervalSince(max(event.startDate, spoken.start))
        }
        guard let event = candidates.max(by: { (overlap($0), $1.id) < (overlap($1), $0.id) }) else { return nil }

        let people = Self.distinctOthers(event).filter { $0.email != nil }
        let addresses = people.compactMap(\.email)
        let names = people.map { $0.name ?? $0.email ?? "" }
        let items = Array(meeting.actionItems.prefix(Self.followUpItemLimit))
        let recipient = DraftRecipient(name: ListFormatter.localizedString(byJoining: names),
                                       addresses: addresses, source: .meetingAttendees)
        let language = settings.draftLanguage
        let body = DraftTemplates.text(.recapIntro, language: language, source: templates)
            + "\n" + DraftTemplates.bulletList(items)
        let greetingName = people.count == 1 ? people[0].name.flatMap(Self.firstName) : nil
        let text = DraftTemplates.email(greetingName: greetingName, body: body, signOff: inputs.wearer.name,
                                        language: language, source: templates)
        let subject = DraftTemplates.text(.recapSubject, ["meeting": event.title], language: language,
                                          source: templates)
        let draft = validatedDraft(
            PreparedDraft(channel: .email, recipient: recipient, subject: subject, text: text, language: language),
            trusted: [event.title, inputs.wearer.name ?? ""] + names + items,
            actionItems: items,
            untrustedSource: meeting.transcript)
        guard let draft else { return nil }

        let count = meeting.actionItems.count
        let card = PreparedCard(
            id: PreparedCardID(kind: .meetingFollowUp, occurrence: "\(event.id):\(dayKey(event.startDate))"),
            headline: String(localized: "Send a recap"),
            subject: event.title,
            signals: [
                CardSignal(source: .meeting,
                           text: count == 1 ? String(localized: "1 thing agreed")
                               : String(localized: "\(count) things agreed"),
                           sensitivity: .personal),
                CardSignal(source: .calendar, text: time(event.startDate)),
            ],
            facts: items.map { CardFact(label: String(localized: "Agreed"),
                                        value: PreparedCardText.clipped($0, to: PreparedCard.subjectLimit)) },
            primary: .handOff(.init(channel: .email)),
            secondary: [.openEvent(id: event.id), .dismiss],
            draft: draft,
            urgency: .upcoming,
            dueAt: nil,
            validUntil: endOfDay,
            sensitivity: .personal,
            absorbs: [eventRow(event)])
        return RuledCard(card: card)
    }

    /// A reminder due today with no time, and a free gap of 30 min or more starting within the
    /// hour. One card: the reminder that ranks first (priority, then title).
    func fitItIn(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let dayEnd = timeOfDay(settings.dayEndsAt, on: today) else { return nil }
        let reminder = inputs.myDay.reminders
            .filter { reminder in
                guard let due = reminder.dueDate, !reminder.hasTime else { return false }
                return due >= today && due < tomorrow
            }
            .min { lhs, rhs in
                let left = Self.reminderPriorityRank(lhs.priority)
                let right = Self.reminderPriorityRank(rhs.priority)
                if left != right { return left < right }
                if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
                return lhs.id < rhs.id
            }
        guard let reminder,
              let gap = freeGap(atLeast: Self.fitItInGap, startingBy: now.addingTimeInterval(Self.fitItInStartsWithin),
                                from: now, until: dayEnd, events: inputs.myDay.events)
        else { return nil }

        let card = PreparedCard(
            id: PreparedCardID(kind: .fitItIn, occurrence: "\(reminder.id):\(dayKey(today))"),
            headline: reminder.title,
            subject: String(localized: "Free till \(time(gap.end))"),
            signals: [
                CardSignal(source: .reminders, text: reminder.listName ?? String(localized: "Due today")),
                CardSignal(source: .calendar, text: String(localized: "Free till \(time(gap.end))")),
            ],
            facts: [
                CardFact(label: String(localized: "Reminder"), value: reminder.title),
                CardFact(label: String(localized: "Free"), value: "\(time(gap.start))–\(time(gap.end))"),
            ],
            primary: .complete(reminderId: reminder.id),
            secondary: [.later],
            urgency: urgency(dueAt: gap.start, now: now),
            dueAt: gap.start,
            validUntil: gap.end,
            absorbs: [CardRowID(MyDayItemID(source: .reminders, rawValue: reminder.id))])
        return RuledCard(card: card)
    }

    // MARK: - Field Assist

    /// The next job today with a time and an address, while leave-by for it is within 30 min and
    /// it has not started. Gives way to job running late.
    func jobOnMyWay(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        guard let facts = inputs.jobs, let job = nextJob(facts, now: now),
              let scheduled = job.scheduledFor, let address = job.address,
              let travel = facts.travel, travel.jobID == job.id,
              travel.leaveAt.timeIntervalSince(now) <= Self.jobOnMyWayLead,
              now < scheduled,
              !isRunningLate(arrival: now.addingTimeInterval(travel.travelDuration), start: scheduled,
                             distance: travel.distanceMeters)
        else { return nil }

        let arrival = max(now, travel.leaveAt).addingTimeInterval(travel.travelDuration)
        let draft = customerDraft(job, inputs: inputs, settings: settings) { language, name in
            var values = ["name": name,
                          "arrival": DraftTemplates.time(arrival, language: language, timeZone: calendar.timeZone)]
            let id: DraftTemplateID
            switch (inputs.wearer.firstName, inputs.wearer.company) {
            case let (wearer?, company?):
                id = .jobOnMyWayFromCompany
                values["wearer"] = wearer
                values["company"] = company
            case let (wearer?, nil):
                id = .jobOnMyWayFromWearer
                values["wearer"] = wearer
            default:
                id = .jobOnMyWay
            }
            return (DraftTemplates.text(id, values, language: language, source: templates), values)
        }
        let directions = PreparedAction.directions(destination: address, mode: CardTravelMode(travel.mode))
        var secondary: [PreparedAction] = []
        if let draft { secondary.append(.handOff(.init(channel: draft.channel))) }
        secondary.append(.later)

        let card = PreparedCard(
            id: PreparedCardID(kind: .jobOnMyWay, occurrence: "\(job.jobReference ?? job.id):\(dayKey(scheduled))"),
            headline: String(localized: "Leave by \(time(travel.leaveAt))"),
            subject: job.label,
            signals: [
                CardSignal(source: .job, text: job.label),
                CardSignal(source: .location, text: address),
                CardSignal(source: .travel, text: minutesText(travel.travelDuration)),
            ],
            facts: [
                job.customer.map { CardFact(label: String(localized: "Customer"), value: $0) },
                CardFact(label: String(localized: "Scheduled"), value: time(scheduled)),
                CardFact(label: String(localized: "Arrive about"), value: time(arrival)),
            ].compactMap { $0 },
            primary: directions,
            secondary: secondary,
            draft: draft,
            urgency: urgency(dueAt: travel.leaveAt, now: now),
            dueAt: travel.leaveAt,
            validUntil: scheduled)
        return RuledCard(card: card,
                         weatherWindow: DateInterval(start: scheduled, duration: 3600),
                         weatherHours: facts.destinationWeather)
    }

    /// As running late, for the next job: until the end of the job's window.
    func jobRunningLate(_ inputs: CardInputs, now: Date, settings: PreparedCardSettings) -> RuledCard? {
        guard let facts = inputs.jobs, let job = nextJob(facts, now: now),
              let scheduled = job.scheduledFor,
              let travel = facts.travel, travel.jobID == job.id
        else { return nil }
        let arrival = now.addingTimeInterval(travel.travelDuration)
        guard isRunningLate(arrival: arrival, start: scheduled, distance: travel.distanceMeters) else { return nil }

        let late = Self.lateMinutes(arrival: arrival, start: scheduled)
        let draft = customerDraft(job, inputs: inputs, settings: settings) { language, name in
            let values = ["name": name,
                          "minutes": DraftTemplates.number(late, language: language),
                          "arrival": DraftTemplates.time(arrival, language: language, timeZone: calendar.timeZone)]
            return (DraftTemplates.text(.jobRunningLate, values, language: language, source: templates), values)
        }
        let directions = job.address.map { PreparedAction.directions(destination: $0, mode: CardTravelMode(travel.mode)) }
        let primary: PreparedAction = draft.map { .handOff(.init(channel: $0.channel)) }
            ?? directions ?? .openJob(id: job.id)
        let secondary: [PreparedAction] = draft == nil ? [.openJob(id: job.id)] : [directions ?? .openJob(id: job.id)]

        let card = PreparedCard(
            id: PreparedCardID(kind: .jobRunningLate, occurrence: "\(job.jobReference ?? job.id):\(dayKey(scheduled))"),
            headline: String(localized: "Running about \(late) min late"),
            subject: job.label,
            signals: [
                CardSignal(source: .job, text: job.label),
                CardSignal(source: .travel, text: String(localized: "\(minutesText(travel.travelDuration)) away")),
            ],
            facts: [
                CardFact(label: String(localized: "Scheduled"), value: time(scheduled)),
                CardFact(label: String(localized: "Arrive about"), value: time(arrival)),
            ],
            primary: primary,
            secondary: secondary,
            draft: draft,
            urgency: .immediate,
            dueAt: scheduled,
            validUntil: scheduled.addingTimeInterval(Self.jobWindow))
        return RuledCard(card: card,
                         weatherWindow: DateInterval(start: scheduled, duration: 3600),
                         weatherHours: facts.destinationWeather)
    }

    /// A job that ended today more than 15 min ago whose report has not gone and is not already in
    /// the send queue. Replaces the job day's "Report not sent" row.
    func jobReportOwed(_ inputs: CardInputs, now: Date) -> [RuledCard] {
        guard let facts = inputs.jobs, let endOfDay = endOfDay(now) else { return [] }
        return finishedToday(facts, now: now)
            .filter { session in
                guard let ended = session.endedAt else { return false }
                return !session.reportSent && !facts.queuedReportSessionIDs.contains(session.id)
                    && now.timeIntervalSince(ended) > Self.reportOwedDelay
            }
            .map { session in
                RuledCard(card: PreparedCard(
                    id: PreparedCardID(kind: .jobReportOwed, occurrence: "\(session.id):\(dayKey(session.startedAt))"),
                    headline: String(localized: "Report not sent"),
                    subject: session.customer ?? session.label,
                    signals: [CardSignal(source: .job, text: session.label),
                              CardSignal(source: .job, text: String(localized: "Report not sent"))],
                    facts: [
                        session.customer.map { CardFact(label: String(localized: "Customer"), value: $0) },
                        session.endedAt.map { CardFact(label: String(localized: "Ended"), value: time($0)) },
                    ].compactMap { $0 },
                    primary: .openReport(sessionId: session.id),
                    secondary: [.openJob(id: session.id)],
                    urgency: .upcoming,
                    dueAt: nil,
                    validUntil: endOfDay,
                    absorbs: [.jobDay("unsent-\(session.id)")]))
            }
    }

    /// A job with parts requests nobody has sent. Replaces the job day's parts row.
    func jobPartsOwed(_ inputs: CardInputs, now: Date) -> [RuledCard] {
        guard let facts = inputs.jobs, let endOfDay = endOfDay(now) else { return [] }
        return facts.sessions
            .filter { !$0.cancelled && $0.unsentPartsRequests > 0 }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
            .map { session in
                let count = session.unsentPartsRequests
                return RuledCard(card: PreparedCard(
                    id: PreparedCardID(kind: .jobPartsOwed, occurrence: "\(session.id):\(dayKey(now))"),
                    headline: String(localized: "Parts not ordered"),
                    subject: session.customer ?? session.label,
                    signals: [CardSignal(source: .job, text: session.label),
                              CardSignal(source: .job, text: count == 1 ? String(localized: "1 part")
                                            : String(localized: "\(count) parts"))],
                    facts: [CardFact(label: String(localized: "Parts"), value: String(count))],
                    primary: .openPartsOrder(sessionId: session.id),
                    secondary: [.openJob(id: session.id)],
                    urgency: .upcoming,
                    dueAt: nil,
                    validUntil: endOfDay,
                    absorbs: [.jobDay("parts-\(session.id)")]))
            }
    }

    /// A job that ended today without the customer's sign-off, when the organisation requires one
    /// and the report has not gone (a signature after the report left signs nothing).
    func jobSignOffOwed(_ inputs: CardInputs, now: Date) -> [RuledCard] {
        guard let facts = inputs.jobs, facts.signOffRequired, let endOfDay = endOfDay(now) else { return [] }
        return finishedToday(facts, now: now)
            .filter { !$0.signedOff && !$0.reportSent }
            .map { session in
                RuledCard(card: PreparedCard(
                    id: PreparedCardID(kind: .jobSignOffOwed, occurrence: "\(session.id):\(dayKey(session.startedAt))"),
                    headline: String(localized: "Sign-off owed"),
                    subject: session.customer ?? session.label,
                    signals: [CardSignal(source: .job, text: session.label)],
                    facts: [session.customer.map { CardFact(label: String(localized: "Customer"), value: $0) }]
                        .compactMap { $0 },
                    primary: .getSignOff(sessionId: session.id),
                    secondary: [.openJob(id: session.id)],
                    urgency: .upcoming,
                    dueAt: nil,
                    validUntil: endOfDay,
                    absorbs: [.jobDay("signoff-\(session.id)")]))
            }
    }

    // MARK: - Shared decisions

    /// §3.2's ladder: ≤ 10 min (or overdue) immediate, ≤ 60 min important, today upcoming,
    /// otherwise routine. No due time reads as today.
    func urgency(dueAt: Date?, now: Date) -> MyDayUrgency {
        guard let dueAt else { return .upcoming }
        let seconds = dueAt.timeIntervalSince(now)
        if seconds <= 10 * 60 { return .immediate }
        if seconds <= 60 * 60 { return .important }
        if calendar.isDate(dueAt, inSameDayAs: now) { return .upcoming }
        return .routine
    }

    func isRunningLate(arrival: Date, start: Date, distance: Double?) -> Bool {
        guard let distance, distance > Self.notThereDistance else { return false }
        return arrival > start.addingTimeInterval(-Self.runningLateMargin)
    }

    /// Minutes late, rounded up to 5, never less than 5.
    static func lateMinutes(arrival: Date, start: Date) -> Int {
        let minutes = max(1, Int((arrival.timeIntervalSince(start) / 60).rounded(.up)))
        let step = lateRoundingMinutes
        return max(step, Int((Double(minutes) / Double(step)).rounded(.up)) * step)
    }

    /// The people on an event other than the wearer, one per address.
    static func distinctOthers(_ event: MyDayCalendarEvent) -> [CalendarPerson] {
        var seen: Set<String> = []
        return event.otherPeople.filter { person in
            guard let email = person.email else { return true }
            return seen.insert(email).inserted
        }
    }

    /// "Ana" from "Ana Example"; nil from an empty name.
    static func firstName(_ name: String) -> String? {
        name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    /// EventKit's 1 is highest, 9 lowest, 0 none.
    static func reminderPriorityRank(_ priority: Int) -> Int { priority == 0 ? 10 : priority }

    /// The next job: today's, scheduled, earliest, still inside its window.
    func nextJob(_ facts: CardJobFacts, now: Date) -> CardJob? {
        facts.upcoming
            .filter { job in
                guard let scheduled = job.scheduledFor else { return false }
                return calendar.isDate(scheduled, inSameDayAs: now)
                    && scheduled.addingTimeInterval(Self.jobWindow) > now
            }
            .min { ($0.scheduledFor ?? .distantFuture, $0.id) < ($1.scheduledFor ?? .distantFuture, $1.id) }
    }

    private func finishedToday(_ facts: CardJobFacts, now: Date) -> [JobDaySession] {
        facts.sessions
            .filter { session in
                guard let ended = session.endedAt, !session.cancelled else { return false }
                return calendar.isDate(ended, inSameDayAs: now) && ended <= now
            }
            .sorted { ($0.endedAt ?? .distantPast, $0.id) < ($1.endedAt ?? .distantPast, $1.id) }
    }

    /// The draft to the one other person on the event, when there is exactly one and they have an
    /// address: a text when Contacts has a number for them, else an email.
    private func oneOtherPersonDraft(
        for event: MyDayCalendarEvent, inputs: CardInputs, settings: PreparedCardSettings,
        text: (String) -> (String, [String: String])
    ) -> PreparedDraft? {
        let others = Self.distinctOthers(event)
        guard others.count == 1, let person = others.first, let email = person.email else { return nil }
        let contact = inputs.contacts[email]
        let name = contact?.name.nilIfBlank ?? person.name ?? email
        let source: DraftRecipientSource = person.isOrganizer ? .calendarOrganiser : .calendarAttendee
        let language = settings.draftLanguage
        let (body, values) = text(language)
        let draft: PreparedDraft
        if let phone = contact?.phone {
            draft = PreparedDraft(channel: .messages,
                                  recipient: DraftRecipient(name: name, addresses: [phone], source: source),
                                  text: body, language: language)
        } else {
            draft = PreparedDraft(channel: .email,
                                  recipient: DraftRecipient(name: name, addresses: [email], source: source),
                                  subject: event.title, text: body, language: language)
        }
        return validatedDraft(draft, trusted: Array(values.values) + [name, event.title])
    }

    /// The text to the job's customer, when the organisation allows it and the job has a number
    /// and a customer name to greet.
    private func customerDraft(
        _ job: CardJob, inputs: CardInputs, settings: PreparedCardSettings,
        text: (String, String) -> (String, [String: String])
    ) -> PreparedDraft? {
        guard settings.customerTextsAllowed, let phone = job.phone,
              let customer = job.customer, let first = Self.firstName(customer) else { return nil }
        let language = settings.draftLanguage
        let (body, values) = text(language, first)
        let draft = PreparedDraft(channel: .messages,
                                  recipient: DraftRecipient(name: customer, addresses: [phone], source: .jobCustomer),
                                  text: body, language: language)
        return validatedDraft(draft, trusted: Array(values.values) + [customer])
    }

    /// The draft, when its filled template passes `DraftValidator`; nil when it does not.
    private func validatedDraft(_ draft: PreparedDraft, trusted: [String], actionItems: [String] = [],
                                untrustedSource: String? = nil) -> PreparedDraft? {
        let context = DraftValidationContext(channel: draft.channel, language: draft.language,
                                             trustedText: trusted + [draft.subject ?? ""],
                                             actionItems: actionItems, untrustedSource: untrustedSource)
        return DraftValidator.validate(draft.text, context: context) == nil ? draft : nil
    }

    /// The first free stretch of `duration` starting at or after `start` (on a quarter hour) and
    /// ending by `end`, among the day's timed events.
    func freeSlot(lasting duration: TimeInterval, from start: Date, until end: Date,
                  events: [MyDayCalendarEvent], ignoring ignoredID: String? = nil) -> Date? {
        let busy = busyIntervals(events, ignoring: ignoredID)
        var candidates = [start] + busy.map(\.end).filter { $0 > start }
        candidates = candidates.map(roundUpToQuarter).sorted()
        return candidates.first { candidate in
            let slot = DateInterval(start: candidate, duration: duration)
            return slot.end <= end && !busy.contains { $0.start < slot.end && $0.end > slot.start }
        }
    }

    /// The first gap of at least `minimum` that starts no later than `latestStart`, from `now`,
    /// ending at the next event or `dayEnd`.
    func freeGap(atLeast minimum: TimeInterval, startingBy latestStart: Date, from now: Date,
                 until dayEnd: Date, events: [MyDayCalendarEvent]) -> DateInterval? {
        let busy = busyIntervals(events, ignoring: nil)
        let candidates = ([now] + busy.map(\.end).filter { $0 > now && $0 <= latestStart }).sorted()
        for candidate in candidates {
            if busy.contains(where: { $0.start <= candidate && $0.end > candidate }) { continue }
            let next = busy.filter { $0.start > candidate }.map(\.start).min() ?? dayEnd
            let gapEnd = min(next, dayEnd)
            if gapEnd.timeIntervalSince(candidate) >= minimum {
                return DateInterval(start: candidate, end: gapEnd)
            }
        }
        return nil
    }

    private func busyIntervals(_ events: [MyDayCalendarEvent], ignoring ignoredID: String?) -> [DateInterval] {
        events
            .filter { !$0.isAllDay && $0.id != ignoredID && $0.endDate > $0.startDate }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }

    private func roundUpToQuarter(_ date: Date) -> Date {
        let minute = calendar.component(.minute, from: date)
        let second = calendar.component(.second, from: date)
        let remainder = minute % 15
        guard remainder != 0 || second != 0 else { return date }
        let floored = calendar.date(bySettingHour: calendar.component(.hour, from: date),
                                    minute: minute - remainder, second: 0, of: date) ?? date
        return floored.addingTimeInterval(15 * 60)
    }

    // MARK: - Formatting (the app's locale)

    func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "34 min".
    func minutesText(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        return String(localized: "\(minutes) min")
    }

    /// "5h 10m".
    func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = self.calendar
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: (duration / 60).rounded(.down) * 60) ?? ""
    }

    /// `yyyy-MM-dd` in the rules' calendar, for occurrence keys.
    func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func timeOfDay(_ components: DateComponents, on day: Date) -> Date? {
        calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: day)
    }

    private func endOfDay(_ now: Date) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }

    private func eventRow(_ event: MyDayCalendarEvent) -> CardRowID {
        CardRowID(MyDayItemID(source: .calendar, rawValue: event.id))
    }

    private func leaveByRow(_ event: MyDayCalendarEvent) -> CardRowID {
        CardRowID(MyDayItemID(source: .travel, rawValue: "leave-by:\(event.id)"))
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
