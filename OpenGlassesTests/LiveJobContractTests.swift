import XCTest
@testable import OpenGlasses

/// The provider-neutral guided-job contract (Plan FO P3a): the bounded block both live backends
/// carry, and the job tool surface they must declare identically.
@MainActor
final class LiveJobContractTests: XCTestCase {

    // MARK: - Fixtures

    private func session(intake: JobIntakeState = .needsReference,
                         reference: String? = nil,
                         pendingUnit: PendingUnitChange? = nil,
                         equipment: EquipmentIdentity? = nil,
                         paused: Bool = false,
                         ended: Bool = false,
                         outcome: FieldSession.Outcome = .inProgress) -> FieldSession {
        var session = FieldSession(id: "s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   endedAt: nil, pausedAt: nil, resumedAt: nil,
                                   outcome: .inProgress, startLocation: nil, endLocation: nil,
                                   escalations: [], billableSeconds: 0)
        session.jobIntake = intake
        session.jobReference = reference
        session.pendingUnitChange = pendingUnit
        session.equipment = equipment
        session.pausedAt = paused ? Date() : nil
        session.endedAt = ended ? Date() : nil
        session.outcome = outcome
        return session
    }

    private func identity(_ token: String) -> EquipmentIdentity {
        EquipmentIdentity(modelToken: token, heading: token, file: "models.md", source: .spoken)
    }

    private func task(_ id: String, _ title: String, _ status: FieldSession.Task.Status) -> FieldSession.Task {
        FieldSession.Task(id: id, title: title, origin: .recommended, status: status)
    }

    // MARK: - The block

    func testNoBlockWithoutAnOpenJob() {
        XCTAssertNil(LiveJobContract.block(session: nil))
        XCTAssertNil(LiveJobContract.block(session: session(ended: true, outcome: .resolved)))
        XCTAssertNil(LiveJobContract.block(session: session(outcome: .cancelled)))
    }

    func testBlockStatesTheJobIsOpenAndWhoRunsIt() throws {
        let block = try XCTUnwrap(LiveJobContract.block(session: session()))
        XCTAssertTrue(block.hasPrefix(LiveJobContract.heading))
        XCTAssertTrue(block.contains("JOB: open and running"))
        // The one rule the whole block exists for.
        XCTAssertTrue(block.contains("Do not ask for a job number"))
    }

    func testPausedJobSaysPaused() throws {
        let block = try XCTUnwrap(LiveJobContract.block(session: session(paused: true)))
        XCTAssertTrue(block.contains("JOB: open and paused"))
    }

    /// Every intake state renders, and each says something different about what the model may do.
    func testEveryIntakeStateRenders() throws {
        let cases: [(JobIntakeState, String)] = [
            (.needsReference, "outstanding"),
            (.asked(attempts: 1), "outstanding"),
            (.confirming(candidate: "1005", attempts: 1), "reading it back"),
            (.recorded(reference: "1005"), "recorded exactly as given"),
            (.declined, "do not have one"),
            (.outstanding, "stopped asking"),
        ]
        for (state, expected) in cases {
            let block = try XCTUnwrap(LiveJobContract.block(session: session(intake: state)))
            XCTAssertTrue(block.contains("JOB NUMBER:"), "\(state) lost the job-number line")
            XCTAssertTrue(block.contains(expected), "\(state) did not say \(expected)")
        }
        // `.notRequired` is the one state with nothing to say about the number.
        let block = try XCTUnwrap(LiveJobContract.block(session: session(intake: .notRequired)))
        XCTAssertFalse(block.contains("JOB NUMBER:"))
    }

    func testRecordedNumberIsQuotedExactlyAsGiven() throws {
        let block = try XCTUnwrap(LiveJobContract.block(
            session: session(intake: .recorded(reference: "WO-1005-B"), reference: "WO-1005-B")))
        XCTAssertTrue(block.contains("\"WO-1005-B\""))

        // A number with a slash in it survives too, JSON-escaped like every other quoted value in
        // the snapshot — the escaping is the quoting, not a change to the number.
        let slashed = try XCTUnwrap(LiveJobContract.block(
            session: session(intake: .recorded(reference: "WO-1005/B"), reference: "WO-1005/B")))
        let line = try XCTUnwrap(slashed.split(separator: "\n").first { $0.hasPrefix("JOB NUMBER:") })
        let quoted = try XCTUnwrap(line.split(separator: "\"").dropFirst().first)
        let decoded = try JSONDecoder().decode(String.self, from: Data("\"\(quoted)\"".utf8))
        XCTAssertEqual(decoded, "WO-1005/B")
    }

