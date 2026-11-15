import Foundation

/// How a private conversation was started (Plan LU §1).
enum PrivateEntry: String, Equatable, Sendable, CaseIterable {
    /// "Off the record", or another start phrase, at the start of a spoken turn.
    case voicePhrase
    /// Start a private conversation, from the conversation page's header menu or the Chat list.
    case button
    /// The watch's Private button.
    case watch
}

/// Whether the wearer is in a private conversation: one Avenkin keeps nothing of (Plan LU §1).
///
/// In memory only. The id is random and is never written to disk, UserDefaults, a log or a trace;
/// the only record a private conversation leaves is a content-free `PrivacyLog` line saying that
/// one started and why it ended. `AppState` owns the one instance, and its only writers are
/// `beginPrivate(entry:)` and `endPrivate(reason:)` (P1).
enum PrivateConversationState: Equatable, Sendable {
    case inactive
    case active(id: UUID, startedAt: Date, entry: PrivateEntry)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var id: UUID? {
        if case .active(let id, _, _) = self { return id }
        return nil
    }

    var startedAt: Date? {
        if case .active(_, let startedAt, _) = self { return startedAt }
        return nil
    }

    var entry: PrivateEntry? {
        if case .active(_, _, let entry) = self { return entry }
        return nil
    }
}

/// The private conversation's turns, held in memory and nowhere else (Plan LU §1).
///
/// It hands the model the same `(role, content)` pairs that `ConversationStore.replayMessages(for:)`
/// returns for a stored thread, so the request is built exactly as it is for any other conversation.
/// Ending the private conversation empties it; nothing else holds the messages.
struct PrivateTranscript: Equatable, Sendable {

    /// One turn. A struct rather than a tuple so the transcript can be compared in tests.
    struct Turn: Equatable, Sendable {
        let role: String
        let content: String
        let at: Date
    }

    private(set) var turns: [Turn] = []

    init() {}

    var isEmpty: Bool { turns.isEmpty }
    var count: Int { turns.count }

    /// When the last turn was added: what the 30-minute quiet gap is measured from. Nil before the
    /// first turn.
    var lastTurnAt: Date? { turns.last?.at }

    mutating func append(role: String, content: String, at: Date = Date()) {
        turns.append(Turn(role: role, content: content, at: at))
    }

    /// The messages in the shape `ConversationStore.replayMessages(for:)` returns.
    func replayMessages() -> [(role: String, content: String)] {
        turns.map { (role: $0.role, content: $0.content) }
    }

    /// Drops every turn. Called when the private conversation ends.
    mutating func clear() {
        turns.removeAll()
    }
}
