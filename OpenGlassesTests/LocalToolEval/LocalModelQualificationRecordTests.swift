import XCTest
@testable import OpenGlasses

/// Plan MQ P3: the grader additions for real models, the record a phone run writes, and decision
/// 8's rule that a catalog entry's evidence names a record git tracks.
@MainActor
final class LocalModelQualificationRecordTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LocalToolEval
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
    }

    private func corpus() throws -> [LocalToolEval.Case] {
        let url = Self.repoRoot.appendingPathComponent("Scripts/local-tool-eval/corpus")
            .appendingPathComponent(LocalToolEval.corpusFileName)
        return LocalToolEval.loadCorpus(try String(contentsOf: url, encoding: .utf8)).cases
    }

    private var registry: NativeToolRegistry!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

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

    private func schemas() -> [String: OnDeviceToolSchema.Node] {
        var schemas: [String: OnDeviceToolSchema.Node] = [:]
        for name in Set(registry.toolNames).union(FieldAssistLocalToolSet.priority) {
            if let tool = registry.tool(named: name) {
                schemas[name] = OnDeviceToolSchema.root(toolName: name, parameters: tool.parametersSchema)
            }
        }
        return schemas
    }

    private func environment(_ generate: @escaping (LocalToolEval.Case, LocalToolLoop.GenerationRequest, Int)
                                async throws -> LocalToolLoop.Generation) -> LocalToolEval.Environment {
        let frozen = schemas()
        return LocalToolEval.Environment(generateTurn: generate, schema: { frozen[$0] },
                                         referenceModelID: "mlx-community/gemma-4-e2b-it-4bit")
    }

    private func stats(tokens: Int, cap: Int = 512, stoppedAtCap: Bool = false) -> LocalGenerationStats {
        LocalGenerationStats(promptTokens: 900, generatedTokens: tokens, promptSeconds: 0.8, generateSeconds: 2,
                             tokenCap: cap, stoppedAtCap: stoppedAtCap)
    }

    // MARK: - Zero tokens and the cap

    func testAReplyOfZeroTokensIsATemplateFaultNotACleanAnswer() async throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "chat-morning" })
        // Blank text with tokens behind it (whitespace) is a model answer; no tokens at all is a fault.
        let blank = await LocalToolEval.run(testCase, environment: environment { _, _, _ in
            .init(text: "", stats: self.stats(tokens: 3))
        })
        XCTAssertEqual(blank.grades[.cleanText], true, "the miss line is spoken: clean, if unhelpful")
        XCTAssertFalse(blank.hadTemplateFault)
        let zero = await LocalToolEval.run(testCase, environment: environment { _, _, _ in
            .init(text: "", stats: self.stats(tokens: 0))
        })
        XCTAssertEqual(zero.grades[.cleanText], false, "zero tokens counts against clean output")
        XCTAssertTrue(zero.hadTemplateFault)
        XCTAssertEqual(zero.measurements.zeroTokenGenerations, 1)
        // A runtime that reports nothing (CI's scripted model) is neither.
        let scripted = await LocalToolEval.run(testCase, environment: environment { _, _, _ in .init(text: "Morning!") })
        XCTAssertFalse(scripted.hadTemplateFault)
        XCTAssertEqual(scripted.measurements.generations, 1)
        XCTAssertTrue(scripted.measurements.promptSeconds.isEmpty)
    }

    func testNothingSaidAfterALoggedReadingIsCoveredByItsResultAndStillCountedAsAFault() async throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "sv-001-log-in" })
        let call = #"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "#
            + #""quantity": "line pressure, in. w.c., Natural", "value": "7.5", "unit": "inWC"}}</tool_call>"#
        let run = await LocalToolEval.run(testCase, environment: environment { _, _, index in
            index == 0 ? .init(text: call, stats: self.stats(tokens: 40)) : .init(text: "", stats: self.stats(tokens: 0))
        })
        XCTAssertEqual(run.grades[.toolName], true)
        XCTAssertEqual(run.grades[.cleanText], true, "the wearer hears the reading's own result, which is clean")
        XCTAssertTrue(run.hadTemplateFault, "the empty reply is still counted")
    }

    func testAReplyThatStopsAtTheCapIsMarkedCut() async throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "chat-morning" })
        let atCap = await LocalToolEval.run(testCase, environment: environment { _, _, _ in
            .init(text: "Morning! Here is a very long", stats: self.stats(tokens: 512))
        })
        XCTAssertTrue(atCap.wasCut)
        XCTAssertTrue(atCap.passed, "cut is marked, not failed")
        let reported = await LocalToolEval.run(testCase, environment: environment { _, _, _ in
            .init(text: "Morning!", stats: self.stats(tokens: 40, stoppedAtCap: true))
        })
        XCTAssertTrue(reported.wasCut, "the runtime's own stop reason counts")
        let short = await LocalToolEval.run(testCase, environment: environment { _, _, _ in
            .init(text: "Morning!", stats: self.stats(tokens: 511))
        })
        XCTAssertFalse(short.wasCut)
        XCTAssertEqual(short.measurements.decodeTokensPerSecond, [255.5])

        var report = LocalToolEval.Report()
        report.add(atCap); report.add(short)
        XCTAssertEqual(report.groups[.everyday]?.cutRuns, 1)
        XCTAssertTrue(report.lines().contains { $0.contains("cut at the token cap: 1") })
    }

    // MARK: - Readings from a real model

    func testTheReaderReadsAReplyTheWayAModelWritesIt() {
        let reading = LocalToolEval.Reader.parse(#"```json\n{"found": true, "answer": "4.5 to 10.5 in. w.c.", "passage": "p1", "quote": "Natural | 4.5 – 10.5"}\n```"#)
        XCTAssertEqual(reading, ManualReading(found: true, answer: "4.5 to 10.5 in. w.c.", passage: "p1",
                                              quote: "Natural | 4.5 – 10.5"))
        XCTAssertEqual(LocalToolEval.Reader.parse(#"<think>{"found": true}</think>{"found": false, "answer": "", "passage": "", "quote": ""}"#)?.found,
                       false, "thinking before the reply is not the reply")
        XCTAssertNil(LocalToolEval.Reader.parse("That isn't in the manual."))
        XCTAssertNil(LocalToolEval.Reader.parse(#"{"answer": "4.5"}"#), "no found, no reading")
        let scripted = LocalToolEval.Reading(found: true, answer: "a", passage: "p1", quote: "q")
        XCTAssertEqual(LocalToolEval.Reader.parse(LocalToolEval.Reader.reply(for: scripted)), scripted.manualReading)
    }

    func testAnUnreadableReadingIsDeclinedAsTheAppWouldAndCounted() async throws {
        let cases = try corpus()
        let answer = try XCTUnwrap(cases.first { $0.category == .manualAnswer })
        let abstain = try XCTUnwrap(cases.first { $0.category == .notInManual && !$0.isCheckOnly })
        func reading(_ reply: String) -> LocalToolEval.Environment {
            let frozen = schemas()
            return LocalToolEval.Environment(generateTurn: { _, _, _ in .init(text: "") },
                                             read: { _, _ in .init(text: reply) },
                                             schema: { frozen[$0] }, referenceModelID: "mlx-community/gemma-4-e2b-it-4bit")
        }
        let prose = await LocalToolEval.run(answer, environment: reading("It's between 4.5 and 10.5."))
        XCTAssertEqual(prose.grades[.manualReading], false)
        XCTAssertEqual(prose.measurements.readerUnparsed, 1)
        let declined = await LocalToolEval.run(abstain, environment: reading(#"{"found": false, "answer": "", "passage": "", "quote": ""}"#))
        XCTAssertEqual(declined.grades[.manualReading], true)
        XCTAssertEqual(declined.measurements.readerUnparsed, 0)
        // The request hands over every passage by id and the question, and nothing else.
        let request = LocalToolEval.Reader.request(for: answer)
        for (id, passage) in answer.passages ?? [:] {
            XCTAssertTrue(request.prompt.contains("Passage \(id):\n\(passage)"))
        }
        XCTAssertTrue(request.prompt.hasSuffix("Question: \(answer.turn)"))
    }

    func testAnErrorCodeLookedUpByCodeIsAsRightAsReadFromTheTable() async throws {
        let testCase = try XCTUnwrap(try corpus().first { $0.id == "code-E105-lookup" })
        func run(_ call: String) async -> LocalToolEval.Run {
            // The model's own call is what is graded here, so the router does not make it first.
            var unrouted = environment { _, _, index in
                index == 0 ? .init(text: call) : .init(text: "E105 is a device communication problem.")
            }
            unrouted.routesTurns = false
            return await LocalToolEval.run(testCase, environment: unrouted)
        }
        let byCode = await run(#"<tool_call>{"name": "equipment_lookup", "arguments": {"query": "E105"}}</tool_call>"#)
        XCTAssertEqual(byCode.grades[.toolName], true)
        XCTAssertEqual(byCode.grades[.argumentValues], true)
        let wrongCode = await run(#"<tool_call>{"name": "equipment_lookup", "arguments": {"query": "E106"}}</tool_call>"#)
        XCTAssertEqual(wrongCode.grades[.argumentValues], false, "the alternative is held to its own values")
        let other = await run(#"<tool_call>{"name": "reading", "arguments": {"action": "record_reading", "value": "1"}}</tool_call>"#)
        XCTAssertEqual(other.grades[.toolName], false)
    }

    func testATargetedRerunTakesOnlyItsCategoriesAndSaysSo() throws {
        var selection = LocalToolEval.Selection.qualification
        selection.onlyCategories = [.toolChoice, .multiTurn]
        let picked = LocalToolEval.select(try corpus(), selection, live: true).cases
        XCTAssertFalse(picked.isEmpty)
        XCTAssertTrue(picked.allSatisfy { [.toolChoice, .multiTurn].contains($0.category) })
        let all = LocalToolEval.select(try corpus(), .qualification, live: true).cases
        XCTAssertEqual(picked.count, all.filter { [.toolChoice, .multiTurn].contains($0.category) }.count)
    }

    func testALiveRunSkipsTheCheckOnlyTwinsAndTakesTheJudgedCategories() throws {
        let cases = try corpus()
        let twins = cases.filter(\.isCheckOnly)
        XCTAssertEqual(twins.count, 98)
        XCTAssertTrue(twins.allSatisfy { twin in
            cases.contains { $0.category == .manualAnswer && $0.turn == twin.turn && $0.passages == twin.passages }
        }, "each twin is an answered case's question and passages")

        let live = LocalToolEval.select(cases, .qualification, live: true)
        XCTAssertEqual(live.checkOnlySkipped, 98)
        XCTAssertFalse(live.cases.contains(where: \.isCheckOnly))
        XCTAssertTrue(live.cases.contains { $0.category == .restraint && $0.group == .fieldAssist },
                      "Field Assist has restraint cases of its own")
        XCTAssertTrue(live.cases.contains { $0.category == .restraint && $0.group == .everyday },
                      "everyday restraint still rides beside it")
        XCTAssertFalse(live.cases.contains { $0.group == .everyday && $0.category != .restraint })
        XCTAssertEqual(live.cases.count, cases.filter { $0.group == .fieldAssist || $0.category == .restraint }.count - 98)

        let scripted = LocalToolEval.select(cases, .everything, live: false)
        XCTAssertEqual(scripted.cases.count, cases.count)
        var smoke = LocalToolEval.Selection.qualification
        smoke.limit = 5
        XCTAssertEqual(LocalToolEval.select(cases, smoke, live: true).cases.count, 5)
    }

    // MARK: - The record

    private func record() -> LocalModelQualificationRecord {
        LocalModelQualificationRecord(
            startedAt: "2026-11-22T00:00:00Z", updatedAt: "2026-11-22T00:00:00Z",
            device: .init(model: "iPhone17,3", osVersion: "Version 26.2", osBuild: "24B113", marketingRAMGB: 8,
                          physicalMemoryBytes: 7_900_000_000),
            app: .init(commit: "b2c3c72cc", version: "1.0", build: "748"),
            runtime: .init(name: "mlx-swift-lm", revision: "4c21c84ba239583d6448dc38bbc9001e2df714a6"),
            model: .init(id: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
                         quantization: "4bit", backing: "copied"),
            sampling: .init(source: "card", general: .init(temperature: 1, topP: 0.95, topK: 64),
                            toolTurn: .init(temperature: 1, topP: 0.95, topK: 64)),
            corpus: .init(version: 2, bodySha256: "abc", groups: ["fieldAssist"], alsoCategories: ["restraint"],
                          limit: nil, repeats: 3, selectedCases: 10, checkOnlySkipped: 98),
            gate: .init(settleSeconds: 120, capSeconds: 1_200, requiresCharger: true),
            memory: .init(killLimitBytes: 6_000_000_000, recommendedWorkingSetBytes: 5_000_000_000,
                          reserveBytes: 536_870_912, footprintBeforeLoadBytes: 200_000_000, fitJudgedAgainst: "killLimit",
                          fitNeededBytes: 4_000_000_000, fitLimitBytes: 6_000_000_000, fits: true),
            window: .init(ordinaryTokens: 4_096, toolTurnTokens: 6_144, reason: "raised", toolTurnPromptBudget: 5_504))
    }

    /// Counts and hashes only: a record of every reference run carries no case id, turn, passage,
    /// tool argument, scripted result or answer.
    func testARecordCarriesCountsAndHashesOnly() async throws {
        let cases = try corpus()
        let frozen = schemas()
        let environment = LocalToolEval.Environment(generate: LocalToolEval.referenceModel, schema: { frozen[$0] },
                                                    referenceModelID: "mlx-community/gemma-4-e2b-it-4bit")
        var record = record()
        for testCase in cases {
            let run = await LocalToolEval.run(testCase, environment: environment)
            record.add(run, repeat: 0, flagged: false, seconds: 1)
        }
        record.finished = true
        record.recompute()
        let text = String(decoding: try record.encoded(), as: UTF8.self)
        XCTAssertEqual(record.runs.count, cases.count)
        for testCase in cases {
            XCTAssertFalse(text.contains("\"\(testCase.id)\""), "no case id")
            XCTAssertFalse(text.contains(testCase.turn), "no turn")
            for passage in (testCase.passages ?? [:]).values { XCTAssertFalse(text.contains(passage), "no passage") }
            for result in (testCase.results ?? [:]).values { XCTAssertFalse(text.contains(result), "no result") }
            for call in testCase.expect.calls {
                for value in call.values.values where value.count > 3 {
                    XCTAssertFalse(text.contains("\"\(value)\""), "no argument value")
                }
            }
            if let reading = testCase.reading, !reading.answer.isEmpty { XCTAssertFalse(text.contains(reading.answer)) }
        }
        // The summary is the eval's own report and floors.
        var report = LocalToolEval.Report()
        for run in record.evalRuns { report.add(run) }
        XCTAssertEqual(record.summary.floors.map(\.name), LocalToolEval.Floors.all.compactMap { report.tally(for: $0) == nil ? nil : $0.name })
        XCTAssertEqual(record.summary.unjudgedFloors, [], "every hard floor has Field Assist cases")
        XCTAssertTrue(record.summary.clearsFloorsUnflagged, "a finished, unflagged reference run clears them")
        XCTAssertEqual(record.summary.groups["fieldAssist"]?.overall.passed, report.groups[.fieldAssist]?.overall.passed)
        XCTAssertNotNil(record.summary.groups["fieldAssist"]?.byCategory["notInManual"]?.lower)
    }

    /// Heat changes the speed, not the answers (owner, 2026-11-22): a run that started `serious`
    /// counts towards the floors, and only the cool runs make the timing.
    func testAHotRunCountsForTheAnswersButNotTheTiming() {
        var record = record()
        func run(_ id: String, rate: Double) -> LocalToolEval.Run {
            var m = LocalToolEval.Measurements()
            m.generations = 1
            m.promptSeconds = [rate / 100]
            m.decodeTokensPerSecond = [rate]
            return LocalToolEval.Run(caseID: id, category: .restraint, group: .fieldAssist,
                                     grades: [.toolName: true], measurements: m)
        }
        record.add(run("cool", rate: 40), repeat: 0, flagged: false, seconds: 1, thermalAtStart: .nominal)
        record.add(run("fair", rate: 38), repeat: 0, flagged: false, seconds: 1, thermalAtStart: .fair)
        record.add(run("hot", rate: 12), repeat: 0, flagged: false, seconds: 1, thermalAtStart: .serious)
        XCTAssertEqual(record.summary.groups["fieldAssist"]?.overall.runs, 3, "every answer counts")
        XCTAssertEqual(record.timing.decodeTokensPerSecond?.count, 2)
        XCTAssertEqual(record.timing.decodeTokensPerSecond?.max, 40)
        XCTAssertEqual(record.timing.hotRunsExcludedFromTiming, 1)
        XCTAssertEqual(record.timing.hotDecodeTokensPerSecond?.max, 12)
        XCTAssertEqual(record.summary.flaggedRuns, 0, "serious is not a flag")
    }

    /// A run that fails on an error keeps the error's type and case name, never its message.
    func testAnErrorIsRecordedByKindOnly() {
        enum Sample: Error { case templateFailed(String), plain, tooLong(tokens: Int, limit: Int), mixed(Int, String) }
        struct Opaque: Error {}
        XCTAssertEqual(LocalToolEval.errorKind(Sample.templateFailed("{{ secret prompt }}")), "Sample.templateFailed")
        XCTAssertEqual(LocalToolEval.errorKind(Sample.tooLong(tokens: 4100, limit: 3456)),
                       "Sample.tooLong(tokens: 4100, limit: 3456)", "whole numbers are kept")
        XCTAssertEqual(LocalToolEval.errorKind(Sample.mixed(3, "a passage")), "Sample.mixed", "a string drops them all")
        XCTAssertEqual(LocalToolEval.errorKind(Sample.plain), "Sample.plain")
        XCTAssertEqual(LocalToolEval.errorKind(Opaque()), "Opaque")
        XCTAssertEqual(LocalToolEval.errorKind(NSError(domain: "Jinja", code: 7, userInfo: [NSLocalizedDescriptionKey: "line 3"])), "Jinja#7")
        XCTAssertEqual(LocalToolEval.errorKind(CancellationError()), "CancellationError")
    }

    func testARecordIsResumedOnlyWithTheSameSettingsAndKeepsEachRunOnce() throws {
        var first = record()
        let run = LocalToolEval.Run(caseID: "sv-001-answer", category: .manualAnswer, group: .fieldAssist,
                                    grades: [.manualReading: true])
        first.add(run, repeat: 0, flagged: false, seconds: 1)
        first.add(run, repeat: 0, flagged: true, seconds: 2)
        XCTAssertEqual(first.runs.count, 1, "a run measured again replaces the earlier one")
        XCTAssertEqual(first.summary.flaggedRuns, 1)
        XCTAssertEqual(first.completedKeys, [LocalModelQualificationRecord.key(caseID: "sv-001-answer", repeat: 0)])
        XCTAssertFalse(first.runs[0].key.contains("sv-001"), "keyed by a hash")

        let decoded = try XCTUnwrap(LocalModelQualificationRecord.decode(try first.encoded()))
        XCTAssertEqual(decoded, first)
        XCTAssertTrue(decoded.resumable(with: record()))
        var otherModel = record()
        otherModel.model.id = "mlx-community/gemma-4-e4b-it-4bit"
        XCTAssertFalse(decoded.resumable(with: otherModel))
        var otherSampling = record()
        otherSampling.sampling = nil
        XCTAssertFalse(decoded.resumable(with: otherSampling))
        var finished = decoded
        finished.finished = true
        XCTAssertFalse(finished.resumable(with: record()), "a finished record is not carried on")
    }

    /// Plan MQ P3: the arguments the loop dropped for a number nobody said, as a count; a record
    /// written before the count existed still decodes.
    func testDroppedArgumentsAreCountedAndAnOlderRecordStillDecodes() throws {
        var record = record()
        var m = LocalToolEval.Measurements()
        m.argumentsDropped = 3
        record.add(LocalToolEval.Run(caseID: "ts-001", category: .twoStep, group: .fieldAssist,
                                     grades: [.toolName: true], measurements: m), repeat: 0, flagged: false, seconds: 1)
        XCTAssertEqual(record.runs.first?.argumentsDropped, 3)
        XCTAssertEqual(record.summary.groups["fieldAssist"]?.argumentsDroppedRuns, 1)
        XCTAssertEqual(record.evalRuns.first?.measurements.argumentsDropped, 3)

        let data = try record.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("ts-001"), "the case id is kept as a hash")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        runs[0].removeValue(forKey: "argumentsDropped")
        object["runs"] = runs
        let older = try XCTUnwrap(LocalModelQualificationRecord.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertNil(older.runs.first?.argumentsDropped)
        XCTAssertEqual(older.evalRuns.first?.measurements.argumentsDropped, 0)
    }

    // MARK: - The runtime's tool fit (Plan MQ P3)

    /// A run tells "the fit dropped the expected tool" from "the model missed it": the dispatcher
    /// refuses a call to a dropped tool as the app does, and the record keeps the counts.
    func testTheFitIsRecordedAndADroppedToolIsNotRun() async throws {
        let cases = try corpus()
        let testCase = try XCTUnwrap(cases.first {
            $0.category == .toolChoice && $0.group == .fieldAssist && $0.expect.calls.count == 1 && $0.offered.count >= 3
        })
        let expected = try XCTUnwrap(testCase.expect.calls.first?.tool)
        let kept = testCase.offered.filter { $0 != expected }
        let reference = testCase.reference ?? []
        // The model calls the expected tool anyway (as the scripted reference does): it was dropped.
        let dropped = await LocalToolEval.run(testCase, environment: environment { _, request, index in
            .init(text: index < reference.count ? reference[index] : "",
                  stats: self.stats(tokens: 20),
                  toolFit: request.toolsOffered
                      ? .init(offered: testCase.offered.count, keptNames: kept, compact: true, contextWindow: 6_144) : nil)
        })
        XCTAssertTrue(dropped.expectedToolDropped)
        XCTAssertEqual(dropped.grades[.toolName], false, "the call was refused, not run")
        XCTAssertEqual(dropped.measurements.toolsOffered, testCase.offered.count)
        XCTAssertEqual(dropped.measurements.toolsKept, kept.count)
        XCTAssertGreaterThan(dropped.measurements.compactGenerations, 0)
        XCTAssertGreaterThan(dropped.measurements.fitDroppedGenerations, 0)
        XCTAssertEqual(dropped.measurements.contextWindow, 6_144)
        XCTAssertEqual(dropped.measurements.promptTokens.first, 900)

        // Everything kept: the reference passes, and nothing is marked.
        let whole = await LocalToolEval.run(testCase, environment: environment { _, request, index in
            .init(text: index < reference.count ? reference[index] : "",
                  toolFit: request.toolsOffered
                      ? .init(offered: testCase.offered.count, keptNames: testCase.offered, compact: false,
                              contextWindow: 4_096) : nil)
        })
        XCTAssertTrue(whole.passed)
        XCTAssertFalse(whole.expectedToolDropped)
        XCTAssertEqual(whole.measurements.fitDroppedGenerations, 0)

        var record = record()
        record.add(dropped, repeat: 0, flagged: false, seconds: 1)
        record.add(whole, repeat: 1, flagged: false, seconds: 1)
        let entry = try XCTUnwrap(record.runs.first)
        XCTAssertEqual(entry.toolsOffered, testCase.offered.count)
        XCTAssertEqual(entry.toolsKept, kept.count)
        XCTAssertTrue(entry.expectedToolDropped)
        XCTAssertEqual(entry.contextWindow, 6_144)
        XCTAssertEqual(entry.promptTokens.first, 900)
        let group = try XCTUnwrap(record.summary.groups["fieldAssist"])
        XCTAssertEqual(group.expectedToolDroppedRuns, 1)
        XCTAssertEqual(group.fitDroppedRuns, 1)
        XCTAssertEqual(group.compactRuns, 1)
        XCTAssertEqual(record.window.toolTurnTokens, 6_144)
        let decoded = try XCTUnwrap(LocalModelQualificationRecord.decode(try record.encoded()))
        XCTAssertEqual(decoded, record)
        // Counts only: no tool name rides in the record.
        let text = String(decoding: try record.encoded(), as: UTF8.self)
        for name in testCase.offered { XCTAssertFalse(text.contains("\"\(name)\""), name) }

        var report = LocalToolEval.Report()
        report.add(dropped)
        XCTAssertTrue(report.lines().contains { $0.contains("expected tool dropped 1") })
    }

    func testARecordWithAnotherWindowIsNotResumed() throws {
        var first = record()
        first.add(LocalToolEval.Run(caseID: "a", category: .restraint, group: .fieldAssist, grades: [.toolName: true]),
                  repeat: 0, flagged: false, seconds: 1)
        var smaller = record()
        smaller.window = .init(ordinaryTokens: 4_096, toolTurnTokens: 4_096, reason: "smallPhone", toolTurnPromptBudget: 3_456)
        XCTAssertFalse(first.resumable(with: smaller))
        XCTAssertTrue(first.resumable(with: record()))
        XCTAssertEqual(LocalModelQualificationRecord.schemaName, "local-model-qualification/2")
    }

    func testADistributionReadsMedianAndTail() throws {
        let values = (1...10).map(Double.init)
        let distribution = try XCTUnwrap(LocalModelQualificationRecord.Distribution(values))
        XCTAssertEqual(distribution.count, 10)
        XCTAssertEqual(distribution.median, 6)
        XCTAssertEqual(distribution.p90, 9)
        XCTAssertEqual(distribution.max, 10)
        XCTAssertNil(LocalModelQualificationRecord.Distribution([]))
    }

    // MARK: - Decision 8

    /// A catalog entry's evidence names its dated record in `reports/`, and the record is in git:
    /// a badge can't rest on a file that was never committed.
    func testEveryEvidenceRecordTheCatalogNamesIsTrackedInGit() throws {
        let ggufURL = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources/Resources/LocalModelCatalog.json")
        let gguf = try LocalModelCatalogDocument.loadStrict(from: Data(contentsOf: ggufURL)).document.entries
        var named: [(id: String, record: String?, verified: Bool)] = LocalModelCatalog.entries.map {
            ($0.id.rawValue, $0.evidenceRecord, $0.evidence == .deviceVerified)
        }
        named += gguf.map { ($0.id.rawValue, $0.evidenceRecord, $0.evidence == .deviceVerified) }

        let tracked = try GitIndex.trackedPaths(repoRoot: Self.repoRoot)
        // The reader itself: it sees what git tracks, and not what it doesn't.
        XCTAssertTrue(tracked.contains("project.base.yml"))
        XCTAssertTrue(tracked.contains("reports/my-manuals-benchmark-2026-10-25.json"))
        XCTAssertFalse(tracked.contains("reports/local-model-qualification-never-committed.json"))

        for entry in named {
            if entry.verified { XCTAssertNotNil(entry.record, "\(entry.id): device evidence names its record") }
            guard let record = entry.record else { continue }
            XCTAssertNil(LocalModelCatalog.evidenceRecordError(record), entry.id)
            XCTAssertTrue(tracked.contains(record), "\(entry.id) names \(record), which git does not track")
        }
    }
}

/// The paths in a repository's git index (formats 2, 3 and 4), read straight from the file: the
/// simulator can't run `git`. A worktree's `.git` is a file naming its git directory.
enum GitIndex {
    enum Failure: Error { case noIndex, malformed }

    static func indexURL(repoRoot: URL) throws -> URL {
        let dotGit = repoRoot.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { throw Failure.noIndex }
        if isDirectory.boolValue { return dotGit.appendingPathComponent("index") }
        let pointer = try String(contentsOf: dotGit, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard pointer.hasPrefix("gitdir: ") else { throw Failure.noIndex }
        let path = String(pointer.dropFirst("gitdir: ".count))
        let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repoRoot.appendingPathComponent(path)
        return gitDir.appendingPathComponent("index")
    }

    static func trackedPaths(repoRoot: URL) throws -> Set<String> {
        let bytes = [UInt8](try Data(contentsOf: try indexURL(repoRoot: repoRoot)))
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        guard bytes.count >= 12, bytes[0...3] == [0x44, 0x49, 0x52, 0x43] else { throw Failure.malformed }   // "DIRC"
        let version = u32(4)
        guard (2...4).contains(version) else { throw Failure.malformed }
        let count = u32(8)
        let hashLength = 20   // SHA-1 repositories
        var offset = 12
        var previous: [UInt8] = []
        var paths = Set<String>()
        for _ in 0..<count {
            let start = offset
            // ctime, mtime (8 each), dev, ino, mode, uid, gid, size (4 each), the hash, then flags.
            offset += 40 + hashLength
            guard offset + 2 <= bytes.count else { throw Failure.malformed }
            let flags = u16(offset)
            offset += 2
            if version >= 3, flags & 0x4000 != 0 { offset += 2 }
            var path: [UInt8]
            if version == 4 {
                // A varint of bytes to drop from the previous path, then the rest, NUL-terminated.
                var c = Int(bytes[offset]); offset += 1
                var drop = c & 0x7F
                while c & 0x80 != 0 {
                    c = Int(bytes[offset]); offset += 1
                    drop = ((drop + 1) << 7) | (c & 0x7F)
                }
                guard let end = bytes[offset...].firstIndex(of: 0) else { throw Failure.malformed }
                path = Array(previous.dropLast(drop)) + bytes[offset..<end]
                offset = end + 1
            } else {
                guard let end = bytes[offset...].firstIndex(of: 0) else { throw Failure.malformed }
                path = Array(bytes[offset..<end])
                // The entry is padded with 1–8 NULs to a multiple of eight bytes.
                let length = end - start
                offset = start + ((length + 8) / 8) * 8
            }
            previous = path
            // Stage bits: only stage 0 (merged) entries are the tracked tree.
            if (flags >> 12) & 0x3 == 0 { paths.insert(String(decoding: path, as: UTF8.self)) }
        }
        return paths
    }
}
