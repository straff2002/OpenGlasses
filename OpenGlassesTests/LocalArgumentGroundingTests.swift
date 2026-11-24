import XCTest
@testable import OpenGlasses

/// Plan MQ P3: the filter that takes numbers nobody said off a downloaded model's calls
/// (`LocalArgumentGrounding`), and the corpus guard that keeps it off the calls a passing model makes.
final class LocalArgumentGroundingTests: XCTestCase {

    private func dropped(_ arguments: [String: Any], _ grounding: String...) -> [String] {
        LocalArgumentGrounding.filter(arguments, groundingText: grounding).dropped
    }

    // MARK: - What a plain number is

    func testPlainNumbersInTheirWrittenForms() {
        let cases: [(Any, Double)] = [
            ("115", 115), ("0.68", 0.68), (".68", 0.68), ("-4", -4), ("\u{2212}4", -4), ("+3", 3), ("1,200", 1200),
            ("115V", 115), ("7.5 inWC", 7.5), ("15%", 15), ("65\u{00B0}F", 65), (" 120 ", 120), ("6\"", 6),
            (120, 120), (0.5, 0.5), (NSNumber(value: 42), 42),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(LocalArgumentGrounding.plainNumber(value), expected, "\(value)")
        }
    }

    func testAnythingElseIsNotAPlainNumber() {
        let values: [Any] = ["1/0", "4/0", "090XV36C", "E223", "R-410A", "3-phase", "copper", "3 bolts on the left",
                             "true", true, false, NSNumber(value: true), "", "7:30", ["x": 1], [16.0]]
        for value in values {
            XCTAssertNil(LocalArgumentGrounding.plainNumber(value), "\(value)")
        }
    }

    // MARK: - Matching

    func testNumbersMatchByValueAfterNormalising() {
        XCTAssertEqual(dropped(["a": "115.0", "b": ".68", "c": 1200, "d": "115V", "e": 0.68],
                               "Supply 115 volts, gap 0.68, fan at 1,200 rpm"), [])
        XCTAssertEqual(dropped(["a": "1200"], "fan at 1,200 rpm"), [])
        XCTAssertEqual(dropped(["a": 115], "it reads 115.0"), [])
    }

    func testANumberWrittenAgainstItsUnitCounts() {
        XCTAssertEqual(dropped(["v": "115", "p": 7.5], "It reads 115V and 7.5in on the manometer"), [])
    }

    func testTheSignIsNotCompared() {
        XCTAssertEqual(dropped(["t": "-4"], "the coil is minus 4"), [])
        XCTAssertEqual(dropped(["t": 4], "it's -4 out there"), [])
    }

    func testSpelledNumbersCount() {
        XCTAssertEqual(dropped(["current_a": 15, "length_ft": 50, "wire_awg": "12"],
                               "fifteen amps over fifty feet of twelve gauge"), [])
        XCTAssertEqual(dropped(["a": 25, "b": 250, "c": 0, "d": 1500],
                               "twenty-five, two hundred and fifty, zero, one thousand five hundred"), [])
        XCTAssertEqual(dropped(["a": 26], "twenty-five"), ["a"])
    }

    func testADurationGroundsItsSecondsAndMinutes() {
        XCTAssertEqual(dropped(["seconds": "600"], "Set a timer for ten minutes"), [])
        XCTAssertEqual(dropped(["seconds": 1800], "half an hour"), [])
        XCTAssertEqual(dropped(["seconds": 7200, "duration_minutes": 120], "book 2 hours"), [])
        XCTAssertEqual(dropped(["seconds": 90], "ten minutes"), ["seconds"])
    }

    func testANumberNobodySaidIsDroppedAndEverythingElseStays() {
        // The phone's call: conductor figures the technician never gave.
        let turn = "Line voltage at the 090XV36C control is 120. Log it, then work out the voltage drop at 15 amps "
            + "over 50 feet of 14 gauge copper."
        let arguments: [String: Any] = [
            "operation": "voltage_drop", "current_a": "15", "length_ft": 50, "wire_awg": "14", "material": "copper",
            "supply_v": 120, "resistance_ohm_per_ft": "16.0", "area_cmil": "22030", "k_factor_ohm_cmil_per_ft": "5.3144",
        ]
        let filtered = LocalArgumentGrounding.filter(arguments, groundingText: [turn])
        XCTAssertEqual(filtered.dropped, ["area_cmil", "k_factor_ohm_cmil_per_ft", "resistance_ohm_per_ft"])
        XCTAssertEqual(Set(filtered.arguments.keys),
                       ["operation", "current_a", "length_ft", "wire_awg", "material", "supply_v"])
    }

    func testAConvertedValueIsDropped() {
        // Accepted: the tool takes the unit the technician used.
        XCTAssertEqual(dropped(["length_m": 15.24], "50 feet of 14 gauge"), ["length_m"])
    }

