import CryptoKit
import Foundation

// MARK: - Plan BQ P2 — content-index models
//
// OpenGlasses content (notes, summaries, locations, scripts, …) becomes findable in
// Spotlight / semantic search via `IndexedEntity` donation. These models are the pure
// substrate: what a donated record looks like, and which content types the user exposes.
// Never candidates, by design: Health Vault / medical data, face-recognition people,
// memory-rewind audio, agent diary. `Config.hipaaMode` hard-disables all donation.

/// A content family the user can expose to Spotlight.
enum SiriContentType: String, Codable, CaseIterable {
    case note
    case meetingSummary = "meeting_summary"
    case savedLocation = "saved_location"
    case teleprompterScript = "teleprompter_script"
    case playbook
    case studyDeck = "study_deck"
    case readingSession = "reading_session"
    case conversation
    case fieldSession = "field_session"

    var displayLabel: String {
        switch self {
        case .note: return String(localized: "Notes")
        case .meetingSummary: return String(localized: "Meeting Summaries")
        case .savedLocation: return String(localized: "Saved Locations")
        case .teleprompterScript: return String(localized: "Teleprompter Scripts")
        case .playbook: return String(localized: "Playbooks")
        case .studyDeck: return String(localized: "Study Decks")
        case .readingSession: return String(localized: "Reading Sessions")
        case .conversation: return String(localized: "Conversations")
        case .fieldSession: return String(localized: "Field Sessions")
        }
    }

    /// Conversations and field sessions are privacy-sensitive → opt-in. Everything else
    /// defaults on.
    var defaultEnabled: Bool {
        switch self {
        case .conversation, .fieldSession: return false
        default: return true
        }
    }
}

/// One indexable item, normalized across all content stores. `text` may be empty for
/// metadata-only donation (field sessions never donate audit-log bodies).
struct IndexableRecord: Codable, Equatable, Identifiable {
    let contentType: SiriContentType
    let itemId: String
    let title: String
    let text: String
    let keywords: [String]
    let date: Date?

    /// Composite Spotlight identifier, stable across re-donations.
    var id: String { "\(contentType.rawValue):\(itemId)" }

    /// Change-detection fingerprint for `IndexPlanner` — re-donate only what changed.
    var contentHash: String {
        var hasher = SHA256()
        for field in [title, text, keywords.joined(separator: "|")] {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))
        }
        if let date {
            var interval = date.timeIntervalSince1970
            hasher.update(data: Data(bytes: &interval, count: MemoryLayout<Double>.size))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Persisted content-index selections (own Config key, separate from the P1 action config
/// so neither migrates when the other grows).
///
/// Default-on types store *disabled* ids (a new type ships exposed without migration);
/// opt-in types store *enabled* ids. Field sessions are opted in **per vault**, never
/// globally — the compliance boundary is the vault.
struct SiriContentIndexConfig: Codable, Equatable {
    var disabledTypes: Set<String> = []
    var optInTypes: Set<String> = []
    /// Vault ids whose (metadata-only) field sessions may be donated.
    var fieldSessionVaults: Set<String> = []

    init(
        disabledTypes: Set<String> = [],
        optInTypes: Set<String> = [],
        fieldSessionVaults: Set<String> = []
    ) {
        self.disabledTypes = disabledTypes
        self.optInTypes = optInTypes
        self.fieldSessionVaults = fieldSessionVaults
    }

    func isEnabled(_ type: SiriContentType) -> Bool {
        switch type {
        case .fieldSession:
            return !fieldSessionVaults.isEmpty
        default:
            return type.defaultEnabled
                ? !disabledTypes.contains(type.rawValue)
                : optInTypes.contains(type.rawValue)
        }
    }
}

/// Deep-link payload an `OpenGlassesContentIntent` hands to the app (Spotlight result →
/// content detail).
struct SiriContentLink: Identifiable, Equatable {
    let id: String
    let typeLabel: String
    let title: String
    let text: String
    let date: Date?
}
