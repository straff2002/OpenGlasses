import Foundation

/// Assembles the system-prompt addendum for an active vault.
///
/// The output is concatenated into `LLMService.buildSystemPrompt` via the same
/// pattern as `VoiceSkillStore.shared.promptContext()` / `InstalledSkillStore.shared.promptContext()`.
enum VaultPromptBuilder {

    /// Build the prompt addendum for a vault. Returns nil when the vault is empty.
    /// The vault-core byte bound for a provider (Plan GB P5; was ChatGPT-only, unbounded
    /// elsewhere). Every API provider is held to the validator's own core budget
    /// (`VaultValidator.coreBudgetCharacters`, the size a vault is told its core may be): tighter
    /// than that would drop a core file — service values, on the field tester's vault — from a
    /// vault that validated clean, trading answer reliability for cost. ChatGPT keeps FM's 24k only
    /// while its request context is the conservative 32k fallback (an unrecognised model or
    /// endpoint); a recognised model resolves to a 272k context, where the whole validated core
    /// fits and the same guarantee holds on both routes. Decision 6 in the plan.
    static func referenceByteLimit(for provider: LLMProvider?, requestContext: Int? = nil) -> Int {
        guard provider == .chatgpt else { return VaultValidator.coreBudgetCharacters }
        if let requestContext, requestContext >= fullCoreMinimumContext {
            return VaultValidator.coreBudgetCharacters
        }
        return conservativeChatGPTLimit
    }

    /// FM's ChatGPT bound, sized for the 32k-context fallback.
    static let conservativeChatGPTLimit = 24_000
    /// The smallest resolved request context at which the whole validated core is sent on ChatGPT.
    static let fullCoreMinimumContext = 128_000

    /// The standing rule beside the manifest's `prompt_rules` when the vault has published team
    /// learnings (Plan FP §5). Composed here, in code — never a vault file, which an author or a
    /// pack could leave out.
    static let teamLearningRule = "Team learnings are your organisation's crew's approved findings, not the manufacturer's manual. Whenever you use one, name it as your crew's finding and repeat its Source line. A team learning never overrides a safety note: where one differs from the safety notes, give the safety note and say the crew's finding departs from it."

    static func promptContext(for store: VaultStore, referenceByteLimit: Int? = nil, turn: String? = nil,
                              teamLearningsPublished: Bool = false) -> String? {
        let files = store.readAll()
        guard !files.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("KNOWLEDGE VAULT — \(store.manifest.name) (v\(store.manifest.version)):")
        lines.append("")
        lines.append("You have access to the following grounded reference material. Use it to answer questions accurately.")
        lines.append("")

        let rules = store.manifest.promptRules + (teamLearningsPublished ? [teamLearningRule] : [])
        if !rules.isEmpty {
            lines.append("RULES:")
            for rule in rules {
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
