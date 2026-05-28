import Foundation

/// Assembles the system-prompt addendum for an active vault.
///
/// The output is concatenated into `LLMService.buildSystemPrompt` via the same
/// pattern as `VoiceSkillStore.shared.promptContext()` / `InstalledSkillStore.shared.promptContext()`.
enum VaultPromptBuilder {

    /// Build the prompt addendum for a vault. Returns nil when the vault is empty.
    static func promptContext(for store: VaultStore) -> String? {
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
        for (filename, contents) in files {
            lines.append("=== \(filename) ===")
            lines.append(contents.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
