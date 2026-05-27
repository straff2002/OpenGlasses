import Foundation

/// Semantic memory search — lets the agent retrieve relevant memories by meaning
/// rather than exact key lookup.
///
/// Usage: `memory_search` with a natural language query.
/// Returns the top matching memories with their topics and timestamps.
struct MemorySearchTool: NativeTool {
    let name = "memory_search"
    let description = "Search your memory about the user using natural language. Returns the most relevant stored facts, preferences, and observations by semantic similarity — not just exact matches. Use this before making personalised recommendations or when the user references something from the past."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "What you want to recall — e.g. 'user's health issues', 'food preferences', 'work projects'"
            ],
            "limit": [
                "type": "integer",
                "description": "Max results to return (default 5, max 15)"
            ],
            "topic": [
                "type": "string",
                "description": "Optional topic filter: health, work, people, places, preferences, finance, learning, general"
            ]
        ],
        "required": ["query"]
    ]

    weak var memoryStore: SemanticMemoryStore?

    func execute(args: [String: Any]) async throws -> String {
        guard let store = memoryStore else {
            return "Memory search unavailable."
        }

        let query = args["query"] as? String ?? ""
        guard !query.isEmpty else { return "Provide a query to search memory." }

        let limit = min(args["limit"] as? Int ?? 5, 15)
        let topicFilter = args["topic"] as? String

        var results = await MainActor.run { store.semanticSearch(query: query, limit: limit) }

        if let topic = topicFilter {
            results = results.filter { $0.topic == topic }
        }

        guard !results.isEmpty else {
            return "No relevant memories found for: \(query)"
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none

        let lines = results.map { r -> String in
            let age = df.string(from: r.createdAt)
            return "[\(r.topic)] \(r.keyName): \(r.value)  (stored \(age))"
        }

        return "Memory search results for '\(query)':\n" + lines.joined(separator: "\n")
    }
}
