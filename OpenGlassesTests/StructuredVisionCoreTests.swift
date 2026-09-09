import XCTest
@testable import OpenGlasses

/// Tests for the structured-vision pure core (Phase 1): `AssessmentCard` codable round-trip + decode
/// from snake_case model JSON, `AssessmentTier` ordering/escalation, reading normalization, the
/// `AssessmentSchemaRegistry`, and the `AssessmentSchema` reading/backstop policy via a fake schema.
/// Headless — no network, no MainActor.
final class StructuredVisionCoreTests: XCTestCase {

    // MARK: - AssessmentTier

    func testTierIsOrdered() {
        XCTAssertTrue(AssessmentTier.unknown < .ok)
        XCTAssertTrue(AssessmentTier.ok < .caution)
        XCTAssertTrue(AssessmentTier.caution < .critical)
        XCTAssertEqual(AssessmentTier.escalated(.ok, .critical), .critical)
        XCTAssertEqual(AssessmentTier.escalated(.caution, .ok), .caution)
        // "Not established" never outranks a real observation, in either direction.
        XCTAssertEqual(AssessmentTier.escalated(.unknown, .ok), .ok)
        XCTAssertEqual(AssessmentTier.escalated(.critical, .unknown), .critical)
    }

    // MARK: - Card round-trip + decode

