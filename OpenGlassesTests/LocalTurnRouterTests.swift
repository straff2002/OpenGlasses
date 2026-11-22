import XCTest
@testable import OpenGlasses

/// Plan MQ P3: the turns a downloaded model answered from memory, called in code before it runs.
/// Pure routing first, then the whole local tool corpus, then a step's result as the real
/// `procedure_runner` writes it.
@MainActor
final class LocalTurnRouterTests: XCTestCase {

    private typealias R = LocalTurnRouter

    private let lookupTools: Set<String> = ["equipment_lookup", "table_lookup", "field_session", "reading"]
    private let stepTools: Set<String> = ["procedure_runner", "field_session", "table_lookup", "reading"]
    private let asked: [LocalToolLoop.Message] = [
        .user("Start the no ignition procedure"),
        .assistant("Measure the ignitor resistance. What did you measure?"),
    ]

    private func route(_ turn: String, offered: Set<String>? = nil, procedure: Bool = false,
                       awaiting: Bool = false, history: [LocalToolLoop.Message] = []) -> R.Route? {
        R.route(turn: turn, history: history,
                context: R.Context(offered: offered ?? lookupTools.union(stepTools), procedureActive: procedure,
                                   procedureAwaitsConfirmation: awaiting))
    }

    // MARK: - Error codes

    func testAnErrorCodeAskedAboutIsLookedUpByCode() {
        for turn in ["The control's showing E110. What do I check?", "and if it's E110 instead?",
                     "What does code e110 mean?", "It's flashing E 110", "Got E110 on the display"] {
            let routed = route(turn, offered: lookupTools)
            XCTAssertEqual(routed?.kind, .errorCode, turn)
            XCTAssertEqual(routed?.tool, "equipment_lookup", turn)
            XCTAssertEqual(routed?.arguments, ["query": "E110"], turn)
            XCTAssertEqual(routed?.speech, .model, turn)
        }
    }

    func testAnErrorCodeNamedWithoutAskingIsLeftToTheModel() {
        for turn in ["I've seen that E223 code loads of times, I know what it is",
                     "Keep the photo of the E223 on the display",
                     "E223, E227, E271 or E272",
                     "Log E110 against the unit"] {
            XCTAssertNil(route(turn, offered: lookupTools), turn)
        }
    }

    func testAnErrorCodeIsNotRoutedWithoutEquipmentLookup() {
        // table_lookup needs a real table id, which only the passages give.
        XCTAssertNil(route("The control's showing E110. What do I check?", offered: ["table_lookup", "reading"]))
    }

    // MARK: - Model numbers

    func testAModelNumberGivenToIdentifyTheUnitIsLookedUpAsSaid() {
        for (turn, number) in [("Which unit is this? The nameplate says 070XV36B", "070XV36B"),
                               ("Which unit is this? The nameplate says SLP99UH070XV36BK", "SLP99UH070XV36BK"),
                               ("Which unit is this? The nameplate says -090-060C", "-090-060C"),
                               ("Model number is SLP99UHXV-090-60C, what is it?", "SLP99UHXV-090-60C")] {
            let routed = route(turn, offered: lookupTools)
            XCTAssertEqual(routed?.kind, .modelNumber, turn)
            XCTAssertEqual(routed?.arguments, ["query": number], turn)
        }
    }

    func testAModelNumberNamedInAQuestionAboutTheUnitIsLeftToTheModel() {
        for turn in ["What's the AFUE on the 070XV36B?",
                     "Line voltage at the 090XV36C control is 115. Log it, then work out the voltage drop",
                     "The nameplate says 115V", "Which unit is this?", "The letter matches the nameplate model"] {
            XCTAssertNil(route(turn, offered: lookupTools), turn)
        }
    }

