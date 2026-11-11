import Foundation

// Plan KT §2 — the facts the card rules read, gathered from what My Day and the job day already
// gather. Every field is a plain value: `PreparedCardRules` reads no store, no framework and no
// clock of its own, so each rule is a table test.

/// Where the wearer is now, for the location chip: the neighbourhood when MapKit gives one, else
/// the street.
struct CardPlace: Equatable, Sendable {
    let subLocality: String?
    let street: String?

    init(subLocality: String?, street: String?) {
        self.subLocality = subLocality
        self.street = street
    }

    init(_ place: GeocodingHelper.PlaceInfo) {
        self.init(subLocality: place.subLocality,
                  street: place.streetAddress ?? place.streetFromShortAddress)
    }
}

/// One hour of forecast at a destination.
struct CardWeatherHour: Equatable, Sendable {
    let start: Date
    /// 0...1.
    let precipitationChance: Double
    let temperatureCelsius: Double
}

/// A person found in Contacts from a calendar attendee's address (`ContactLookupHelper.resolve(email:)`).
struct CardContact: Equatable, Sendable {
    let name: String
    /// The number a text should go to, when the contact has one.
    let phone: String?
}

/// A job ahead, as the card rules need it (from `UpcomingJob`).
struct CardJob: Equatable, Sendable {
    let id: String
    let jobReference: String?
    let customer: String?
    let address: String?
    /// The number to text: the office connector's client phone, else the job's contact when it
    /// reads as a number. Nil means the card has no draft.
    let phone: String?
    let scheduledFor: Date?

    init(id: String, jobReference: String?, customer: String?, address: String?, phone: String?,
         scheduledFor: Date?) {
        self.id = id
        self.jobReference = jobReference
        self.customer = customer
        self.address = address
        self.phone = phone
        self.scheduledFor = scheduledFor
    }

    /// From the job as the store holds it. `officePhone` is the office connector's client phone
    /// (`WorkizClient.phone`), when the job came from one.
    init(_ job: UpcomingJob, officePhone: String? = nil) {
        let contact = job.site.contact.flatMap { ContactLookupHelper.isPhoneNumber($0) ? $0 : nil }
        self.init(id: job.id, jobReference: job.jobReference, customer: job.site.customer,
                  address: job.site.address, phone: JobSite.cleaned(officePhone) ?? contact,
                  scheduledFor: job.scheduledFor)
    }

    /// "Job 1005", or the customer, or "Next job".
    var label: String {
        if let jobReference, !jobReference.isEmpty { return JobDaySession.label(reference: jobReference) }
        return customer ?? String(localized: "Next job")
    }
}

/// Travel to the next job, worked out the way My Day's leave-by is.
struct CardJobTravel: Equatable, Sendable {
    let jobID: String
    let travelDuration: TimeInterval
    let leaveAt: Date
    let mode: MyDayTransportMode
    /// From where the wearer is now to the job; nil when location is unknown.
    let distanceMeters: Double?
}

/// The job day's facts (Plan HB), when Field Assist is on.
struct CardJobFacts: Equatable {
    var upcoming: [CardJob] = []
    var sessions: [JobDaySession] = []
    /// The organisation requires a customer sign-off before a report goes.
    var signOffRequired = false
    /// Sessions whose report is already in the send queue (waiting or failed): that row covers it.
    var queuedReportSessionIDs: Set<String> = []
    var travel: CardJobTravel?
    var destinationWeather: [CardWeatherHour] = []
}

/// The wearer, as a draft signs off.
struct CardWearer: Equatable, Sendable {
    var name: String?
    /// From the organisation profile, when there is one.
    var company: String?

    init(name: String? = nil, company: String? = nil) {
        self.name = JobSite.cleaned(name)
        self.company = JobSite.cleaned(company)
    }

    var firstName: String? { name.flatMap(PreparedCardRules.firstName) }
}

/// The switches and thresholds the rules read (§5.6).
struct PreparedCardSettings: Equatable, Sendable {
    /// Every kind but the opt-in ones, by default.
    var enabledKinds: Set<PreparedCardKind> = Set(PreparedCardKind.allCases.filter { !$0.isOptIn })
    /// Short night: slept less than this.
    var shortNightThreshold: TimeInterval = 6 * 3600
    /// Short night: a meeting starting before this time of day.
    var earlyMeetingBefore = DateComponents(hour: 9, minute: 30)
    /// Where "later that day" and "free till" stop looking.
    var dayEndsAt = DateComponents(hour: 18, minute: 0)
    /// Field Assist is on: job kinds rank before personal ones.
    var isFieldAssistDay = false
    /// The organisation profile can pin "Text customers from cards" off (decision 8).
    var customerTextsAllowed = true
    /// BCP 47 language drafts are written in when the contact's is not known.
    var draftLanguage: String = Locale.preferredLanguages.first ?? "en"

    func isEnabled(_ kind: PreparedCardKind) -> Bool { enabledKinds.contains(kind) }
}

/// Everything `PreparedCardRules` reads.
struct CardInputs: Equatable {
    var myDay: MyDayInputs
    /// From where the wearer is now to `myDay.travel`'s destination; nil when location is unknown.
    var travelDistanceMeters: Double?
    /// The forecast at `myDay.travel`'s destination.
    var destinationWeather: [CardWeatherHour] = []
    var here: CardPlace?
    /// Contacts found for attendees, by lower-cased email address.
    var contacts: [String: CardContact] = [:]
    var sleep: SleepNight?
    var meeting: MeetingSummaryFacts?
    var jobs: CardJobFacts?
    var wearer = CardWearer()

    init(myDay: MyDayInputs, travelDistanceMeters: Double? = nil,
         destinationWeather: [CardWeatherHour] = [], here: CardPlace? = nil,
         contacts: [String: CardContact] = [:], sleep: SleepNight? = nil,
         meeting: MeetingSummaryFacts? = nil, jobs: CardJobFacts? = nil,
         wearer: CardWearer = CardWearer()) {
        self.myDay = myDay
        self.travelDistanceMeters = travelDistanceMeters
        self.destinationWeather = destinationWeather
        self.here = here
        self.contacts = contacts
        self.sleep = sleep
        self.meeting = meeting
        self.jobs = jobs
        self.wearer = wearer
    }
}

extension CardTravelMode {
    init(_ mode: MyDayTransportMode) {
        switch mode {
        case .walking: self = .walking
        case .driving: self = .driving
        case .transit: self = .transit
        }
    }
}

extension CardRowID {
    init(_ id: MyDayItemID) { self.init(source: id.source.rawValue, rawValue: id.rawValue) }
}
