import XCTest
@testable import OpenGlasses

// Plan KM P3 — coaching steps: written on the expert's phone, sent back as an `.ogcase` of kind
// `coaching`, loaded on the technician's open job only when they answer its own handover, walked
// one step at a time as written, the safety rule first, with readings recorded against each step.
//
// Every name, number, company, step and safety rule here is invented.

enum CoachingFixture {

    static let gasStep = "Turn the gas valve off at the appliance and open the burner door."
    static let hoseStep = "Pull the hose off the pressure switch and blow it through."
    static let readStep = "Read the switch with the inducer running."

    static let steps: [CoachingStep] = [
        CoachingStep(id: "s1", instruction: hoseStep, stopIf: "the hose is clear and the switch still reads open"),
        CoachingStep(id: "s2", instruction: readStep, reading: .init(quantity: "switch pressure", unit: "inWC")),
        CoachingStep(id: "s3", instruction: gasStep),
    ]

    /// A safety file of the vault's, invented.
    static let coreFiles: [(filename: String, contents: String)] = [
        ("safety.md", """
        # Safety
        ## Gas isolation
        - Shut the supply at the appliance valve and check for leaks before any gas train is opened.
        ## Electrical lockout
        - Lock out and tag the disconnect before touching wiring.
        """),
        ("unit-notes.md", "## Gas notes\nNothing here is a safety file."),
    ]

    /// The expert's side: the handover opened, steps written, the reply built.
    @MainActor
    static func reply(for handovers: [ExpertHandover], steps: [CoachingStep] = steps, card: ExpertCard? = nil,
                      directory: URL) throws -> ExpertCoachingReply {
        let store = AssistingHandoverStore(directory: directory.appendingPathComponent(UUID().uuidString),
                                           now: { AssistingFixture.start })
        for handover in handovers { store.open(AssistingFixture.opened(handover)) }
        let id = handovers[0].handoverId
        store.setCoachingDraft(id: id, steps: steps)
        let held = try XCTUnwrap(store.handover(id: id))
        return try ExpertCoachingReply.build(for: held, steps: held.coachingDraft ?? [], card: card,
                                             now: AssistingFixture.start).get()
    }
}

// MARK: - The expert's side: the editor's draft and the reply