    func testPendingUnitQuestionIsStatedAndForbidsRescoping() throws {
        let pending = PendingUnitChange(candidate: identity("SLP99"), candidateSerial: nil)
        let block = try XCTUnwrap(LiveJobContract.block(session: session(pendingUnit: pending)))
        XCTAssertTrue(block.contains("PENDING APP QUESTION:"))
        XCTAssertTrue(block.contains("do not re-scope"))
        XCTAssertTrue(block.contains("SLP99"))
    }

    func testEquipmentLineNamesTheMachineOrSaysThereIsNone() throws {
        let none = try XCTUnwrap(LiveJobContract.block(session: session()))
        XCTAssertTrue(none.contains("EQUIPMENT: not identified yet"))
        let known = try XCTUnwrap(LiveJobContract.block(session: session(equipment: identity("SLP99"))))
        XCTAssertTrue(known.contains("EQUIPMENT: \"SLP99\""))
    }

    func testTaskPositionIsStatedWhenOneIsInHand() throws {
        var open = session(equipment: identity("SLP99"))
        open.tasks = [task("t1", "Check the flue", .done),
                      task("t2", "Check the pressure switch", .inProgress)]
        let block = try XCTUnwrap(LiveJobContract.block(session: open))
        XCTAssertTrue(block.contains("TASK: \"Check the pressure switch\" (2 of 2, in progress)"))
        XCTAssertTrue(block.contains("Visiting a step does not complete it"))
    }

    func testTaskLineSaysNoneInHandWhenNothingIsRunning() throws {
        var open = session()
        open.tasks = [task("t1", "Check the flue", .recommended)]
        let block = try XCTUnwrap(LiveJobContract.block(session: open))
        XCTAssertTrue(block.contains("TASK: none in hand; 1 on this machine"))
    }

    // MARK: - The bound

    /// A job whose every field is absurdly long still produces a block within the bound, and still
    /// carries the number — the line a model that lost it would ask about again.
    func testBlockStaysWithinItsBoundAndKeepsTheNumber() throws {
        let long = String(repeating: "A", count: 900)
        var open = session(intake: .recorded(reference: "1005"), reference: "1005",
                           pendingUnit: PendingUnitChange(candidate: identity(long)),
                           equipment: identity(long))
        open.tasks = (0..<40).map { task("t\($0)", long, $0 == 0 ? .inProgress : .recommended) }
        open.visitedUnits = (0..<20).map {
            VisitedUnit(identity: identity("\(long)-\($0)"), continuityScope: "initial")
        }
        let block = try XCTUnwrap(LiveJobContract.block(session: open))
        XCTAssertLessThanOrEqual(block.count, LiveJobContract.characterLimit)
        XCTAssertTrue(block.contains("JOB NUMBER:"))
        XCTAssertTrue(block.hasPrefix(LiveJobContract.heading))
    }

    func testOrdinaryBlockIsWellUnderTheBound() throws {
        let block = try XCTUnwrap(LiveJobContract.block(
            session: session(intake: .recorded(reference: "1005"), reference: "1005",
                             equipment: identity("SLP99"))))
        XCTAssertLessThan(block.count, LiveJobContract.characterLimit)
    }

    // MARK: - The tool surface

    /// The generic declarations both providers start from, built from the real tools rather than
    /// from a registry (which cannot be constructed headlessly).
    private func jobToolDeclarations() -> [[String: Any]] {
        let tools: [any NativeTool] = [FieldSessionTool(), EquipmentLookupTool()]
        return tools.map {
            ["name": $0.name, "description": $0.description, "parameters": $0.parametersSchema]
        }
    }

    func testTheJobToolSurfaceIsTheTwoToolsTheFlowNeeds() {
        XCTAssertEqual(LiveJobContract.jobToolNames, ["field_session", "equipment_lookup"])
        let shapes = LiveJobContract.jobToolDeclarations(in: jobToolDeclarations())
        XCTAssertEqual(shapes.map(\.name), ["equipment_lookup", "field_session"])
    }