    func testModelNumberTokens() {
        XCTAssertEqual(R.modelNumbers(in: "says 070XV36B, or 115V at 3.5in, E110 and R-410A"), ["070XV36B", "R-410A"])
        XCTAssertEqual(R.modelNumbers(in: "SLP99 and 1234"), [], "two digits, and a plain number, are not model numbers")
    }

    // MARK: - Procedure steps

    func testStepWordsWhileAProcedureRunsAreTheRunnersNextAndRepeat() {
        for turn in ["Done. Next step", "next", "OK, next one please", "carry on", "What's next?"] {
            let routed = route(turn, offered: stepTools, procedure: true, history: asked)
            XCTAssertEqual(routed?.kind, .procedureNext, turn)
            XCTAssertEqual(routed?.arguments, ["action": "next"], turn)
            XCTAssertEqual(routed?.speech, .result, turn)
        }
        for turn in ["Sorry, say that step again", "repeat that", "Come again?", "What was that?"] {
            let routed = route(turn, offered: stepTools, procedure: true, history: asked)
            XCTAssertEqual(routed?.kind, .procedureRepeat, turn)
            XCTAssertEqual(routed?.arguments, ["action": "repeat"], turn)
        }
    }

    /// The no-model procedure voice's step words mean the same here.
    func testTheNoModelVoicesStepWordsRouteTheSameWay() {
        for phrase in ProcedureVoiceDecider.plainNextPhrases {
            XCTAssertEqual(R.stepCommand(phrase), .procedureNext, phrase)
        }
        for phrase in ProcedureVoiceDecider.repeatPhrases {
            XCTAssertEqual(R.stepCommand(phrase), .procedureRepeat, phrase)
        }
    }

    func testAShortReplyToTheStepsQuestionIsItsAnswer() {
        for turn in ["Open or out of specification", "The ignitor does not glow", "Yes", "E223, E227, E271 or E272",
                     "Low 0.20 to 0.40 (0.15 to 0.35 on the 090XV60C) and high 0.95 to 1.25"] {
            let routed = route(turn, offered: stepTools, procedure: true, history: asked)
            XCTAssertEqual(routed?.kind, .procedureAnswer, turn)
            XCTAssertEqual(routed?.arguments, ["action": "answer", "value": turn], turn)
        }
        let told: [LocalToolLoop.Message] = [.assistant("Repeat on high heat. Tell me both readings in inches of water column.")]
        XCTAssertEqual(route("Low 0.3, high 1.1", offered: stepTools, procedure: true, history: told)?.kind, .procedureAnswer)
    }

    func testAReplyIsNotAnAnswerWhenNothingWasAskedOrItIsARequest() {
        let instructed: [LocalToolLoop.Message] = [.assistant("Power off at the disconnect and remove the door.")]
        XCTAssertNil(route("The door's off", offered: stepTools, procedure: true, history: instructed),
                     "the step asked nothing")
        for turn in ["Hang on, the customer's at the door", "Log 3.5 inches", "Take a photo of the ignitor",
                     "Is that normal?", "I'll do that in a minute", "Open a new job for the next furnace",
                     "This flue is properly awkward to get at and I think I need the long screwdriver from the van"] {
            XCTAssertNil(route(turn, offered: stepTools, procedure: true, history: asked), turn)
        }
    }

    func testAReadBackOrANoteIsLeftToTheModel() {
        XCTAssertNil(route("Yes", offered: stepTools, procedure: true, awaiting: true, history: asked))
        XCTAssertEqual(route("Next step", offered: stepTools, procedure: true, awaiting: true, history: asked)?.kind,
                       .procedureNext, "step words still reach the runner, which refuses what it must")
    }

    func testNoStepRouteWithoutARunningProcedureOrItsTool() {
        for turn in ["Done. Next step", "Sorry, say that step again", "Open or out of specification"] {
            XCTAssertNil(route(turn, offered: stepTools, procedure: false, history: asked), turn)
            XCTAssertNil(route(turn, offered: ["reading", "table_lookup"], procedure: true, history: asked), turn)
        }
        XCTAssertNil(route("I already ran the no ignition procedure yesterday, it was the igniter",
                           offered: stepTools, procedure: true, history: asked))
        XCTAssertNil(route("Start the no ignition procedure", offered: stepTools, procedure: true),
                     "a start needs the catalogue; the model has it")
    }

