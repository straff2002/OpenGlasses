import Foundation

// Plan KT §1 — a prepared card: one suggestion, the reasons for it and the one thing to do about
// it, ready to go. Pure data, Foundation only, and compiled into both the phone and the watch
// (listed in `project.watch.yml`), so the phone that builds a card and the wrist that shows it
// read the same types.
//
// Four rules make the model safe to fill from untrusted sources (§1):
// 1. a rule picks the recipient (`DraftRecipient.source`), never a model;
// 2. a rule picks the action, never a model — a model only ever writes `PreparedDraft.text`;
// 3. every time, duration, price and count on a card comes from the source rows;
// 4. everything has an end (`validUntil`): an expired card is removed, never shown greyed.

/// My Day's urgency ladder (Plan DY), unchanged. It lives here rather than beside `MyDayItem` so
/// that a prepared card, which the watch also decodes, can carry it.
enum MyDayUrgency: Int, Codable, Comparable, Equatable, Sendable {
    case routine = 0
    case upcoming = 1
    case important = 2
    case immediate = 3

    static func < (lhs: MyDayUrgency, rhs: MyDayUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The catalogue of §2. Declaration order is the tie-break order within one urgency and due time.
enum PreparedCardKind: String, Codable, CaseIterable, Comparable, Sendable {
    // Field Assist
    case jobRunningLate
    case jobOnMyWay
    case jobReportOwed
    case jobPartsOwed
    case jobSignOffOwed
    // Personal
    case runningLate
    case leaveBy
    case shortNight
    case meetingFollowUp
    case fitItIn

    var isJobKind: Bool {
        switch self {
        case .jobRunningLate, .jobOnMyWay, .jobReportOwed, .jobPartsOwed, .jobSignOffOwed: true
        case .runningLate, .leaveBy, .shortNight, .meetingFollowUp, .fitItIn: false
        }
    }

    /// Off until the wearer turns it on (decision 4: short night is opt-in).
    var isOptIn: Bool { self == .shortNight }

    /// The order the catalogue declares, for ranking.
    var catalogueIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: PreparedCardKind, rhs: PreparedCardKind) -> Bool {
        lhs.catalogueIndex < rhs.catalogueIndex
    }
}

/// `kind` plus an occurrence key built from the source ids (`leaveBy:<eventId>:<yyyy-MM-dd>`).
/// A refresh that rebuilds the same card builds the same id, so the card keeps its state, its
/// edited draft and its place. Encoded as its one-string `rawValue`, which is also the store key.
struct PreparedCardID: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let kind: PreparedCardKind
    let occurrence: String

    init(kind: PreparedCardKind, occurrence: String) {
        self.kind = kind
        self.occurrence = occurrence
    }

