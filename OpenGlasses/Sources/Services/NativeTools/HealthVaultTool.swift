import Foundation

/// Thin convenience wrapper over the generic `VaultStore` for the user's Personal Health Vault.
/// Grounds health questions in the user's own editable markdown (biometrics, conditions,
/// medications, etc.) and lets the user log new entries by voice. Gated by the Medical Compliance IAP.
@MainActor
final class HealthVaultTool: NativeTool {
    let name = "health_vault"
    let description = """
    Query or update the user's Personal Health Vault — their own notes on biometrics, conditions, \
    diet, lab results, medications, and wearables. Use 'query' to ground a health question in their \
    recorded data before answering (always cite the source file), and 'log' to record a new entry \
    (e.g. "log my blood pressure 120 over 80"). Only uses what the user has written — never \
    fabricate health data.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'query' to retrieve grounded health context, or 'log' to record a new entry."
            ],
            "question": [
                "type": "string",
                "description": "On 'query': the health question to ground (e.g. 'what medications am I taking?')."
            ],
            "file": [
                "type": "string",
                "description": "On 'log': which file — 'biometrics', 'conditions', 'dietary_context', 'lab_baselines', 'medications', or 'wearables'."
            ],
            "entry": [
                "type": "string",
                "description": "On 'log': the text to append (e.g. 'BP 120/80')."
            ]
        ],
        "required": ["action"]
    ]

    private static let vaultId = "health"
    private static let logFiles = ["biometrics", "conditions", "dietary_context", "lab_baselines", "medications", "wearables"]

    func execute(args: [String: Any]) async throws -> String {
        guard VaultRegistry.shared.isUnlocked(Self.vaultId) else {
            return "The Personal Health Vault is locked. It unlocks with the Medical Compliance subscription."
        }
        guard let store = VaultRegistry.shared.store(forId: Self.vaultId) else {
            return "Health vault is unavailable."
        }
        let action = (args["action"] as? String)?.lowercased() ?? "query"

        switch action {
        case "query":
            return query(args: args, store: store)
        case "log", "add":
            return log(args: args, store: store)
        default:
            return "Unknown action '\(action)'. Use 'query' or 'log'."
        }
    }

    // MARK: - Query

    private func query(args: [String: Any], store: VaultStore) -> String {
        let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keywords = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        var matches: [(file: String, section: String)] = []
        for (filename, contents) in store.readAll() {
            for section in sections(in: contents) {
                let lower = section.lowercased()
                if keywords.isEmpty || keywords.contains(where: lower.contains) {
                    matches.append((filename, section))
                    if matches.count >= 5 { break }
                }
            }
            if matches.count >= 5 { break }
        }

        if matches.isEmpty {
            let available = store.readAll().map { $0.filename }.joined(separator: ", ")
            return "No matching entries in the health vault. Available files: \(available.isEmpty ? "none yet — the vault is empty" : available). Ask the user to add the relevant detail, and never guess health facts."
        }

        let rendered = matches.map { "=== \($0.file) ===\n\($0.section)" }.joined(separator: "\n\n")
        let citation = Set(matches.map { $0.file }).sorted().joined(separator: ", ")
        return "\(rendered)\n\n(Source: \(citation))"
    }

    // MARK: - Log

    private func log(args: [String: Any], store: VaultStore) -> String {
        guard let fileKey = (args["file"] as? String)?.lowercased(), Self.logFiles.contains(fileKey) else {
            return "Specify a valid 'file': \(Self.logFiles.joined(separator: ", "))."
        }
        guard let entry = (args["entry"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else {
            return "Specify the 'entry' text to log."
        }
        do {
            try store.append("\(fileKey).md", entry: entry)
            return "Logged to \(fileKey): \"\(entry)\"."
        } catch {
            return "Could not log the entry: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Split markdown into `##`/`###` sections (keeping the top intro as one block).
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
