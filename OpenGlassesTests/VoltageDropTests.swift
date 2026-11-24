import XCTest
@testable import OpenGlasses

/// Plan JJ P4 — voltage drop as `domain_calc`'s electrical domain, and the same arithmetic in a
/// rule chain's `calc` step. Every resistance, factor, area and table here is invented (QX sizes,
/// Table 96, Rule QR-30); no value is a conductor's real resistance or any code's factor. The one
/// exception is a run given as a wire size or an area in mm² with its metal (Plan MQ P3, Plan JJ
/// decision 8): the standard AWG areas and the copper and aluminium factors in the bundled
/// conductor file (`ConductorTable`), which the answer names.
@MainActor
final class VoltageDropTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        super.tearDown()
    }

    private func run(_ args: [String: Any]) async throws -> String {
        try await DomainCalcTool().execute(args: args.merging(["operation": "voltage_drop"]) { a, _ in a })
    }

    private func volts(_ input: VoltageDrop.Input) throws -> Double {
        try VoltageDrop.compute(input).get().volts
    }

    /// The bundled conductor file.
    private var conductors: ConductorTable {
        get throws { try XCTUnwrap(ConductorTableCatalog.table(), "conductors.json is bundled and decodes") }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - The core

    func testSinglePhaseAndThreePhaseInBothUnitSystems() throws {
        // Single-phase, metric resistance: 2 × 20 A × 30 m × 5.25 Ω/km.
        let single = try VoltageDrop.compute(.init(phase: .single, current: 20, length: 30, lengthUnit: .metres,
                                                   conductor: .resistance(5.25, .ohmsPerKilometre), supply: 230)).get()
        XCTAssertEqual(single.volts, 6.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(single.percent), 6.3 / 230 * 100, accuracy: 1e-9)

        // Three-phase, imperial resistance: √3 × 40 A × 150 ft × 0.875 Ω per 1000 ft.
        let three = try volts(.init(phase: .three, current: 40, length: 150, lengthUnit: .feet,
                                    conductor: .resistance(0.875, .ohmsPerThousandFeet), supply: 480))
        XCTAssertEqual(three, 3.0.squareRoot() * 40 * 150 * 0.000875, accuracy: 1e-9)

        // The factor form: K / area, metric (Ω·mm²/m over mm²) and imperial (Ω·cmil/ft over cmil).
        let metricFactor = try volts(.init(phase: .single, current: 25, length: 40, lengthUnit: .metres,
                                           conductor: .factor(0.05, .ohmSquareMillimetresPerMetre, area: 8), supply: nil))
        XCTAssertEqual(metricFactor, 2 * 0.05 * 25 * 40 / 8, accuracy: 1e-9)
        let imperialFactor = try volts(.init(phase: .three, current: 30, length: 200, lengthUnit: .feet,
                                             conductor: .factor(7.5, .ohmCircularMilsPerFoot, area: 15000), supply: nil))
        XCTAssertEqual(imperialFactor, 3.0.squareRoot() * 7.5 * 30 * 200 / 15000, accuracy: 1e-9)

        // The same run said in either system gives the same drop.
        let inFeet = try volts(.init(phase: .single, current: 20, length: 30 / 0.3048, lengthUnit: .feet,
                                     conductor: .resistance(5.25 * 0.3048, .ohmsPerThousandFeet), supply: nil))
        XCTAssertEqual(inFeet, 6.3, accuracy: 1e-9)
    }

    func testAQuantityAtOrBelowZeroIsRefused() {
        let base = VoltageDrop.Input(phase: .single, current: 20, length: 30, lengthUnit: .metres,
                                     conductor: .resistance(5.25, .ohmsPerKilometre), supply: 230)
        var zeroCurrent = base; zeroCurrent.current = 0
        XCTAssertEqual(VoltageDrop.compute(zeroCurrent), .failure(.notPositive("current")))
        var noResistance = base; noResistance.conductor = .resistance(0, .ohmsPerKilometre)
        XCTAssertEqual(VoltageDrop.compute(noResistance), .failure(.notPositive("resistance")))
        var noArea = base; noArea.conductor = .factor(0.05, .ohmSquareMillimetresPerMetre, area: 0)
        XCTAssertEqual(VoltageDrop.compute(noArea), .failure(.notPositive("area")))
        var badSupply = base; badSupply.supply = -1
        XCTAssertEqual(VoltageDrop.compute(badSupply), .failure(.notPositive("supply")))
    }

    func testThePhaseIsReadFromWords() {
        XCTAssertEqual(VoltageDrop.Phase(words: "single"), .single)
        XCTAssertEqual(VoltageDrop.Phase(words: "Single-phase"), .single)
        XCTAssertEqual(VoltageDrop.Phase(words: "1"), .single)
        XCTAssertEqual(VoltageDrop.Phase(words: "three phase"), .three)
        XCTAssertEqual(VoltageDrop.Phase(words: "3"), .three)
        XCTAssertNil(VoltageDrop.Phase(words: "two"))
        XCTAssertNil(VoltageDrop.Phase(words: ""))
    }

    // MARK: - domain_calc

    func testTheToolGivesTheDropWithItsInputsEchoed() async throws {
        let metric = try await run(["phase": "single", "current_a": 20, "length_m": 30,
                                    "resistance_ohm_per_km": 5.25, "supply_v": 230])
        XCTAssertTrue(metric.hasPrefix("Voltage drop ≈ 6.3 V, 2.74 % of the 230 V supply (single-phase: 2 × current"), metric)
        XCTAssertTrue(metric.contains("Inputs as given: single-phase; current 20 A; one-way length 30 m; "
                                      + "conductor resistance 5.25 Ω/km; supply 230 V."), metric)
        XCTAssertTrue(metric.contains("Resistance only: reactance and power factor are not included."), metric)
        XCTAssertTrue(metric.contains("not a value from any code or table"), metric)

        let imperial = try await run(["phase": "three", "current_a": 40, "length_ft": 150,
                                      "resistance_ohm_per_1000ft": 0.875, "supply_v": 480])
        XCTAssertTrue(imperial.hasPrefix("Voltage drop ≈ 9.09 V, 1.89 % of the 480 V supply (three-phase: √3 × current"), imperial)
        XCTAssertTrue(imperial.contains("one-way length 150 ft; conductor resistance 0.875 Ω/1000 ft; supply 480 V."), imperial)

        let factor = try await run(["phase": "three", "current_a": 30, "length_ft": 200,
                                    "k_factor_ohm_cmil_per_ft": 7.5, "area_cmil": 15000, "supply_v": 208])
        XCTAssertTrue(factor.hasPrefix("Voltage drop ≈ 5.2 V, 2.5 % of the 208 V supply"), factor)
        XCTAssertTrue(factor.contains("factor 7.5 Ω·cmil/ft, conductor area 15000 cmil"), factor)

        let metricFactor = try await run(["phase": "single", "current_a": 25, "length_m": 40,
                                          "k_factor_ohm_mm2_per_m": 0.05, "area_mm2": 8])
        XCTAssertTrue(metricFactor.hasPrefix("Voltage drop ≈ 12.5 V (single-phase"), metricFactor)
        XCTAssertTrue(metricFactor.contains("Give the supply voltage for the drop as a percentage."), metricFactor)
    }

    func testTheToolRefusesAMissingResistanceFactorAreaOrPhaseRatherThanAssumingOne() async throws {
        let noConductor = try await run(["phase": "single", "current_a": 20, "length_m": 30, "supply_v": 230])
        XCTAssertTrue(noConductor.contains("No resistance or factor is assumed"), noConductor)
        XCTAssertFalse(noConductor.contains("Voltage drop ≈"), noConductor)

        let noArea = try await run(["phase": "single", "current_a": 20, "length_m": 30, "k_factor_ohm_mm2_per_m": 0.05])
        XCTAssertTrue(noArea.contains("needs the conductor's area in mm²"), noArea)
        let noCmil = try await run(["phase": "single", "current_a": 20, "length_ft": 30, "k_factor_ohm_cmil_per_ft": 7.5])
        XCTAssertTrue(noCmil.contains("needs the conductor's area in circular mils"), noCmil)

        let noPhase = try await run(["current_a": 20, "length_m": 30, "resistance_ohm_per_km": 5.25])
        XCTAssertTrue(noPhase.contains("The phase is never assumed"), noPhase)
        let noLength = try await run(["phase": "single", "current_a": 20, "resistance_ohm_per_km": 5.25])
        XCTAssertTrue(noLength.contains("one-way length"), noLength)
        let zero = try await run(["phase": "single", "current_a": 0, "length_m": 30, "resistance_ohm_per_km": 5.25])
        XCTAssertEqual(zero, "The current must be a number above zero.")
    }

    func testVoltageDropNeedsNoRefrigerantAndTheRefrigerantOperationsStillDo() async throws {
        let drop = try await DomainCalcTool().execute(args: ["operation": "voltage_drop", "phase": "single",
                                                             "current_a": 20, "length_m": 30, "resistance_ohm_per_km": 5.25])
        XCTAssertTrue(drop.hasPrefix("Voltage drop ≈ 6.3 V"), drop)
        let superheat = try await DomainCalcTool().execute(args: ["operation": "superheat"])
        XCTAssertTrue(superheat.contains("It is never assumed"), superheat)
        let schema = DomainCalcTool().parametersSchema
        XCTAssertEqual(schema["required"] as? [String], ["operation"])
        XCTAssertTrue(DomainCalcTool().description.contains("'voltage_drop'"))
    }

    // MARK: - A run given as a wire size (Plan MQ P3)

    func testFourteenGaugeCopperFromItsSize() async throws {
        // 14 AWG is 4,110 cmil and copper's factor 12.9 Ω·cmil/ft, so R = 12.9 / 4,110 Ω/ft.
        // Single-phase: 2 × 15 A × 50 ft × 12.9 / 4,110 = 19,350 / 4,110 = 4.708 V;
        // of a 120 V supply, 4.708 / 120 = 3.92 %.
        let answer = try await run(["phase": "single", "current_a": 15, "length_ft": 50,
                                    "wire_awg": "14", "material": "copper", "supply_v": 120])
        XCTAssertTrue(answer.hasPrefix("Voltage drop ≈ 4.71 V, 3.92 % of the 120 V supply (single-phase"), answer)
        XCTAssertTrue(answer.contains("conductor 14 AWG copper: factor 12.9 Ω·cmil/ft, conductor area 4110 cmil"), answer)
        XCTAssertTrue(answer.contains("the area is the standard 14 AWG size and the factor the usual figure for "
                                      + "copper at 75 °C; a figure from the organisation's own book wins"), answer)
        XCTAssertFalse(answer.contains("not a value from any code or table"), answer)

        XCTAssertTrue(answer.contains("Conductor data: standard AWG conductor areas and conductor resistivity "
                                      + "figures at 75 °C."), answer)

        let table = try conductors
        let gauge = try XCTUnwrap(VoltageDrop.WireGauge(words: "14", table: table))
        let copper = try XCTUnwrap(table.factor(for: .copper, unit: .ohmCircularMilsPerFoot))
        let core = try volts(.init(phase: .single, current: 15, length: 50, lengthUnit: .feet,
                                   conductor: .factor(copper.value, .ohmCircularMilsPerFoot,
                                                      area: gauge.circularMils), supply: 120))
        XCTAssertEqual(core, 19_350.0 / 4_110, accuracy: 1e-9)

        // A size sent as a number, the metal in another case.
        let asNumber = try await run(["phase": "single", "current_a": 15, "length_ft": 50,
                                      "wire_awg": 14, "material": "Copper"])
        XCTAssertTrue(asNumber.hasPrefix("Voltage drop ≈ 4.71 V (single-phase"), asNumber)
    }

    func testSizesAndMetalsAreReadAsSaid() throws {
        let table = try conductors
        func size(_ words: String) -> VoltageDrop.WireGauge? { VoltageDrop.WireGauge(words: words, table: table) }
        XCTAssertEqual(size("#12")?.circularMils, 6_530)
        XCTAssertEqual(size("12 AWG")?.circularMils, 6_530)
        XCTAssertEqual(size("10 gauge")?.circularMils, 10_380)
        XCTAssertEqual(size("14.0")?.name, "14")
        XCTAssertEqual(size("1/0")?.circularMils, 105_600)
        XCTAssertEqual(size("00")?.name, "2/0")
        XCTAssertEqual(size("4/0 AWG")?.circularMils, 211_600)
        for unknown in ["7", "13", "22", "5/0", "250 kcmil", "2.5", "", "fourteen"] {
            XCTAssertNil(size(unknown), unknown)
        }
        XCTAssertEqual(VoltageDrop.Material(words: "aluminium"), .aluminum)
        XCTAssertEqual(VoltageDrop.Material(words: "Al"), .aluminum)
        XCTAssertEqual(VoltageDrop.Material(words: "CU"), .copper)
        XCTAssertNil(VoltageDrop.Material(words: "steel"))
        XCTAssertEqual(table.factor(for: .aluminum, unit: .ohmCircularMilsPerFoot)?.value, 21.2)
    }

    func testGivenValuesWinOverTheWireSize() async throws {
        let base: [String: Any] = ["phase": "single", "current_a": 15, "length_ft": 50]
        // A resistance wins outright: 2 × 15 × 50 × 2.5 / 1000 = 3.75 V.
        let resistance = try await run(base.merging(["wire_awg": "14", "material": "copper",
                                                     "resistance_ohm_per_1000ft": 2.5]) { a, _ in a })
        XCTAssertTrue(resistance.hasPrefix("Voltage drop ≈ 3.75 V"), resistance)
        XCTAssertFalse(resistance.contains("AWG"), resistance)

        // A factor given with a size: the size's area, the given factor, no metal needed.
        // 2 × 15 × 50 × 10 / 4,110 = 3.65 V.
        let factor = try await run(base.merging(["wire_awg": "14", "k_factor_ohm_cmil_per_ft": 10]) { a, _ in a })
        XCTAssertTrue(factor.hasPrefix("Voltage drop ≈ 3.65 V"), factor)
        XCTAssertTrue(factor.contains("conductor 14 AWG: factor 10 Ω·cmil/ft, conductor area 4110 cmil"), factor)
        XCTAssertTrue(factor.contains("the area is the standard 14 AWG size and the factor the one given"), factor)

        // An area given with a metal: the given area, the metal's factor. 2 × 15 × 50 × 21.2 / 5,000 = 6.36 V.
        let area = try await run(base.merging(["area_cmil": 5_000, "wire_awg": "14", "material": "aluminum"]) { a, _ in a })
        XCTAssertTrue(area.hasPrefix("Voltage drop ≈ 6.36 V"), area)
        XCTAssertTrue(area.contains("conductor aluminum: factor 21.2 Ω·cmil/ft, conductor area 5000 cmil"), area)
        XCTAssertTrue(area.contains("the area is the one given and the factor the usual figure for aluminum"), area)
    }

    func testTheMetricFactorPathIsUnchangedBySize() async throws {
        // 2 × 0.05 × 25 A × 40 m / 8 mm² = 12.5 V, as before, a size and a metal beside it or not.
        for extra in [[:], ["wire_awg": "14", "material": "copper"]] as [[String: Any]] {
            let answer = try await run(["phase": "single", "current_a": 25, "length_m": 40,
                                        "k_factor_ohm_mm2_per_m": 0.05, "area_mm2": 8].merging(extra) { a, _ in a })
            XCTAssertTrue(answer.hasPrefix("Voltage drop ≈ 12.5 V (single-phase"), answer)
            XCTAssertTrue(answer.contains("factor 0.05 Ω·mm²/m, conductor area 8 mm²"), answer)
            XCTAssertTrue(answer.contains("not a value from any code or table"), answer)
            XCTAssertFalse(answer.contains("AWG"), answer)
        }
    }

    func testAnUnknownSizeOrAMissingMetalIsRefused() async throws {
        let base: [String: Any] = ["phase": "single", "current_a": 15, "length_ft": 50, "material": "copper"]
        let unknown = try await run(base.merging(["wire_awg": "7"]) { a, _ in a })
        XCTAssertEqual(unknown, "'wire_awg' must be an AWG size from 18 to 4/0 (18, 16, 14, 12, 10, 8, 6, 4, 3, 2, 1, "
                       + "1/0, 2/0, 3/0 or 4/0); '7' is not one. For another size, give the conductor's resistance "
                       + "per unit length or its area in circular mils ('area_cmil').")
        let kcmil = try await run(base.merging(["wire_awg": "250 kcmil"]) { a, _ in a })
        XCTAssertFalse(kcmil.contains("Voltage drop ≈"), kcmil)

        for metal in [nil, "steel"] as [String?] {
            var args: [String: Any] = ["phase": "single", "current_a": 15, "length_ft": 50, "wire_awg": "14"]
            if let metal { args["material"] = metal }
            let answer = try await run(args)
            XCTAssertEqual(answer, "Specify 'material': 'copper' or 'aluminum', the conductor's metal. It is never "
                           + "assumed: ask the technician.")
        }
        // The phase is still never assumed.
        let noPhase = try await run(["current_a": 15, "length_ft": 50, "wire_awg": "14", "material": "copper"])
        XCTAssertTrue(noPhase.contains("The phase is never assumed"), noPhase)
    }

    func testTheSchemaOffersTheSizeAndTheOperationAsChoices() {
        let properties = DomainCalcTool().parametersSchema["properties"] as? [String: Any]
        func property(_ name: String) -> [String: Any]? { properties?[name] as? [String: Any] }
        XCTAssertEqual(property("operation")?["enum"] as? [String], ["pt_lookup", "superheat", "subcool", "voltage_drop"])
        XCTAssertEqual(property("material")?["enum"] as? [String], ["copper", "aluminum"])
        XCTAssertEqual(property("wire_awg")?["type"] as? String, "string")
        XCTAssertTrue(DomainCalcTool().description.contains("'wire_awg' with 'material' is enough"))
    }

    // MARK: - The conductor file (Plan JJ decision 8)

    func testTheBundledConductorFileLoadsWithItsStatedFigures() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: ConductorTableCatalog.resourceName, withExtension: "json"),
                        "conductors.json is in the app bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("OpenGlasses/Sources/Resources/Electrical/conductors.json").path))
        let table = try conductors
        XCTAssertEqual(table.awg.map(\.size), ["18", "16", "14", "12", "10", "8", "6", "4", "3", "2", "1",
                                              "1/0", "2/0", "3/0", "4/0"])
        XCTAssertEqual(table.gauge(named: "14")?.circularMils, 4_110)
        let expected: [(VoltageDrop.Material, VoltageDrop.FactorUnit, Double)] = [
            (.copper, .ohmCircularMilsPerFoot, 12.9), (.aluminum, .ohmCircularMilsPerFoot, 21.2),
            (.copper, .ohmSquareMillimetresPerMetre, 0.02097), (.aluminum, .ohmSquareMillimetresPerMetre, 0.03453),
        ]
        for (metal, unit, value) in expected {
            let factor = try XCTUnwrap(table.factor(for: metal, unit: unit), "\(metal) \(unit)")
            XCTAssertEqual(factor.value, value, "\(metal) \(unit)")
            XCTAssertEqual(factor.temperatureC, 75, "every factor is stated at one temperature")
        }
        // The metric factors are the 20 °C standard resistivities corrected to 75 °C:
        // copper 0.017241 × (1 + 0.00393 × 55) = 0.020968, aluminium 0.028264 × (1 + 0.00403 × 55) = 0.034529.
        XCTAssertEqual(0.017241 * (1 + 0.00393 * 55), 0.02097, accuracy: 0.000005)
        XCTAssertEqual(0.028264 * (1 + 0.00403 * 55), 0.03453, accuracy: 0.000005)
        XCTAssertEqual(table.source, "standard AWG conductor areas and conductor resistivity figures at 75 °C")
        XCTAssertFalse(table.basis.isEmpty)
        XCTAssertEqual(ConductorTableCatalog.table(), table, "a second load is the cached one")

        let note = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "Vaults/electrical/conductors",
                                                                         withExtension: "md")), encoding: .utf8)
        XCTAssertTrue(note.contains("`domain_calc`") && note.contains("Never quote"), note)
        XCTAssertTrue(VaultRegistry.builtInManifest(id: VaultRegistry.electricalStarterId)?.files
            .contains("conductors.md") == true)
        // Credited in Settings › Attributions, under Reference data, as the saturation tables are.
        let view = try String(contentsOf: Self.repoRoot.appendingPathComponent("OpenGlasses/Sources/App/Views/AttributionsView.swift"),
                              encoding: .utf8)
        let row = try XCTUnwrap(view.range(of: "String(localized: \"Conductor reference data\")"), "no conductor data row")
        XCTAssertTrue(view[row.upperBound...].prefix(400).contains("Standard AWG conductor areas and conductor resistivity figures"))
    }

    func testTheLoaderParsesAFileAndRefusesABadOne() throws {
        // Invented figures: the loader reads whatever the file says.
        func file(sizes: String = #"[{"size": "QX1", "circularMils": 1000}]"#,
                  aluminium: String = #"{"material": "aluminum", "ohmCircularMilsPerFoot": {"value": 2, "temperatureC": 20}, "ohmSquareMillimetresPerMetre": {"value": 0.002, "temperatureC": 20}}"#,
                  source: String = "invented") -> Data {
            Data("""
            {"awg": \(sizes), "materials": [
              {"material": "copper", "ohmCircularMilsPerFoot": {"value": 1, "temperatureC": 20},
               "ohmSquareMillimetresPerMetre": {"value": 0.001, "temperatureC": 20}}, \(aluminium)],
             "source": "\(source)", "basis": "invented for a test"}
            """.utf8)
        }
        let table = try ConductorTable.decode(file())
        XCTAssertEqual(table.gauge(named: "QX1")?.circularMils, 1_000)
        XCTAssertEqual(table.factor(for: .aluminum, unit: .ohmSquareMillimetresPerMetre),
                       ConductorTable.Factor(value: 0.002, temperatureC: 20))
        XCTAssertEqual(VoltageDrop.WireGauge(words: "qx1 awg", table: table)?.circularMils, 1_000)

        XCTAssertThrowsError(try ConductorTable.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try ConductorTable.decode(file(sizes: "[]"))) { XCTAssertEqual($0 as? ConductorTable.Problem, .noSizes) }
        XCTAssertThrowsError(try ConductorTable.decode(file(sizes: #"[{"size": "QX1", "circularMils": 0}]"#))) {
            XCTAssertEqual($0 as? ConductorTable.Problem, .badSize("QX1"))
        }
        XCTAssertThrowsError(try ConductorTable.decode(file(aluminium: #"{"material": "steel", "ohmCircularMilsPerFoot": {"value": 2, "temperatureC": 20}, "ohmSquareMillimetresPerMetre": {"value": 0.002, "temperatureC": 20}}"#))) {
            XCTAssertEqual($0 as? ConductorTable.Problem, .missingMaterial("aluminum"))
        }
        XCTAssertThrowsError(try ConductorTable.decode(file(source: " "))) { XCTAssertEqual($0 as? ConductorTable.Problem, .noSource) }
    }

    func testWithoutTheFileTheSizeAndMetalPathsRefuseAndGivenFiguresStillWork() async throws {
        // A bundle without the file (the test bundle) and a file that does not decode refuse alike.
        let testBundle = Bundle(for: VoltageDropTests.self)
        XCTAssertNil(ConductorTableCatalog.table(bundle: testBundle))
        let sized = try await DomainCalcTool(bundle: testBundle).execute(args: [
            "operation": "voltage_drop", "phase": "single", "current_a": 15, "length_ft": 50,
            "wire_awg": "14", "material": "copper"])
        XCTAssertEqual(sized, DomainCalcTool.conductorDataUnavailable)
        XCTAssertFalse(sized.contains("Voltage drop ≈"), sized)

        let broken = try? ConductorTable.decode(Data(#"{"awg": [], "materials": [], "source": "", "basis": ""}"#.utf8))
        XCTAssertNil(broken)
        let base: [String: Any] = ["phase": "single", "current_a": 20, "length_m": 30]
        for extra in [["wire_awg": "14", "material": "copper"], ["area_mm2": 2.5, "material": "copper"],
                      ["area_cmil": 4_110, "material": "copper"], ["wire_awg": "14", "k_factor_ohm_cmil_per_ft": 10]]
            as [[String: Any]] {
            let answer = DomainCalcTool.voltageDrop(base.merging(extra) { a, _ in a }, conductors: broken)
            XCTAssertEqual(answer, DomainCalcTool.conductorDataUnavailable, "\(extra)")
        }
        // Figures the technician gives need no file: 2 × 20 × 30 × 5.25 / 1000 = 6.3 V, and
        // 2 × 0.05 × 25 × 40 / 8 = 12.5 V.
        XCTAssertTrue(DomainCalcTool.voltageDrop(base.merging(["resistance_ohm_per_km": 5.25]) { a, _ in a },
                                                 conductors: nil).hasPrefix("Voltage drop ≈ 6.3 V"))
        XCTAssertTrue(DomainCalcTool.voltageDrop(["phase": "single", "current_a": 25, "length_m": 40,
                                                  "k_factor_ohm_mm2_per_m": 0.05, "area_mm2": 8], conductors: nil)
            .hasPrefix("Voltage drop ≈ 12.5 V"))
        // The metal is asked for before the file is needed.
        XCTAssertTrue(DomainCalcTool.voltageDrop(base.merging(["area_mm2": 2.5]) { a, _ in a }, conductors: nil)
            .hasPrefix("Specify 'material'"))
    }

    // MARK: - A run given as an area in mm² with its metal (Plan JJ decision 8)

    func testAnAreaInSquareMillimetresWithItsMetal() async throws {
        // 2.5 mm² copper: the file's 0.02097 Ω·mm²/m at 75 °C, so R = 0.02097 / 2.5 = 0.008388 Ω/m.
        // Single-phase: 2 × 20 A × 30 m × 0.008388 = 1,200 × 0.008388 = 10.0656 V;
        // of a 230 V supply, 10.0656 / 230 = 4.38 %.
        let answer = try await run(["phase": "single", "current_a": 20, "length_m": 30,
                                    "area_mm2": 2.5, "material": "copper", "supply_v": 230])
        XCTAssertTrue(answer.hasPrefix("Voltage drop ≈ 10.07 V, 4.38 % of the 230 V supply (single-phase"), answer)
        XCTAssertTrue(answer.contains("conductor copper: factor 0.02097 Ω·mm²/m, conductor area 2.5 mm² (8.39 Ω/km)"), answer)
        XCTAssertTrue(answer.contains("the area is the one given and the factor the usual figure for copper at 75 °C; "
                                      + "a figure from the organisation's own book wins over these."), answer)
        XCTAssertTrue(answer.contains("Conductor data: standard AWG conductor areas"), answer)
        XCTAssertFalse(answer.contains("AWG size"), answer)
        let core = try volts(.init(phase: .single, current: 20, length: 30, lengthUnit: .metres,
                                   conductor: .factor(0.02097, .ohmSquareMillimetresPerMetre, area: 2.5), supply: 230))
        XCTAssertEqual(core, 10.0656, accuracy: 1e-9)

        // Aluminium, three-phase: √3 × 50 A × 100 m × 0.03453 / 16 mm² = 18.69 V.
        let aluminium = try await run(["phase": "three", "current_a": 50, "length_m": 100,
                                       "area_mm2": 16, "material": "aluminium"])
        XCTAssertTrue(aluminium.hasPrefix("Voltage drop ≈ 18.69 V (three-phase"), aluminium)

        // The area given wins over a wire size beside it.
        let withSize = try await run(["phase": "single", "current_a": 20, "length_m": 30,
                                      "area_mm2": 2.5, "wire_awg": "14", "material": "copper"])
        XCTAssertTrue(withSize.hasPrefix("Voltage drop ≈ 10.07 V"), withSize)
        XCTAssertFalse(withSize.contains("14 AWG"), withSize)
    }

    func testAGivenMetricFactorWinsAndTheMetalIsNeverAssumed() async throws {
        // A factor given beside the metal wins: 2 × 20 A × 30 m × 0.0225 / 2.5 mm² = 10.8 V.
        let given = try await run(["phase": "single", "current_a": 20, "length_m": 30,
                                   "k_factor_ohm_mm2_per_m": 0.0225, "area_mm2": 2.5, "material": "copper"])
        XCTAssertTrue(given.hasPrefix("Voltage drop ≈ 10.8 V"), given)
        XCTAssertTrue(given.contains("factor 0.0225 Ω·mm²/m, conductor area 2.5 mm²"), given)
        XCTAssertTrue(given.contains("not a value from any code or table"), given)
        XCTAssertFalse(given.contains("Conductor data"), given)

        for metal in [nil, "steel"] as [String?] {
            var args: [String: Any] = ["phase": "single", "current_a": 20, "length_m": 30, "area_mm2": 2.5]
            if let metal { args["material"] = metal }
            let answer = try await run(args)
            XCTAssertEqual(answer, "Specify 'material': 'copper' or 'aluminum', the conductor's metal. It is never "
                           + "assumed: ask the technician.")
        }
    }

    // MARK: - The same arithmetic in a chain

    private func run(_ chain: ChainDefinition, answers: [String], tables: [TableLookup.Source]) -> (ChainStep, ChainState) {
        var state = ChainState()
        var step = ChainRunner.advance(chain, state: &state, answer: nil, tables: tables)
        for answer in answers {
            guard case .ask = step else { break }
            step = ChainRunner.advance(chain, state: &state, answer: answer, tables: tables)
        }
        return (step, state)
    }

    func testAChainCalcReachesTheSameDropThroughNamedValues() throws {
        let file = """
        ## Three-phase drop
        Answers: the drop along a three-phase run, from values the technician says.

        ```chain
        ask current (A) range 1..400: What current does the run carry?
        ask length (m) range 1..1000: How long is the run, one way?
        ask resistance (Ω/km) range 0.01..100: What is the conductor's resistance per km?
        calc volts (V) = sqrt(3) * current * length * resistance / 1000
        ask supply (V) range 50..1000: What is the supply voltage?
        calc percent (%) = volts / supply * 100
        say "{volts} V, {percent} % of {supply} V."
        ```
        """
        let parsed = ChainParser.parse(file)
        XCTAssertEqual(parsed.problems, [], "sqrt is a function, not a name used before it is set")
        let chain = try XCTUnwrap(parsed.chains.first)
        let (step, state) = run(chain, answers: ["40", "120", "2.5", "400"], tables: [])
        guard case .finished = step else { return XCTFail("\(step)") }
        let tool = try VoltageDrop.compute(.init(phase: .three, current: 40, length: 120, lengthUnit: .metres,
                                                 conductor: .resistance(2.5, .ohmsPerKilometre), supply: 400)).get()
        XCTAssertEqual(try XCTUnwrap(state.values["volts"]?.number), tool.volts, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(state.values["percent"]?.number), try XCTUnwrap(tool.percent), accuracy: 1e-9)
    }

    /// Invented Table 96: a resistance per km by size, for a chain that looks a factor up and then
    /// computes. The values are made up and match no real conductor.
    private func resistanceTable() throws -> TableLookup.Source {
        typealias Item = TableFixtureLayouts.Item
        var page: TableFixtureLayouts.Page = [Item(text: "TABLE 96 Invented resistances", x: 50, y: 60, size: 10, bold: true)]
        page += [Item(text: "Size", x: 50, y: 90, bold: true), Item(text: "Resistance (Ω/km)", x: 200, y: 90, bold: true)]
        for (index, row) in [("QX4", "12.5"), ("QX6", "8.75"), ("QX10", "5.25")].enumerated() {
            let y = 106 + Double(index) * 14
            page += [Item(text: row.0, x: 50, y: y), Item(text: row.1, x: 200, y: y)]
        }
        let table = try XCTUnwrap(TableExtractor.extractAll(words: TableFixtureLayouts.words(page),
                                                            page: ManualTable.Page(physical: 7, printed: "30"))
            .first?.outcome.table, "the invented table extracts")
        return TableLookup.Source(documentId: "a", documentName: "Invented Book A", table: table)
    }

    func testAChainLooksTheResistanceUpThenComputesTheToolsNumber() throws {
        let file = """
        ## Single-phase drop from the table
        Answers: the drop along a single-phase run, its resistance read from the table.

        ```chain
        ask size (text): Which size is the run?
        ask current (A) range 1..400: What current does the run carry?
        ask length (m) range 1..1000: How long is the run, one way?
        lookup ohms = Table 96 row {size} column Resistance rule exact
        cite Rule QR-30
        calc volts (V) = 2 * current * length * ohms / 1000
        say "{volts} V along {size}, at {ohms} per km ({ohms.table}, {ohms.page})."
        ```
        """
        let chain = try XCTUnwrap(ChainParser.parse(file).chains.first)
        let (step, state) = run(chain, answers: ["QX6", "20", "30"], tables: [try resistanceTable()])
        guard case .finished(let said) = step else { return XCTFail("\(step)") }
        let tool = try volts(.init(phase: .single, current: 20, length: 30, lengthUnit: .metres,
                                   conductor: .resistance(8.75, .ohmsPerKilometre), supply: nil))
        XCTAssertEqual(try XCTUnwrap(state.values["volts"]?.number), tool, accuracy: 1e-9)
        XCTAssertEqual(tool, 10.5, accuracy: 1e-9)
        XCTAssertEqual(said.first?.hasPrefix("10.5 V along QX6, at 8.75 per km"), true, "\(said)")
        let readBack = ChainRunner.readBack(chain, state: state)
        XCTAssertTrue(readBack.contains("volts = 2 * current * length * ohms / 1000 = 2 * 20 * 30 * 8.75 / 1000 = 10.5 V"), readBack)
        XCTAssertTrue(readBack.contains("— follows Rule QR-30"), readBack)
    }

    func testTheOnDeviceSetIsUnchanged() {
        XCTAssertEqual(AppleOnDeviceToolSet.fieldAssistPriority,
                       ["field_session", "reading", "evidence", "deliver_report", "parts_request", "van_stock", "table_lookup"])
        let registered = ["field_session", "reading", "table_lookup", "rule_chain", "propose_chain", "domain_calc", "get_datetime"]
        for offline in [false, true] {
            let names = AppleOnDeviceToolSet.priorityNames(registered: registered, fieldAssistActive: true,
                                                           offlineHandoff: offline)
            XCTAssertFalse(names.contains("domain_calc"))
            XCTAssertFalse(names.contains("rule_chain"))
            XCTAssertTrue(names.contains("table_lookup"))
        }
    }

    func testTheEvaluatorTakesSquareRootsAndNothingElseNew() throws {
        XCTAssertEqual(try XCTUnwrap(ArithmeticExpression.evaluate("sqrt(9) * 2")), 6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ArithmeticExpression.evaluate("SQRT(3)")), 3.0.squareRoot(), accuracy: 1e-12)
        XCTAssertNil(ArithmeticExpression.evaluate("sqrt(-1)"), "no square root of a negative")
        XCTAssertNil(ArithmeticExpression.evaluate("sqrt(4"), "an unclosed bracket")
        XCTAssertNil(ArithmeticExpression.evaluate("cos(0)"), "only sqrt is a function")
        let node = try ArithmeticExpression.parse("sqrt(3) * current * length")
        XCTAssertEqual(ArithmeticExpression.names(in: node), ["current", "length"])
        // A value named sqrt, not called, is still a value.
        XCTAssertEqual(ArithmeticExpression.names(in: try ArithmeticExpression.parse("sqrt * 2")), ["sqrt"])
    }
}
