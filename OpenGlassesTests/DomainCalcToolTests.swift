import XCTest
@testable import OpenGlasses

/// Tests for DomainCalcTool refrigeration math: PT interpolation, superheat, subcool, normalization,
/// and out-of-range handling. PT anchors mirror pt_charts.md.
@MainActor
final class DomainCalcToolTests: XCTestCase {

    private var tool: DomainCalcTool!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        tool = DomainCalcTool()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        super.tearDown()
    }

    // MARK: - Interpolation unit

    func testSaturationTempAtAnchorPoint() throws {
        // R-410A anchor: 200 PSIG -> 70°F (from pt_charts.md).
        let table = [(psig: 50.0, tempF: 8.0), (psig: 200.0, tempF: 70.0), (psig: 300.0, tempF: 96.0)]
        let temp = try XCTUnwrap(DomainCalcTool.saturationTemp(psig: 200, table: table))
        XCTAssertEqual(temp, 70, accuracy: 0.001)
    }

    func testSaturationTempInterpolatesBetweenAnchors() throws {
        // Halfway between 200 PSIG/70°F and 300 PSIG/96°F => 250 PSIG -> 83°F.
        let table = [(psig: 200.0, tempF: 70.0), (psig: 300.0, tempF: 96.0)]
        let temp = try XCTUnwrap(DomainCalcTool.saturationTemp(psig: 250, table: table))
        XCTAssertEqual(temp, 83, accuracy: 0.001)
    }

    func testSaturationTempOutOfRangeReturnsNil() {
        let table = [(psig: 50.0, tempF: 8.0), (psig: 300.0, tempF: 96.0)]
        XCTAssertNil(DomainCalcTool.saturationTemp(psig: 10, table: table))
        XCTAssertNil(DomainCalcTool.saturationTemp(psig: 500, table: table))
    }

    // MARK: - Normalization

    func testNormalizeRefrigerantDesignations() {
        XCTAssertEqual(DomainCalcTool.normalize("410a"), "R-410A")
        XCTAssertEqual(DomainCalcTool.normalize("R410A"), "R-410A")
        XCTAssertEqual(DomainCalcTool.normalize("r-410a"), "R-410A")
        XCTAssertEqual(DomainCalcTool.normalize("R-22"), "R-22")
    }

    // MARK: - Tool execution

    func testPTLookupReturnsSaturationTemp() async throws {
        let result = try await tool.execute(args: [
            "operation": "pt_lookup", "refrigerant": "R-410A", "pressure_psig": 200
        ])
        XCTAssertTrue(result.contains("70°F"), result)
        XCTAssertTrue(result.contains("pt_charts.md"), result)
    }

    func testSuperheatCalculation() async throws {
        // R-410A at 118 PSIG ≈ ~40°F sat (interp 100/31 -> 125/44). Suction line 55°F -> ~15°F superheat.
        let result = try await tool.execute(args: [
            "operation": "superheat", "refrigerant": "R-410A",
            "suction_pressure_psig": 118, "suction_line_temp_f": 55
        ])
        XCTAssertTrue(result.contains("Superheat"), result)
        XCTAssertTrue(result.contains("superheat_subcool.md"), result)
    }

    func testSubcoolCalculation() async throws {
        // R-410A at 300 PSIG -> 96°F sat. Liquid line 86°F -> 10°F subcool.
        let result = try await tool.execute(args: [
            "operation": "subcool", "refrigerant": "R-410A",
            "liquid_pressure_psig": 300, "liquid_line_temp_f": 86
        ])
        XCTAssertTrue(result.contains("10°F") || result.contains("Subcooling ≈ 10"), result)
    }

    func testUnknownRefrigerantIsRejected() async throws {
        let result = try await tool.execute(args: [
            "operation": "pt_lookup", "refrigerant": "R-999", "pressure_psig": 100
        ])
        XCTAssertTrue(result.lowercased().contains("no pt data"), result)
    }

    func testOutOfRangePressureReferralNotFabricated() async throws {
        let result = try await tool.execute(args: [
            "operation": "pt_lookup", "refrigerant": "R-410A", "pressure_psig": 5
        ])
        XCTAssertTrue(result.lowercased().contains("outside the tabulated"), result)
    }
}