    /// `set_job_reference` is an action on `field_session`, not a tool of its own — the plan's
    /// wording notwithstanding. Whichever provider is asking, the action has to be declared, or a
    /// job number can never be recorded by the model at all.
    func testFieldSessionDeclaresTheJobReferenceAction() throws {
        let shapes = LiveJobContract.jobToolDeclarations(in: jobToolDeclarations())
        let fieldSession = try XCTUnwrap(shapes.first { $0.name == "field_session" })
        XCTAssertTrue(fieldSession.parameters.contains(LiveJobContract.jobReferenceAction))
    }

    /// The diff test: what Gemini Live is handed and what OpenAI Realtime is handed describe the
    /// same three things, character for character.
    func testBothProvidersDeclareIdenticalJobToolSchemas() {
        let generic = jobToolDeclarations()
        // Gemini Live takes the generic shape straight through.
        let gemini = LiveJobContract.jobToolDeclarations(in: generic)
        // OpenAI Realtime takes the flat session-tool shape.
        let realtime = LiveJobContract.jobToolDeclarations(
            in: ToolDeclarations.openAIRealtimeTools(declarations: generic,
                                                     names: LiveJobContract.jobToolNames))
        XCTAssertEqual(gemini, realtime)
        XCTAssertFalse(gemini.isEmpty)
    }

    func testRealtimeMapperUsesTheFlatShapeTheApiAccepts() throws {
        let mapped = ToolDeclarations.openAIRealtimeTools(declarations: jobToolDeclarations(),
                                                          names: LiveJobContract.jobToolNames)
        let first = try XCTUnwrap(mapped.first)
        XCTAssertEqual(first["type"] as? String, "function")
        // Flat, not nested: a `function` key here is the shape the API accepts and ignores.
        XCTAssertNil(first["function"])
        XCTAssertNotNil(first["name"])
        XCTAssertNotNil(first["parameters"])
    }

    func testRealtimeMapperDropsEverythingOutsideTheJobSurface() {
        let extra = jobToolDeclarations() + [["name": "take_photo", "description": "x",
                                              "parameters": ["type": "object"]]]
        let mapped = ToolDeclarations.openAIRealtimeTools(declarations: extra,
                                                          names: LiveJobContract.jobToolNames)
        XCTAssertEqual(Set(mapped.compactMap { $0["name"] as? String }),
                       LiveJobContract.jobToolNames)
    }

    // MARK: - A hundred turns

    /// The reason the live block exists rather than the continuity render being re-sent.
    ///
    /// After a long visit the continuity render compacts: older records are dropped to fit its
    /// budget. The job's own state must not be among them — a model that has lost "a number is
    /// still owed" asks for it again, over the top of the app that is already asking. So this
    /// checks both halves after a hundred turns: the render keeps the job lines, and the bounded
    /// block that is actually transmitted mid-session carries them whatever the log holds.
    func testAHundredTurnsDoNotCompactAwayTheIntakeOrThePendingQuestion() throws {
        var open = session(intake: .confirming(candidate: "1005", attempts: 1),
                           pendingUnit: PendingUnitChange(candidate: identity("SLP99")),
                           equipment: identity("SLP99"))
        open.continuityScope = "initial"
        let events: [SessionLogger.Event] = (0..<100).map { index in
            SessionLogger.Event(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                kind: .userMessage,
                text: String(repeating: "the technician said something long ", count: 8),
                payload: ["source_id": AnyCodable("t\(index)"),
                          "equipment_scope": AnyCodable("initial")])
        }

        let render = FieldSessionContextSnapshot.render(session: open, events: events)
        XCTAssertTrue(render.contains("records omitted"), "the fixture did not actually compact")
        XCTAssertTrue(render.contains("reading it back for confirmation"))
        XCTAssertTrue(render.contains("PENDING APP QUESTION:"))

        let block = try XCTUnwrap(LiveJobContract.block(session: open))
        XCTAssertTrue(block.contains("reading it back for confirmation"))
        XCTAssertTrue(block.contains("PENDING APP QUESTION:"))
        XCTAssertLessThanOrEqual(block.count, LiveJobContract.characterLimit)
    }

    func testCanonicalJSONIsOrderIndependent() {
        let a: [String: Any] = ["b": 1, "a": ["z": true, "y": false]]
        let b: [String: Any] = ["a": ["y": false, "z": true], "b": 1]
        XCTAssertEqual(LiveJobContract.canonicalJSON(a), LiveJobContract.canonicalJSON(b))
    }
}