    func testCardEncodeDecodeRoundTrip() throws {
        let card = AssessmentCard(
            kind: "instrument_reading", title: "Reading", tier: .caution,
            summary: "One gauge read.",
            findings: [AssessmentFinding(label: "Frost on coil", severity: .caution, confidence: 0.7)],
            recommendedAction: "monitor", stillNeeded: ["cut fruit"],
            readings: [InstrumentReading(quantity: "pressure", value: 100, unit: "psi")],
            confidence: 0.8, disclaimer: "Advisory only.")
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AssessmentCard.self, from: data)
        XCTAssertEqual(decoded, card)
    }

    func testCardDecodesFromSnakeCaseModelJSON() throws {
        let json: [String: Any] = [
            "kind": "first_aid_triage", "title": "Triage", "tier": "critical",
            "summary": "Casualty unresponsive.", "recommended_action": "call_emergency",
            "still_needed": ["check breathing"], "confidence": 0.6,
            "readings": [["quantity": "spo2", "value": 88.0, "unit": "%", "confidence": 0.5]]
        ]
        let card = try AssessmentJSON.decode(AssessmentCard.self, from: json)
        XCTAssertEqual(card.tier, .critical)
        XCTAssertEqual(card.recommendedAction, "call_emergency")
        XCTAssertEqual(card.stillNeeded, ["check breathing"])
        XCTAssertEqual(card.readings.first?.quantity, "spo2")
    }

    func testCardDefaultsTolerateMissingFields() throws {
        let card = try AssessmentJSON.decode(AssessmentCard.self, from: ["kind": "x", "title": "X"])
        XCTAssertEqual(card.tier, .caution)        // default
        XCTAssertTrue(card.findings.isEmpty)
        XCTAssertTrue(card.readings.isEmpty)
        // The absent field stays absent. This assertion used to read `== 1.0`, which is exactly the
        // fabricated certainty W08.2 removes: nothing reported a confidence, so nothing has one.
        XCTAssertNil(card.confidence)
        XCTAssertNil(card.certainty)
    }

    // MARK: - Escalation only raises

    func testEscalatingOnlyRaisesTier() {
        let card = AssessmentCard(kind: "k", title: "T", tier: .ok, summary: "")
        let raised = card.escalating(to: .critical, action: "call 111", appending: "check airway")
        XCTAssertEqual(raised.tier, .critical)
        XCTAssertEqual(raised.recommendedAction, "call 111")
        XCTAssertEqual(raised.stillNeeded, ["check airway"])
        // Escalating "down" is a no-op on tier; an existing action is preserved when none is supplied.
        let high = AssessmentCard(kind: "k", title: "T", tier: .critical, summary: "", recommendedAction: "x")
        let lowered = high.escalating(to: .ok)
        XCTAssertEqual(lowered.tier, .critical)
        XCTAssertEqual(lowered.recommendedAction, "x")
    }

    // MARK: - Reading normalization

    func testReadingNormalizationFillsCanonical() {
        let r = InstrumentReading(quantity: "temperature", value: 212, unit: "°F").normalized()
        XCTAssertEqual(r.canonical!, 100, accuracy: 0.0001)
        XCTAssertEqual(r.canonicalUnit, "°C")
    }

    func testReadingNormalizationLeavesUnknownUnitsAlone() {
        let r = InstrumentReading(quantity: "x", value: 5, unit: "furlongs").normalized()
        XCTAssertNil(r.canonical)
        XCTAssertEqual(r.value, 5, accuracy: 0.0001)
    }

    // MARK: - Registry

    func testRegistryRegisterLookup() {
        let reg = AssessmentSchemaRegistry()
        XCTAssertNil(reg.schema(for: "fake"))
        XCTAssertFalse(reg.contains("fake"))
        reg.register(FakeSchema())
        XCTAssertNotNil(reg.schema(for: "fake"))
        XCTAssertTrue(reg.contains("fake"))
        XCTAssertEqual(reg.kinds, ["fake"])
    }

    // MARK: - Schema reading policy + backstop

    func testReadingPolicyPushesLowConfidenceToStillNeeded() throws {
        let schema = FakeSchema()
        let json: [String: Any] = [
            "tier": "caution",
            "readings": [
                ["quantity": "pressure", "value": 100.0, "unit": "psi", "confidence": 0.9],
                ["quantity": "temperature", "value": 38.0, "unit": "°F", "confidence": 0.2]
            ]
        ]
        let card = try schema.makeCard(from: json, context: nil)
        // Low-confidence temperature reading → a re-capture entry; high-confidence pressure → none.
        XCTAssertTrue(card.stillNeeded.contains { $0.contains("temperature") })
        XCTAssertFalse(card.stillNeeded.contains { $0.contains("pressure") })
        // Readings were normalized in passing.
        XCTAssertEqual(card.readings.first(where: { $0.quantity == "pressure" })?.canonicalUnit, "kPa")
    }

    func testBackstopEscalates() {
        let schema = FakeSchema()
        let ok = AssessmentCard(kind: "fake", title: "T", tier: .ok, summary: "danger word")
        XCTAssertEqual(schema.backstop(ok).tier, .critical)
        let calm = AssessmentCard(kind: "fake", title: "T", tier: .ok, summary: "all good")
        XCTAssertEqual(schema.backstop(calm).tier, .ok)
    }
}

// MARK: - Fixture

/// Minimal schema exercising the protocol surface: decodes free-form readings, applies the reading
/// policy, and escalates to critical when the summary contains the word "danger".
private struct FakeSchema: AssessmentSchema {
    let kind = "fake"
    let title = "Fake"
    var jsonSchema: [String: Any] { ["type": "object"] }
    var systemPrompt: String { AssessmentPrompt.instrumentFragment }

    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard {
        let readings = (json["readings"] as? [[String: Any]])?.compactMap {
            try? AssessmentJSON.decode(InstrumentReading.self, from: $0)
        } ?? []
        let tier = AssessmentTier(rawValue: json["tier"] as? String ?? "caution") ?? .caution
        let card = AssessmentCard(kind: kind, title: title, tier: tier,
                                  summary: json["summary"] as? String ?? "", readings: readings)
        return applyingReadingPolicy(to: card)
    }

    func backstop(_ card: AssessmentCard) -> AssessmentCard {
        card.summary.localizedCaseInsensitiveContains("danger") ? card.escalating(to: .critical) : card
    }
}