    init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":"),
              let kind = PreparedCardKind(rawValue: String(rawValue[..<colon])) else { return nil }
        self.init(kind: kind, occurrence: String(rawValue[rawValue.index(after: colon)...]))
    }

    var rawValue: String { "\(kind.rawValue):\(occurrence)" }
    var description: String { rawValue }

    static func < (lhs: PreparedCardID, rhs: PreparedCardID) -> Bool { lhs.rawValue < rhs.rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = PreparedCardID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Not a prepared card id")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A row on a page a card replaces (§3.3): a My Day item (`source` is its `MyDaySource` raw value)
/// or a job-day row (`source` is `jobDay`, `rawValue` the row's id). Strings, so the watch can
/// decode it without either page's types.
struct CardRowID: Codable, Hashable, Comparable, Sendable {
    static let jobDaySource = "jobDay"

    let source: String
    let rawValue: String

    init(source: String, rawValue: String) {
        self.source = source
        self.rawValue = rawValue
    }

    static func jobDay(_ rowID: String) -> CardRowID { .init(source: jobDaySource, rawValue: rowID) }

    static func < (lhs: CardRowID, rhs: CardRowID) -> Bool {
        (lhs.source, lhs.rawValue) < (rhs.source, rhs.rawValue)
    }
}

/// Where a chip's reason came from. Decides its icon on every surface.
enum CardSource: String, Codable, CaseIterable, Sendable {
    case calendar
    case reminders
    case travel
    case weather
    case sleep
    case location
    case meeting
    case job
}

/// Where a card, a chip or a draft may show and be spoken (§6.6). Ordered: the strictest wins.
enum CardSensitivity: Int, Codable, Comparable, Sendable {
    /// Calendar, travel, weather, jobs.
    case ordinary = 0
    /// A meeting follow-up; a draft's text.
    case personal = 1
    /// Sleep.
    case health = 2

    static func < (lhs: CardSensitivity, rhs: CardSensitivity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A chip: one reason the card exists. ≤ 24 characters.
struct CardSignal: Codable, Equatable, Sendable {
    static let maximumLength = 24

    let source: CardSource
    let text: String
    let sensitivity: CardSensitivity

    init(source: CardSource, text: String, sensitivity: CardSensitivity = .ordinary) {
        self.source = source
        self.text = PreparedCardText.clipped(text, to: Self.maximumLength)
        self.sensitivity = sensitivity
    }
}

/// A label/value row: "Doors" "19:00".
struct CardFact: Codable, Equatable, Sendable {
    let label: String
    let value: String
}

/// How the wearer is travelling, for directions. Mirrors My Day's transport modes.
enum CardTravelMode: String, Codable, CaseIterable, Sendable {
    case walking
    case driving
    case transit
}

/// How a draft leaves the phone (§7.1).
enum DraftChannel: String, Codable, CaseIterable, Sendable {
    case messages
    case email
    case whatsapp
}

/// Which rule chose the recipient. There is no case for "a model chose it": a draft whose
/// recipient was not set by a rule cannot be built (§1 rule 1).
enum DraftRecipientSource: String, Codable, CaseIterable, Sendable {
    case calendarOrganiser
    case calendarAttendee
    case jobCustomer
    case meetingAttendees
}

/// Who a draft goes to: a display name and the addresses (phone numbers or email addresses) the
/// rule found, and where it found them.
struct DraftRecipient: Codable, Equatable, Sendable {
    let name: String
    let addresses: [String]
    let source: DraftRecipientSource

    init(name: String, addresses: [String], source: DraftRecipientSource) {
        self.name = name
        self.addresses = addresses
        self.source = source
    }
}

/// Who wrote the draft's text. P0 writes templates only.
enum DraftOrigin: Codable, Equatable, Sendable {
    case template
    case onDevice
    case cloud(provider: String)
}

/// A drafted message, shown in full before anything can be handed off.
struct PreparedDraft: Codable, Equatable, Sendable {
    let channel: DraftChannel
    let recipient: DraftRecipient
    /// Email only.
    let subject: String?
    /// Editable on the phone; the edit is kept (§5.4).
    var text: String
    let origin: DraftOrigin
    /// BCP 47: the wearer's language, or the contact's when known.
    let language: String

    init(channel: DraftChannel, recipient: DraftRecipient, subject: String? = nil, text: String,
         origin: DraftOrigin = .template, language: String) {
        self.channel = channel
        self.recipient = recipient
        self.subject = subject
        self.text = text
        self.origin = origin
        self.language = language
    }
}

/// Points an action at the card's own draft, and says through which channel it leaves.
struct PreparedDraftRef: Codable, Hashable, Sendable {
    let channel: DraftChannel
}

/// A person to call.
struct ContactRef: Codable, Hashable, Sendable {
    let name: String
    let phone: String
}

/// An event a card proposes adding: shown, confirmed, then written through EventKit.
struct ProposedEvent: Codable, Hashable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let location: String?
}

/// What a card's buttons do. A rule picks these, never a model (§1 rule 2).
enum PreparedAction: Codable, Equatable, Sendable {
    /// Open the composer with the card's draft (§7).
    case handOff(PreparedDraftRef)
    case directions(destination: String, mode: CardTravelMode)
    case openEvent(id: String)
    case openJob(id: String)
    /// Field Assist's own report composer, as `JobDayDestination.send`.
    case openReport(sessionId: String)
    case openPartsOrder(sessionId: String)
    /// The finished job's page, where the customer signs.
    case getSignOff(sessionId: String)
    case addToCalendar(ProposedEvent)
    case call(ContactRef)
    case complete(reminderId: String)
    /// §3.5.
    case later
    case dismiss
}

/// §1.
struct PreparedCard: Codable, Equatable, Identifiable, Sendable {
    static let headlineLimit = 40
    static let subjectLimit = 60
    static let maximumSignals = 3
    static let maximumFacts = 4
    static let maximumSecondary = 2

    let id: PreparedCardID
    var kind: PreparedCardKind { id.kind }
    /// "Leave by 18:15", ≤ 40 characters.
    let headline: String
    /// "Gig at the Town Hall", ≤ 60.
    let subject: String?
    /// The chips: why this card exists, 1–3.
    var signals: [CardSignal]
    /// Label/value rows, 0–4.
    var facts: [CardFact]
    /// The one obvious thing.
    let primary: PreparedAction
    /// 0–2 more.
    let secondary: [PreparedAction]
    /// Present when an action sends something.
    var draft: PreparedDraft?
    let urgency: MyDayUrgency
    /// When it matters.
    let dueAt: Date?
    /// After this it is gone, not stale.
    let validUntil: Date
    let sensitivity: CardSensitivity
    /// The rows it replaces on the page (§3.3).
    var absorbs: [CardRowID]

    init(id: PreparedCardID, headline: String, subject: String?, signals: [CardSignal],
         facts: [CardFact], primary: PreparedAction, secondary: [PreparedAction] = [],
         draft: PreparedDraft? = nil, urgency: MyDayUrgency, dueAt: Date?, validUntil: Date,
         sensitivity: CardSensitivity = .ordinary, absorbs: [CardRowID] = []) {
        self.id = id
        self.headline = PreparedCardText.clipped(headline, to: Self.headlineLimit)
        self.subject = subject.map { PreparedCardText.clipped($0, to: Self.subjectLimit) }
        self.signals = Array(signals.prefix(Self.maximumSignals))
        self.facts = Array(facts.prefix(Self.maximumFacts))
        self.primary = primary
        self.secondary = Array(secondary.prefix(Self.maximumSecondary))
        self.draft = draft
        self.urgency = urgency
        self.dueAt = dueAt
        self.validUntil = validUntil
        // A card is at least as sensitive as its most sensitive chip.
        self.sensitivity = max(sensitivity, signals.map(\.sensitivity).max() ?? .ordinary)
        self.absorbs = absorbs
    }

    enum CodingKeys: String, CodingKey {
        case id, headline, subject, signals, facts, primary, secondary, draft, urgency, dueAt,
             validUntil, sensitivity, absorbs
    }

    /// Every action the card offers, primary first.
    var actions: [PreparedAction] { [primary] + secondary }
}

enum PreparedCardText {
    /// Cuts `text` to `limit` characters, ending in "…" when it had to cut.
    static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 1 else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
