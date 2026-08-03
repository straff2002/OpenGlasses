import XCTest
@testable import OpenGlasses

/// Tests for category-only privacy reporting in vision prompts (Plan CJ item 4): schema/prompt
/// augmentation, closed-vocabulary parsing, and the card surfacing.
final class AssessmentPrivacyTests: XCTestCase {

    private let baseSchema: [String: Any] = [
        "type": "object",
        "properties": ["summary": ["type": "string"]],
        "required": ["summary"],
    ]

    func testAugmentAddsPropertyAndFragment() {
        let (prompt, schema) = AssessmentPrivacy.augment(systemPrompt: "Assess.", jsonSchema: baseSchema)
        XCTAssertTrue(prompt.hasPrefix("Assess."))
        XCTAssertTrue(prompt.contains("NEVER transcribe"))
        let properties = schema["properties"] as? [String: Any]
        let sensitive = properties?["sensitive_items"] as? [String: Any]
        XCTAssertEqual(sensitive?["type"] as? String, "array")
        let items = sensitive?["items"] as? [String: Any]
        XCTAssertEqual(items?["enum"] as? [String], AssessmentPrivacy.categories)
        // The original required list is untouched — reporting is optional, never forced.
        XCTAssertEqual(schema["required"] as? [String], ["summary"])
    }

    func testAugmentDoesNotOverwriteExistingProperty() {
        var custom = baseSchema
        var properties = custom["properties"] as! [String: Any]
        properties["sensitive_items"] = ["type": "string"]   // a schema's own definition wins
        custom["properties"] = properties
        let (_, schema) = AssessmentPrivacy.augment(systemPrompt: "x", jsonSchema: custom)
        let kept = (schema["properties"] as? [String: Any])?["sensitive_items"] as? [String: Any]
        XCTAssertEqual(kept?["type"] as? String, "string")
    }

    func testReportedCategoriesFilterUnknownAndDedup() {
        let json: [String: Any] = ["sensitive_items": ["payment_card", "made_up", "payment_card", "screen"]]
        XCTAssertEqual(AssessmentPrivacy.reportedCategories(in: json), ["payment_card", "screen"])
        XCTAssertEqual(AssessmentPrivacy.reportedCategories(in: [:]), [])
        XCTAssertEqual(AssessmentPrivacy.reportedCategories(in: ["sensitive_items": "card"]), [])
    }

    func testFindingsAreCategoryOnly() {
        let findings = AssessmentPrivacy.findings(for: ["id_document"])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].label, "Privacy: ID document visible")
        XCTAssertEqual(findings[0].detail, "Contents not read")
        XCTAssertEqual(findings[0].severity, .caution)
    }

    func testAddingFindingsPreservesCardAndAppends() {
        let card = AssessmentCard(kind: "instrument_reading", title: "Gauge", tier: .ok,
                                  summary: "All normal",
                                  findings: [AssessmentFinding(label: "existing")])
        let extra = AssessmentPrivacy.findings(for: ["handwriting"])
        let updated = card.addingFindings(extra)
        XCTAssertEqual(updated.findings.map(\.label), ["existing", "Privacy: handwriting visible"])
        XCTAssertEqual(updated.kind, card.kind)
        XCTAssertEqual(updated.tier, card.tier)
        XCTAssertEqual(updated.summary, card.summary)
        // Empty append returns the identical card.
        XCTAssertEqual(card.addingFindings([]), card)
    }
}