@MainActor
final class CoachingReplyTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = AssistingFixture.temporaryDirectory("coaching-reply")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func service(_ store: AssistingHandoverStore) -> AssistingService {
        let replies = StagedExportCoordinator(channel: .assistingReply, rootDirectoryName: "unused",
                                              store: ProtectedExportFileStore(rootDirectoryName: "unused",
                                                                              root: directory.appendingPathComponent("staging")))
        return AssistingService(store: store, cards: ExpertCardStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                replies: replies, now: { AssistingFixture.start })
    }

    func testTheEditorsDraftAndNotePersistAcrossARelaunch() throws {
        let folder = directory.appendingPathComponent("store")
        let first = AssistingHandoverStore(directory: folder, now: { AssistingFixture.start })
        let assisting = service(first)
        XCTAssertTrue(assisting.open(AssistingFixture.opened(AssistingFixture.handover())).shown)
        for step in CoachingFixture.steps { XCTAssertNil(assisting.saveCoachingStep(step, for: "H-1")) }
        // Edit the first, move the last to the top, delete the middle one.
        XCTAssertNil(assisting.saveCoachingStep(CoachingStep(id: "s1", instruction: "Check the hose for water."), for: "H-1"))
        assisting.moveCoachingSteps(for: "H-1", from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(assisting.coachingSteps(for: "H-1").map(\.id), ["s3", "s1", "s2"])
        assisting.deleteCoachingSteps(for: "H-1", at: IndexSet(integer: 2))
        assisting.saveNote("Swap the switch if it reads open.", for: "H-1")

        // The app dies; the store opens again from disk.
        let again = AssistingHandoverStore(directory: folder, now: { AssistingFixture.start })
        let held = try XCTUnwrap(again.handover(id: "H-1"))
        XCTAssertEqual(held.coachingDraft?.map(\.id), ["s3", "s1"])
        XCTAssertEqual(held.coachingDraft?[1].instruction, "Check the hose for water.")
        XCTAssertEqual(held.noteDraft, "Swap the switch if it reads open.")
        XCTAssertEqual(service(again).noteDraft(for: "H-1"), "Swap the switch if it reads open.")

        // A later generation replaces the handover and keeps the expert's draft.
        again.open(AssistingFixture.opened(AssistingFixture.handover(generation: 2)))
        XCTAssertEqual(again.handover(id: "H-1")?.coachingDraft?.count, 2)
    }

    func testAMoveIsWhatOnMoveReports() {
        XCTAssertEqual(AssistingService.moved(["a", "b", "c"], from: IndexSet(integer: 0), to: 3), ["b", "c", "a"])
        XCTAssertEqual(AssistingService.moved(["a", "b", "c"], from: IndexSet(integer: 2), to: 0), ["c", "a", "b"])
        XCTAssertEqual(AssistingService.moved(["a", "b", "c"], from: IndexSet(integer: 1), to: 1), ["a", "b", "c"])
    }

    func testStepsAreTidiedButNeverShortenedOrReworded() {
        let step = CoachingStep(instruction: "  Check the hose\n for   water.\u{0007} ", readingQuantity: "  ",
                                readingUnit: "inWC", stopIf: "\n")
        XCTAssertEqual(step.instruction, "Check the hose for water.")
        XCTAssertNil(step.reading, "no reading without what to read")
        XCTAssertNil(step.stopIf)
        let long = CoachingStep(instruction: String(repeating: "a", count: CoachingStep.instructionLimit + 1))
        XCTAssertEqual(long.instruction.count, CoachingStep.instructionLimit + 1, "never cut short")
        XCTAssertNotNil(long.problem, "refused by name instead")
        XCTAssertNotNil(service(AssistingHandoverStore(directory: directory)).saveCoachingStep(long, for: "H-1"))
    }

    func testTheCoachingFileRoundTripsAndCarriesNoRate() throws {
        let card = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111", faceTimeHandle: "sam@example.com",
                              handoverChannel: .messages, specialties: ["furnace"], licences: [])
        let reply = try CoachingFixture.reply(for: [AssistingFixture.handover(generation: 1), AssistingFixture.handover(generation: 2)],
                                              card: card, directory: directory)
        XCTAssertEqual(reply.kind, "coaching")
        XCTAssertEqual(reply.generationsSeen, [1, 2])
        XCTAssertEqual(reply.expert.listId, "sam")
        XCTAssertEqual(reply.expert.cardId, card.cardId)
        XCTAssertEqual(reply.steps, CoachingFixture.steps)

        let file = try ExpertCoachingReplyFile.write(reply)
        XCTAssertEqual(try ExpertCoachingReplyFile.read(file).get(), reply)
        guard case .coachingReply(let received) = ExpertHandoverFile.received(file) else {
            return XCTFail("an .ogcase of kind coaching is read as a coaching reply")
        }
        XCTAssertEqual(received, reply)
        XCTAssertEqual(ExpertCoachingReplyFile.fileName(reply), "job-4471-coaching.ogcase")

        let json = String(decoding: try ExpertHandoverFile.encoder().encode(reply), as: UTF8.self).lowercased()
        for word in ["rate", "perhour", "currency", "amount"] { XCTAssertFalse(json.contains(word), word) }

        // Neither of the other readers takes it, and it takes neither of theirs.
        XCTAssertEqual(ExpertTimeReplyFile.read(file).failureValue, .notAReply)
        XCTAssertEqual(ExpertHandoverFile.read(file).failureValue, .notAHandover)
        let handoverFile = try ExpertHandoverFile.write(AssistingFixture.handover(photos: 0), photos: [:])
        XCTAssertEqual(ExpertCoachingReplyFile.read(handoverFile).failureValue, .notCoaching)

        // The same steps for the same handover are the same reply.
        XCTAssertEqual(try CoachingFixture.reply(for: [AssistingFixture.handover()], directory: directory).coachingId,
                       try CoachingFixture.reply(for: [AssistingFixture.handover()], directory: directory).coachingId)
    }

    func testTheReaderRefusesAnythingButCleanSteps() throws {
        let reply = try CoachingFixture.reply(for: [AssistingFixture.handover()], directory: directory)
        let json = try ExpertHandoverFile.encoder().encode(reply)
        XCTAssertEqual(ExpertCoachingReplyFile.read(StoredZipWriter.zip([(ExpertHandoverFile.manifestName, json),
                                                                           ("photos/01.jpg", AssistingFixture.jpeg)])).failureValue,
                       .unexpectedEntry("photos/01.jpg"))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["steps"] = []
        XCTAssertEqual(ExpertCoachingReplyFile.read(StoredZipWriter.zip([(ExpertHandoverFile.manifestName,
                                                                           try JSONSerialization.data(withJSONObject: object))])).failureValue,
                       .badSteps)
        object["steps"] = (0...CoachingStep.maxSteps).map { ["id": "x\($0)", "instruction": "Step \($0)"] }
        XCTAssertEqual(ExpertCoachingReplyFile.read(StoredZipWriter.zip([(ExpertHandoverFile.manifestName,
                                                                           try JSONSerialization.data(withJSONObject: object))])).failureValue,
                       .badSteps)
        object["steps"] = [["id": "../x", "instruction": "Step"]]
        XCTAssertEqual(ExpertCoachingReplyFile.read(StoredZipWriter.zip([(ExpertHandoverFile.manifestName,
                                                                           try JSONSerialization.data(withJSONObject: object))])).failureValue,
                       .badSteps)
        XCTAssertEqual(ExpertCoachingReply.build(for: HeldHandover(handover: AssistingFixture.handover(), receivedAt: AssistingFixture.start),
                                                 steps: [], card: nil, now: AssistingFixture.start).failureValue, .noSteps)
    }

    func testStagingWritesTheFileOnlyForTheShareSheetAndOnlyACompletedShareMarksItSent() throws {
        let store = AssistingHandoverStore(directory: directory.appendingPathComponent("s"), now: { AssistingFixture.start })
        let assisting = service(store)
        assisting.open(AssistingFixture.opened(AssistingFixture.handover()))
        XCTAssertEqual(assisting.stageCoaching(for: "H-1").failureValue?.message, ExpertCoachingReply.Refusal.noSteps.message)
        for step in CoachingFixture.steps { assisting.saveCoachingStep(step, for: "H-1") }
        let staged = try assisting.stageCoaching(for: "H-1").get()
        XCTAssertEqual(try ExpertCoachingReplyFile.read(Data(contentsOf: staged.lease.fileURL)).get(), staged.reply)
        assisting.finishShare(staged, for: "H-1", completed: false)
        XCTAssertNil(store.handover(id: "H-1")?.coachingSentAt)
        let again = try assisting.stageCoaching(for: "H-1").get()
        assisting.finishShare(again, for: "H-1", completed: true)
        XCTAssertNotNil(store.handover(id: "H-1")?.coachingSentAt)
    }

    func testTheSubjectErasureReadsTheDraftsToo() {
        let store = AssistingHandoverStore(directory: directory.appendingPathComponent("e"), now: { AssistingFixture.start })
        store.open(AssistingFixture.opened(AssistingFixture.handover(conversation: false)))
        store.setCoachingDraft(id: "H-1", steps: [CoachingStep(instruction: "Ask Mrs Ngaio Tamatea where the drain runs.")])
        XCTAssertEqual(store.deleteMatching("Tamatea"), 1)
        XCTAssertNil(store.handover(id: "H-1"))
    }
}

