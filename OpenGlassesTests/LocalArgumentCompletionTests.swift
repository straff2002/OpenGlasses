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

    func testTheTurnsGaugeAndMetalAreFilled() {
        let completed = complete(voltageDrop, phoneTurn)
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14")
        XCTAssertEqual(completed.arguments["material"] as? String, "copper")
        XCTAssertEqual(completed.arguments["phase"] as? String, "single", "the phase stays the model's")
        XCTAssertNil(completed.arguments["supply_v"], "never the supply")
        XCTAssertEqual(completed.changes, 2)
        XCTAssertEqual(completed.removed, [])
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
        XCTAssertEqual(completed.arguments["supply_v"] as? String, "115", "the supply is left alone")
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
        let completed = complete(voltageDrop.merging(["material": "aluminum", "wire_awg": "14"]) { $1 }, phoneTurn)
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
        let completed = complete(voltageDrop.merging(["wire_awg": "14 AWG", "material": "Copper"]) { $1 }, phoneTurn)
        XCTAssertEqual(completed.changes, 0)
        XCTAssertEqual(completed.arguments["wire_awg"] as? String, "14 AWG")
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
