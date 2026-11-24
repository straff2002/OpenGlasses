import XCTest
@testable import OpenGlasses

/// Plan MQ P3: the step that fills a downloaded model's call from what the technician said
/// (`LocalArgumentCompletion`), and the corpus guard that keeps it off the calls a passing model makes.
final class LocalArgumentCompletionTests: XCTestCase {

    private let phoneTurn = "Line voltage at the 090XV36C control is 120. Log it, then work out the voltage drop "
        + "at 15 amps over 50 feet of 14 gauge copper."

    private func complete(_ arguments: [String: Any], name: String = "domain_calc",
                          _ messages: String...) -> LocalArgumentCompletion.Completed {
        LocalArgumentCompletion.complete(name: name, arguments: arguments,
                                         context: .init(userMessages: messages))
    }

    private func said(_ messages: String...) -> LocalArgumentCompletion.Conductor {
        LocalArgumentCompletion.conductor(in: messages, table: ConductorTableCatalog.table())
    }

    private let voltageDrop: [String: Any] = ["operation": "voltage_drop", "phase": "single", "current_a": "15",
                                              "length_ft": "50"]

    // MARK: - Reading the size and the metal

    func testEveryAWGPhrasing() throws {
        _ = try XCTUnwrap(ConductorTableCatalog.table(), "conductors.json is bundled")
        let fourteen = ["14 gauge", "14 AWG", "14awg", "#14", "# 14", "14 ga", "14-gauge", "number 14 wire",
                        "no. 14 copper", "fourteen gauge", "a 14 Gauge run"]
        for phrase in fourteen {
            XCTAssertEqual(said("over 50 feet of \(phrase) wire").awg, "14", phrase)
        }
        let others: [(String, String)] = [
            ("1/0", "1/0"), ("2/0 AWG", "2/0"), ("4/0 aluminium", "4/0"), ("two aught", "2/0"), ("one aught", "1/0"),
            ("4 aught", "4/0"), ("00 gauge", "2/0"), ("12 ga", "12"), ("#6", "6"), ("eighteen gauge", "18"),
        ]
        for (phrase, size) in others {
            XCTAssertEqual(said("run of \(phrase)").awg, size, phrase)
        }
    }

    func testEveryMetricPhrasing() {
        for phrase in ["2.5 mm²", "2.5 mm2", "2.5mm²", "2.5 mm^2", "2.5 sq mm", "2.5 sq. mm", "2.5 square mm",
                       "2.5 square millimetres", "2.5 mm squared", "2.5 square", "2.5 squared"] {
            XCTAssertEqual(said("20 m of \(phrase) copper").areaMM2, 2.5, phrase)
        }
        XCTAssertEqual(said("a 16 square cable").areaMM2, 16)
        for phrase in ["50 square feet", "12 square metres", "3 square m", "2.5 mm"] {
            XCTAssertNil(said("it's \(phrase) of copper").areaMM2, phrase)
        }
    }

    func testEveryMetalAsAWholeWord() {
        let metals: [(String, VoltageDrop.Material)] = [
            ("copper", .copper), ("Copper", .copper), ("aluminium", .aluminum), ("aluminum", .aluminum),
            ("alu", .aluminum), ("Cu", .copper), ("Al", .aluminum),
        ]
        for (word, metal) in metals {
            XCTAssertEqual(said("14 gauge \(word) run").material, metal, word)
        }
        for text in ["Smith et al said 14 gauge", "a copperhead", "the aluminate", "14 gauge, cu later"] {
            XCTAssertNil(said(text).material, text)
        }
        XCTAssertNil(said("copper-clad aluminum, 10 gauge").material, "two metals: neither")
    }

    func testOtherGaugesAndNumbersAreNotASize() {
        let conductor = said("Line voltage at the 090XV36C control is 120, two gauges on the manifold, the 2.5 is low")
        XCTAssertFalse(conductor.hasSize)
    }

    // MARK: - Filling