// MARK: - The technician's side: accepted only for this phone's own open handover

@MainActor
class CoachingJobTestCase: XCTestCase {

    var tempRoot: URL!
    var service: FieldSessionService!
    var intake: ExpertReplyIntake!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = AssistingFixture.temporaryDirectory("coaching-job")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.coachingMedicalMode = { false }
        intake = ExpertReplyIntake()
        intake.sessions = service
        intake.now = { AssistingFixture.start }
        intake.medicalMode = { false }
        intake.coreFiles = { CoachingFixture.coreFiles }
        intake.organisationExperts = { [] }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// An open job that sent `handovers` to the expert they name.
    @discardableResult
    func openJob(sent handovers: [ExpertHandover] = [AssistingFixture.handover()],
                 kind: EscalationContact.Kind = .staff) throws -> FieldSession {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "4471")
        for handover in handovers {
            service.recordHandoverSent(
                AssistingFixture.sent(handover, expert: ExpertSnapshot(id: handover.expert.id, name: handover.expert.name, kind: kind)),
                sessionId: session.id)
        }
        return try XCTUnwrap(service.activeSession)
    }

    func reply(_ handovers: [ExpertHandover] = [AssistingFixture.handover()],
               steps: [CoachingStep] = CoachingFixture.steps) throws -> ExpertCoachingReply {
        try CoachingFixture.reply(for: handovers, steps: steps, directory: tempRoot)
    }

    /// Nothing of a refused reply is on the job, in the list, or startable.
    func assertNothingLoaded(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(service.activeSession?.expertCoaching, file: file, line: line)
        XCTAssertTrue(service.coachingOnJob.isEmpty, file: file, line: line)
        XCTAssertFalse(service.availableProcedures().contains { $0.hasPrefix(CoachingProcedure.idPrefix) }, file: file, line: line)
        XCTAssertThrowsError(try service.startProcedure(id: CoachingProcedure.procedureId(ordinal: 1)), file: file, line: line)
        XCTAssertNil(service.activeProcedureId, "nothing reached the procedure runner", file: file, line: line)
    }
}

@MainActor
final class CoachingIntakeTests: CoachingJobTestCase {

