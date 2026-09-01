import Foundation

/// Orchestrates the Personal Health-Safety Advisor (Plan AB): grounds in the user's
/// Health Vault, runs the deterministic `InteractionRubric` (authoritative), grounds
/// the LLM long-tail in the selected entries, and composes an answer that always
/// cites its sources and disclaims. `@MainActor` because it reads the vault + LLM;
/// all the decision logic lives in the pure core (catalog/grounding/rubric/builder),
/// so this layer stays thin. Gated behind the Medical Compliance entitlement.
@MainActor
final class HealthSafetyAdvisor {
    static let shared = HealthSafetyAdvisor()

    /// Injected by AppState for the grounded long-tail. When nil, the deterministic
    /// rubric + grounding answer still stands (the model is never required).
    var llm: LLMService?

    private let grounding = VaultGrounding()
    private let rubric = InteractionRubric()
    private static let vaultId = "health"

    private init() {}

    /// True when the Health Vault is unlocked (Medical Compliance subscription).
    var isAvailable: Bool { VaultRegistry.shared.isUnlocked(Self.vaultId) }

    /// Evaluate a query and return the composed, cited, disclaimed answer.
    func evaluate(_ query: HealthSafetyQuery) async -> String {
        guard VaultRegistry.shared.isUnlocked(Self.vaultId) else {
            return "The Health-Safety advisor needs the Medical Compliance subscription, which unlocks your Health Vault."
        }
        guard let store = VaultRegistry.shared.store(forId: Self.vaultId) else {
            return "Your Health Vault is unavailable."
        }

        let medsText = store.read("medications.md") ?? ""
        let conditionsText = store.read("conditions.md") ?? ""
        let allergiesText = allergyLines(in: store)

        if medsText.isEmpty && conditionsText.isEmpty && allergiesText.isEmpty {
            return "Your Health Vault has no medications, conditions, or allergies recorded yet — add them so I can check \"\(query.subject)\" against your profile.\n\n\(HealthSafetyResponseBuilder.disclaimer)"
        }

        let context = grounding.relevantEntries(
            for: query, medicationsText: medsText, conditionsText: conditionsText, allergiesText: allergiesText)

        let hits: [InteractionRubric.Hit]
        let recognized: Bool
        switch query.kind {
        case .canITake:
            let substance = SubstanceCatalog.substance(from: query.matchText)
            hits = rubric.check(substance, against: context)
            recognized = substance.isClassified
        case .canIEat:
            let tags = SubstanceCatalog.foodTags(in: query.matchText)
            hits = rubric.checkFood(tags, against: context)
            recognized = !tags.isEmpty
        }

        let advisory = await llmAdvisory(for: query, context: context, hasAuthoritative: HealthSafetyResponseBuilder.hasAuthoritativeWarning(hits))
        let citations = citationFiles(medsText: medsText, conditionsText: conditionsText, allergiesText: allergiesText)
        return HealthSafetyResponseBuilder.compose(subject: query.subject, hits: hits, subjectRecognized: recognized, llmAdvisory: advisory, citations: citations)
    }

    // MARK: - LLM long tail (grounded, stateless)

    private func llmAdvisory(for query: HealthSafetyQuery, context: GroundingContext, hasAuthoritative: Bool) async -> String? {
        guard let llm, !context.citedLines.isEmpty else { return nil }
        let verb = query.kind == .canITake ? "take" : "eat"
        let system = """
        You are a cautious health-safety assistant. Using ONLY the user's vault entries below, give at most \
        two sentences on whether it's reasonable for them to \(verb) "\(query.subject)". Do not invent facts \
        not in the entries. \(hasAuthoritative ? "A serious interaction has already been flagged deterministically — reinforce caution, never say it is safe." : "") \
        Never give a definitive medical instruction; this is advisory.

        VAULT ENTRIES:
        \(context.citedLines.joined(separator: "\n"))
        """
        let user = query.kind == .canITake
            ? "Can I take \(query.subject)?"
            : "Can I eat \(query.subject)?"
        guard let raw = try? await llm.completeStateless(user, system: system) else { return nil }

        // Retrieve-or-silence gate (Plan CJ item 3): the advisory is grounded ONLY in the user's
        // vault entries — no guideline text was retrieved — so any external-authority citation
        // the model free-formed is unverifiable. Withhold it from speech and queue it for review
        // (the field-session audit log when one is active; always the console).
        let gated = CitationGate.scrub(raw)
        if !gated.queuedCitations.isEmpty {
            PrivacyLog.medical(.healthSafety, .citationsWithheld,
                               count: gated.queuedCitations.count)
            FieldSessionService.shared.logAssistantMessage(
                "Withheld unverified citation claims from health-safety advisory for \"\(query.subject)\"",
                citations: gated.queuedCitations)
        }
        return gated.spokenText.isEmpty ? nil : gated.spokenText
    }

    // MARK: - Vault helpers

    /// Allergies have no dedicated vault file; gather any line mentioning an allergy
    /// across all health-vault files.
    private func allergyLines(in store: VaultStore) -> String {
        store.readAll()
            .flatMap { $0.contents.components(separatedBy: .newlines) }
            .filter { $0.lowercased().contains("allerg") }
            .joined(separator: "\n")
    }

    private func citationFiles(medsText: String, conditionsText: String, allergiesText: String) -> [String] {
        var files: [String] = []
        if !medsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { files.append("medications") }
        if !conditionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { files.append("conditions") }
        if !allergiesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { files.append("allergies") }
        return files
    }
}
