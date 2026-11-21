import XCTest
@testable import OpenGlasses

/// Plan MQ P0's CI runner: the local tool corpus played through the shipped loop, parser, coercion
/// and reading check against a scripted fake model. This is where a regression in any of them is
/// caught; P3's Mac screener and device app hand the same cases to real models.
///
/// Output is counts only (`LocalToolEval.Report`), never a turn, a passage or an answer.
@MainActor
final class LocalToolEvalCorpusTests: XCTestCase {

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LocalToolEval
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/local-tool-eval/corpus", isDirectory: true)
            .appendingPathComponent(LocalToolEval.corpusFileName)
    }

    private var registry: NativeToolRegistry!

    override func setUp() {
        super.setUp()
        registry = NativeToolRegistry(locationService: LocationService())
    }

    override func tearDown() {
        registry = nil
        super.tearDown()
    }

    private func corpus() throws -> [LocalToolEval.Case] {
        let text = try String(contentsOf: Self.corpusURL, encoding: .utf8)
        let loaded = LocalToolEval.loadCorpus(text)
        XCTAssertEqual(loaded.undecodable, 0, "a corpus line does not decode")
        return loaded.cases
    }

    private func schema(_ name: String) -> OnDeviceToolSchema.Node? {
        registry.tool(named: name).map {
            OnDeviceToolSchema.root(toolName: name, parameters: $0.parametersSchema)
        }
    }

    private func environment(_ generate: @escaping (LocalToolEval.Case, LocalToolLoop.GenerationRequest, Int)
                                async throws -> String = LocalToolEval.referenceModel) -> LocalToolEval.Environment {
        // Read once here, on the main actor: the registry's tools are main-actor types, and the
        // loop runs off it.
        var schemas: [String: OnDeviceToolSchema.Node] = [:]
        for name in registry.toolNames { schemas[name] = schema(name) }
        let frozen = schemas
        return LocalToolEval.Environment(generate: generate, schema: { frozen[$0] },
                                         referenceModelID: "mlx-community/gemma-4-e2b-it-4bit")
    }

    // MARK: - The corpus itself

    func testTheCorpusCoversEveryCategoryWithUniqueIDs() throws {
        let cases = try corpus()
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "case ids must be unique")
        for category in LocalToolEval.Category.allCases {
            XCTAssertGreaterThanOrEqual(cases.filter { $0.category == category }.count, 2,
                                        "\(category.rawValue) needs cases")
        }
    }

    func testEveryExpectationNamesARealToolAndItsDeclaredArguments() throws {
        for testCase in try corpus() {
            for name in testCase.offered {
                XCTAssertNotNil(registry.tool(named: name), "\(testCase.id) offers \(name), which is not registered")
                XCTAssertTrue(OfflineToolPolicy.isOfferedOffline(name), "\(testCase.id): \(name) needs the network")
            }
            for call in testCase.expect.calls {
                XCTAssertTrue(testCase.offered.contains(call.tool), "\(testCase.id) expects \(call.tool) but doesn't offer it")
                guard case .object(_, _, let properties)? = schema(call.tool) else {
                    XCTFail("\(testCase.id): \(call.tool) has no schema"); continue
                }
                let declared = Set(properties.map(\.name))
                for name in call.required + Array(call.values.keys) {
                    XCTAssertTrue(declared.contains(name), "\(testCase.id): \(call.tool) declares no '\(name)'")
                }
            }
            if testCase.category == .notInManual {
                XCTAssertNotNil(testCase.reading, testCase.id)
                XCTAssertNotNil(testCase.expect.readingAccepted, testCase.id)
            }
            if testCase.category == .longPrompt { XCTAssertNotNil(testCase.contextTokens, testCase.id) }
            if testCase.category == .cancellation { XCTAssertNotNil(testCase.cancel, testCase.id) }
            if testCase.category == .twoStep { XCTAssertGreaterThanOrEqual(testCase.expect.calls.count, 2, testCase.id) }
        }
    }

    func testTheCorpusHoldsNotInTheManualCasesBothWays() throws {
        let readings = try corpus().filter { $0.category == .notInManual }
        XCTAssertTrue(readings.contains { $0.expect.readingAccepted == true }, "a control the check must accept")
        XCTAssertGreaterThanOrEqual(readings.filter { $0.expect.readingAccepted == false }.count, 3)
    }

    // MARK: - The reference model passes

    func testEveryReferenceRunPassesEveryGrader() async throws {
        let cases = try corpus()
        var report = LocalToolEval.Report()
        let repeats = 3
        for testCase in cases {
            for _ in 0..<repeats {
                let run = await LocalToolEval.run(testCase, environment: environment())
                report.add(run)
                let failed = run.grades.filter { !$0.value }.map(\.key.rawValue).sorted()
                XCTAssertTrue(run.passed, "\(testCase.id) failed \(failed)")
            }
        }
        XCTAssertEqual(report.overall.runs, cases.count * repeats)
        // Counts only.
        for line in report.lines() { print(line) }
        let printed = report.lines().joined(separator: "\n")
        for testCase in cases {
            XCTAssertFalse(printed.contains(testCase.turn), "the report must never carry a turn")
            for passage in (testCase.passages ?? [:]).values {
                XCTAssertFalse(printed.contains(passage), "the report must never carry a passage")
            }
        }
    }

    // MARK: - The graders catch what they exist to catch

    private func runCase(_ id: String, script: [String]) async throws -> LocalToolEval.Run {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == id })
        return await LocalToolEval.run(testCase, environment: environment { _, _, index in
            index < script.count ? script[index] : ""
        })
    }

    func testTheWrongToolFailsToolName() async throws {
        let run = try await runCase("choice-03", script: [
            #"<tool_call>{"name": "field_session", "arguments": {"action": "status"}}</tool_call>"#, "Done.",
        ])
        XCTAssertEqual(run.grades[.toolName], false)
    }

    func testAMissingRequiredArgumentFailsPresence() async throws {
        let run = try await runCase("choice-03", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading"}}</tool_call>"#, "Done.",
        ])
        XCTAssertEqual(run.grades[.toolName], true)
        XCTAssertEqual(run.grades[.argumentPresence], false)
    }

    func testAValueThatCannotBeReadAtItsTypeFailsTypes() async throws {
        let run = try await runCase("choice-06", script: [
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "superheat", "refrigerant": "R-454B", "suction_pressure_psig": "about a hundred", "suction_line_temp_f": 52}}</tool_call>"#,
            "Done.",
        ])
        XCTAssertEqual(run.grades[.argumentTypes], false)
    }

    func testANumberWrittenAsTextStillPassesTypesAfterCoercion() async throws {
        let run = try await runCase("choice-06", script: [
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "superheat", "refrigerant": "R-454B", "suction_pressure_psig": "118", "suction_line_temp_f": "52"}}</tool_call>"#,
            "Superheat is 11.8 degrees.",
        ])
        XCTAssertEqual(run.grades[.argumentTypes], true)
        XCTAssertEqual(run.grades[.argumentValues], true)
    }

    func testAWrongValueFailsValues() async throws {
        let run = try await runCase("choice-03", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "180", "unit": "psig"}}</tool_call>"#,
            "Logged.",
        ])
        XCTAssertEqual(run.grades[.argumentValues], false)
    }

    func testARepeatedCallFailsNoRepeats() async throws {
        let call = #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "118", "unit": "psig"}}</tool_call>"#
        let run = try await runCase("choice-03", script: [call, call, "Logged."])
        XCTAssertEqual(run.grades[.noRepeats], false)
    }

    func testAToolOnARestraintCaseFails() async throws {
        let run = try await runCase("restraint-01", script: [
            #"<tool_call>{"name": "field_session", "arguments": {"action": "start"}}</tool_call>"#, "Started.",
        ])
        XCTAssertEqual(run.grades[.toolName], false)
    }

    func testLeftoverMarkupFailsCleanText() {
        XCTAssertFalse(LocalToolEval.isClean("Logged. <|tool_call>call:reading{}<tool_call|>"))
        XCTAssertFalse(LocalToolEval.isClean("<think>hmm</think> fine"))
        XCTAssertFalse(LocalToolEval.isClean("Sure <tool_call>{\"name\": \"x\""))
        XCTAssertTrue(LocalToolEval.isClean("The web_search tool takes a query."))
    }

    func testABrokenCarryFailsCarry() async throws {
        let run = try await runCase("twostep-01", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "118", "unit": "psig"}}</tool_call>"#,
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "superheat", "refrigerant": "R-454B", "suction_pressure_psig": 181, "suction_line_temp_f": 52}}</tool_call>"#,
            "Done.",
        ])
        XCTAssertEqual(run.grades[.carry], false)
    }

    func testAMadeUpManualValueIsDeclined() throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "manual-02" })
        let reading = try XCTUnwrap(testCase.reading)
        XCTAssertFalse(ManualReadingCheck.check(reading.manualReading, passages: testCase.passages ?? [:]).isAccepted)
    }

    func testCancellationIsGradedOnlyWhereTheCaseCancels() async throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "cancel-01" })
        // The scripted model never looks at cancellation; the loop stops the turn by itself.
        let run = await LocalToolEval.run(testCase, environment: environment())
        XCTAssertEqual(run.grades[.cancellation], true)
        // The same case without a cancel point is not a cancellation case.
        var uncancelled = testCase
        uncancelled.cancel = nil
        let plain = await LocalToolEval.run(uncancelled, environment: environment())
        XCTAssertNil(plain.grades[.cancellation])
    }
}