    func testCoachingThatAnswersTheOpenJobsHandoverIsLoadedCredited() throws {
        try openJob()
        let message = intake.receive(try reply())
        XCTAssertTrue(message.contains("Sam Ferreira (staff expert) sent 3 steps"), message)
        XCTAssertTrue(message.contains("walk Sam's steps"), message)
        let received = try XCTUnwrap(service.coachingOnJob.first)
        XCTAssertEqual(received.procedureId, "coaching-1")
        XCTAssertEqual(received.credit, "Sam Ferreira (staff expert)")
        XCTAssertEqual(received.steps.map(\.instruction), CoachingFixture.steps.map(\.instruction))
        XCTAssertTrue(service.availableProcedures().contains { $0.hasPrefix("coaching-1 — Coaching from Sam Ferreira (staff expert)") })

        // Once is once.
        XCTAssertEqual(intake.receive(try reply()), CoachingReplyMatch.Refusal.alreadyOnJob(procedureId: "coaching-1").message)
        XCTAssertEqual(service.coachingOnJob.count, 1)

        // The job's file keeps it, and an older job without it decodes unchanged.
        let session = try XCTUnwrap(service.activeSession)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(FieldSession.self, from: encoder.encode(session)).expertCoaching, session.expertCoaching)
    }

    func testAContractedExpertIsCreditedAsOne() throws {
        try openJob(kind: .contracted)
        _ = intake.receive(try reply())
        XCTAssertEqual(service.coachingOnJob.first?.credit, "Sam Ferreira (contracted expert)")
        XCTAssertEqual(CoachingProcedure.procedure(for: try XCTUnwrap(service.coachingOnJob.first)).title,
                       "Coaching from Sam Ferreira (contracted expert)")

        // The organisation's list saying contracted is enough, whatever the sent record says.
        let match = CoachingReplyMatch.match(
            try reply(), openJob: try XCTUnwrap(service.activeSession).withoutCoaching, otherJobs: [], lockedSessionIds: [],
            organisationExperts: [EscalationContact(id: "sam", name: "Sam Ferreira", phone: "+64 21 000 1111", kind: .contracted)],
            coreFiles: [], medicalMode: false, now: AssistingFixture.start)
        XCTAssertEqual(try match.get().received.expert.kind, .contracted)
    }

    func testAReplyWithAnUnknownHandoverIdIsNeverLoaded() throws {
        try openJob()
        let message = intake.receive(try reply([AssistingFixture.handover(id: "H-other")]))
        XCTAssertEqual(message, CoachingReplyMatch.Refusal.unknownHandover.message)
        XCTAssertTrue(message.contains("didn't ask for"))
        assertNothingLoaded()
    }

    func testAReplyFromAnotherSenderIsNeverLoaded() throws {
        try openJob()
        let message = intake.receive(try reply([AssistingFixture.handover(expertId: "priya", expertName: "Priya Lindqvist")]))
        XCTAssertEqual(message, CoachingReplyMatch.Refusal.otherSender.message)
        assertNothingLoaded()

        // An entry made from a card is answered only by that card.
        let card = ExpertCard(name: "Sam Ferreira", phone: "+64 21 000 1111", faceTimeHandle: nil,
                              handoverChannel: .messages, specialties: [], licences: [])
        let handover = AssistingFixture.handover(expertId: card.cardId)
        let job = try XCTUnwrap(service.activeSession)
        var cardJob = job
        cardJob.expertHandovers = [AssistingFixture.sent(handover)]
        let unsigned = try CoachingFixture.reply(for: [handover], directory: tempRoot)
        XCTAssertEqual(CoachingReplyMatch.match(unsigned, openJob: cardJob, otherJobs: [], lockedSessionIds: [],
                                                organisationExperts: [], coreFiles: [], medicalMode: false,
                                                now: AssistingFixture.start).failureValue, .cardMismatch)
    }

    func testAReplyClaimingAnUpdateNeverSentIsNeverLoaded() throws {
        try openJob(sent: [AssistingFixture.handover(generation: 1)])
        let message = intake.receive(try reply([AssistingFixture.handover(generation: 1), AssistingFixture.handover(generation: 2)]))
        XCTAssertEqual(message, CoachingReplyMatch.Refusal.generationNotSent.message)
        assertNothingLoaded()
    }

    func testAReplyForAClosedJobIsNeverLoaded() throws {
        try openJob()
        _ = try service.endSession(outcome: .resolved)
        XCTAssertNil(service.activeSession)
        XCTAssertEqual(intake.receive(try reply()), CoachingReplyMatch.Refusal.jobClosed.message)
        XCTAssertNil(service.history.first?.expertCoaching, "the closed job takes nothing")

        // A new job open on the phone takes nothing for the old one either.
        try openJob(sent: [])
        XCTAssertEqual(intake.receive(try reply()), CoachingReplyMatch.Refusal.jobClosed.message)
        assertNothingLoaded()
    }

    func testNoJobAtAllLoadsNothing() throws {
        XCTAssertEqual(intake.receive(try reply()), CoachingReplyMatch.Refusal.unknownHandover.message)
        XCTAssertTrue(service.coachingOnJob.isEmpty)
    }

    func testMedicalComplianceModeLoadsNothing() throws {
        try openJob()
        intake.medicalMode = { true }
        XCTAssertEqual(intake.receive(try reply()), CoachingReplyMatch.Refusal.medicalMode.message)
        assertNothingLoaded()

        // Loaded before the mode came on: it is not walked in it.
        intake.medicalMode = { false }
        _ = intake.receive(try reply())
        service.coachingMedicalMode = { true }
        XCTAssertThrowsError(try service.startProcedure(id: "coaching-1")) { error in
            guard case FieldSessionError.coachingInMedicalMode = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(service.activeProcedureId)
    }

    /// The refusal is structural: only the matcher makes the token the loader takes, only the loader
    /// and the job's own decoding write the job's coaching, and the reply file's type has no route
    /// to the runner, the tool or the job.
    func testOnlyTheMatcherMakesTheTokenAndOnlyTheLoaderWritesTheJob() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            var code = try String(contentsOf: url, encoding: .utf8)
            code = code.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
            if code.range(of: #"\bAcceptedCoaching\("#, options: .regularExpression) != nil {
                XCTAssertEqual(relative, "Services/FieldAssist/Experts/ExpertCoachingIntake.swift",
                               "\(relative) makes an AcceptedCoaching; only the matcher may")
            }
            if code.range(of: #"ExpertCoachingReceived\("#, options: .regularExpression) != nil {
                XCTAssertEqual(relative, "Services/FieldAssist/Experts/ExpertCoachingIntake.swift", relative)
            }
            if code.range(of: #"\.expertCoaching\s*=[^=]|\bexpertCoaching\s*=[^=]"#, options: .regularExpression) != nil {
                XCTAssertTrue(["Services/FieldAssist/FieldSession.swift", "Services/FieldAssist/FieldSessionService.swift"].contains(relative),
                              "\(relative) writes a job's coaching; only the loader may")
            }
            if ["Services/FieldAssist/FieldSessionService.swift", "Services/FieldAssist/ProcedureRunner.swift",
                "Services/NativeTools/ProcedureRunnerTool.swift", "Services/FieldAssist/WorkRecord.swift"].contains(relative) {
                XCTAssertNil(code.range(of: #"\bExpertCoachingReply\b"#, options: .regularExpression),
                             "\(relative) names the reply file's type; only an accepted reply reaches the job")
            }
        }
    }
}

