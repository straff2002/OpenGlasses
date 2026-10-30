import Foundation

/// Pure orchestration of one web-grounded re-ask (Plan BI): search → splice results into a
/// grounding prompt → regenerate **exactly once** (no loops, bounded latency). Any failure —
/// empty search, search throw, regenerate throw, empty regeneration — falls back to the
/// original answer, so the gate is never worse than doing nothing.
///
/// Conversation-aware (field-traced failure): a follow-up like "what about the other semi
/// final?" is a useless literal search query — no tournament, no sport — and a grounding prompt
/// that never shows the model what was already said can't reconcile the new results with its
/// earlier (possibly incomplete) answer. So: context-dependent questions are first rewritten
/// into a self-contained query via the caller's model, and the grounding prompt carries the
/// recent exchanges.
///
/// The transparency prefix means a re-grounded answer is never silently swapped in for the
/// model's own — consistent with the project's no-silent-fallback stance.
///
/// It searches without going through the router, so `NativeToolRouter`'s gate never sees it. A job
/// on a vault-only vault (Plan KE) is therefore a required argument: no caller can leave it out.
enum UncertaintyReask {

    static let transparencyPrefix = "Checked the web for that — "

    /// A question that can't stand alone as a search query: too short to name its subject, or
    /// leaning on anaphora ("the other one", "what about them"). Pure heuristic, cheap, testable.
    /// The length trigger is ≤2 words — a 3-word question can carry its own subject ("who won
    /// Wimbledon") and must NOT be rewritten against possibly-unrelated history, while
    /// elliptical stubs ("who won?", "and tomorrow?") must be.
    static func isContextDependent(_ question: String) -> Bool {
        let lowered = question.lowercased()
        let words = lowered
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.count <= 2 { return true }
        if lowered.contains("what about") || lowered.contains("how about") { return true }
        let anaphors: Set<String> = ["other", "that", "it", "they", "them", "this", "those",
                                     "he", "she", "him", "her", "its", "their", "else", "again"]
        return words.contains { anaphors.contains($0) }
    }

    /// Compact recent-conversation block for prompts (last `maxTurns` turns, each clipped) —
    /// enough for the model to resolve "the other one", small enough not to crowd the budget.
    static func conversationBlock(history: [(role: String, content: String)],
                                  maxTurns: Int = 4, clipTo: Int = 300) -> String {
        history.suffix(maxTurns).map { turn in
            "\(turn.role == "assistant" ? "Assistant" : "User"): \(String(turn.content.prefix(clipTo)))"
        }.joined(separator: "\n")
    }

    /// Normalize a model-rewritten search query: first line only, surrounding quotes and a
    /// "query:"-style prefix stripped. Returns nil when the result is empty or implausibly long
    /// (the model answered instead of rewriting) — callers then fall back to the raw question.
    static func cleanedRewrittenQuery(_ raw: String?) -> String? {
        guard var q = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return nil }
        q = String(q.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        if let colon = q.range(of: "query:", options: [.caseInsensitive, .anchored]) {
            q = String(q[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        guard !q.isEmpty, q.count <= 120 else { return nil }
        return q
    }

    static func answer(
        question: String,
        originalAnswer: String,
        vaultOnly: Bool,
        history: [(role: String, content: String)] = [],
        search: (String) async throws -> String?,
        rewriteQuery: ((String) async throws -> String)? = nil,
        regenerate: (String) async throws -> String
    ) async -> String {
        // A sealed job searches nothing, and the query is not even rewritten.
        guard !vaultOnly else { return originalAnswer }

        // Contextualize the search query when the question leans on the conversation. Any
        // rewrite failure (throw, empty, rambling) falls back to the raw question — the gate
        // never gets worse than the old behaviour.
        var searchQuery = question
        if !history.isEmpty, isContextDependent(question), let rewriteQuery,
           let rewritten = cleanedRewrittenQuery(try? await rewriteQuery(question)) {
            searchQuery = rewritten
        }

        // Search failed, threw, or came back empty → the original answer stands.
        let searched = (try? await search(searchQuery)) ?? nil
        guard let results = searched?.trimmingCharacters(in: .whitespacesAndNewlines),
              !results.isEmpty else {
            return originalAnswer
        }

        let convo = conversationBlock(history: history)
        let grounding = """
        \(convo.isEmpty ? "" : "Recent conversation:\n\(convo)\n\n")Web search results for "\(searchQuery)":

        \(results)

        Using these results where they are relevant\(convo.isEmpty ? "" : " — and staying consistent with the recent conversation above (correct it if the results show it was incomplete or wrong)"), \
        answer the user's question concisely. If the results don't actually answer it, say so briefly.
        Question: \(question)
        """

        // Exactly one regeneration; a throw or empty reply falls back to the original.
        guard let regenerated = (try? await regenerate(grounding))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !regenerated.isEmpty else {
            return originalAnswer
        }
        return transparencyPrefix + regenerated
    }
}
