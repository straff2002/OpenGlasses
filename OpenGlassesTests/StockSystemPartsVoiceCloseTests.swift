import XCTest
@testable import OpenGlasses

/// Plan MM P4 — the voice close with parts waiting for a business's own system: the close is held,
/// the app puts its own question at the end of the turn, the person's plain yes or no is taken
/// before the model hears it, and the close then finishes. A real `FieldSessionService` and
/// `ConversationStore` on temp directories, as `GuidedJobFlowTests` uses.
@MainActor
final class StockSystemPartsVoiceCloseTests: XCTestCase {

    private var sessionsRoot: URL!
    private var storeDirectory: URL!
    private var service: FieldSessionService!
    private var store: ConversationStore!
    private var flow: GuidedJobFlow!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    private var spoken: [String] = []
    private var question: String? = "Two parts used on this job: one Run capacitor 45/5, half a litre of Coolant. Send them to Square?"
    private var answers: [StockUseConfirmation?] = []
    private var settled: [String] = []

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        sessionsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PartsVoice-sessions-\(unique)")
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PartsVoice-store-\(unique)")
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        service = FieldSessionService(sessionsRoot: sessionsRoot)
        store = ConversationStore(directory: storeDirectory)
        flow = GuidedJobFlow(sessions: service, store: store, seams: .init(
            speak: { [weak self] line in self?.spoken.append(line) },
            partsQuestion: { [weak self] _ in self?.question },
            answerParts: { [weak self] _, confirmation in
                self?.answers.append(confirmation)
                self?.question = nil
                return confirmation == nil ? "Kept on the job, not sent to Square." : "Sending two parts to Square."
            },
            settlePartsAtClose: { [weak self] id in self?.settled.append(id) }))
    }

    override func tearDown() {
        flow = nil
        service = nil
        store = nil
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try? FileManager.default.removeItem(at: sessionsRoot)
        try? FileManager.default.removeItem(at: storeDirectory)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func startAndHold() throws -> String {
        let session = try flow.startJob(vaultId: "refrigeration", jobReference: "1027")
        XCTAssertThrowsError(try flow.closeJob(outcome: .resolved, route: .voice)) { error in
            guard case FieldSessionError.jobCloseHeld(let held) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(held, JobCloseSequence.partsHeld, "the model is told to stand back")
        }
        XCTAssertNotNil(service.activeSession, "not closed until the person answers")
        XCTAssertEqual(flow.pendingPartsSend?.asked, false)
        return session.id
    }

    func testAYesIsThePersonsConfirmationAndTheCloseFinishes() async throws {
        let id = try startAndHold()
        // A "yes" before the question is put answers nothing.
        let early = await flow.handleUtterance("yes")
        XCTAssertFalse(early)
        XCTAssertTrue(answers.isEmpty)

        let asked = await flow.speakPendingQuestionIfDue()
        XCTAssertTrue(asked)
        XCTAssertEqual(spoken.last, question)
        // Something that is not an answer reaches the model, with the question still open.
        let other = await flow.handleUtterance("what's the superheat on this one?")
        XCTAssertFalse(other)
        XCTAssertNotNil(flow.pendingPartsSend)

        let consumed = await flow.handleUtterance("yes please")
        XCTAssertTrue(consumed)
        XCTAssertEqual(answers, [.person(.voice)])
        XCTAssertNil(service.activeSession, "the close the person asked for finished")
        XCTAssertEqual(settled, [id], "the record is settled as the job ends")
        XCTAssertEqual(spoken.last, "Sending two parts to Square. The job is closed.")
        XCTAssertNil(flow.pendingPartsSend)
    }

    func testANoKeepsThemAndTheCloseFinishes() async throws {
        _ = try startAndHold()
        _ = await flow.speakPendingQuestionIfDue()
        let consumed = await flow.handleUtterance("no")
        XCTAssertTrue(consumed)
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers.first ?? nil, "a no is no confirmation")
        XCTAssertNil(service.activeSession)
        XCTAssertEqual(spoken.last, "Kept on the job, not sent to Square. The job is closed.")
    }

    func testAskedOnceAndNotAnsweredTheyStayOnTheJobUnsent() async throws {
        _ = try startAndHold()
        _ = await flow.speakPendingQuestionIfDue()
        // The person talked about something else, and the model closes again.
        let closed = try flow.closeJob(outcome: .resolved, route: .voice)
        XCTAssertNotNil(closed.endedAt)
        XCTAssertTrue(answers.isEmpty, "nothing was confirmed, so nothing is sent")
    }

    func testTheScreensCloseIsNotHeldAndNothingIsAskedWithNoQuestion() throws {
        _ = try flow.startJob(vaultId: "refrigeration", jobReference: "1028")
        _ = try flow.closeJob(outcome: .resolved, route: .screen)
        XCTAssertNil(flow.pendingPartsSend)
        question = nil
        _ = try flow.startJob(vaultId: "refrigeration", jobReference: "1029")
        _ = try flow.closeJob(outcome: .resolved, route: .voice)
        XCTAssertTrue(answers.isEmpty)
        XCTAssertEqual(settled.count, 2)
    }

    func testTheSequenceHoldsOnlyTheVoiceClose() {
        var inputs = JobCloseSequence.Inputs(requestedOutcome: .resolved, openVerifications: [], evidenceCount: 0,
                                             evidenceDecided: true, signOff: .allowed, route: .voice)
        inputs.partsToSend = "Two parts…"
        XCTAssertEqual(JobCloseSequence.decide(inputs), .ask(JobCloseSequence.partsHeld))
        inputs.unrecordedVanParts = "Igniter (22B22)"
        guard case .ask(let first) = JobCloseSequence.decide(inputs) else { return XCTFail() }
        XCTAssertNotEqual(first, JobCloseSequence.partsHeld, "parts on finished tasks are asked about first")
        inputs.unrecordedVanParts = ""
        inputs.route = .screen
        XCTAssertEqual(JobCloseSequence.decide(inputs), .proceed(outcome: .resolved))
        XCTAssertFalse(JobCloseSequence.partsHeld.lowercased().contains("square"))
    }

    func testANotedPartIsAccountedForAtTheClose() {
        let part = TaskPart(number: "ZX-455", partDescription: "Run capacitor", verified: true)
        XCTAssertEqual(VanStockReconciler.unrecorded(partsUsed: [part], uses: [], notFromVan: [], noted: [" zx-455 "]), [])
        XCTAssertEqual(VanStockReconciler.unrecorded(partsUsed: [part], uses: [], notFromVan: [], noted: []).count, 1)
    }
}
