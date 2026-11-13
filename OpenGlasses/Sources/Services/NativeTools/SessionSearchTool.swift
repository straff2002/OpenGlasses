import Foundation

/// Searches past conversation sessions for relevant context.
/// Enables cross-session recall: "what did we discuss about X last week?"
struct SessionSearchTool: NativeTool {
    let name = "session_search"
    let description = "Find an earlier conversation by its topic words ('boiler', 'Lisbon trip') and show its title and a few excerpts. To answer a question about what was said, including 'yesterday' or 'last week', use brain with action 'recall' instead."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Topic words to find the conversation by, e.g. 'boiler service'"
            ],
            "max_results": [
                "type": "integer",
                "description": "Maximum number of matching sessions to return (default: 3)"
            ]
        ],
        "required": ["query"]
    ]

    weak var conversationStore: ConversationStore?

    init(conversationStore: ConversationStore) {
        self.conversationStore = conversationStore
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Please provide a search query."
        }
        let maxResults = args["max_results"] as? Int ?? 3

        guard let store = conversationStore else {
            return "Conversation store not available."
        }

        // Plan LP §7: the question's own words ("what did we discuss about", "yesterday") are not
        // topic words — matched as substrings they found every conversation. Stripped the way
        // recall strips them; a date they named narrows the conversations searched.
        let parsed = FTSQueryBuilder.searchTerms(in: query)
        let keywords = parsed.terms
        guard !keywords.isEmpty || parsed.since != nil else {
            return "Give a topic word or two to find the conversation by."
        }

        // Access MainActor-isolated properties
        let threads = await MainActor.run { store.threads }
            .filter { Self.isInWindow($0.updatedAt, since: parsed.since, until: parsed.until) }
        let activeId = await MainActor.run { store.activeThreadId }

        // Score each thread by keyword match density
        var scored: [(thread: ConversationThread, score: Int, matchedMessages: [ConversationMessage])] = []

        for thread in threads {
            guard !thread.messages.isEmpty else { continue }
            // Skip the currently active thread (the user is asking about *past* sessions)
            if thread.id == activeId { continue }

            var threadScore = 0
            var matched: [ConversationMessage] = []

            // Check title and summary first. Plan LQ §6: a conversation's note is scored the way
            // the word-prefix summary is, its headline and each point, and stands in for it.
            let titleLower = thread.title.lowercased()
            let summaryFields = Self.summaryFields(of: thread).map { $0.lowercased() }
            for kw in keywords {
                if titleLower.contains(kw) { threadScore += 3 }
                for field in summaryFields where field.contains(kw) { threadScore += 2 }
            }

            // Search message content
            for msg in thread.messages {
                let contentLower = msg.content.lowercased()
                var msgScore = 0
                for kw in keywords {
                    if contentLower.contains(kw) { msgScore += 1 }
                }
                if msgScore > 0 {
                    threadScore += msgScore
                    matched.append(msg)
                }
            }

            // With no topic words left, a date alone finds the conversations it names.
            if keywords.isEmpty { threadScore = 1 }
            if threadScore > 0 {
                scored.append((thread, threadScore, matched))
            }
        }

        guard !scored.isEmpty else {
            return "No past conversations found matching '\(query)'."
        }

        // Sort by score descending, take top results
        let topResults = scored.sorted { $0.score > $1.score }.prefix(maxResults)

        var output: [String] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for result in topResults {
            let thread = result.thread
            let date = dateFormatter.string(from: thread.updatedAt)
            var section = "**\(thread.title)** (\(date))"

            if let note = Self.noteSection(for: thread) {
                section += "\n" + note
            } else if let summary = thread.summary {
                section += "\nSummary: \(summary)"
            }

            // Include up to 3 most relevant message excerpts
            let excerpts = result.matchedMessages.prefix(3)
            if !excerpts.isEmpty {
                section += "\nRelevant excerpts:"
                for msg in excerpts {
                    let role = msg.role == "user" ? "You" : "Assistant"
                    let excerpt = String(msg.content.prefix(200))
                    let truncated = msg.content.count > 200 ? "..." : ""
                    section += "\n  [\(role)] \(excerpt)\(truncated)"
                }
            }

            output.append(section)
        }

        let header = "Found \(scored.count) matching conversation\(scored.count == 1 ? "" : "s") (showing top \(topResults.count)):\n"
        return header + output.joined(separator: "\n\n")
    }

    /// What is scored as the conversation's summary: its note's headline and points when it has
    /// one, the word-prefix summary otherwise.
    static func summaryFields(of thread: ConversationThread) -> [String] {
        if let digest = thread.digest, let headline = digest.visibleHeadline {
            return [headline] + digest.points.map(\.text)
        }
        return thread.summary.map { [$0] } ?? []
    }

    /// The note, dated, inside the same envelope saved memory goes back in: it was written by a
    /// model from text that may have come from outside, so it is data, never an instruction.
    static func noteSection(for thread: ConversationThread) -> String? {
        guard let digest = thread.digest, let headline = digest.visibleHeadline else { return nil }
        let date = digest.writtenAt.formatted(date: .abbreviated, time: .omitted)
        let lines = ["Note (\(date)): \(headline)"] + digest.points.map { "- \($0.text)" }
        return PromptInjectionPolicy.wrap(toolName: "conversation_note", content: lines.joined(separator: "\n"))
    }

    /// Whether a conversation last touched at `date` falls in [since, until). Open ends match.
    static func isInWindow(_ date: Date, since: Date?, until: Date?) -> Bool {
        if let since, date < since { return false }
        if let until, date >= until { return false }
        return true
    }
}
