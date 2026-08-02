import Foundation

/// Category-only privacy reporting for vision prompts (Plan CJ item 4).
///
/// `PrivacyFilterService` protects *pixels* (face blur); this is the *words* side: the model
/// must report **that** a sensitive item is visible — as a closed-enum category — while being
/// schema- and prompt-forbidden from transcribing its content. The `sensitive_items` field
/// accepts only the enum values below (nothing free-form can ride in it), and the prompt
/// fragment forbids leaking contents into any other field.
///
/// Pure helpers: augmentation happens at the `StructuredVisionService.assess` chokepoint, so
/// every registered vertical gets the capability without touching each schema; the assistive
/// free-text path appends the same fragment.
enum AssessmentPrivacy {

    /// The closed category vocabulary. Free-form values are rejected on parse.
    static let categories = [
        "payment_card", "id_document", "prescription", "screen", "handwriting", "mail_or_label",
    ]

    /// The language-side guarantee, appended to a vision system prompt.
    static let promptFragment = """
    PRIVACY (category-only reporting): if a sensitive item is visible — a payment card, an ID \
    document, a prescription, someone's personal screen, handwriting, or mail/address label — \
    report it ONLY as a category in `sensitive_items`. NEVER transcribe, quote, paraphrase, or \
    describe its contents anywhere in your output: no numbers, names, addresses, codes, or \
    partial values, in any field.
    """

    /// JSON-Schema property for `sensitive_items`: enum-only, so the reporting channel itself
    /// cannot carry transcribed content.
    static var sensitiveItemsProperty: [String: Any] {
        [
            "type": "array",
            "items": ["type": "string", "enum": categories],
            "description": "Categories of sensitive items visible in frame. Categories only — never their contents.",
        ]
    }

    /// Augmented copies of a schema's prompt + JSON schema. Non-destructive: a schema that
    /// already declares `sensitive_items` keeps its own definition.
    static func augment(systemPrompt: String, jsonSchema: [String: Any])
        -> (systemPrompt: String, jsonSchema: [String: Any]) {
        var schema = jsonSchema
        if var properties = schema["properties"] as? [String: Any], properties["sensitive_items"] == nil {
            properties["sensitive_items"] = sensitiveItemsProperty
            schema["properties"] = properties
        }
        return (systemPrompt + "\n\n" + promptFragment, schema)
    }

    /// The reported categories from a model payload — unknown values are dropped, order kept,
    /// duplicates removed.
    static func reportedCategories(in json: [String: Any]) -> [String] {
        guard let raw = json["sensitive_items"] as? [String] else { return [] }
        var seen = Set<String>()
        return raw.filter { categories.contains($0) && seen.insert($0).inserted }
    }

    /// Card findings for the reported categories — how the flag surfaces to the user without
    /// any card-type change.
    static func findings(for reported: [String]) -> [AssessmentFinding] {
        reported.map {
            AssessmentFinding(label: "Privacy: \(displayName($0)) visible",
                              detail: "Contents not read", severity: .caution, confidence: 1.0)
        }
    }

    static func displayName(_ category: String) -> String {
        switch category {
        case "payment_card": return "payment card"
        case "id_document": return "ID document"
        case "prescription": return "prescription"
        case "screen": return "personal screen"
        case "handwriting": return "handwriting"
        case "mail_or_label": return "mail or address label"
        default: return category
        }
    }
}

extension AssessmentCard {
    /// A copy with extra findings appended (fields are immutable by design).
    func addingFindings(_ extra: [AssessmentFinding]) -> AssessmentCard {
        guard !extra.isEmpty else { return self }
        return AssessmentCard(kind: kind, title: title, subtitle: subtitle, tier: tier,
                              summary: summary, findings: findings + extra,
                              recommendedAction: recommendedAction, stillNeeded: stillNeeded,
                              readings: readings, confidence: confidence, disclaimer: disclaimer)
    }
}