private extension FieldSession {
    var withoutCoaching: FieldSession {
        var copy = self
        copy.expertCoaching = nil
        return copy
    }
}

// MARK: - The walkthrough: as written, safety first, readings against each step

@MainActor
final class CoachingWalkthroughTests: CoachingJobTestCase {

    private func loadAndStart() throws -> Procedure.Step {
        try openJob()
        _ = intake.receive(try reply())
        return try service.startProcedure(id: "coaching-1")
    }

    func testAStepThatHitsTheSafetyFileIsReadWithItsRuleFirstAndFlagged() throws {
        // The matcher, step by step.
        let gas = try XCTUnwrap(CoachingSafety.assess(CoachingFixture.steps[2], coreFiles: CoachingFixture.coreFiles))
        XCTAssertEqual(gas.file, "safety.md")
        XCTAssertTrue(gas.terms.contains("gas"))
        XCTAssertEqual(gas.rule, "Gas isolation: Shut the supply at the appliance valve and check for leaks before any gas train is opened.")
        XCTAssertNil(CoachingSafety.assess(CoachingFixture.steps[0], coreFiles: CoachingFixture.coreFiles))
        // A hazard word no section names still flags, with the standing rule.
        let jumper = try XCTUnwrap(CoachingSafety.assess(CoachingStep(instruction: "Fit a jumper across the limit for a minute."),
                                                         coreFiles: CoachingFixture.coreFiles))
        XCTAssertNil(jumper.file)
        XCTAssertTrue(jumper.rule.contains("no coaching step overrides one"), jumper.rule)

        _ = try loadAndStart()
        let received = try XCTUnwrap(service.coachingOnJob.first)
        XCTAssertEqual(received.flaggedSteps.map(\.number), [3])
        let procedure = CoachingProcedure.procedure(for: received)
        let gasStep = try XCTUnwrap(procedure.step(id: "step-3"))
        XCTAssertEqual(gasStep.safetyNote, gas.rule)
        XCTAssertEqual(gasStep.instruction, CoachingFixture.gasStep, "the step is never rewritten around its rule")

        // Read with the rule first: in the lines the model is given, and in the runner's prompt.
        let lines = CoachingProcedure.stepLines(gasStep)
        let ruleLine = try XCTUnwrap(lines.firstIndex { $0.contains(gas.rule) })
        let stepLine = try XCTUnwrap(lines.firstIndex { $0.contains(CoachingFixture.gasStep) })
        XCTAssertLessThan(ruleLine, stepLine)
        _ = try service.advanceProcedure(choice: "continue")
        _ = try service.advanceProcedure(choice: nil)
        XCTAssertEqual(service.activeProcedureStep?.id, "step-3")
        let runnerPrompt = try XCTUnwrap(promptOfRunner())
        let ruleAt = try XCTUnwrap(runnerPrompt.range(of: gas.rule)).lowerBound
        let stepAt = try XCTUnwrap(runnerPrompt.range(of: CoachingFixture.gasStep)).lowerBound
        XCTAssertLessThan(ruleAt, stepAt)
        XCTAssertTrue(runnerPrompt.contains("never overrides a safety rule"))

        // Flagged on the record.
        let record = WorkRecord(session: try XCTUnwrap(service.activeSession), vaultName: "Refrigeration")
        let walkthrough = try XCTUnwrap(record.coachingWalkthroughs?.first)
        XCTAssertEqual(walkthrough.steps.filter(\.safetyFlagged).map(\.number), [3])
        XCTAssertTrue(record.summaryLines.contains { $0.contains("Safety rule read first") && $0.contains(gas.rule) })
    }

