import XCTest
@testable import OpenGlasses

/// Tests for Plan I label parsing + cross-check against the Health Vault medications record.
/// The camera/OCR round-trip isn't unit-tested (covered by OCRServiceTests).
@MainActor
final class MedicationIdentifierTests: XCTestCase {
    typealias Tool = MedicationIdentifierTool

    private let medsRecord = """
    # Medications

    ## Current
    | Medication | Dosage | Schedule | Started |
    |------------|--------|----------|---------|
    | Metformin | 500mg | twice daily with meals | 2021-03 |
    | Atorvastatin | 20mg | nightly | 2020-11 |
    """

    func testParsesNameAndStrength() {
        let r = Tool.parseLabel("METFORMIN 500 mg\nTake one tablet twice daily")
        XCTAssertTrue(r.names.contains { $0.lowercased() == "metformin" })
        XCTAssertTrue(r.strengths.contains("500mg"))
        // Stop words shouldn't be treated as drug names.
        XCTAssertFalse(r.names.contains { $0.lowercased() == "tablet" })
        XCTAssertFalse(r.names.contains { $0.lowercased() == "twice" })
    }

    func testParsesGluedStrength() {
        let r = Tool.parseLabel("Atorvastatin 20mg tablets")
        XCTAssertTrue(r.strengths.contains("20mg"))
    }

    func testCrossCheckMatch() {
        let r = Tool.Readout(names: ["Metformin"], strengths: ["500mg"])
        XCTAssertEqual(Tool.crossCheck(readout: r, medicationsMarkdown: medsRecord), .match(name: "Metformin"))
    }

    func testCrossCheckStrengthMismatch() {
        let r = Tool.Readout(names: ["Metformin"], strengths: ["1000mg"])
        guard case .strengthMismatch(let name, let label, let recorded) =
                Tool.crossCheck(readout: r, medicationsMarkdown: medsRecord) else {
            return XCTFail("Expected strengthMismatch")
        }
        XCTAssertEqual(name, "Metformin")
        XCTAssertEqual(label, "1000mg")
        XCTAssertEqual(recorded, "500mg")
    }

    func testCrossCheckNotListed() {
        let r = Tool.Readout(names: ["Lisinopril"], strengths: ["10mg"])
        XCTAssertEqual(Tool.crossCheck(readout: r, medicationsMarkdown: medsRecord), .notListed)
    }

    func testLockedWhenComplianceInactive() async throws {
        // Tool needs a camera; we only exercise the gate, which returns before capture.
        // VaultRegistry health is locked by default in tests.
        let result = try await Tool(cameraService: CameraService()).execute(args: [:])
        XCTAssertTrue(result.lowercased().contains("medical compliance"), "Got: \(result)")
    }
}
