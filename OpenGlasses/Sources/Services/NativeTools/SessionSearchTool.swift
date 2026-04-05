import Foundation

/// Searches past conversation sessions for relevant context.
/// Enables cross-session recall: "what did we discuss about X last week?"
struct SessionSearchTool: NativeTool {
    let name = "session_search"
    let description = "Search past conversations for relevant context. Use when the user references a previous discussion, asks 'what did we talk about', or needs to recall something from an earlier session."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Keywords to search for in past conversations"
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

        let keywords = query.lowercased().split(separator: " ").map(String.init)
        guard !keywords.isEmpty else {
            return "No valid search keywords provided."
        }

        // Access MainActor-isolated properties
        let threads = await MainActor.run { store.threads }
        let activeId = await MainActor.run { store.activeThreadId }

        // Score each thread by keyword match density
        var scored: [(thread: ConversationThread, score: Int, matchedMessages: [ConversationMessage])] = []

        for thread in threads {
            guard !thread.messages.isEmpty else { continue }
            // Skip the currently active thread (the user is asking about *past* sessions)
            if thread.id == activeId { continue }

            var threadScore = 0
            var matched: [ConversationMessage] = []

            // Check title and summary first
            let titleLower = thread.title.lowercased()
            let summaryLower = (thread.summary ?? "").lowercased()
            for kw in keywords {
                if titleLower.contains(kw) { threadScore += 3 }
                if summaryLower.contains(kw) { threadScore += 2 }
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

            if let summary = thread.summary {
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
}
