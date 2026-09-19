import Foundation

/// Assembles the system-prompt addendum for an active vault.
///
/// The output is concatenated into `LLMService.buildSystemPrompt` via the same
/// pattern as `VoiceSkillStore.shared.promptContext()` / `InstalledSkillStore.shared.promptContext()`.
enum VaultPromptBuilder {

    /// Build the prompt addendum for a vault. Returns nil when the vault is empty.
    static func promptContext(for store: VaultStore, referenceByteLimit: Int? = nil, turn: String? = nil) -> String? {
        let files = store.readAll()
        guard !files.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("KNOWLEDGE VAULT — \(store.manifest.name) (v\(store.manifest.version)):")
        lines.append("")
        lines.append("You have access to the following grounded reference material. Use it to answer questions accurately.")
        lines.append("")

        if !store.manifest.promptRules.isEmpty {
            lines.append("RULES:")
            for rule in store.manifest.promptRules {
                lines.append("- \(rule)")
            }
            lines.append("")
        }

        if let format = store.manifest.sourceAttributionFormat {
            let requirement = store.manifest.sourceAttributionRequired
                ? "REQUIRED: every factual claim drawn from the vault must end with a source line in the form: \(format)"
                : "When drawing from the vault, cite the source like: \(format)"
            lines.append(requirement)
            lines.append("")
        }

        lines.append("VAULT CONTENTS:")
        lines.append("")
        let words = Set((turn ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 2 }.map(String.init))
        // Keep safety files and manifest rules intact; rank optional core references by the
        // current question. Entire files remain available to equipment_lookup if omitted here.
        let ordered = referenceByteLimit == nil ? files : files.enumerated().sorted { left, right in
            func score(_ file: (filename: String, contents: String)) -> Int {
                if file.filename.lowercased().contains("safety") { return Int.max }
                let text = (file.filename + " " + file.contents).lowercased()
                return words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            }
            let lhs = score(left.element), rhs = score(right.element)
            return lhs == rhs ? left.offset < right.offset : lhs > rhs
        }.map(\.element)
        var remaining = referenceByteLimit ?? Int.max
        var omitted: [String] = []
        for (filename, contents) in ordered {
            let protected = filename.lowercased().contains("safety")
            if !protected && contents.utf8.count > remaining {
                omitted.append(filename)
                continue
            }
            remaining = max(0, remaining - contents.utf8.count)
            lines.append("=== \(filename) ===")
            lines.append(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        if !omitted.isEmpty {
            lines.append("Core references omitted by the context budget: \(omitted.joined(separator: ", ")). Use equipment_lookup with a query and optional file to retrieve the relevant section before making a claim from these files. Omitted content is not evidence of absence; never assume a missing warning does not apply.")
        }

        return lines.joined(separator: "\n")
    }
}
