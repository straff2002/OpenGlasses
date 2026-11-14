import Foundation

// MARK: - The activity trail (Plan IW P0)
//
// One record of one thing the assistant did, held for you, or was stopped from doing. The trail
// records the assistant's actions only: never a read, never the conversation, never the wearer's
// words. It links to the operation journal, turn traces and threads by `refs` rather than copying
// them.
//
// Every enum here persists as an explicit string. Entries written today must still read after an
// app update renames a case, so no case name or ordinal ever reaches the disk.

/// What sort of record an entry is. Drives the "counts by kind" opening of a spoken summary.
enum ActivityKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// A side-effecting tool call made in a turn.
    case action = "action"
    /// One step of a multi-step plan.
    case plannedStep = "planned_step"
    /// One run of a scheduled task.
    case scheduledRun = "scheduled_run"
    /// Something said to the wearer straight away, so it never reached the digest.
    case toldYou = "told_you"
    /// An action kept back until the wearer is there to approve it.
    case held = "held"
    /// An action the authorization floor stopped.
    case refused = "refused"
}

/// How the action was authorised. Persisted as `asked`, `standing_grant:<scope>`, `read_only`,
/// `held_for_you`, `refused:<reason>` or `scheduled`.
enum ActivityAuthorisation: Equatable, Sendable {
    /// The wearer asked for it, or approved it when asked.
    case asked
    /// It ran under a permission the wearer gave earlier, for this scope.
    case standingGrant(scope: String)
    /// The integration is read-only, so the action was turned away.
    case readOnly
    /// Kept for the wearer to approve.
    case heldForYou
    /// Stopped by the floor; `reason` is a stable code such as a `ToolRefusalReason` raw value,
    /// never free text.
    case refused(reason: String)
    /// A scheduled task the wearer set up ran it.
    case scheduled

    var codeValue: String {
        switch self {
        case .asked: return "asked"
        case .standingGrant(let scope): return "standing_grant:\(scope)"
        case .readOnly: return "read_only"
        case .heldForYou: return "held_for_you"
        case .refused(let reason): return "refused:\(reason)"
        case .scheduled: return "scheduled"
        }
    }

    init?(codeValue: String) {
        switch codeValue {
        case "asked": self = .asked
        case "read_only": self = .readOnly
        case "held_for_you": self = .heldForYou
        case "scheduled": self = .scheduled
        default:
            if let scope = Self.suffix(of: codeValue, after: "standing_grant:") {
                self = .standingGrant(scope: scope)
            } else if let reason = Self.suffix(of: codeValue, after: "refused:") {
                self = .refused(reason: reason)
            } else {
                return nil
            }
        }
    }

    init(refusal: ToolRefusalReason) { self = .refused(reason: refusal.rawValue) }

    fileprivate static func suffix(of value: String, after prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        let rest = String(value.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }
}

/// Where the request came from. Persisted as `wearer`, `scheduled`, `agent` or `remote:<source>`.
enum ActivityOrigin: Equatable, Sendable {
    case wearer
    case scheduled
    case agent
    case remote(source: String)

    var codeValue: String {
        switch self {
        case .wearer: return "wearer"
        case .scheduled: return "scheduled"
        case .agent: return "agent"
        case .remote(let source): return "remote:\(source)"
        }
    }

    init?(codeValue: String) {
        switch codeValue {
        case "wearer": self = .wearer
        case "scheduled": self = .scheduled
        case "agent": self = .agent
        default:
            guard let source = ActivityAuthorisation.suffix(of: codeValue, after: "remote:") else {
                return nil
            }
            self = .remote(source: source)
        }
    }
}

/// How it ended.
enum ActivityOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    case done = "done"
    case failed = "failed"
    /// It may have happened; the journal could not say (a lost race against the timeout).
    case uncertain = "uncertain"
    /// Nothing happens until the wearer answers.
    case waitingOnYou = "waiting_on_you"
}

/// How a held entry was answered after it was held (Plan LE §3). Written by the recorder when the
/// held operation reaches the authorization boundary again (P1); absent on every entry recorded
/// before it existed, and on every entry still waiting.
enum ActivityResolution: String, Codable, Equatable, Sendable, CaseIterable {
    /// The wearer said yes when the operation came back to them.
    case approved = "approved"
    /// The wearer said no.
    case declined = "declined"
    /// It outlived its operation's own expiry without an answer.
    case expired = "expired"
}

/// A link from an entry (or a goal step) to the record that holds the detail. Persisted as
/// `operation:<id>`, `trace:<id>`, `thread:<id>` or `goal:<id>`.
enum ActivityRef: Hashable, Sendable {
    case operation(String)
    case trace(String)
    case thread(String)
    case goal(String)

    var codeValue: String {
        switch self {
        case .operation(let id): return "operation:\(id)"
        case .trace(let id): return "trace:\(id)"
        case .thread(let id): return "thread:\(id)"
        case .goal(let id): return "goal:\(id)"
        }
    }