    func testTheTurnsGaugeMetalAndSupplyAreFilled() {
        let completed = complete(voltageDrop, phoneTurn)
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
        XCTAssertEqual(completed.arguments["material"] as? String, "copper")
        XCTAssertEqual(completed.arguments["supply_v"] as? String, "120", "the line voltage the turn opens with")
        XCTAssertEqual(completed.arguments["phase"] as? String, "single", "the phase stays the model's")
        XCTAssertEqual(completed.filled.map { $0.name }, ["wire_awg", "material", "supply_v"])
        XCTAssertEqual(completed.changes, 3)
        XCTAssertEqual(completed.removed, [])
        XCTAssertEqual(LocalArgumentCompletion.modelNote(filled: completed.filled, inferred: completed.inferred,
                                                         notUsed: completed.removed),
                       "Filled from what the technician said: wire_awg 14, material copper, supply_v 120.")
    }

    func testAnAughtSizeIsFilledAsTheTableNamesIt() {
        XCTAssertEqual(complete(voltageDrop, "40 amps over 120 feet of two aught aluminum").arguments["wire_awg"] as? String,
                       "2/0")
    }

    func testAMetricAreaIsFilledAsANumber() {
        let completed = complete(["operation": "voltage_drop", "material": "copper"], "20 metres of 2.5 mm² copper at 16 amps")
        XCTAssertEqual(completed.arguments["area_mm2"] as? Double, 2.5)
        XCTAssertNil(completed.arguments["wire_awg"])
        XCTAssertEqual(completed.changes, 1)
    }

    func testASizeTheTableDoesNotKnowIsNotFilledAndHidesNoOlderSize() {
        let completed = complete(voltageDrop, "15 amps over 50 feet of 22 gauge copper", "it's 14 gauge")
        XCTAssertNil(completed.arguments["wire_awg"])
        XCTAssertEqual(completed.arguments["material"] as? String, "copper")
        XCTAssertNil(complete(voltageDrop, "13 AWG copper").arguments["wire_awg"])
        XCTAssertNil(complete(voltageDrop, "12 or 14 gauge copper").arguments["wire_awg"], "two sizes: neither")
    }

    func testAMissingMetalIsNotFilled() {
        let completed = complete(voltageDrop, "15 amps over 50 feet of 14 gauge")
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
        XCTAssertNil(completed.arguments["material"], "the metal is never assumed")
    }

    func testNothingSaidFillsNothing() {
        let completed = complete(voltageDrop, "work out the voltage drop at 15 amps over 50 feet")
        XCTAssertEqual(completed.changes, 0)
        XCTAssertEqual(completed.arguments.count, voltageDrop.count)
        XCTAssertNil(LocalArgumentCompletion.modelNote(filled: completed.filled, notUsed: completed.removed))
    }

