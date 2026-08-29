import Foundation
import Combine

/// A recall result: a synthesized answer plus the conversation turns it was drawn from.
struct RecallAnswer: Equatable {
    let summary: String
    let citations: [RecallHit]
    var isEmpty: Bool { citations.isEmpty }
}

/// Cross-session recall (Phase 2): searches the lock-scoped recall coordinator and summarizes the top
/// turns into a cited answer. The summarizer is an injectable seam (wired in `AppState` to the
/// user's active provider via `LLMService.completeStateless` — which honors on-device models),
/// so the search→answer flow is unit-testable without a model. Shared singleton like
/// `BrainStore` / `StudyService`.
@MainActor
final class RecallService: ObservableObject {
    static let shared = RecallService()

    private var coordinator: ConversationRecallCoordinator?
    /// (question, hits) → answer text. Injected by `configure`; nil → a plain bulleted fallback.
    var summarize: ((String, [RecallHit]) async -> String)?

    var isConfigured: Bool { coordinator != nil }

    init() {}

    func configure(coordinator: ConversationRecallCoordinator,
                   summarize: @escaping (String, [RecallHit]) async -> String) {
        self.coordinator = coordinator
        self.summarize = summarize
    }

    /// Raw search with an explicit availability state. Callers must not turn locked, rebuilding,
    /// or unavailable into a misleading empty-history answer.
    func search(_ phrase: String, now: Date = Date(), limit: Int = 12) -> ConversationRecallSearchResult {
        coordinator?.search(phrase, now: now, limit: limit) ?? .unavailable
    }

    /// Search + summarize into a cited answer.
    func recall(_ question: String, now: Date = Date()) async -> RecallAnswer {
        let hits: [RecallHit]
        switch search(question, now: now, limit: 8) {
        case .locked:
            return RecallAnswer(summary: "Your conversations are locked. Unlock them to search past conversations.",
                                citations: [])
        case .rebuilding:
            return RecallAnswer(summary: "Conversation recall is rebuilding after unlock. Try again shortly.",
                                citations: [])
        case .unavailable:
            return RecallAnswer(summary: "Conversation recall is temporarily unavailable.", citations: [])
        case .ready(let readyHits, _):
            hits = readyHits
        }
        guard !hits.isEmpty else {
            return RecallAnswer(
                summary: "I couldn't find anything about that in our past conversations.",
                citations: []
            )
        }
        let summary = await summarize?(question, hits) ?? Self.fallbackSummary(hits)
        return RecallAnswer(summary: summary, citations: hits)
    }

    /// Bulleted snippets — used when no summarizer is wired (or it fails).
    static func fallbackSummary(_ hits: [RecallHit]) -> String {
        hits.prefix(5).map { "• \($0.snippet)" }.joined(separator: "\n")
    }

    /// The prompt the configured summarizer runs: answer strictly from the cited excerpts.
    static func summarizationPrompt(question: String, hits: [RecallHit]) -> (system: String, user: String) {
        let excerpts = hits.enumerated().map { i, hit in
            "[\(i + 1)] (\(hit.role), \(RecallTimestamp.string(from: hit.timestamp))) \(hit.text)"
        }.joined(separator: "\n")
        let system = """
        You answer the user's question using ONLY the excerpts from their past conversations \
        below. Be concise and conversational. Cite excerpts inline like [1]. If the excerpts \
        don't actually answer the question, say you couldn't find it.
        """
        let user = "Question: \(question)\n\nPast conversation excerpts:\n\(excerpts)"
        return (system, user)
    }
}
