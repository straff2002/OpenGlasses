import Foundation

/// A card as speech (Plan KT §6.5): what it says, and the offer it makes, if any.
struct PreparedCardPhrase: Equatable {
    /// One sentence about the card, or two when the wearer asked about their sleep.
    let statement: String
    /// The offer, as a question: "Want me to get a message to Ana ready?". Nil without a draft.
    let offer: String?
    /// How the two are joined: short night's offer runs on from its statement ("Your 08:30 with
    /// Tom — want to ask to move it?").
    let joinsWithDash: Bool

    /// Whether a spoken "yes" to this phrase stages the card's draft.
    var offersStage: Bool { offer != nil }

    var text: String {
        guard let offer else { return statement }
        return joinsWithDash ? "\(statement) — \(offer)" : "\(statement) \(offer)"
    }
}

/// Plan KT §6.5 — says a card in at most two sentences and offers its action as a question. Pure:
/// the card, whether the wearer asked about their sleep, the Medical Compliance reading and the
/// time format are all inputs.
///
/// - **Sleep is never said** unless the wearer asked about their sleep: a short-night card is said
///   as "Your 08:30 with Tom — want to ask to move it?". No `health` chip is ever said unasked.
/// - **`personal` says the headline only** (a meeting follow-up): no subject, no chips, no facts.
/// - **It never quotes caption text**: no fact and no draft text is ever part of a phrase, so a
///   meeting's agreed items (caption-derived) never are.
/// - **Medical Compliance** withholds what the Today glance withholds
///   (`PreparedCardMedicalWithholding`): the event's title is never said.
/// - **A "yes" only stages.** The only offer is to put the drafted message on the phone.
enum PreparedCardPhraser {

    static func phrase(_ card: PreparedCard, askedAboutSleep: Bool = false, withholding: Bool = false,
                       time: (Date) -> String = PreparedCardPhraser.shortTime) -> PreparedCardPhrase {
        let shown = PreparedCardMedicalWithholding.shown(card, withholding: withholding)
        let offer = self.offer(card)

        if card.kind == .shortNight {
            let when = card.dueAt.map(time)
            let organiser = card.draft.flatMap { PreparedCardRules.firstName($0.recipient.name) }
            let meeting: String
            switch (when, organiser) {
            case let (when?, name?):
                meeting = String(localized: "Your \(when) with \(name)",
                                 comment: "Spoken: a morning meeting at this time with this person. The offer to move it follows.")
            case let (when?, nil):
                meeting = String(localized: "Your \(when) meeting", comment: "Spoken: a morning meeting at this time.")
            default:
                meeting = String(localized: "Your early meeting", comment: "Spoken: a morning meeting with no time known.")
            }
            let move = card.draft == nil ? nil
                : String(localized: "want to ask to move it?",
                         comment: "Spoken, after a dash: offers to put an email asking to move the meeting on the phone.")
            var statement = move == nil ? sentence(meeting) : meeting
            if askedAboutSleep, let sleep = card.signals.first(where: { $0.source == .sleep }) {
                statement = sentence(sleep.text) + " " + statement
            }
            return PreparedCardPhrase(statement: statement, offer: move, joinsWithDash: move != nil)
        }

        // `personal`: the headline only.
        if shown.sensitivity == .personal {
            return PreparedCardPhrase(statement: sentence(shown.headline), offer: offer, joinsWithDash: false)
        }

        let headline = shown.headline
        let statement: String
        switch card.kind {
        case .leaveBy, .runningLate, .jobOnMyWay, .jobRunningLate, .jobReportOwed, .jobPartsOwed, .jobSignOffOwed:
            let subject = shown.subject.flatMap(nonEmpty)
            var line = subject.map {
                String(localized: "\(headline) for \($0)", comment: "Spoken: a card's headline and what it is about, e.g. Leave by 18:15 for the gig.")
            } ?? headline
            if let weather = ordinarySignal(shown, .weather) { line += " — \(weather)" }
            statement = sentence(line)
        case .fitItIn:
            statement = sentence(shown.subject.flatMap(nonEmpty).map { "\(headline) — \($0)" } ?? headline)
        case .shortNight, .meetingFollowUp:
            statement = sentence(headline)
        }
        return PreparedCardPhrase(statement: statement, offer: offer, joinsWithDash: false)
    }

