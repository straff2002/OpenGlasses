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
                     "a start needs the catalogue")
    }

    // MARK: - Starting a procedure

    private let catalogue: [R.CatalogueEntry] = [
        .init(id: "slp99_no_ignition", title: "SLP99 No Ignition, Soft Lockout E270"),
        .init(id: "slp99_pressure_switch_lockout", title: "SLP99 Pressure Switch Lockout (E223 / E227 / E271 / E272)"),
        .init(id: "slp99_unit_size_code", title: "SLP99 Program the Unit Size Code (E203 / three bars)"),
    ]

    private func start(_ turn: String, offered: Set<String>? = nil, procedure: Bool = false,
                       catalogue: [R.CatalogueEntry]? = nil) -> R.Route? {
        R.route(turn: turn, history: [],
                context: R.Context(offered: offered ?? stepTools.union(["equipment_lookup"]), procedureActive: procedure,
                                   procedures: catalogue ?? self.catalogue))
    }

    func testAStartNamingOneProcedureStartsItByID() {
        for (turn, id) in [("Start the sLP99 No Ignition, Soft Lockout E270 procedure", "slp99_no_ignition"),
                           ("Start the sLP99 Pressure Switch Lockout (E223 / E227 / E271 / E272) procedure",
                            "slp99_pressure_switch_lockout"),
                           ("Start the sLP99 Program the Unit Size Code (E203 / three bars) procedure", "slp99_unit_size_code"),
                           ("Start the no ignition procedure", "slp99_no_ignition"),
                           ("OK, can you run the no-ignition procedure please?", "slp99_no_ignition"),
                           ("Let's do the pressure switch procedure", "slp99_pressure_switch_lockout"),
                           ("Begin the E203 procedure", "slp99_unit_size_code"),
                           ("Start SLP99 no ignition soft lockout", "slp99_no_ignition")] {
            let routed = start(turn)
            XCTAssertEqual(routed?.kind, .procedureStart, turn)
            XCTAssertEqual(routed?.tool, "procedure_runner", turn)
            XCTAssertEqual(routed?.arguments, ["action": "start", "procedure_id": id], turn)
            XCTAssertEqual(routed?.speech, .result, turn)
        }
    }

    func testAStartThatNamesNoneOrMoreThanOneIsLeftToTheModel() {
        for turn in ["Open a new job for the SLP99 furnace at 14 Hill Street", "Start job 1005"] {
            XCTAssertEqual(start(turn)?.kind, .jobCommand, "a job, not a procedure: \(turn)")
        }
        for turn in ["Start the furnace tune-up procedure", "Start the no ignition troubleshooting procedure",
                     "Start the SLP99 procedure", "Run the lockout procedure", "Start the code procedure",
                     "Start the procedure", "Open the pressure switch",
                     "Start the no ignition procedure, the igniter isn't glowing",
                     "Start the no ignition procedure and log 120 volts"] {
            XCTAssertNil(start(turn), turn)
        }
        XCTAssertEqual(start("Start the SLP99 procedure", catalogue: [catalogue[0]])?.arguments["procedure_id"],
                       "slp99_no_ignition", "one procedure in the vault: naming the unit is enough")
    }

    func testAStartIsNotRoutedWhileOneRunsOrWithoutTheRunnerOrTheCatalogue() {
        let turn = "Start the no ignition procedure"
        XCTAssertNil(start(turn, procedure: true))
        XCTAssertNil(start(turn, offered: ["field_session", "reading", "equipment_lookup"]))
        XCTAssertNil(start(turn, catalogue: []))
    }

    func testTalkAboutAProcedureIsNotAStart() {
        for turn in ["I already ran the no ignition procedure yesterday, it was the igniter",
                     "We started the no ignition procedure earlier", "Did you start the no ignition procedure?",
                     "Don't start the no ignition procedure yet", "I'll start the no ignition procedure in a minute",
                     "The no ignition procedure is the one I need", "Give me a second to think about where to start"] {
            XCTAssertNil(start(turn), turn)
        }
    }

    func testAStartResultIsSaidWithItsOwnLine() {
        let result = LocalToolLoop.ExecutionResult(text: """
            Started procedure 'SLP99 No Ignition, Soft Lockout E270'.

            Step — Confirm the lockout
            Read the code on the control.
            (Call 'next' to continue.)
            """)
        XCTAssertEqual(R.spokenProcedureResult(result),
                       "Started procedure 'SLP99 No Ignition, Soft Lockout E270'. Confirm the lockout. Read the code on the control.")
        XCTAssertNil(R.spokenProcedureResult(.init(text: "Could not start procedure: unknown procedure.")))
    }

    // MARK: - Job commands (part 2)

    private let jobTools: Set<String> = ["field_session", "reading", "evidence", "equipment_lookup", "procedure_runner"]

    private func job(_ turn: String, offered: Set<String>? = nil, procedure: Bool = false) -> R.Route? {
        route(turn, offered: offered ?? jobTools, procedure: procedure)
    }

    func testThePhonesJobCommandsRouteToTheirAction() {
        let cases: [(String, [String: String])] = [
            ("Open a new job for the SLP99 furnace at 14 Hill Street", ["action": "start"]),
            ("Start job 1005", ["action": "start", "job_reference": "1005"]),
            ("The work order number is 2231", ["action": "set_job_reference", "job_reference": "2231"]),
            ("Right, back on the furnace job", ["action": "resume"]),
            ("Moving on to the second furnace in the plant room", ["action": "next_unit"]),
            ("How long have I been on this job?", ["action": "status"]),
            ("Pause the job, I'm going for lunch", ["action": "pause"]),
            ("That's it, close the job", ["action": "end"]),
        ]
        for (turn, arguments) in cases {
            let routed = job(turn)
            XCTAssertEqual(routed?.kind, .jobCommand, turn)
            XCTAssertEqual(routed?.tool, "field_session", turn)
            XCTAssertEqual(routed?.arguments, arguments, turn)
            XCTAssertEqual(routed?.speech, .model, "field_session writes for the model: \(turn)")
        }
    }

    func testOtherPlainShapesOfTheSameCommands() {
        let cases: [(String, [String: String])] = [
            ("OK, start a new job", ["action": "start"]),
            ("New job, work order WO-2231", ["action": "start", "job_reference": "WO-2231"]),
            ("Can you open a job for me please?", ["action": "start"]),
            ("Job number 1005", ["action": "set_job_reference", "job_reference": "1005"]),
            ("Set the work order to 2231", ["action": "set_job_reference", "job_reference": "2231"]),
            ("It's work order 2231", ["action": "set_job_reference", "job_reference": "2231"]),
            ("Resume the job", ["action": "resume"]),
            ("I'm back on the job", ["action": "resume"]),
            ("Put the job on hold", ["action": "pause"]),
            ("Next unit", ["action": "next_unit"]),
            ("Now the other boiler, it's a 090XV36C", ["action": "next_unit", "unit": "090XV36C"]),
            ("On to the next furnace", ["action": "next_unit"]),
            ("What's the job status?", ["action": "status"]),
            ("Wrap up the job", ["action": "end"]),
            ("Close the job, it's all working", ["action": "end"]),
        ]
        for (turn, arguments) in cases {
            XCTAssertEqual(job(turn)?.arguments, arguments, turn)
        }
    }

    func testJobTalkThatIsNotACommandIsLeftToTheModel() {
        for turn in ["I'll start the job properly once I've had a look", "I opened the job yesterday",
                     "We started the job this morning", "Don't close the job yet", "Close the job later",
                     "Should I close the job?", "Did you start the job?", "Start the job properly",
                     "The work order number was 2231", "I'll give you the work order number in a bit",
                     "Okay, I'm back", "Back on the other job", "The second furnace is in the plant room",
                     "The next furnace has the same fault", "Moving on to the second furnace after lunch",
                     "How do I get to the next job from here?", "Thanks, that's all for this one",
                     "Close the job and send the report", "Close the job, then email the customer",
                     "Pause the job, no wait, hang on", "Start the job if the customer's in",
                     "Moving on to the second furnace?", "Job 1005"] {
            XCTAssertNil(job(turn), turn)
        }
    }

    func testAJobCommandNeedsFieldSessionAndAStartOrNextUnitNoProcedure() {
        XCTAssertNil(job("Start job 1005", offered: ["reading", "evidence"]))
        XCTAssertNil(job("Open a new job for the next furnace", procedure: true), "a job is open while a procedure runs")
        XCTAssertNil(job("Moving on to the second furnace", procedure: true))
        XCTAssertEqual(job("Pause the job", procedure: true)?.arguments, ["action": "pause"])
    }

    func testJobReferencesAreTakenAsWritten() {
        XCTAssertEqual(R.jobReferences(in: "Start job 1005"), ["1005"])
        XCTAssertEqual(R.jobReferences(in: "Open a new job for the SLP99 furnace at 14 Hill Street"), [])
        XCTAssertEqual(Set(R.jobReferences(in: "Job 1005, no, work order 2231")), ["1005", "2231"])
        XCTAssertNil(job("Start job 1005, work order 2231"), "two numbers: which is the job's is the model's question")
    }

    // MARK: - Evidence (part 2)

    private let evidenceTools: Set<String> = ["evidence", "field_session", "reading"]

    func testThePhonesEvidenceChoicesRouteToTheirAction() {
        for (turn, action) in [("Keep the photo of the gas valve label", "keep"),
                               ("Keep the photo of the E223 on the display", "keep"),
                               ("Exclude the blurry photo of the inducer", "exclude"),
                               ("Include all the all of today's photos", "include_all"),
                               ("Leave that photo out", "exclude"), ("Leave out the last picture", "exclude"),
                               ("Don't include the photo of the flue", "exclude"),
                               ("Put the last picture back", "include"), ("Include that photo", "include"),
                               ("Exclude all the photos", "exclude_all"), ("Keep all the photos as they are", "keep"),
                               ("OK, include every photo", "include_all")] {
            let routed = route(turn, offered: evidenceTools)
            XCTAssertEqual(routed?.kind, .evidence, turn)
            XCTAssertEqual(routed?.arguments, ["action": action], "no item: a photo is described, never given by id: \(turn)")
            XCTAssertEqual(routed?.speech, .model, turn)
        }
    }

    func testPhotoTalkThatIsNotAChoiceIsLeftToTheModel() {
        for turn in ["I'll take photos once I've got the cover off", "Take a photo of the gas valve",
                     "Keep taking photos of the flue", "Keep a photo of this for me", "Keep the photo out",
                     "Leave the photo in", "Should I keep the photo?", "Don't keep anything yet",
                     "Keep the photo of the label and log 3.5 inches", "The photo of the inducer is blurry",
                     "Exclude the blurry photo later", "Keep going"] {
            XCTAssertNil(route(turn, offered: evidenceTools), turn)
        }
        XCTAssertNil(route("Keep the photo of the gas valve label", offered: ["field_session", "reading"]),
                     "not without evidence offered")
    }

    // MARK: - A reading's follow-up (part 2)

    private let twoValues: [LocalToolLoop.Message] = [
        .user("Manifold, natural gas reads 0.68 on Low, all models except 090XV60C, and 1.22 on the other burner. Log the first."),
        .assistant("Logged 0.68 in. w.c.."),
    ]

    func testTheOtherOfTwoValuesIsRecordedAfterTheFirstWasLogged() {
        for turn in ["and the other one?", "The other one", "Log the other one too", "And the second one, please"] {
            let routed = route(turn, offered: ["reading", "field_session"], history: twoValues)
            XCTAssertEqual(routed?.kind, .readingFollowUp, turn)
            XCTAssertEqual(routed?.tool, "reading", turn)
            XCTAssertEqual(routed?.arguments, ["action": "record_reading", "quantity": "Manifold, natural gas",
                                               "value": "1.22", "unit": "in. w.c."], turn)
            XCTAssertEqual(routed?.speech, .model, turn)
        }
    }

    func testTheFollowUpTakesTheFirstsQuantityAndUnitFromTheEarlierCall() {
        let call = LocalToolLoop.Call(id: "call_1", name: "reading",
                                      arguments: ["action": "record_reading", "quantity": "manifold pressure",
                                                  "value": "0.68", "unit": "inWC"])
        let history: [LocalToolLoop.Message] = [
            twoValues[0], .assistant("", calling: call),
            .toolResult("Recorded manifold pressure 0.68 inWC, as the technician reported it.", for: call),
            .assistant("Done."),
        ]
        XCTAssertEqual(route("and the other one?", offered: ["reading"], history: history)?.arguments,
                       ["action": "record_reading", "quantity": "manifold pressure", "value": "1.22", "unit": "inWC"])
        XCTAssertEqual(route("and the other?", offered: ["reading"], history: [
            .user("Supply pressure is 7.5 in. w.c. and 7.2 in. w.c. at the outlet. Log the first one."),
            .assistant("Recorded supply pressure 7.5 in. w.c."),
        ])?.arguments, ["action": "record_reading", "quantity": "Supply pressure", "value": "7.2", "unit": "in. w.c."])
    }

    func testAFollowUpThatIsNotCertainIsLeftToTheModel() {
        let ambiguous: [(String, [LocalToolLoop.Message])] = [
            ("three values", [.user("Manifold reads 0.68, 1.22 and 1.4. Log the first."), .assistant("Logged 0.68.")]),
            ("nothing logged", [twoValues[0], .assistant("Which one did you want first?")]),
            ("not logged", [twoValues[0], .assistant("I couldn't log 0.68, there's no job open.")]),
            ("both logged", [twoValues[0], .assistant("Logged 0.68 and 1.22.")]),
            ("different quantities", [.user("Supply air reads 140 and return air 72. Log the first."),
                                      .assistant("Logged 140.")]),
            ("different units", [.user("Line reads 120 volts and 4.5 amps. Log the first."), .assistant("Logged 120 volts.")]),
            ("no reply yet", [twoValues[0]]),
            ("no quantity", [.user("0.68 and 1.22. Log the first."), .assistant("Logged 0.68.")]),
            ("the same value twice", [.user("Manifold reads 0.68 and 0.68. Log the first."), .assistant("Logged 0.68.")]),
        ]
        for (why, history) in ambiguous {
            XCTAssertNil(route("and the other one?", offered: ["reading"], history: history), why)
        }
        for turn in ["and the other one is 1.3", "what about the other furnace?", "the other one's fine", "and the next step?"] {
            XCTAssertNil(route(turn, offered: ["reading"], history: twoValues), turn)
        }
        XCTAssertNil(route("and the other one?", offered: ["field_session", "evidence"], history: twoValues),
                     "not without reading offered")
    }

    // MARK: - A reading logged in one breath

    func testALogCommandWithOneValueAndWhatWasMeasuredIsRecorded() {
        let cases: [(String, [String: String])] = [
            ("Log manifold, natural gas, Low, all models except 090XV60C at 0.68 in. w.c.",
             ["quantity": "manifold, natural gas, Low, all models except 090XV60C", "value": "0.68", "unit": "in. w.c."]),
            ("Log line pressure, in. w.c., Natural at 7.5 in. w.c.",
             ["quantity": "line pressure, in. w.c., Natural", "value": "7.5", "unit": "in. w.c."]),
            ("Log high fire co2 % natural, -070, -090XV36C/48C, -110, -135 at 7.8 %",
             ["quantity": "high fire co2 % natural, -070, -090XV36C/48C, -110, -135", "value": "7.8", "unit": "%"]),
            ("Log manifold pressure on low fire, 0.6 inches",
             ["quantity": "manifold pressure on low fire", "value": "0.6", "unit": "inches"]),
            ("Log line pressure 7 inches natural", ["quantity": "line pressure, natural", "value": "7", "unit": "inches"]),
            ("OK, log supply air at 140, it's running a bit warm", ["quantity": "supply air", "value": "140"]),
            ("Log 0.6 on low fire", ["quantity": "low fire", "value": "0.6"]),
            ("Flame signal reads 2.9 microamps, log it", ["quantity": "Flame signal", "value": "2.9", "unit": "microamps"]),
            ("Return air is 72 degrees, record that please", ["quantity": "Return air", "value": "72", "unit": "degrees"]),
        ]
        for (turn, said) in cases {
            let routed = route(turn, offered: ["reading", "field_session", "table_lookup", "domain_calc"])
            XCTAssertEqual(routed?.kind, .readingLogged, turn)
            XCTAssertEqual(routed?.tool, "reading", turn)
            XCTAssertEqual(routed?.arguments, said.merging(["action": "record_reading"]) { a, _ in a }, turn)
            XCTAssertEqual(routed?.speech, .model, turn)
        }
    }

    func testALogTurnThatIsNotJustTheCommandIsLeftToTheModel() {
        let offered: Set<String> = ["reading", "field_session", "domain_calc"]
        for turn in [
            "Can you log 0.6 on low fire?",                                   // a question
            "Log supply air at 140 and return air at 72",                     // two values
            "Don't log anything yet, I'm just looking",                       // denied
            "Log supply at 140 once it settles",                              // conditioned
            "Log 140",                                                        // nothing said of what
            "Supply air was 135, not 140",                                    // a correction
            "Line voltage at the control is 115. Log it, then work out the voltage drop",
            "Log supply air at 140 and take a photo",                         // another tool too
            "Supply air reads 140",                                           // no command
            "What should manifold pressure be at 0.6?",                       // a question
        ] {
            XCTAssertNil(route(turn, offered: offered), turn)
        }
        XCTAssertNil(route("Log manifold pressure at 0.6 inches", offered: ["field_session", "table_lookup"]),
                     "not without reading offered")
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
        case errorCode, modelNumber, procedureStart, procedureNextRepeat, procedureAnswer
        case jobCommand, evidence, readingFollowUp, readingLogged

        init?(id: String) {
            if id.hasPrefix("code-"), id.hasSuffix("-lookup") || id.hasSuffix("-followup") { self = .errorCode }
            else if id.hasPrefix("job-") { self = .jobCommand }
            else if id.hasPrefix("evidence-") { self = .evidence }
            else if id.hasPrefix("sv-"), id.hasSuffix("-followup") { self = .readingFollowUp }
            else if id.hasPrefix("sv-"), id.hasSuffix("-log-in") || id.hasSuffix("-log-out") { self = .readingLogged }
            else if id.hasPrefix("model-"), id.hasSuffix("-lookup") { self = .modelNumber }
            else if id.hasPrefix("proc-"), id.hasSuffix("-start") { self = .procedureStart }
            else if id.hasPrefix("proc-"), id.hasSuffix("-next") || id.hasSuffix("-repeat") { self = .procedureNextRepeat }
            else if id.hasPrefix("proc-"), id.hasSuffix("-answer") { self = .procedureAnswer }
            else { return nil }
        }

        var floor: Double {
            switch self {
            case .errorCode, .modelNumber, .procedureAnswer: return 0.9
            case .procedureStart, .procedureNextRepeat, .jobCommand, .evidence, .readingFollowUp, .readingLogged: return 1.0
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
                                                         procedureActive: testCase.procedureActive ?? false,
                                                         procedures: testCase.procedures ?? [])) else {
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
        let catalogued = loaded.cases.filter { $0.vault == "lennox-slp99" }
        XCTAssertTrue(!catalogued.isEmpty && catalogued.allSatisfy { ($0.procedures ?? []).count == 3 },
                      "every case of the vault sees its catalogue, restraint included")
        for target in Target.allCases {
            let total = try XCTUnwrap(totals[target], "the corpus has no \(target.rawValue) case")
            let routed = routedByTarget[target] ?? 0
            XCTAssertGreaterThanOrEqual(Double(routed), target.floor * Double(total),
                                        "\(target.rawValue): \(routed)/\(total) routed")
        }
    }
}