    func testAnEarlierMessageGivesWhatTheTurnDoesNot() {
        let completed = complete(voltageDrop, "now do it at 20 amps", "the run is 12 gauge aluminium", "it's copper, 10 gauge")
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "12", "the newest message that names one")
        XCTAssertEqual(completed.arguments["material"] as? String, "aluminum")
    }

    // MARK: - The said conductor wins

    func testTheModelsConductorFiguresGiveWayToASaidGauge() {
        // The phone's coincidences: 115 was the line voltage.
        var arguments = voltageDrop
        arguments["area_cmil"] = "115"
        arguments["k_factor_ohm_per_ft"] = "115"
        arguments["resistance_ohm_per_ft"] = "1.18"
        arguments["area_mm2"] = "2.5"
        arguments["supply_v"] = "115"
        let completed = complete(arguments, phoneTurn.replacingOccurrences(of: "120", with: "115"))
        XCTAssertEqual(completed.removed, ["area_cmil", "area_mm2", "k_factor_ohm_per_ft", "resistance_ohm_per_ft"])
        for key in completed.removed { XCTAssertNil(completed.arguments[key], key) }
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
        XCTAssertEqual(completed.arguments["supply_v"] as? String, "115", "the supply the technician said stays")
        XCTAssertEqual(completed.changes, 6)
    }

    func testAQuantityTheTechnicianStatedStays() {
        let resistance = complete(voltageDrop.merging(["resistance_ohm_per_1000ft": "2.5"]) { $1 },
                                  "14 gauge copper, resistance is 2.5 ohms per 1000 feet")
        XCTAssertEqual(resistance.arguments["resistance_ohm_per_1000ft"] as? String, "2.5")
        XCTAssertEqual(resistance.removed, [])

        let factor = complete(voltageDrop.merging(["k_factor_ohm_cmil_per_ft": "12.9"]) { $1 }, "14 gauge copper, k of 12.9")
        XCTAssertEqual(factor.arguments["k_factor_ohm_cmil_per_ft"] as? String, "12.9")

        let area = complete(voltageDrop.merging(["area_cmil": "4110"]) { $1 }, "14 gauge copper, 4110 circular mils")
        XCTAssertEqual(area.arguments["area_cmil"] as? String, "4110")
    }

    func testAMetalAloneTakesNothingOff() {
        let completed = complete(voltageDrop.merging(["resistance_ohm_per_ft": "0.003"]) { $1 },
                                 "copper, 0.003 per foot")
        XCTAssertEqual(completed.arguments["resistance_ohm_per_ft"] as? String, "0.003")
        XCTAssertEqual(completed.removed, [])
    }

    func testAContradictingMaterialIsReplaced() {
        let completed = complete(voltageDrop.merging(["material": "aluminum", "wire_awg": "14", "supply_v": "120"]) { $1 }, phoneTurn)
        XCTAssertEqual(completed.arguments["material"] as? String, "copper")
        XCTAssertEqual(completed.filled.map { $0.name }, ["material"])
        XCTAssertEqual(completed.changes, 1)
    }

    func testTheKindOfSizeSaidDecidesBetweenAreaAndGauge() {
        let metric = complete(voltageDrop.merging(["wire_awg": "14", "material": "copper"]) { $1 }, "20 m of 2.5 mm2 copper")
        XCTAssertEqual(metric.arguments["area_mm2"] as? Double, 2.5)
        XCTAssertNil(metric.arguments["wire_awg"])
        XCTAssertEqual(metric.removed, ["wire_awg"])

        let gauge = complete(voltageDrop.merging(["area_mm2": 2.5, "material": "copper"]) { $1 }, phoneTurn)
        XCTAssertEqual(gauge.arguments["wire_awg"] as? String, "14")
        XCTAssertNil(gauge.arguments["area_mm2"])
        XCTAssertEqual(gauge.removed, ["area_mm2"])

        let both = complete(voltageDrop, "14 gauge, that's 2.5 mm² copper")
        XCTAssertEqual(both.arguments["wire_awg"] as? String, "14")
        XCTAssertEqual(both.arguments["area_mm2"] as? Double, 2.5, "both said: the tool's own precedence decides")
    }

    func testTheModelsOwnMatchingValuesAreLeftAsSent() {
        let completed = complete(voltageDrop.merging(["wire_awg": "14 AWG", "material": "Copper", "supply_v": "120"]) { $1 }, phoneTurn)
        XCTAssertEqual(completed.changes, 0)
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14 AWG")
    }

    // MARK: - The supply

    func testEverySupplyWording() {
        let wordings: [(String, Double)] = [
            (phoneTurn, 120), ("Line voltage at the 070XV36B control is 115.", 115), ("the supply is 230 V", 230),
            ("supply is 230V", 230), ("it's a 230 volt supply", 230), ("230-volt supply", 230), ("240 VAC mains", 240),
            ("120 V at the panel", 120), ("118 volts at the control", 118), ("240 V from the disconnect", 240),
            ("measured 118 volts line to neutral", 118), ("208 V L-L", 208), ("120 V phase to ground", 120),
            ("line voltage 120", 120), ("line voltage reads 119.5", 119.5), ("mains of 240 volts", 240),
            ("incoming is 277 V", 277), ("supply voltage: 230", 230), ("line voltage under load is 114 volts", 114),
            ("line voltage was 120, supply is 120 V", 120), ("what's the drop on a 120 volt supply", 120),
            ("keep the drop under 3 percent on the 230 V supply", 230),
        ]
        for (text, volts) in wordings {
            XCTAssertEqual(LocalArgumentCompletion.supplyVoltage(in: [text]), volts, text)
        }
    }

    func testADropALimitOrAnotherQuantityIsNotTheSupply() {
        for text in ["the drop is 3 V", "a drop of 3 V at the panel", "no more than 5 V at the panel", "3 V drop on the supply",
                     "line voltage drop of 3 volts", "supply loss of 4 volts", "keep the line voltage drop under 3 percent",
                     "line voltage drop at 15 amps over 50 feet", "line pressure is 7.5", "liquid line temperature is 95",
                     "24 VAC at the thermostat", "measured 118 volts", "the 090XV36C control", "line voltage is fine",
                     "Log line pressure, in. w.c., Natural at 7.5 in. w.c.", "supply voltage for a 3 phase run",
                     "transformer kit, 75 VA, 24 V accessories", "supply is within 5 V"] {
            XCTAssertNil(LocalArgumentCompletion.supplyVoltage(in: [text]), text)
        }
    }

    func testTwoSuppliesGiveNoneAndHideNoOlderOne() {
        XCTAssertNil(LocalArgumentCompletion.supplyVoltage(in: ["supply is 230 V, or 240 V at the panel"]))
        let completed = complete(voltageDrop, "it's 230 volt supply or maybe 240 V mains, 14 gauge copper", "supply is 120 V")
        XCTAssertNil(completed.arguments["supply_v"], "two supplies: neither, and no older one")
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
    }

    func testAnEarlierMessageGivesTheSupplyTheTurnDoesNot() {
        let completed = complete(voltageDrop, "work out the drop at 15 amps over 50 feet of 14 gauge copper",
                                 "the supply is 230 V", "line voltage is 120")
        XCTAssertEqual(completed.arguments["supply_v"] as? String, "230", "the newest message that states one")
    }

    func testTheModelsDifferentSupplyIsReplacedAndItsOwnMatchingOneKept() {
        let different = complete(voltageDrop.merging(["supply_v": "240"]) { $1 }, phoneTurn)
        XCTAssertEqual(different.arguments["supply_v"] as? String, "120", "the technician's reading wins")
        XCTAssertTrue(different.filled.contains { $0.name == "supply_v" && $0.value == "120" })
        XCTAssertTrue(different.governs("supply_v"))

        let matching = complete(voltageDrop.merging(["supply_v": 120, "wire_awg": "14", "material": "copper"]) { $1 }, phoneTurn)
        XCTAssertEqual(matching.changes, 0)
        XCTAssertEqual(matching.arguments["supply_v"] as? Int, 120, "left as sent")
    }

    func testNoSupplySaidFillsNone() {
        let completed = complete(voltageDrop, "15 amps over 50 feet of 14 gauge copper")
        XCTAssertNil(completed.arguments["supply_v"], "never invented")
        XCTAssertFalse(completed.governs("supply_v"))
        // The supply is read only from what the technician said: the context carries their messages alone.
        XCTAssertNil(complete(["operation": "superheat", "refrigerant": "R-410A"], phoneTurn).arguments["supply_v"])
        XCTAssertNil(complete(["action": "record_reading", "value": "120"], name: "reading", phoneTurn).arguments["supply_v"])
    }

    // MARK: - A voltage drop with no operation

    func testGemmasCallWithNoOperationIsAVoltageDrop() {
        // Gemma 4 E2B on the phone, after grounding took the made-up factor off.
        let gemma: [String: Any] = ["current_a": "15", "length_ft": "50", "material": "copper"]
        XCTAssertTrue(LocalArgumentCompletion.isVoltageDrop(name: "domain_calc", arguments: gemma))
        let completed = complete(gemma, phoneTurn)
        XCTAssertEqual(completed.arguments["operation"] as? String, "voltage_drop")
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
        XCTAssertEqual(completed.arguments["supply_v"] as? String, "120")
        XCTAssertEqual(completed.inferred.map { $0.name }, ["operation"])
        XCTAssertEqual(completed.changes, 3, "the operation, the size and the supply")
        XCTAssertEqual(LocalArgumentCompletion.modelNote(filled: completed.filled, inferred: completed.inferred,
                                                         notUsed: completed.removed),
                       "Set from the call's own arguments: operation voltage_drop. "
                       + "Filled from what the technician said: wire_awg 14, supply_v 120.")

        // With the made-up factor still on it, the said gauge takes it off.
        let unfiltered = complete(gemma.merging(["k_factor_ohm_per_ft": "2.617"]) { $1 }, phoneTurn)
        XCTAssertEqual(unfiltered.arguments["operation"] as? String, "voltage_drop")
        XCTAssertEqual(unfiltered.removed, ["k_factor_ohm_per_ft"])

        XCTAssertEqual(complete(["operation": " ", "current_a": 15, "length_m": 20], "supply is 230 V")
            .arguments["operation"] as? String, "voltage_drop", "a blank operation names none")
    }

    func testACallShapedForAnotherOperationIsNotAVoltageDrop() {
        let shapes: [[String: Any]] = [
            ["refrigerant": "R-410A", "suction_pressure_psig": 118, "suction_line_temp_f": 52],
            ["current_a": 15, "length_ft": 50, "refrigerant": "R-410A"],
            ["current_a": 15, "length_ft": 50, "pressure_psig": 118],
            ["current_a": 15, "length_ft": 50, "note": "superheat"],
            ["current_a": 15],
            ["length_ft": 50, "material": "copper"],
        ]
        for arguments in shapes {
            XCTAssertFalse(LocalArgumentCompletion.isVoltageDrop(name: "domain_calc", arguments: arguments), "\(arguments)")
            let completed = complete(arguments, phoneTurn)
            XCTAssertEqual(completed.changes, 0, "\(arguments)")
            XCTAssertNil(completed.arguments["operation"])
        }
        XCTAssertNil(complete(["current_a": 15, "length_ft": 50], name: "table_lookup", phoneTurn).arguments["operation"])
        XCTAssertNil(complete(["operation": "superheat", "current_a": 15, "length_ft": 50], phoneTurn).arguments["supply_v"],
                     "an operation that names another one decides")
    }

    /// The shape keys are `DomainCalcTool`'s own: the current and the lengths are declared for
    /// `voltage_drop` alone, and every property another operation declares starts with a prefix the
    /// shape refuses, while none of the voltage drop's do.
    @MainActor
    func testTheVoltageDropShapeIsTheSchemas() throws {
        let schema = DomainCalcTool().parametersSchema
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let shape = LocalArgumentCompletion.voltageDropShape
        func description(_ key: String) -> String { properties[key]?["description"] as? String ?? "" }
        for key in [shape.current] + shape.lengths {
            XCTAssertTrue(description(key).hasPrefix("For 'voltage_drop'"), key)
        }
        func refused(_ key: String) -> Bool { shape.otherOperationPrefixes.contains { key.hasPrefix($0) } }
        for (key, _) in properties where key != "operation" {
            let forOthers = ["'pt_lookup'", "'superheat'", "'subcool'", "Refrigerant", "refrigerant", "gauge pressure",
                             "altitude"].contains { description(key).contains($0) }
            if description(key).hasPrefix("For 'voltage_drop'") {
                XCTAssertFalse(refused(key), "a voltage drop's own key is refused: \(key)")
            } else if forOthers {
                XCTAssertTrue(refused(key), "another operation's key is not refused: \(key)")
            }
        }
    }

    // MARK: - Which calls

    func testOtherCallsAreUntouched() {
        let superheat: [String: Any] = ["operation": "superheat", "refrigerant": "R-410A"]
        XCTAssertEqual(complete(superheat, phoneTurn).changes, 0)
        XCTAssertEqual(complete(["operation": "superheat", "note": "voltage_drop"], phoneTurn).changes, 0,
                       "an operation that names another one decides")
        XCTAssertEqual(complete(["action": "record_reading", "value": "120"], name: "reading", phoneTurn).changes, 0)
        XCTAssertEqual(complete(["operation": "voltage_drop"], name: "table_lookup", phoneTurn).changes, 0)
    }

    func testAMisnamedOperationStillCounts() {
        // The coercion that moves `application` to `operation` runs later, in the dispatcher.
        let completed = complete(["application": "voltage_drop", "current_a": 15, "length_ft": 50], phoneTurn)
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
        XCTAssertTrue(LocalArgumentCompletion.isVoltageDrop(name: "domain_calc", arguments: ["operation": "Voltage Drop"]))
    }

    func testAMissingConductorFileFillsNoSize() {
        let completed = LocalArgumentCompletion.complete(name: "domain_calc", arguments: voltageDrop,
                                                         context: .init(userMessages: [phoneTurn], conductors: { nil }))
        XCTAssertNil(completed.arguments["wire_awg"])
        XCTAssertEqual(completed.arguments["material"] as? String, "copper")
    }

    // MARK: - The model's note

    func testTheModelNoteSaysWhatWasFilledAndWhatWasNotUsed() {
        XCTAssertEqual(LocalArgumentCompletion.modelNote(filled: [("wire_awg", "14"), ("material", "copper")], notUsed: []),
                       "Filled from what the technician said: wire_awg 14, material copper.")
        XCTAssertEqual(LocalArgumentCompletion.modelNote(filled: [("wire_awg", "14")],
                                                         notUsed: ["area_cmil", "resistance_ohm_per_ft"]),
                       "Filled from what the technician said: wire_awg 14. "
                       + "Not used, because the technician named the wire: area_cmil, resistance_ohm_per_ft.")
        XCTAssertNil(LocalArgumentCompletion.modelNote(filled: [], notUsed: []))
    }

    // MARK: - The source rule

    func testShowSourceGetsTheOrdinalTheTurnPutOnTheSource() {
        for (turn, which) in [("Show me the last source you used", "last"), ("Show me the first source you used", "first"),
                              ("Open the second page", "second"), ("Show me the latest one", "last")] {
            let completed = complete([:], name: "show_source", turn)
            XCTAssertEqual(completed.arguments["which"] as? String, which, turn)
            XCTAssertEqual(completed.filled.map { $0.name }, ["which"], turn)
            XCTAssertEqual(complete(["which": "  "], name: "show_source", turn).arguments["which"] as? String, which,
                           "a blank which is none: \(turn)")
        }
    }

    func testWhatTheTurnNamesReplacesTheModelsWhich() {
        for (given, turn, which) in [
            ("first", "Show me the page that table came from", "table"),
            ("table", "Show me the last source you used", "last"),
            ("first", "Open Table 99", "Table 99"),
            ("first", "Show me all the pages", "all"),
        ] {
            let completed = complete(["which": given], name: "show_source", turn)
            XCTAssertEqual(completed.arguments["which"] as? String, which, turn)
            XCTAssertEqual(completed.filled.map { $0.name }, ["which"], turn)
        }
        XCTAssertNil(complete(["which": "first"], name: "show_source",
                              "Show me that table and the last source").filled.first,
                     "two sources named: the model's stands")
    }

    func testShowSourceIsNeverGuessed() {
        for turn in ["Show me the page for the second burner", "Show me where it says that",
                     "Show me the first source and the last one", "Show me that"] {
            let completed = complete([:], name: "show_source", turn)
            XCTAssertNil(completed.arguments["which"], turn)
            XCTAssertEqual(completed.changes, 0, turn)
        }
        let given = complete(["which": "table"], name: "show_source", "Show me that")
        XCTAssertEqual(given.arguments["which"] as? String, "table", "with nothing said, the model's which stands")
        XCTAssertEqual(given.changes, 0)
        XCTAssertEqual(complete(["which": "last"], name: "show_source", "Show me the last source you used").changes, 0,
                       "the same which is no change")
        XCTAssertEqual(complete([:], name: "table_lookup", "Show me the last source you used").changes, 0)
        XCTAssertEqual(LocalArgumentCompletion.modelNote(filled: [("which", "last")], notUsed: []),
                       "Filled from what the technician said: which last.")
    }

    // MARK: - The corpus guard

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/local-tool-eval/corpus", isDirectory: true)
            .appendingPathComponent(LocalToolEval.corpusFileName)
    }

    /// Every reference call a passing model makes, grounded and then completed as the loop does it:
    /// completion never changes or removes an argument a case expects, and changes nothing else on a
    /// call that already carries what was said. Counts only.
    func testCompletionNeverChangesAnArgumentAReferenceCallNeeds() throws {
        let text = try String(contentsOf: Self.corpusURL, encoding: .utf8)
        let loaded = LocalToolEval.loadCorpus(text)
        XCTAssertEqual(loaded.undecodable, 0)
        XCTAssertGreaterThan(loaded.cases.count, 100)
        _ = try XCTUnwrap(ConductorTableCatalog.table())

        var referenceCalls = 0
        var referenceArguments = 0
        var voltageDropCalls = 0
        var changedArguments = 0
        var wronglyChanged: [String] = []
        for testCase in loaded.cases {
            let history = testCase.loopHistory
            var grounding = LocalArgumentGrounding.Grounding(history.map(\.content) + [testCase.turn])
            let context = LocalArgumentCompletion.Context(
                userMessages: [testCase.turn] + history.filter { $0.role == .user }.reversed().map(\.content))
            let expected = testCase.expect.calls
            var callIndex = 0
            for reference in testCase.reference ?? [] {
                for invocation in LocalToolLoop.parse(reference).invocations {
                    let grounded = LocalArgumentGrounding.filter(invocation.arguments, grounding: grounding).arguments
                    let completed = LocalArgumentCompletion.complete(name: invocation.name, arguments: grounded,
                                                                     context: context)
                    referenceCalls += 1
                    referenceArguments += invocation.arguments.count
                    if LocalArgumentCompletion.isVoltageDrop(name: invocation.name, arguments: grounded) {
                        voltageDropCalls += 1
                    }
                    changedArguments += completed.changes
                    let needed = expected.indices.contains(callIndex)
                        ? expected[callIndex].variant(for: invocation.name).map { Set($0.required).union($0.values.keys) } ?? []
                        : []
                    let touched = Set(completed.removed).union(completed.filled.map { $0.name }.filter { grounded[$0] != nil })
                    for name in touched.sorted() where needed.contains(name) {
                        wronglyChanged.append("\(testCase.id) call \(callIndex) \(name)")
                    }
                    if let result = testCase.results?[invocation.name] { grounding.add(result) }
                    callIndex += 1
                }
            }
        }
        XCTAssertGreaterThan(referenceArguments, 500)
        XCTAssertGreaterThan(voltageDropCalls, 0, "the corpus carries voltage-drop calls for the rule to see")
        XCTAssertEqual(wronglyChanged, [], "completion changed an argument a correct call needs")
        XCTAssertEqual(changedArguments, 0, "reference arguments changed: \(changedArguments) of \(referenceArguments)")
        print("local-argument-completion corpus guard: \(changedArguments) of \(referenceArguments) reference arguments "
              + "changed over \(referenceCalls) calls (\(voltageDropCalls) voltage drop)")
    }
}