    /// The offer for a card with a draft: put it on the phone. Nil without one.
    static func offer(_ card: PreparedCard) -> String? {
        guard let draft = card.draft, card.actions.contains(where: PreparedCardHUDBuilder.isHandOff) else { return nil }
        let first = draft.recipient.source == .meetingAttendees ? nil : PreparedCardRules.firstName(draft.recipient.name)
        switch (card.kind, first) {
        case (.jobOnMyWay, let name?):
            return String(localized: "Shall I get an on-my-way text ready for \(name)?",
                          comment: "Spoken: offers to put a drafted on-my-way text to this customer on the phone.")
        case (.jobRunningLate, let name?):
            return String(localized: "Shall I get a text ready for \(name)?",
                          comment: "Spoken: offers to put a drafted text to this customer on the phone.")
        case (_, let name?) where draft.channel == .email:
            return String(localized: "Want me to get an email to \(name) ready?",
                          comment: "Spoken: offers to put a drafted email to this person on the phone.")
        case (_, let name?):
            return String(localized: "Want me to get a message to \(name) ready?",
                          comment: "Spoken: offers to put a drafted message to this person on the phone.")
        case (_, nil):
            return String(localized: "Want me to put it on your phone?",
                          comment: "Spoken: offers to put a drafted message on the phone, ready to send.")
        }
    }

