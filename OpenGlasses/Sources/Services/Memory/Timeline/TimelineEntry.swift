import Foundation

/// Plan KK — one dated note about a run of a thread's saved messages that the request no longer
/// carries word for word.
///
/// A note is derived text, never a record: the saved messages it was made from stay in the thread
/// unchanged, and readings and procedure state keep living in the job record. It names its span by
/// message id rather than by index, so an edit, a regenerate or an erasure can tell exactly which
/// notes it invalidates, and it carries its dates so the model reads it in order and a job floor
/// can leave it out.
struct TimelineEntry: Codable, Equatable, Sendable {

    /// A chunk is made from saved messages; a merged entry from four older entries, when enough
    /// have piled up that keeping each one costs more than it tells.
    enum Tier: String, Codable, Sendable {
        case chunk
        case merged
    }

    let id: String
    let firstMessageID: String
    let lastMessageID: String
    let startedAt: Date
    let endedAt: Date
    let tier: Tier
    let text: String
}

/// A saved message reduced to what the timeline's arithmetic needs. No text: coverage, chunking and
/// merging decide on ids, order, time and size, so the policies that run most often never touch
/// the wearer's words.
struct TimelineMessage: Equatable, Sendable {
    let id: String
    let role: String
    let timestamp: Date
    let estimatedTokens: Int

    init(id: String, role: String, timestamp: Date, estimatedTokens: Int) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.estimatedTokens = estimatedTokens
    }

    /// Sized with the estimate the request budget uses for a text message, so "about 5k tokens
    /// have left" here means the same thing it means to `APIHistoryBudget`.
    init(_ message: ConversationMessage) {
        self.init(id: message.id, role: message.role, timestamp: message.timestamp,
                  estimatedTokens: HistoryHygiene.estimatedTokens(
                    forMessage: ["role": message.role, "content": message.content]))
    }

    /// Only the wearer's words and the replies count. A system line is the app talking to itself,
    /// and tool output never reaches the saved thread at all.
    var isConversational: Bool { role == "user" || role == "assistant" }

    /// A thread's messages as the timeline sees them: in order, user and assistant only.
    static func reduce(_ messages: [ConversationMessage]) -> [TimelineMessage] {
        messages.map { TimelineMessage($0) }.filter(\.isConversational)
    }
}

extension TimelineEntry {
    /// The entry's span as positions in `messageIDs`, or nil when either end is no longer there
    /// (or the ends are out of order). An unresolvable span covers nothing: what it summarised can
    /// no longer be shown to be what the thread still says.
    func span(in positions: [String: Int]) -> ClosedRange<Int>? {
        guard let first = positions[firstMessageID], let last = positions[lastMessageID],
              first <= last else { return nil }
        return first...last
    }

    /// Position of each id. A thread's ids are unique; if one ever repeats, the first wins.
    static func positions(of messageIDs: [String]) -> [String: Int] {
        var positions: [String: Int] = [:]
        for (index, id) in messageIDs.enumerated() where positions[id] == nil {
            positions[id] = index
        }
        return positions
    }
}
