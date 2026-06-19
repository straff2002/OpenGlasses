import XCTest
@testable import OpenGlasses

/// Tests for `FirstAidTriageSchema` (structured-vision first-aid consumer): payload → card mapping and
/// the **deterministic safety backstop** — any life-threat sign forces a critical, call-emergency
/// result even when the model under-rates it. Headless. Advisory feature, not a medical device.
@MainActor
final class FirstAidTriageSchemaTests: XCTestCase {

    private let schema = FirstAidTriageSchema()

    /// Mirrors what `StructuredVisionService` does: makeCard then backstop.
    private func triage(_ json: [String: Any]) throws -> AssessmentCard {
        schema.backstop(try schema.makeCard(from: json, context: nil))
    }

    func testResponsiveMinorStaysCaution() throws {
        let card = try triage([
            "responsiveness": "responsive", "breathing": "yes", "severe_bleeding": false,
            "suspected_conditions": [["name": "Sprained ankle", "severity": "major", "confidence": 0.7]],
            "recommended_action": "monitor",
            "still_to_check": ["check for other injuries"],
            "summary": "Conscious, ankle injury.", "confidence": 0.7
        ])
        XCTAssertEqual(card.tier, .caution)
        XCTAssertEqual(card.findings.first?.label, "Sprained ankle")
        XCTAssertTrue(card.recommendedAction?.localizedCaseInsensitiveContains("monitor") ?? false)
        XCTAssertTrue(card.stillNeeded.contains("check for other injuries"))
        XCTAssertNotNil(card.disclaimer)
    }

    func testNotBreathingForcesCriticalAndCPR_evenIfModelSaidMonitor() throws {
        let card = try triage([
            "responsiveness": "responsive", "breathing": "no", "severe_bleeding": false,
            "recommended_action": "monitor",   // model under-rates
            "summary": "Person on the ground.", "confidence": 0.5
        ])
        XCTAssertEqual(card.tier, .critical)
        XCTAssertTrue(card.recommendedAction?.localizedCaseInsensitiveContains("call emergency services") ?? false)
        XCTAssertTrue(card.recommendedAction?.localizedCaseInsensitiveContains("cpr") ?? false)
        XCTAssertTrue(card.stillNeeded.contains { $0.localizedCaseInsensitiveContains("emergency services") })
        XCTAssertTrue(card.findings.contains { $0.label == "Not breathing" && $0.severity == .critical })
    }

    func testUnresponsiveForcesCritical() throws {
        let card = try triage([
            "responsiveness": "unresponsive", "breathing": "unsure", "severe_bleeding": false,
            "recommended_action": "recovery_position", "summary": "Not responding."
        ])
        XCTAssertEqual(card.tier, .critical)
        XCTAssertTrue(card.recommendedAction?.localizedCaseInsensitiveContains("call emergency services") ?? false)
    }

    func testSevereBleedingForcesCritical() throws {
        let card = try triage([
            "responsiveness": "responsive", "breathing": "yes", "severe_bleeding": true,
            "recommended_action": "control_bleeding", "summary": "Heavy bleeding from the arm."
        ])
        XCTAssertEqual(card.tier, .critical)
        XCTAssertTrue(card.recommendedAction?.localizedCaseInsensitiveContains("call emergency services") ?? false)
        XCTAssertFalse(card.recommendedAction?.localizedCaseInsensitiveContains("cpr") ?? true)
    }

    func testDegeneratePayloadIsSafeCaution() throws {
        let card = try triage([:])
        XCTAssertEqual(card.tier, .caution)
        XCTAssertTrue(card.findings.isEmpty)
        XCTAssertNotNil(card.disclaimer)
    }

    func testServiceRegistersTriageSchema() {
        let svc = StructuredVisionService()
        let registry = AssessmentSchemaRegistry()
        svc.registry = registry
        svc.registerBuiltinSchemas()
        XCTAssertTrue(registry.contains("first_aid_triage"))
        XCTAssertTrue(registry.contains("instrument_reading"))
    }
}
