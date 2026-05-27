import Foundation

/// Agent diary — lets the agent record and recall its own observations, decisions,
/// and learnings across sessions, separate from user memory.
///
/// Write: agent logs what it noticed, did, or learned.
/// Read: agent retrieves recent or topically relevant diary entries.
///
/// Diary entries are injected back via [DIARY: ...] command parsing,
/// or explicitly via this tool.
struct AgentDiaryTool: NativeTool {
    let name = "agent_diary"
    let description = "Record or recall agent observations and learnings. Write entries to remember what you noticed, decided, or did. Read entries to recall your own history and stay consistent across sessions. Separate from user memory — this is your private journal."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["write", "read", "search"],
                "description": "'write' to log an observation, 'read' to get recent entries, 'search' to find relevant past entries"
            ],
            "text": [
                "type": "string",
                "description": "The observation or event to record (required for write)"
            ],
            "query": [
                "type": "string",
                "description": "What to search for in past diary entries (required for search)"
            ],
            "limit": [
                "type": "integer",
                "description": "Max entries to return for read/search (default 5)"
            ]
        ],
        "required": ["action"]
    ]

    weak var memoryStore: SemanticMemoryStore?

    func execute(args: [String: Any]) async throws -> String {
        guard let store = memoryStore else { return "Diary unavailable." }

        let action = args["action"] as? String ?? "read"
        let limit = min(args["limit"] as? Int ?? 5, 20)

        switch action {
        case "write":
            guard let text = args["text"] as? String, !text.isEmpty else {
                return "Provide 'text' to write a diary entry."
            }
            await MainActor.run { store.writeDiary(text) }
            return "Diary entry recorded."

        case "search":
            guard let query = args["query"] as? String, !query.isEmpty else {
                return "Provide 'query' to search diary."
            }
            let entries = await MainActor.run { store.relevantDiary(for: query, limit: limit) }
            return formatEntries(entries, label: "Diary search: '\(query)'")

        default: // "read"
            let entries = await MainActor.run { store.readDiary(limit: limit) }
            return formatEntries(entries, label: "Recent diary entries")
        }
    }

    private func formatEntries(_ entries: [SemanticMemoryStore.DiaryEntry], label: String) -> String {
        guard !entries.isEmpty else { return "No diary entries found." }
        let df = RelativeDateTimeFormatter()
        df.unitsStyle = .full
        let lines = entries.map { "[\(df.localizedString(for: $0.createdAt, relativeTo: Date()))] \($0.text)" }
        return "\(label):\n" + lines.joined(separator: "\n")
    }
}