    func testTheStepsAreReadAsWritten() async throws {
        let entry = try loadAndStart()
        let received = try XCTUnwrap(service.coachingOnJob.first)
        let procedure = CoachingProcedure.procedure(for: received)
        XCTAssertTrue(CoachingProcedure.isVerbatim(procedure, received))
        for (built, step) in zip(procedure.steps, CoachingFixture.steps) {
            XCTAssertEqual(CoachingProcedure.spokenInstruction(built), step.instruction)
        }
        XCTAssertEqual(entry.instruction, CoachingFixture.hoseStep)

        // A procedure whose step no longer says what the expert wrote is not as written.
        let reworded = Procedure(id: procedure.id, title: procedure.title, version: "1",
                                 steps: procedure.steps.map { step in
                                     step.id == "step-1"
                                         ? Procedure.Step(id: step.id, title: step.title, instruction: "Check the hose.",
                                                          branches: step.branches, defaultNext: step.defaultNext)
                                         : step
                                 })
        XCTAssertFalse(CoachingProcedure.isVerbatim(reworded, received))

        // What the model is given carries the step exactly, with the instruction to keep it so.
        let prompt = try XCTUnwrap(promptOfRunner())
        XCTAssertTrue(prompt.contains("Read exactly as written: \(CoachingFixture.hoseStep)"), prompt)
        XCTAssertTrue(prompt.contains("never reworded"))
        XCTAssertTrue(prompt.contains("Sam Ferreira (staff expert)"))

        // And so does the tool's answer.
        let tool = ProcedureRunnerTool(sessionService: service)
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(status.contains("Read exactly as written: \(CoachingFixture.hoseStep)"), status)
        let next = try await tool.execute(args: ["action": "next", "choice": "continue"])
        XCTAssertTrue(next.contains("Read exactly as written: \(CoachingFixture.readStep)"), next)
        XCTAssertTrue(next.contains("Reading to take: switch pressure, in inWC"), next)
    }

    func testAStopIfEndsTheWalkthroughAndSaysToCallBack() throws {
        _ = try loadAndStart()
        guard case .arrivedAtTerminal(let stop) = try service.advanceProcedure(choice: "stop") else {
            return XCTFail("the stop-if leads to the stop step")
        }
        XCTAssertTrue(stop.instruction.contains("Call Sam back"))
        _ = try service.completeProcedure(outcome: "escalated")
        let record = WorkRecord(session: try XCTUnwrap(service.activeSession), vaultName: "Refrigeration")
        XCTAssertEqual(record.coachingWalkthroughs?.first?.status, "escalated")
        XCTAssertTrue(record.summaryLines.contains("Coaching steps from Sam Ferreira (staff expert), read as written — finished as escalated."))
    }

