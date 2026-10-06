import Foundation

/// Voice-driven personal knowledge base ("second brain") over the generic `VaultStore`. The user
/// logs notes by voice and queries them later with grounded, cited answers. Free (no IAP gate).
@MainActor
final class NotesVaultTool: NativeTool {
    let name = "notes_vault"
    let description = """
    The user's personal notes / second brain. Use 'log' to remember something they say ("note that…", \
    "remember…", "add to my ideas…") and 'query' to recall it later ("what did I note about…", \
    "what's on my todos"). Answers only from their recorded notes — never invent notes.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "'query' to recall notes, or 'log' to add one."],
            "question": ["type": "string", "description": "On 'query': what to recall."],
            "file": ["type": "string", "description": "On 'log': 'general', 'people', 'ideas', or 'todos' (default 'general')."],
            "entry": ["type": "string", "description": "On 'log': the note text to append."]
        ],
        "required": ["action"]
    ]

    private static let vaultId = "notes"
    private static let files = ["general", "people", "ideas", "todos"]

    func execute(args: [String: Any]) async throws -> String {
        guard let store = VaultRegistry.shared.store(forId: Self.vaultId) else {
            return "Notes vault is unavailable."
        }
        switch (args["action"] as? String)?.lowercased() ?? "query" {
        case "log", "add", "remember":
            return log(args: args, store: store)
        default:
            return query(args: args, store: store)
        }
    }

    /// The line under every logged entry (Plan HQ P1 item 4): the entry's text is the model's
    /// rendering of what the wearer said, so the file says who wrote it. A fixed English marker —
    /// it lives in the wearer's Markdown, where a later read must find the same words.
    static let aiMarker = "_Written by Avenkin AI from your dictation._"

    /// An entry as it is appended: the text, then the marker on its own line.
    static func markedEntry(_ entry: String) -> String {
        "\(entry)\n\n\(aiMarker)"
    }

    func log(args: [String: Any], store: VaultStore) -> String {
        let fileKey = (args["file"] as? String)?.lowercased() ?? "general"
        let file = Self.files.contains(fileKey) ? fileKey : "general"
        guard let entry = (args["entry"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else {
            return "What should I note?"
        }
        do {
            try store.append("\(file).md", entry: Self.markedEntry(entry))
            return "Noted in \(file): \"\(entry)\"."
        } catch {
            return "Could not save the note: \(error.localizedDescription)"
        }
    }

    private func query(args: [String: Any], store: VaultStore) -> String {
        let question = (args["question"] as? String)?.lowercased() ?? ""
        let keywords = question.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }

        var matches: [(file: String, section: String)] = []
        for (filename, contents) in store.readAll() {
            for section in sections(in: contents) {
                let lower = section.lowercased()
                if keywords.isEmpty || keywords.contains(where: lower.contains) {
                    matches.append((filename, section))
                    if matches.count >= 6 { break }
                }
            }
            if matches.count >= 6 { break }
        }
        guard !matches.isEmpty else {
            return "I don't have any notes matching that. Want me to add one?"
        }
        let rendered = matches.map { "=== \($0.file) ===\n\($0.section)" }.joined(separator: "\n\n")
        let citation = Set(matches.map { $0.file }).sorted().joined(separator: ", ")
        return "\(rendered)\n\n(Source: \(citation))"
    }

    private func sections(in markdown: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(joined) }
            current = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") || line.hasPrefix("### ") { flush() }
            current.append(String(line))
        }
        flush()
        return out
    }
}