    // MARK: - Speaking a step's result

    func testAStepResultIsSaidWithoutTheLinesForTheModel() {
        let result = LocalToolLoop.ExecutionResult(text: """
            Last step.

            ⚠️ SAFETY: Power off at the disconnect.
            Step — Check the ignitor
            Measure the ignitor resistance. What did you measure?
            This step takes an answer: a number, the resistance, in ohms (required).
            When the technician gives it, call procedure_runner action 'answer' with value set to exactly what they said.
            Choices for 'next':
            - open: Open or out of specification
            Source: p. 12
            """)
        XCTAssertEqual(R.spokenProcedureResult(result),
                       "Last step. ⚠️ SAFETY: Power off at the disconnect. Check the ignitor. "
                       + "Measure the ignitor resistance. What did you measure?")
    }

    func testResultsThatNeedTheModelAreNotSaid() {
        for text in ["Could not advance: choose a route.", "No active Field Assist session. Start a session first.",
                     #"Read this back to the technician and wait for them: "4.30, is that right?" If they agree, call 'answer'."#,
                     "Recorded, and it needs a corrective note before the procedure goes on: what did you do? Call 'answer'.",
                     "Choices for 'next':\n- a: one", ""] {
            XCTAssertNil(R.spokenProcedureResult(.init(text: text)), text)
        }
        XCTAssertNil(R.spokenProcedureResult(.init(text: "Next step.", isError: true)))
        XCTAssertEqual(R.spokenProcedureResult(.init(text: "Next step.")), "Next step.")
        XCTAssertEqual(R.spokenProcedureResult(.init(text: "Procedure complete. Outcome: resolved.")),
                       "Procedure complete. Outcome: resolved.")
    }

    /// The real runner's wording, so a change to it that this would say aloud fails here.
    func testTheRunnersOwnResultsAreSaidAsAuthored() async throws {
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        let previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        let root = ProcedureAnswerFixtures.temporaryRoot("LocalTurnRouterTests")
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
            EntitlementTestScope.restore(previousEntitlement)
        }
        let service = FieldSessionService(sessionsRoot: root)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let procedure = Procedure(id: "router_check", title: "Router check", version: "1.0.0", steps: [
            .init(id: "first", title: "Isolate the unit", instruction: "Turn the disconnect off. Is it off?",
                  safetyNote: "Never work on a live control.", citations: ["p. 3"], defaultNext: "second"),
            .init(id: "second", title: "Read the pH", instruction: "Read the pH meter.",
                  defaultNext: "done", answer: ProcedureAnswerFixtures.phAnswer),
            .init(id: "done", title: "Done", instruction: "Close up.", terminal: true, outcome: "resolved"),
        ])
        _ = try service.startProcedure(procedure)
        let tool = ProcedureRunnerTool(sessionService: service)

        let repeated = try await tool.execute(args: ["action": "repeat"])
        XCTAssertEqual(R.spokenProcedureResult(.init(text: repeated)),
                       "⚠️ SAFETY: Never work on a live control. Isolate the unit. Turn the disconnect off. Is it off?")

        let moved = try await tool.execute(args: ["action": "next"])
        let spoken = try XCTUnwrap(R.spokenProcedureResult(.init(text: moved)), moved)
        XCTAssertEqual(spoken, "Read the pH. Read the pH meter.")

        let heard = try await tool.execute(args: ["action": "answer", "value": "4.3"])
        XCTAssertNil(R.spokenProcedureResult(.init(text: heard)), "a read-back is the model's to say and confirm")
        let confirmed = try await tool.execute(args: ["action": "answer", "confirmed": true])
        XCTAssertEqual(R.spokenProcedureResult(.init(text: confirmed)), "Recorded pH: 4.30 (in spec).")