    func testReadingsAreRecordedAgainstTheirSteps() throws {
        _ = try loadAndStart()
        let first = try XCTUnwrap(service.recordReading(quantity: "hose", value: "dry", unit: nil))
        XCTAssertEqual(first.procedureId, "coaching-1")
        XCTAssertEqual(first.procedureStepId, "step-1")
        _ = try service.advanceProcedure(choice: "continue")
        let second = try XCTUnwrap(service.recordReading(quantity: "switch pressure", value: "0.28", unit: "inWC"))
        XCTAssertEqual(second.procedureStepId, "step-2")
        let corrected = try XCTUnwrap(service.correctReading(value: "0.31", unit: nil))
        XCTAssertEqual(corrected.procedureStepId, "step-2", "a correction stays on the step it corrects")
        _ = try service.advanceProcedure(choice: nil)
        _ = try service.advanceProcedure(choice: nil)
        _ = try service.completeProcedure(outcome: "resolved")
        let outside = try XCTUnwrap(service.recordReading(quantity: "supply air", value: "120", unit: "°F"))
        XCTAssertNil(outside.procedureId, "with nothing running, a reading stores what it always did")

        let record = WorkRecord(session: try XCTUnwrap(service.activeSession), vaultName: "Refrigeration")
        let walkthrough = try XCTUnwrap(record.coachingWalkthroughs?.first)
        XCTAssertEqual(walkthrough.status, "resolved")
        XCTAssertEqual(walkthrough.credit, "Sam Ferreira (staff expert)")
        XCTAssertEqual(walkthrough.steps.map(\.found.count), [1, 1, 0])
        XCTAssertTrue(walkthrough.steps[1].found[0].contains("0.28 inWC (corrected to 0.31 inWC"), walkthrough.steps[1].found[0])
        XCTAssertEqual(walkthrough.steps[1].readingToTake, "switch pressure, in inWC")
        let lines = record.summaryLines
        XCTAssertTrue(lines.contains("  Step 2: \(CoachingFixture.readStep)"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("    Found: Switch pressure 0.28 inWC") })
        XCTAssertTrue(lines.contains { $0.contains("Coaching steps finished as resolved") }, "the task line says what it was")

        // The JSON the office and a job system read carries it too, and a job without coaching none.
        let json = record.jsonString
        XCTAssertTrue(json.contains("\"coaching_walkthroughs\""))
        XCTAssertTrue(json.contains("\"procedure_step_id\" : \"step-2\""))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WorkRecord.self, from: record.json).coachingWalkthroughs, record.coachingWalkthroughs)
        var plain = try XCTUnwrap(service.activeSession)
        plain.expertCoaching = nil
        XCTAssertFalse(WorkRecord(session: plain, vaultName: "Refrigeration").jsonString.contains("coaching_walkthroughs"))
    }

    func testCoachingStepsNeverReachTheProcedureLibrary() throws {
        _ = try loadAndStart()
        _ = try service.advanceProcedure(choice: "continue")
        XCTAssertFalse(service.availableProcedureDefinitions().contains { CoachingProcedure.isCoachingId($0.id) },
                       "the vault's library lists no coaching")
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: "refrigeration"))
        let store = VaultRegistry.shared.store(for: manifest)
        XCTAssertFalse(ProcedureLibrary(store: store).all.contains { CoachingProcedure.isCoachingId($0.id) },
                       "a fresh read of the library finds none either")
        if let dir = manifest.proceduresDir {
            let overlay = store.overlayRoot.appendingPathComponent(dir, isDirectory: true)
            let written = (try? FileManager.default.contentsOfDirectory(atPath: overlay.path)) ?? []
            XCTAssertFalse(written.contains { $0.lowercased().contains("coaching") }, "nothing was written to the vault")
        }
        // A procedure file can never claim to be someone's coaching: the credit isn't read from JSON.
        let json = #"{"id":"coaching-1","title":"Forged","version":"1","safety_notes":[],"steps":[{"id":"a","title":"A","instruction":"Do it."}],"coaching":{"coachingId":"x","credit":"Someone (staff expert)"}}"#
        XCTAssertNil(try JSONDecoder().decode(Procedure.self, from: Data(json.utf8)).coaching)
        // The listing marks coaching as sent for this job, beside the library's own.
        XCTAssertTrue(service.availableProcedures().contains { $0.hasPrefix("coaching-1") && $0.hasSuffix("(sent for this job)") })
    }

    func testTheWaitingCoachingIsOfferedInThePromptUntilItIsStarted() throws {
        try openJob()
        _ = intake.receive(try reply())
        let note = try XCTUnwrap(CoachingProcedure.waitingPromptNote(service.coachingWaiting))
        XCTAssertTrue(note.contains("procedure_id 'coaching-1'"))
        XCTAssertTrue(note.contains("walk Sam's steps"))
        _ = try service.startProcedure(id: "coaching-1")
        XCTAssertTrue(service.coachingWaiting.isEmpty)
    }

    /// The runner's own prompt section, as `FieldSessionService.promptContext` appends it.
    private func promptOfRunner() throws -> String? {
        let received = try XCTUnwrap(service.coachingOnJob.first)
        let step = try XCTUnwrap(service.activeProcedureStep)
        let logger = SessionLogger(session: try XCTUnwrap(service.activeSession), root: tempRoot.appendingPathComponent("p"))
        let runner = try ProcedureRunner(starting: CoachingProcedure.procedure(for: received), logger: logger)
        // Walk a scratch runner to the same step.
        while runner.currentStepId != step.id {
            _ = try runner.advance(choice: runner.currentStep?.branches.isEmpty == false ? "continue" : nil)
        }
        return runner.promptContext()
    }
}

// MARK: - The team's: offered for staff, never for contracted unless the organisation says

@MainActor
final class CoachingTeamLearningTests: CoachingJobTestCase {

    private var candidates: LearningCandidateService!

    override func setUp() {
        super.setUp()
        candidates = LearningCandidateService(store: LearningCandidateStore(directory: tempRoot.appendingPathComponent("candidates", isDirectory: true)),
                                              sessions: service)
        candidates.capability = { .granted }
        candidates.authorName = { "Technician" }
        candidates.organisationExperts = { [] }
    }

    private func contracted(flag: Bool) -> EscalationContact {
        EscalationContact(id: "sam", name: "Sam Ferreira", phone: "+64 21 000 1111", kind: .contracted,
                          rate: .init(perHour: 90, minimumMinutes: 15, roundingMinutes: 15, currency: "NZD"),
                          coachingMayBecomeTeamLearning: flag)
    }

    func testAStaffExpertsStepsAreOfferedThroughTheReviewCreditedToThem() throws {
        try openJob()
        _ = intake.receive(try reply())
        let received = try XCTUnwrap(service.coachingOnJob.first)
        XCTAssertEqual(CoachingTeamLearning.decide(received, organisationExperts: []), .offered)
        let candidate = try candidates.offerCoaching(coachingId: received.coachingId).get()
        XCTAssertEqual(candidate.status, .filed, "a candidate for review, never an approved entry")
        XCTAssertTrue(candidate.finding.contains("Sam Ferreira (staff expert)"))
        XCTAssertTrue(candidate.finding.contains("Credit: Sam Ferreira"))
        XCTAssertTrue(candidate.finding.contains("1. \(CoachingFixture.hoseStep)"))
        XCTAssertTrue(candidate.finding.contains("(Touches the safety rules.)"))
        XCTAssertNotNil(service.coachingOnJob.first?.offeredAsTeamLearningAt)
        XCTAssertEqual(candidates.offerCoaching(coachingId: received.coachingId).failureValue,
                       .coachingNotOffered(CoachingTeamLearning.alreadyOffered))
        XCTAssertFalse(service.availableProcedureDefinitions().contains { CoachingProcedure.isCoachingId($0.id) },
                       "offering is not adding to the library")
    }

