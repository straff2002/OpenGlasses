import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan MQ P0's CI runner: the local tool corpus played through the shipped loop, parser, coercion
/// and reading check against a scripted fake model. This is where a regression in any of them is
/// caught; P3's Mac screener and device app hand the same cases to real models.
///
/// The corpus is generated from the Lennox SLP99 example vault (`Scripts/local-tool-eval/
/// generate-corpus.py`) and is mostly Field Assist job turns. Output is counts only
/// (`LocalToolEval.Report`, Field Assist first), never a turn, a passage or an answer.
@MainActor
final class LocalToolEvalCorpusTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LocalToolEval
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
    }

    private static var corpusURL: URL {
        repoRoot.appendingPathComponent("Scripts/local-tool-eval/corpus", isDirectory: true)
            .appendingPathComponent(LocalToolEval.corpusFileName)
    }

    /// What the generator reads, in the order it hashes them (sorted by path).
    private static let generatorInputs = [
        "Scripts/local-tool-eval/generate-corpus.py",
        "examples/vaults/lennox-slp99/error_codes.md",
        "examples/vaults/lennox-slp99/eval/calibration.jsonl",
        "examples/vaults/lennox-slp99/models.md",
        "examples/vaults/lennox-slp99/parts.md",
        "examples/vaults/lennox-slp99/procedures/slp99_no_ignition.json",
        "examples/vaults/lennox-slp99/procedures/slp99_pressure_switch_lockout.json",
        "examples/vaults/lennox-slp99/procedures/slp99_unit_size_code.json",
        "examples/vaults/lennox-slp99/safety.md",
        "examples/vaults/lennox-slp99/service_values.md",
    ]

    private var registry: NativeToolRegistry!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    /// The registry hands out Field Assist tools only while Field Assist is active.
    override func setUp() {
        super.setUp()
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        registry = NativeToolRegistry(locationService: LocationService())
    }

    override func tearDown() {
        registry = nil
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
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
        for name in Set(registry.toolNames).union(FieldAssistLocalToolSet.priority) { schemas[name] = schema(name) }
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

    /// The point of running Field Assist on a downloaded model is cost, so the corpus is mostly
    /// Field Assist job turns, drawn mostly from the example vault, with every job category in it.
    func testTheCorpusIsMostlyFieldAssistFromTheVault() throws {
        let cases = try corpus()
        let field = cases.filter { $0.group == .fieldAssist }
        XCTAssertGreaterThanOrEqual(Double(field.count) / Double(cases.count), 0.7)
        XCTAssertGreaterThanOrEqual(Double(field.filter { $0.source != "synthetic" }.count) / Double(field.count), 0.7)
        for category: LocalToolEval.Category in [.toolChoice, .manualAnswer, .notInManual, .twoStep, .longPrompt,
                                                 .multiTurn, .cleanOutput, .cancellation] {
            XCTAssertTrue(field.contains { $0.category == category }, "Field Assist has no \(category.rawValue) case")
        }
        XCTAssertTrue(field.allSatisfy { $0.vault == "lennox-slp99" }, "a Field Assist case names its job context")
        for tool in FieldAssistLocalToolSet.priority {
            XCTAssertTrue(field.contains { $0.expect.calls.contains { $0.tool == tool } }, "no case expects \(tool)")
        }
        XCTAssertTrue(cases.contains { $0.group == .everyday && $0.category == .restraint })
    }

    /// The corpus is generated; a vault edit (or a generator edit) without a regeneration fails
    /// here. Fix: `python3 -I Scripts/local-tool-eval/generate-corpus.py`.
    func testTheCorpusMatchesItsGeneratorInputs() throws {
        let text = try String(contentsOf: Self.corpusURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        func recorded(_ key: String) -> String? {
            lines.first { $0.hasPrefix("// \(key): ") }.map { String($0.dropFirst("// \(key): ".count)) }
        }
        var hasher = SHA256()
        for path in Self.generatorInputs {
            hasher.update(data: Data(path.utf8) + Data([0]))
            hasher.update(data: try Data(contentsOf: Self.repoRoot.appendingPathComponent(path)) + Data([0]))
        }
        let inputs = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recorded("inputs-sha256"), inputs,
                       "the vault or the generator changed: run Scripts/local-tool-eval/generate-corpus.py")
        let body = lines.filter { !$0.hasPrefix("//") }.joined(separator: "\n")
        let bodyHash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recorded("body-sha256"), bodyHash, "the corpus was edited by hand: regenerate it")
    }

    func testEveryExpectationNamesARealToolAndItsDeclaredArguments() throws {
        for testCase in try corpus() {
            for name in testCase.offered {
                XCTAssertNotNil(registry.tool(named: name), "\(testCase.id) offers \(name), which is not registered")
                XCTAssertTrue(OfflineToolPolicy.isOfferedOffline(name), "\(testCase.id): \(name) needs the network")
            }
            for call in testCase.expect.calls {
                for tool in call.tools {
                    XCTAssertTrue(testCase.offered.contains(tool), "\(testCase.id) expects \(tool) but doesn't offer it")
                    guard case .object(_, _, let properties)? = schema(tool), let variant = call.variant(for: tool) else {
                        XCTFail("\(testCase.id): \(tool) has no schema"); continue
                    }
                    let declared = Set(properties.map(\.name))
                    for name in variant.required + Array(variant.values.keys) {
                        XCTAssertTrue(declared.contains(name), "\(testCase.id): \(tool) declares no '\(name)'")
                    }
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

    func testEveryManualCaseExpectsTheCheckTheWayItsCategorySays() throws {
        let cases = try corpus()
        let answers = cases.filter { $0.category == .manualAnswer }
        let misses = cases.filter { $0.category == .notInManual }
        XCTAssertTrue(answers.allSatisfy { $0.expect.readingAccepted == true && $0.reading?.found == true })
        XCTAssertTrue(misses.allSatisfy { $0.expect.readingAccepted == false })
        XCTAssertTrue(misses.contains { $0.reading?.found == true },
                      "near-miss twins: a made-up value beside a real quote, which the check must decline")
        XCTAssertTrue(misses.contains { $0.reading?.found == false }, "honest abstentions")
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
        XCTAssertEqual(report.floorShortfalls(), [], "the reference model clears decision 5's floors")
        // Every hard floor has Field Assist cases to judge it, restraint included (36 job turns
        // that need no tool, added 2026-11-22), so the reference model clears all three.
        XCTAssertEqual(report.unjudgedFloors().map(\.name), [])
        XCTAssertTrue(report.clearsFloors)
        // Counts only.
        for line in report.lines() { print(line) }
        let printed = report.lines().joined(separator: "\n")
        XCTAssertTrue(printed.contains("fieldAssist"), "Field Assist is reported as its own group")
        for testCase in cases {
            XCTAssertFalse(printed.contains(testCase.turn), "the report must never carry a turn")
            for passage in (testCase.passages ?? [:]).values {
                XCTAssertFalse(printed.contains(passage), "the report must never carry a passage")
            }
        }
    }

    // MARK: - Decision 5's floors

    func testTheFloorsAreTheOwnersNumbers() {
        XCTAssertEqual(LocalToolEval.Floors.notInManualDeclined, 0.95)
        XCTAssertEqual(LocalToolEval.Floors.cleanOutput, 1.0)
        XCTAssertEqual(LocalToolEval.Floors.restraint, 0.90)
        XCTAssertEqual(LocalToolEval.Floors.judgedGroup, .fieldAssist)
        XCTAssertEqual(LocalToolEval.Floors.all.count, 3)
    }

    private func report(_ runs: [(LocalToolEval.Category, LocalToolEval.Group, Bool, Bool)]) -> LocalToolEval.Report {
        var report = LocalToolEval.Report()
        for (index, run) in runs.enumerated() {
            report.add(LocalToolEval.Run(caseID: "r\(index)", category: run.0, group: run.1,
                                         grades: [.toolName: run.2, .cleanText: run.3]))
        }
        return report
    }

    func testEachFloorIsJudgedOnItsOwnInTheFieldAssistGroup() {
        // 19 of 20 declined is 0.95: on the floor. Ten restraint runs, nine clean of tools: 0.90.
        var runs: [(LocalToolEval.Category, LocalToolEval.Group, Bool, Bool)] =
            (0..<20).map { (.notInManual, .fieldAssist, $0 != 0, true) }
        runs += (0..<10).map { (.restraint, .fieldAssist, $0 != 0, true) }
        XCTAssertEqual(report(runs).floorShortfalls(), [])
        XCTAssertTrue(report(runs).clearsFloors)

        // One more miss on either is below its floor, however well the other does.
        var short = runs
        short[1] = (.notInManual, .fieldAssist, false, true)
        XCTAssertEqual(report(short).floorShortfalls().map(\.name), ["not in the manual declined"])
        short = runs
        short[21] = (.restraint, .fieldAssist, false, true)
        XCTAssertEqual(report(short).floorShortfalls().map(\.name), ["restraint"])

        // One piece of markup in the voice, on any case, misses clean output.
        short = runs + [(.toolChoice, .fieldAssist, true, false)]
        XCTAssertEqual(report(short).floorShortfalls().map(\.name), ["clean output"])

        // The everyday group is not what is judged, and a floor with nothing to judge it is not cleared.
        let everydayOnly = report(runs.map { ($0.0, LocalToolEval.Group.everyday, $0.2, $0.3) })
        XCTAssertEqual(everydayOnly.floorShortfalls(), [])
        XCTAssertEqual(everydayOnly.unjudgedFloors().count, 3)
        XCTAssertFalse(everydayOnly.clearsFloors)
    }

    // MARK: - The graders catch what they exist to catch

    private func runCase(_ id: String, script: [String]) async throws -> LocalToolEval.Run {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == id })
        return await LocalToolEval.run(testCase, environment: environment { _, _, index in
            index < script.count ? script[index] : ""
        })
    }

    func testTheWrongToolFailsToolName() async throws {
        let run = try await runCase("long-1", script: [
            #"<tool_call>{"name": "field_session", "arguments": {"action": "status"}}</tool_call>"#, "Done.",
        ])
        XCTAssertEqual(run.grades[.toolName], false)
    }

    func testAMissingRequiredArgumentFailsPresence() async throws {
        let run = try await runCase("long-1", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading"}}</tool_call>"#, "Done.",
        ])
        XCTAssertEqual(run.grades[.toolName], true)
        XCTAssertEqual(run.grades[.argumentPresence], false)
    }

    func testAValueThatCannotBeReadAtItsTypeFailsTypes() async throws {
        let run = try await runCase("twostep-070XV36B-115", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "115"}}</tool_call>"#,
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "voltage_drop", "supply_v": 115, "current_a": "about fifteen", "length_ft": 50}}</tool_call>"#,
            "Done.",
        ])
        XCTAssertEqual(run.grades[.argumentTypes], false)
    }

    func testANumberWrittenAsTextStillPassesTypesAfterCoercion() async throws {
        let run = try await runCase("twostep-070XV36B-115", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": 115}}</tool_call>"#,
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "voltage_drop", "supply_v": "115", "current_a": "15", "length_ft": "50", "area_cmil": "4110"}}</tool_call>"#,
            "The drop is about 3 volts.",
        ])
        XCTAssertEqual(run.grades[.argumentTypes], true)
        XCTAssertEqual(run.grades[.argumentValues], true)
    }

    func testAWrongValueFailsValues() async throws {
        let run = try await runCase("long-1", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "6", "unit": "inWC"}}</tool_call>"#,
            "Logged.",
        ])
        XCTAssertEqual(run.grades[.argumentValues], false)
    }

    func testARepeatedCallFailsNoRepeats() async throws {
        let call = #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "0.6", "unit": "inWC"}}</tool_call>"#
        let run = try await runCase("long-1", script: [call, call, "Logged."])
        XCTAssertEqual(run.grades[.noRepeats], false)
    }

    func testAToolOnARestraintCaseFails() async throws {
        let run = try await runCase("chat-morning", script: [
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

    /// Plan MQ P3: the eval runs the loop's completion as the app does; Gemma's call without the
    /// size still passes and the fill is counted.
    func testACallMissingTheSaidGaugeIsCompletedAndCounted() async throws {
        let run = try await runCase("twostep-090XV36C-120", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "120"}}</tool_call>"#,
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "voltage_drop", "supply_v": "120", "current_a": "15", "length_ft": "50", "material": "copper", "phase": "single"}}</tool_call>"#,
            "Logged 120 volts; the drop is about 3 volts.",
        ])
        XCTAssertEqual(run.measurements.argumentsCompleted, 1)
        XCTAssertEqual(run.grades[.argumentValues], true)
        XCTAssertEqual(run.grades[.argumentTypes], true)
    }

    func testABrokenCarryFailsCarry() async throws {
        // The reading logged the wrong number; the calculation's supply is the one the technician said.
        let run = try await runCase("twostep-070XV36B-115", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "50"}}</tool_call>"#,
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "voltage_drop", "supply_v": 50, "current_a": 15, "length_ft": 50}}</tool_call>"#,
            "Done.",
        ])
        XCTAssertEqual(run.grades[.carry], false)
    }

    /// Plan MQ P3: a supply the model got wrong is replaced by the one the technician said, so the
    /// carry reaches the calculation.
    func testAWrongSupplyIsReplacedByTheSaidOne() async throws {
        let run = try await runCase("twostep-070XV36B-115", script: [
            #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "115"}}</tool_call>"#,
            #"<tool_call>{"name": "domain_calc", "arguments": {"operation": "voltage_drop", "supply_v": 151, "current_a": 15, "length_ft": 50}}</tool_call>"#,
            "Done.",
        ])
        XCTAssertEqual(run.grades[.carry], true)
        XCTAssertGreaterThan(run.measurements.argumentsCompleted, 0)
    }

    func testAMadeUpManualValueIsDeclined() throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "sv-001-miss" })
        let reading = try XCTUnwrap(testCase.reading)
        XCTAssertFalse(ManualReadingCheck.check(reading.manualReading, passages: testCase.passages ?? [:]).isAccepted)
    }

    func testCancellationIsGradedOnlyWhereTheCaseCancels() async throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "cancel-job-1" })
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
