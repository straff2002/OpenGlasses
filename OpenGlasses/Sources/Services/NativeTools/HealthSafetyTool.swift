import Foundation

/// `health_check` — the Personal Health-Safety Advisor (Plan AB). Answers "Can I take
/// X?" and "Can I eat this?" grounded in the user's Health Vault, with a deterministic
/// high-severity interaction rubric backstopping the model. Advisory only; gated by
/// the Medical Compliance entitlement (the Health Vault unlock).
@MainActor
final class HealthSafetyTool: NativeTool {
    let name = "health_check"
    let description = """
    Check whether something is safe for THIS user given their Health Vault (medications, conditions, \
    allergies). Use 'can_i_take' for a drug/supplement ("can I take ibuprofen?") and 'can_i_eat' for a \
    food ("can I eat aged cheese?"). Cross-references known high-severity interactions deterministically \
    and grounds the rest in their vault — always cites the vault and reminds the user to confirm with a \
    pharmacist or doctor. Advisory only, never a definitive medical decision.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["can_i_take", "can_i_eat"],
                "description": "'can_i_take' for a medication/supplement, 'can_i_eat' for a food."
            ],
            "subject": [
                "type": "string",
                "description": "The substance or food in question (e.g. 'ibuprofen', 'aged cheese')."
            ],
            "label_text": [
                "type": "string",
                "description": "Optional: text read from a product/medication label to refine matching."
            ]
        ],
        "required": ["action", "subject"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.healthSafetyAdvisor) else {
            return AIFeatureGate.disabledMessage(.healthSafetyAdvisor)
        }
        let action = (args["action"] as? String)?.lowercased() ?? "can_i_take"
        let subject = (args["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !subject.isEmpty else {
            return "Tell me what to check — a medication ('can I take ibuprofen?') or a food ('can I eat aged cheese?')."
        }
        let label = (args["label_text"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let kind: HealthSafetyQuery.Kind = (action == "can_i_eat") ? .canIEat : .canITake
        let query = HealthSafetyQuery(kind: kind, subject: subject, capturedLabel: label)
        return await HealthSafetyAdvisor.shared.evaluate(query)
    }
}
