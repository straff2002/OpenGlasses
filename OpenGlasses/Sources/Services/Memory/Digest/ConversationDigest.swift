import Foundation

/// Plan LQ §1 — a short, model-written note of a finished conversation: one headline and up to
/// five points, kept on the thread it describes.
///
/// It lives on `ConversationThread` for the reason the timeline does: encryption, the save guards,
/// the 200-thread cap, the retention setting, `deleteThread` and `deleteAllThreads` all cover it
/// without new code, and it goes when the thread goes. It is derived text, never a fact: it is not
/// written to semantic memory or the brain, never pushed to the gateway, and never carried in the
/// thread's own requests (the timeline does that job). It is how *other* conversations find this one.
struct ConversationDigest: Codable, Equatable, Sendable {

    /// What a point says about the conversation.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case decided
        case learned
        case toDo
        case askedAbout
    }

    struct Point: Codable, Equatable, Sendable {
        let kind: Kind
        let text: String
    }

    /// Which kind of model wrote it, for the log and the badge.
    enum Tier: String, Codable, Sendable {
        case cloud
        case onDevice
    }

    /// One line, at most `maximumHeadlineCharacters`.
    let headline: String
    /// At most `maximumPoints`, each at most `maximumPointCharacters`.
    let points: [Point]
    /// The last saved message the note describes. Messages after it are a new tail, which earns
    /// a resumed conversation one rewrite.
    let coversThroughMessageID: String
    let writtenAt: Date
    let tier: Tier
    /// Set by a forget or a person erasure: the text is gone and the note is never written again.
    /// Nil on an ordinary note, so a saved one only grows for the threads that carry it.
    var redacted: Bool? = nil

    static let maximumHeadlineCharacters = 90
    static let maximumPoints = 5
    static let maximumPointCharacters = 160

    var isRedacted: Bool { redacted == true }

    /// The headline to show in place of the word-prefix summary, or nil for a forgotten note.
    var visibleHeadline: String? {
        guard !isRedacted else { return nil }
        let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The note's words as one searchable text: the headline, then each point on its own line.
    /// Empty for a forgotten note.
    var searchableText: String {
        guard let headline = visibleHeadline else { return "" }
        return ([headline] + points.map(\.text)).joined(separator: "\n")
    }

    /// This note with its text gone and its coverage kept, so it is not written again.
    func redacting() -> ConversationDigest {
        ConversationDigest(headline: "", points: [], coversThroughMessageID: coversThroughMessageID,
                           writtenAt: writtenAt, tier: tier, redacted: true)
    }

    /// The id the note's row has in the recall index. One per thread, so a rewrite replaces it.
    static func recallRowID(threadID: String) -> String { "digest:\(threadID)" }

    /// The role a note's recall row carries, so a hit can be told from a turn.
    static let recallRole = "note"
}

extension ConversationThread {
    /// What the Chat list, the watch and Siri show under the title: the note's headline when the
    /// conversation has one, the word-prefix summary otherwise (Plan LQ §6).
    var listSummary: String? {
        if let headline = digest?.visibleHeadline { return headline }
        return summary
    }
}

/// Plan LQ §6 — the recall index row a thread's note adds, or nil when it has none to show.
enum ConversationDigestRecallRow {
    static func turn(for thread: ConversationThread) -> IndexedTurn? {
        guard let digest = thread.digest else { return nil }
        let text = digest.searchableText
        guard !text.isEmpty else { return nil }
        return IndexedTurn(id: ConversationDigest.recallRowID(threadID: thread.id), threadID: thread.id,
                           role: ConversationDigest.recallRole, text: text, timestamp: digest.writtenAt)
    }
}

/// One point of one thread's note, named for removal: what a fact's forget sheet lists when the
/// note mentions the fact (Plan LQ §8).
struct ConversationDigestPointReference: Equatable, Hashable, Sendable {
    let threadID: String
    let text: String
}