        for said in [repeated, moved, confirmed].compactMap({ R.spokenProcedureResult(.init(text: $0)) }) {
            for directed in ["procedure_runner", "Call '", "call '", "Source:", "Choices"] {
                XCTAssertFalse(said.contains(directed), "\(directed) in what is said")
            }
        }
    }

    // MARK: - The whole corpus

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/local-tool-eval/corpus", isDirectory: true)
            .appendingPathComponent(LocalToolEval.corpusFileName)
    }

    /// The turn shapes the router exists for, by case id.
    private enum Target: String, CaseIterable {
        case errorCode, modelNumber, procedureNextRepeat, procedureAnswer

        init?(id: String) {
            if id.hasPrefix("code-"), id.hasSuffix("-lookup") || id.hasSuffix("-followup") { self = .errorCode }
            else if id.hasPrefix("model-"), id.hasSuffix("-lookup") { self = .modelNumber }
            else if id.hasPrefix("proc-"), id.hasSuffix("-next") || id.hasSuffix("-repeat") { self = .procedureNextRepeat }
            else if id.hasPrefix("proc-"), id.hasSuffix("-answer") { self = .procedureAnswer }
            else { return nil }
        }

        var floor: Double {
            switch self {
            case .errorCode, .modelNumber, .procedureAnswer: return 0.9
            case .procedureNextRepeat: return 1.0
            }
        }
    }

    func testEveryCorpusCaseRoutesOnlyWhereTheCaseExpectsThatCall() throws {
        let loaded = LocalToolEval.loadCorpus(try String(contentsOf: Self.corpusURL, encoding: .utf8))
        XCTAssertEqual(loaded.undecodable, 0)
        var totals: [Target: Int] = [:]
        var routedByTarget: [Target: Int] = [:]
        var routedElsewhere = 0
        var wrong: [String] = []
        for testCase in loaded.cases {
            let target = Target(id: testCase.id)
            if let target { totals[target, default: 0] += 1 }
            guard let route = R.route(turn: testCase.turn, history: testCase.loopHistory,
                                      context: R.Context(offered: Set(testCase.offered),
                                                         procedureActive: testCase.procedureActive ?? false)) else {
                continue
            }
            if let target { routedByTarget[target, default: 0] += 1 } else { routedElsewhere += 1 }
            guard let expected = testCase.expect.calls.first else {
                wrong.append("\(testCase.id): routed a case that expects no call")
                continue
            }
            guard let variant = expected.variant(for: route.tool) else {
                wrong.append("\(testCase.id): routed \(route.tool), not an expected tool")
                continue
            }
            let missing = variant.required.filter { route.arguments[$0] == nil }
            let unmatched = variant.values.filter { !LocalToolEval.matches(route.arguments[$0.key], expected: $0.value) }
            if !missing.isEmpty || !unmatched.isEmpty {
                wrong.append("\(testCase.id): arguments missing \(missing.sorted()), wrong \(unmatched.keys.sorted())")
            }
        }
        // Counts only, by kind: never a turn.
        for target in Target.allCases {
            print("local-turn-router corpus \(target.rawValue): \(routedByTarget[target] ?? 0)/\(totals[target] ?? 0) routed")
        }
        print("local-turn-router corpus other cases routed: \(routedElsewhere); wrongly routed: \(wrong.count)")

        XCTAssertEqual(wrong, [])
        for target in Target.allCases {
            let total = try XCTUnwrap(totals[target], "the corpus has no \(target.rawValue) case")
            let routed = routedByTarget[target] ?? 0
            XCTAssertGreaterThanOrEqual(Double(routed), target.floor * Double(total),
                                        "\(target.rawValue): \(routed)/\(total) routed")
        }
    }
}
