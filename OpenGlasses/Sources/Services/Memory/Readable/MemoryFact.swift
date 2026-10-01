import Foundation

// Plan GG (the first cut of Plan DX) — readable memory: what the assistant knows about the
// wearer, one fact at a time, read from the stores that already hold it. Nothing here is a copy:
// a `MemoryFact` is a view onto one row of one store, rebuilt on every read, and every mutation
// goes back to that store.

/// Which store a fact lives in. Part of the fact's identity, so the same words held by two stores
/// stay two facts with two honest deletes rather than one fact with an ambiguous one.
enum MemoryFactStore: String, Codable, CaseIterable, Sendable {
    /// A key/value fact in `SemanticMemoryStore` (`memories`), global or per persona.
    case semantic
    /// An agent diary observation in `SemanticMemoryStore` (`diary`). Inferred by construction.
    case diary
    /// A typed relation in `BrainStore` (`edges`).
    case brainEdge
    /// An open follow-up in `BrainStore` (`needs`).
    case brainNeed
    /// A project note in `BrainStore` (`project_memory`).
    case projectNote
    /// One line of the agent's own `memory.md` (`AgentDocumentStore`).
    case agentNote
    /// A remembered object location (`ObjectMemoryStore`).
    case object
    /// A saved place (`SavedLocationStore`).
    case savedPlace
}

/// Stable identity: the owning store plus that store's own record id.
struct MemoryFactID: Hashable, Codable, Sendable, Comparable {
    let store: MemoryFactStore
    let recordID: String

    var rendered: String { "\(store.rawValue):\(recordID)" }

    static func < (lhs: MemoryFactID, rhs: MemoryFactID) -> Bool { lhs.rendered < rhs.rendered }
}

/// Where a fact came from. Data, not copy: a row written before provenance existed reads as
/// `legacyUnknown` and is never upgraded to "you told me" by a guess.
enum MemoryOrigin: Hashable, Sendable {
    /// The wearer said it, and asked for it to be kept (or stated it to a tool that keeps it).
    case toldMe
    /// The assistant drew it from a conversation without being asked to keep it.
    case inferred
    /// An add-on (skill pack) wrote it.
    case fromAddOn(String)
    /// Taken from a meeting summary.
    case fromMeeting
    /// Read off something the wearer scanned or read — a badge, a page.
    case fromScan
    /// Brought in from elsewhere.
    case imported
    /// Written before the app recorded where facts came from.
    case legacyUnknown

    /// The column value. `nil` is what an unknown origin stores, so a legacy row and a row whose
    /// writer said nothing read back identically.
    var storageValue: String? {
        switch self {
        case .toldMe: return "told_me"
        case .inferred: return "inferred"
        case .fromAddOn(let id): return "add_on:\(id)"
        case .fromMeeting: return "meeting"
        case .fromScan: return "scan"
        case .imported: return "imported"
        case .legacyUnknown: return nil
        }
    }

    init(storageValue: String?) {
        switch storageValue {
        case "told_me": self = .toldMe
        case "inferred": self = .inferred
        case "meeting": self = .fromMeeting
        case "scan": self = .fromScan
        case "imported": self = .imported
        case let value? where value.hasPrefix("add_on:"):
            self = .fromAddOn(String(value.dropFirst("add_on:".count)))
        default: self = .legacyUnknown
        }
    }

    /// Whether the assistant decided this on its own. Drives the "inferred" badge and the
    /// tombstone rule: an inferred write of a forgotten fact is dropped, a told-me write wins.
    var isInferred: Bool { self == .inferred }
}

/// How the wearer thinks about their facts. Health sits apart and is collapsed by default.
enum MemoryFactGroup: String, CaseIterable, Sendable {
    case people, places, preferences, unfinished, other, health

    /// Display order on the phone: the four everyday groups, then the catch-all, then Health.
    static let displayOrder: [MemoryFactGroup] = [.people, .places, .preferences, .unfinished, .other, .health]
}

/// What a fact is, in the terms of the store that holds it — the input to grouping.
enum MemoryFactKind: Equatable, Sendable {
    /// A semantic fact and the topic `SemanticMemoryStore.detectTopic` gave it.
    case semantic(topic: String)
    case diary
    /// A brain relation, with its endpoint kinds ("person", "org", "place", …).
    case relation(relation: String, srcKind: String, dstKind: String)
    case need
    case projectNote
    case agentNote
    case object
    case savedPlace
}

/// What the wearer may do to a fact from the phone or by voice. A store that cannot change or
/// delete one record truthfully does not offer the action.
struct MemoryFactCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let correct = MemoryFactCapabilities(rawValue: 1 << 0)
    static let forget = MemoryFactCapabilities(rawValue: 1 << 1)
    static let all: MemoryFactCapabilities = [.correct, .forget]
}

/// One fact, as the wearer reads it. Bounded and rebuilt on every read; holds no embedding.
struct MemoryFact: Identifiable, Equatable, Sendable {
    let id: MemoryFactID
    /// The fact as a sentence ("sister city: Wellington", "Maria lives in Wellington").
    let text: String
    let kind: MemoryFactKind
    let origin: MemoryOrigin
    /// The conversation thread, meeting title, book or add-on the fact came from, when known.
    let sourceRef: String?
    let createdAt: Date
    let capabilities: MemoryFactCapabilities
    /// The persona a semantic fact belongs to; `nil` for shared (global) facts and other stores.
    let persona: String?
    /// The value a correction replaces — the semantic value, the relation's destination, the
    /// note's text. What "Actually, she lives in Nelson" swaps out.
    let correctableValue: String

    var group: MemoryFactGroup { MemoryFactGrouper.group(for: kind) }

    init(id: MemoryFactID, text: String, kind: MemoryFactKind, origin: MemoryOrigin,
         sourceRef: String? = nil, createdAt: Date,
         capabilities: MemoryFactCapabilities = .all, persona: String? = nil,
         correctableValue: String? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.origin = origin
        self.sourceRef = sourceRef
        self.createdAt = createdAt
        self.capabilities = capabilities
        self.persona = persona
        self.correctableValue = correctableValue ?? text
    }
}

// MARK: - Grouping

/// Pure: which group a fact belongs to. Every kind lands in exactly one group.
enum MemoryFactGrouper {

    static func group(for kind: MemoryFactKind) -> MemoryFactGroup {
        switch kind {
        case .semantic(let topic):
            switch topic {
            case "people": return .people
            case "places": return .places
            case "preferences": return .preferences
            case "health": return .health
            default: return .other   // work, finance, learning, general, and anything newer
            }
        case .diary, .agentNote:
            return .other
        case .relation(_, let srcKind, let dstKind):
            // A person and their edges are People & family; a relation between two non-people
            // (an org located in a city) is still a fact, just not about someone.
            return (srcKind == "person" || dstKind == "person") ? .people : .other
        case .need, .projectNote:
            return .unfinished
        case .object, .savedPlace:
            return .places
        }
    }

    /// Facts bucketed by group, each bucket newest first, groups in display order; empty groups
    /// are left out.
    static func grouped(_ facts: [MemoryFact]) -> [(group: MemoryFactGroup, facts: [MemoryFact])] {
        let buckets = Dictionary(grouping: facts, by: \.group)
        return MemoryFactGroup.displayOrder.compactMap { group in
            guard let bucket = buckets[group], !bucket.isEmpty else { return nil }
            return (group, MemoryFactRepository.ordered(bucket))
        }
    }
}