    /// **Read it**: the draft, said with who it is to. Only ever on the wearer's press or word.
    static func draftReading(_ card: PreparedCard, withholding: Bool = false) -> String? {
        guard let draft = card.draft else { return nil }
        if PreparedCardMedicalWithholding.withholdsDraftText(card, withholding: withholding) {
            return PreparedCardMedicalWithholding.draftHiddenLine
        }
        let name = draft.recipient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return text }
        return String(localized: "To \(name): \(text)", comment: "Spoken: a drafted message read aloud, after who it is to.")
    }

    /// What staging said, spoken.
    static func staged(_ outcome: PreparedCardStager.Outcome) -> String? {
        switch outcome {
        case .openedComposer:
            return String(localized: "It's open on your phone — tap Send there.",
                          comment: "Spoken: a drafted message opened on the phone, which is in front and unlocked.")
        case .notified:
            return String(localized: "It's on your phone — tap the notification to send.",
                          comment: "Spoken: a drafted message was put on the phone to send there.")
        case .nothingToStage:
            return nil
        }
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Pieces

    /// An ordinary chip's text from `source`, never a health one.
    private static func ordinarySignal(_ card: PreparedCard, _ source: CardSource) -> String? {
        card.signals.first { $0.source == source && $0.sensitivity == .ordinary }.flatMap { nonEmpty($0.text) }
    }

    /// `text` ending in a full stop, unless it already ends in a mark.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - "What's ready?" read aloud

/// Plan KT §6.5 — the stack read aloud, one card at a time: "Three things. First: …". Pure: every
/// answer is a value in, a step out, and the app speaks and acts on the step.
///
/// While it reads, these work: **next** / **skip** / **no** (the next card), **later**, **not
/// useful**, **dismiss**, **back** (the card before), **again**, **read it** (the draft), **stop**.
/// **Yes** to an offer stages the draft (§6.4) — it never sends, so the short-utterance approval
/// (`RemoteActionVoiceConsent`) is safe here: the worst a stray "yes" can do is put a draft on the
/// phone. A "yes" to a card that offers nothing moves on.
///
/// A reading is live for `answerWindow` after its last line; after that an answer is not one, so
/// a "yes" said minutes later stages nothing.
struct PreparedCardSpokenStack: Equatable {
    static let answerWindow: TimeInterval = 45

    enum Answer: Equatable {
        case yes
        case next
        case back
        case again
        case later
        case notUseful
        case dismiss
        case readIt
        case stop

        /// What `text` answers, or nil when it is not an answer (it then goes to the model).
        static func parse(_ text: String) -> Answer? {
            let core = PreparedCardSpokenStack.normalized(text)
            if stopWords.contains(core) { return .stop }
            if againWords.contains(core) { return .again }
            if let command = PreparedCardVoiceCommand.parse(text) {
                switch command {
                case .next, .nextCard: return .next
                case .back: return .back
                case .later: return .later
                case .notUseful: return .notUseful
                case .dismiss: return .dismiss
                case .close: return .stop
                case .readIt: return .readIt
                case .sendOnPhone: return .yes
                }
            }
            switch RemoteActionVoiceConsent.interpret(text) {
            case true?: return .yes
            case false?: return .next
            case nil: return nil
            }
        }

        static let stopWords: Set<String> = [
            "stop", "stop it", "stop reading", "cancel", "thats all", "that is all", "thats it", "that is it",
            "enough", "nothing else", "no more", "close", "done",
        ]
        static let againWords: Set<String> = ["again", "say again", "say that again", "repeat", "repeat that", "what"]
    }

    /// What the app does for an answer.
    enum Effect: Equatable {
        /// §6.4: put the card's draft on the phone.
        case stage(PreparedCardID)
        case later(PreparedCardID)
        case notUseful(PreparedCardID)
        case dismiss(PreparedCardID)
    }

    struct Step: Equatable {
        var effect: Effect?
        /// What to say after the effect (the effect's own line, if any, goes first).
        var say: String?
        /// The reading is still waiting for an answer.
        var awaiting: Bool
    }

    let cards: [PreparedCard]
    let phrases: [PreparedCardPhrase]
    /// Medical Compliance withholding, as it stood when the reading began.
    let withholding: Bool
    private(set) var index = 0
    private(set) var lastSpokeAt: Date
    private(set) var finished = false

    /// A reading of `cards`, or nil with none.
    init?(cards: [PreparedCard], withholding: Bool, now: Date,
          time: @escaping (Date) -> String = PreparedCardPhraser.shortTime) {
        guard !cards.isEmpty else { return nil }
        self.cards = cards
        self.withholding = withholding
        self.phrases = cards.map { PreparedCardPhraser.phrase($0, withholding: withholding, time: time) }
        self.lastSpokeAt = now
    }

    var current: PreparedCard? { cards.indices.contains(index) && !finished ? cards[index] : nil }

    /// Waiting for an answer, and not yet past the window.
    func isLive(at now: Date) -> Bool {
        !finished && now >= lastSpokeAt && now.timeIntervalSince(lastSpokeAt) <= Self.answerWindow
    }

    /// The first line: "Three things. First: …", or the one card on its own.
    func opening() -> String {
        guard let first = phrases.first?.text else { return "" }
        guard cards.count > 1 else { return first }
        return String(localized: "\(cards.count) things. First: \(first)",
                      comment: "Spoken: how many cards are ready, then the first one.")
    }

    /// The last line was said at `now`: the answer window starts here.
    mutating func noteSpoke(at now: Date) { lastSpokeAt = now }

    /// The wearer's answer.
    mutating func answer(_ answer: Answer) -> Step {
        guard let card = current else { return Step(effect: nil, say: nil, awaiting: false) }
        switch answer {
        case .yes:
            guard phrases[index].offersStage else { return advance() }
            return advance(effect: .stage(card.id))
        case .next:
            return advance()
        case .later:
            return advance(effect: .later(card.id))
        case .notUseful:
            return advance(effect: .notUseful(card.id))
        case .dismiss:
            return advance(effect: .dismiss(card.id))
        case .back:
            guard index > 0 else { return Step(effect: nil, say: phrases[index].text, awaiting: true) }
            index -= 1
            return Step(effect: nil, say: phrases[index].text, awaiting: true)
        case .again:
            return Step(effect: nil, say: phrases[index].text, awaiting: true)
        case .readIt:
            let reading = PreparedCardPhraser.draftReading(card, withholding: withholding) ?? phrases[index].text
            let follow = phrases[index].offer.map { " " + $0 } ?? ""
            return Step(effect: nil, say: reading + follow, awaiting: true)
        case .stop:
            finished = true
            return Step(effect: nil, say: Self.stoppedLine, awaiting: false)
        }
    }

    private mutating func advance(effect: Effect? = nil) -> Step {
        index += 1
        guard index < cards.count else {
            finished = true
            return Step(effect: effect, say: cards.count > 1 ? Self.endLine : nil, awaiting: false)
        }
        let lead = index == cards.count - 1
            ? String(localized: "Last one: \(phrases[index].text)", comment: "Spoken: the last ready card, read after the others.")
            : String(localized: "Next: \(phrases[index].text)", comment: "Spoken: the next ready card.")
        return Step(effect: effect, say: lead, awaiting: true)
    }

    static var endLine: String {
        String(localized: "That's everything.", comment: "Spoken: every ready card has been read.")
    }
    static var stoppedLine: String {
        String(localized: "OK. They're on My Day.", comment: "Spoken: the wearer stopped the cards being read; they are still on the phone.")
    }
    static var nothingLine: String {
        String(localized: "Nothing's ready right now.", comment: "Spoken: there are no prepared cards.")
    }

    /// Lowercased, punctuation gone, filler at the front dropped — the cards' own matching.
    static func normalized(_ text: String) -> String {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ").map(String.init)
        let filler: Set<String> = ["ok", "okay", "hey", "uh", "um", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        while let last = core.last, last == "please" { core.removeLast() }
        return core.joined(separator: " ")
    }
}