    func testAContractedExpertsStepsAreNotOfferedUnlessTheOrganisationTurnedItOn() throws {
        try openJob(kind: .contracted)
        _ = intake.receive(try reply())
        let received = try XCTUnwrap(service.coachingOnJob.first)
        XCTAssertEqual(CoachingTeamLearning.decide(received, organisationExperts: []),
                       .notOffered(CoachingTeamLearning.contractedReason))
        XCTAssertEqual(CoachingTeamLearning.decide(received, organisationExperts: [contracted(flag: false)]),
                       .notOffered(CoachingTeamLearning.contractedReason))
        candidates.organisationExperts = { [self.contracted(flag: false)] }
        XCTAssertEqual(candidates.offerCoaching(coachingId: received.coachingId).failureValue,
                       .coachingNotOffered(CoachingTeamLearning.contractedReason))
        XCTAssertNil(service.coachingOnJob.first?.offeredAsTeamLearningAt)

        // The organisation turned it on for this expert.
        XCTAssertEqual(CoachingTeamLearning.decide(received, organisationExperts: [contracted(flag: true)]), .offered)
        candidates.organisationExperts = { [self.contracted(flag: true)] }
        XCTAssertNoThrow(try candidates.offerCoaching(coachingId: received.coachingId).get())

        // A staff expert who is contracted on the organisation's list now is not offered.
        _ = try? service.endSession(outcome: .resolved)
        try openJob(kind: .staff)
        _ = intake.receive(try reply())
        let staffNow = try XCTUnwrap(service.coachingOnJob.first)
        XCTAssertEqual(CoachingTeamLearning.decide(staffNow, organisationExperts: [contracted(flag: false)]),
                       .notOffered(CoachingTeamLearning.contractedReason))
    }

    func testOnlyTheOrganisationCanSetTheFlagAndAPersonalAdditionCannotCarryIt() throws {
        // A staff entry never carries it, by init or by decoding.
        XCTAssertFalse(EscalationContact(id: "a", name: "Sam Ferreira", phone: "+15550100", kind: .staff,
                                         coachingMayBecomeTeamLearning: true).coachingMayBecomeTeamLearning)
        let staffJSON = #"[{"id":"a","name":"Sam Ferreira","phone":"+15550100","kind":"staff","coachingToTeam":true}]"#
        XCTAssertEqual(try ExpertListCodec.decode(staffJSON).get().first?.coachingMayBecomeTeamLearning, false)
        // Off by default, and on only where the organisation's list says so.
        let off = #"[{"id":"b","name":"Priya Lindqvist","phone":"+15550101","kind":"contracted"}]"#
        XCTAssertEqual(try ExpertListCodec.decode(off).get().first?.coachingMayBecomeTeamLearning, false)
        let on = #"[{"id":"b","name":"Priya Lindqvist","phone":"+15550101","kind":"contracted","coachingToTeam":true}]"#
        let listed = try XCTUnwrap(try ExpertListCodec.decode(on).get().first)
        XCTAssertTrue(listed.coachingMayBecomeTeamLearning)
        XCTAssertTrue(ExpertListCodec.encode([listed]).contains("\"coachingToTeam\":true"))
        XCTAssertFalse(ExpertListCodec.encode([contracted(flag: false)]).contains("coachingToTeam"), "absent when off")

        // A personal addition has no such field at all…
        let labels = Set(Mirror(reflecting: PersonalExpert(name: "Lee Moreno", phone: "+15550102")).children.compactMap(\.label))
        XCTAssertFalse(labels.contains("coachingMayBecomeTeamLearning"))
        // …so a stored payload that tries decodes without it, and the entry can't offer contracted steps.
        let suite = "coaching-personal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tampered = #"[{"id":"p1","name":"Lee Moreno","phone":"+15550102","specialties":[],"kind":"contracted","coachingToTeam":true}]"#
        defaults.set(Data(tampered.utf8), forKey: ExpertListStore.personalKey)
        let store = ExpertListStore(defaults: defaults, profileList: { nil })
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.source, .personal)
        XCTAssertFalse(entry.contact.coachingMayBecomeTeamLearning)
        XCTAssertTrue(store.organizationExperts.isEmpty, "decision 10 reads the organisation's list, which this is not")

        // A refreshed card keeps the organisation's own setting.
        let card = ExpertCard(name: "Priya Lindqvist", phone: "+15550103", faceTimeHandle: nil, handoverChannel: .messages,
                              specialties: [], licences: [])
        var owner = ExpertCardImport.ownerEntry(card)
        owner = EscalationContact(id: owner.id, name: owner.name, phone: owner.phone, kind: .contracted,
                                  coachingMayBecomeTeamLearning: true)
        XCTAssertNil(store.setDeviceOwnerExperts([owner]))
        XCTAssertEqual(ExpertCardImport.apply(card, to: store), .updated(.organisation))
        XCTAssertEqual(store.deviceOwnerExperts.first?.coachingMayBecomeTeamLearning, true)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
