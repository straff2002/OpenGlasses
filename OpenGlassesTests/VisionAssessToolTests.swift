import XCTest
@testable import OpenGlasses

/// Tests for `VisionAssessTool` routing (structured-vision Phase 3): missing/unknown `kind` guidance
/// (no camera needed) and the speakable `summarize` output. The camera happy path is integration-only.
@MainActor
final class VisionAssessToolTests: XCTestCase {

    private let tool = VisionAssessTool()

    override func setUp() {
        super.setUp()
        // Ensure at least the built-in kind is discoverable via the shared registry.
        AssessmentSchemaRegistry.shared.register(InstrumentReadingSchema())
    }

    func testMissingKindReturnsGuidance() async throws {
        let result = try await tool.execute(args: [:])
        XCTAssertTrue(result.localizedCaseInsensitiveContains("specify"))
        XCTAssertTrue(result.contains("instrument_reading"))
    }

    func testUnknownKindIsRejected() async throws {
        let result = try await tool.execute(args: ["kind": "bogus"])
        XCTAssertTrue(result.contains("Unknown assessment kind 'bogus'"))
        XCTAssertTrue(result.contains("instrument_reading"))
    }

    func testToolMetadata() {
        XCTAssertEqual(tool.name, "vision_assess")
        XCTAssertTrue(tool.description.contains("instrument_reading"))
        let props = tool.parametersSchema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["kind"])
        XCTAssertEqual(tool.parametersSchema["required"] as? [String], ["kind"])
    }

    // MARK: - First-aid triage honours the first-aid switch (Plan HP P1 item 4)

    private func withFirstAid(_ enabled: Bool, _ body: () async throws -> Void) async rethrows {
        let sw = AIFeature.firstAidAssist.record.disableSwitch
        let saved = sw.isEnabled()
        sw.setEnabled(enabled)
        defer { sw.setEnabled(saved) }
        AssessmentSchemaRegistry.shared.register(FirstAidTriageSchema())
        try await body()
    }

    func testTriageIsRefusedWhenFirstAidIsOff() async throws {
        try await withFirstAid(false) {
            var reached = false
            let tool = VisionAssessTool(assess: { kind, _ in
                reached = true
                return AssessmentCard(kind: kind, title: "First-Aid Triage", tier: .ok, summary: "reached")
            })
            let answer = try await tool.execute(args: ["kind": "first_aid_triage"])
            XCTAssertEqual(answer, AIFeatureGate.disabledMessage(.firstAidAssist))
            XCTAssertFalse(reached, "the camera and the model were reached with the feature off")
        }
    }

    func testTriageReachesTheServiceWhenFirstAidIsOn() async throws {
        try await withFirstAid(true) {
            var assessedKind: String?
            let tool = VisionAssessTool(assess: { kind, _ in
                assessedKind = kind
                return AssessmentCard(kind: kind, title: "First-Aid Triage", tier: .ok, summary: "reached")
            })
            let answer = try await tool.execute(args: ["kind": "first_aid_triage"])
            XCTAssertEqual(assessedKind, "first_aid_triage")
            XCTAssertTrue(answer.contains("reached"))
        }
    }

    /// The switch gates triage only: reading a gauge is not first aid.
    func testOtherKindsAreNotGatedByTheFirstAidSwitch() async throws {
        try await withFirstAid(false) {
            var reached = false
            let tool = VisionAssessTool(assess: { kind, _ in
                reached = true
                return AssessmentCard(kind: kind, title: "Instrument Reading", tier: .ok, summary: "read")
            })
            _ = try await tool.execute(args: ["kind": "instrument_reading"])
            XCTAssertTrue(reached)
        }
        XCTAssertEqual(VisionAssessTool.gatedKinds, ["first_aid_triage": .firstAidAssist])
        XCTAssertEqual(FirstAidTriageSchema().kind, "first_aid_triage", "the gate keys on the schema's own kind")
    }

    func testSummarizeIncludesReadingsAndAction() {
        let card = AssessmentCard(
            kind: "instrument_reading", title: "Instrument Reading", tier: .ok,
            summary: "Read 1 value.",
            recommendedAction: "log it",
            stillNeeded: ["wipe the lens"],
            readings: [InstrumentReading(quantity: "pressure", value: 100, unit: "psi",
                                         canonical: 689.4757, canonicalUnit: "kPa")])
        let s = VisionAssessTool.summarize(card)
        XCTAssertTrue(s.contains("Read 1 value."))
        XCTAssertTrue(s.contains("pressure: 100 psi"))
        XCTAssertTrue(s.contains("kPa"))
        XCTAssertTrue(s.contains("Recommended: log it"))
        XCTAssertTrue(s.contains("Still needed: wipe the lens"))
    }
}