    init?(codeValue: String) {
        let pairs: [(String, (String) -> ActivityRef)] = [
            ("operation:", ActivityRef.operation), ("trace:", ActivityRef.trace),
            ("thread:", ActivityRef.thread), ("goal:", ActivityRef.goal),
        ]
        for (prefix, make) in pairs {
            if let id = ActivityAuthorisation.suffix(of: codeValue, after: prefix) {
                self = make(id)
                return
            }
        }
        return nil
    }
}

// MARK: - String codecs

private func decodeCode<T>(_ decoder: Decoder, _ make: (String) -> T?, _ what: String) throws -> T {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let value = make(raw) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown \(what)")
    }
    return value
}

extension ActivityAuthorisation: Codable {
    init(from decoder: Decoder) throws {
        self = try decodeCode(decoder, ActivityAuthorisation.init(codeValue:), "authorisation")
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codeValue)
    }
}

extension ActivityOrigin: Codable {
    init(from decoder: Decoder) throws {
        self = try decodeCode(decoder, ActivityOrigin.init(codeValue:), "origin")
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codeValue)
    }
}

extension ActivityRef: Codable {
    init(from decoder: Decoder) throws {
        self = try decodeCode(decoder, ActivityRef.init(codeValue:), "reference")
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codeValue)
    }
}

// MARK: - Entry

/// One line of the trail.
struct ActivityEntry: Codable, Equatable, Sendable, Identifiable {
    static let titleLength = 100
    static let detailLength = 200

    let id: UUID
    let at: Date
    let kind: ActivityKind
    /// Past tense, second person, in the assistant's voice: "Added the dentist to your calendar".
    let title: String
    /// The tool's own summary or a scheduled result's lead — never the wearer's words.
    let detail: String?
    let tool: String?
    let goalID: UUID?
    let stepID: UUID?
    let authorisation: ActivityAuthorisation
    let origin: ActivityOrigin
    var outcome: ActivityOutcome
    let refs: [ActivityRef]
    /// When a held entry was answered (Plan LE §3). Nil while it waits, and on old entries.
    var resolvedAt: Date?
    /// How it was answered. `outcome` keeps what was true when the entry was written; this says
    /// what became of it.
    var resolution: ActivityResolution?

    /// Still waiting on the wearer: waiting when written, and not answered since. The only test
    /// "is this waiting on you?" — a resolved held entry never is.
    var isAwaitingWearer: Bool {
        outcome == .waitingOnYou && resolution == nil && resolvedAt == nil
    }

    /// The same entry, answered.
    func resolved(_ resolution: ActivityResolution, at date: Date) -> ActivityEntry {
        var copy = self
        copy.resolution = resolution
        copy.resolvedAt = date
        return copy
    }

    /// Over-long text is shortened rather than refused: an entry is a record that something
    /// happened, and losing the record would hide the action.
    init(id: UUID, at: Date, kind: ActivityKind, title: String, detail: String? = nil,
         tool: String? = nil, goalID: UUID? = nil, stepID: UUID? = nil,
         authorisation: ActivityAuthorisation, origin: ActivityOrigin,
         outcome: ActivityOutcome, refs: [ActivityRef] = [],
         resolvedAt: Date? = nil, resolution: ActivityResolution? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = Self.clamp(title, to: Self.titleLength)
        self.detail = detail.map { Self.clamp($0, to: Self.detailLength) }.flatMap { $0.isEmpty ? nil : $0 }
        self.tool = tool
        self.goalID = goalID
        self.stepID = stepID
        self.authorisation = authorisation
        self.origin = origin
        self.outcome = outcome
        self.refs = refs
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, kind, title, detail, tool, goalID, stepID, authorisation, origin, outcome, refs
        case resolvedAt, resolution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  at: try container.decode(Date.self, forKey: .at),
                  kind: try container.decode(ActivityKind.self, forKey: .kind),
                  title: try container.decode(String.self, forKey: .title),
                  detail: try container.decodeIfPresent(String.self, forKey: .detail),
                  tool: try container.decodeIfPresent(String.self, forKey: .tool),
                  goalID: try container.decodeIfPresent(UUID.self, forKey: .goalID),
                  stepID: try container.decodeIfPresent(UUID.self, forKey: .stepID),
                  authorisation: try container.decode(ActivityAuthorisation.self, forKey: .authorisation),
                  origin: try container.decode(ActivityOrigin.self, forKey: .origin),
                  outcome: try container.decode(ActivityOutcome.self, forKey: .outcome),
                  refs: try container.decodeIfPresent([ActivityRef].self, forKey: .refs) ?? [],
                  resolvedAt: try container.decodeIfPresent(Date.self, forKey: .resolvedAt),
                  // A resolution a later version wrote and this one cannot name still marks the
                  // entry answered (through `resolvedAt`); it never fails the whole trail.
                  resolution: (try? container.decodeIfPresent(ActivityResolution.self, forKey: .resolution)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(at, forKey: .at)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(goalID, forKey: .goalID)
        try container.encodeIfPresent(stepID, forKey: .stepID)
        try container.encode(authorisation, forKey: .authorisation)
        try container.encode(origin, forKey: .origin)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(refs, forKey: .refs)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(resolution, forKey: .resolution)
    }

    static func clamp(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