    func testNonNumericValuesAreNeverTouched() {
        let arguments: [String: Any] = [
            "material": "copper", "wire_awg": "1/0", "query": "090XV36C", "flag": true, "off": false,
            "nested": ["x": 16.0], "list": [16.0, 260], "procedure_id": "slp99_no_ignition", "empty": "",
        ]
        let filtered = LocalArgumentGrounding.filter(arguments, groundingText: [])
        XCTAssertEqual(filtered.dropped, [])
        XCTAssertEqual(filtered.arguments.count, arguments.count)
    }

    func testPagingControlsAreExempt() {
        XCTAssertEqual(dropped(["offset": 10, "limit": "5", "page": 14]), ["page"])
    }

    func testToolResultsAndExtraGroundingCount() {
        var grounding = LocalArgumentGrounding.Grounding(["log the inducer's rated amps"])
        XCTAssertEqual(LocalArgumentGrounding.filter(["value": "3.2"], grounding: grounding).dropped, ["value"])
        grounding.add("090XV36C: inducer rated 3.2 A.")
        XCTAssertEqual(LocalArgumentGrounding.filter(["value": "3.2"], grounding: grounding).dropped, [])
        XCTAssertEqual(dropped(["value": 118], "log the suction again", "Readings so far: suction 118 psig."), [])
    }

    func testTheModelNoteNamesWhatWasNotUsed() {
        XCTAssertEqual(LocalArgumentGrounding.modelNote(dropped: ["area_cmil", "resistance_ohm_per_ft"]),
                       "Not used, because nobody said these numbers: area_cmil, resistance_ohm_per_ft. "
                       + "Ask for a value rather than guess it.")
        XCTAssertFalse(LocalArgumentGrounding.modelNote(dropped: ["a"]).contains(where: \.isNumber),
                       "no number of its own that a later call could take")
    }

    func testTheAppGroundsOnTheJobContextOfThePromptAlone() {
        let prompt = "CURRENT DATE & TIME: Monday, 23 November 2026, 9:41 am\n\n<field_assist_context>\nReadings: "
            + "suction 118 psig\n</field_assist_context>\n\nTOOLS: one or two sentences."
        XCTAssertEqual(LLMService.localGroundingText(systemPrompt: prompt), ["\nReadings: suction 118 psig\n"])
        XCTAssertEqual(LLMService.localGroundingText(systemPrompt: "No job open. 23 November 2026."), [])
    }

    // MARK: - The corpus guard

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/local-tool-eval/corpus", isDirectory: true)
            .appendingPathComponent(LocalToolEval.corpusFileName)
    }

    /// Every reference call a passing model makes, filtered with what its case's turn, history and
    /// earlier scripted results ground: the filter never drops an argument a case expects, and drops
    /// next to nothing else. Counts only.
    func testTheFilterNeverDropsAnArgumentAReferenceCallNeeds() throws {
        let text = try String(contentsOf: Self.corpusURL, encoding: .utf8)
        let loaded = LocalToolEval.loadCorpus(text)
        XCTAssertEqual(loaded.undecodable, 0)
        XCTAssertGreaterThan(loaded.cases.count, 100)

        var referenceArguments = 0
        var droppedArguments = 0
        var wronglyDropped: [String] = []
        for testCase in loaded.cases {
            var grounding = LocalArgumentGrounding.Grounding(
                (testCase.history ?? []).map(\.content) + [testCase.turn])
            let expected = testCase.expect.calls
            var callIndex = 0
            for reference in testCase.reference ?? [] {
                for invocation in LocalToolLoop.parse(reference).invocations {
                    let filtered = LocalArgumentGrounding.filter(invocation.arguments, grounding: grounding)
                    referenceArguments += invocation.arguments.count
                    droppedArguments += filtered.dropped.count
                    let needed = expected.indices.contains(callIndex)
                        ? expected[callIndex].variant(for: invocation.name).map { Set($0.required).union($0.values.keys) } ?? []
                        : []
                    for name in filtered.dropped where needed.contains(name) {
                        wronglyDropped.append("\(testCase.id) call \(callIndex) \(name)")
                    }
                    if let result = testCase.results?[invocation.name] { grounding.add(result) }
                    callIndex += 1
                }
            }
        }
        XCTAssertGreaterThan(referenceArguments, 500)
        XCTAssertEqual(wronglyDropped, [], "the filter took off an argument a correct call needs")
        XCTAssertEqual(droppedArguments, 0, "reference arguments dropped: \(droppedArguments) of \(referenceArguments)")
        print("local-argument-grounding corpus guard: \(droppedArguments) of \(referenceArguments) reference arguments dropped")
    }
}
