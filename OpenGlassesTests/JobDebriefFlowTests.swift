import PDFKit
import XCTest
@testable import OpenGlasses

/// The debrief against real services (Plan FO P3b): a real `FieldSessionService` on a temp
/// sessions root, a real `ConversationStore` on a temp directory, and the guided flow's own
/// chokepoint. Only speech, the model's history and the model call itself are seams.
///
/// What these are for is the promise the whole phase turns on: **a debrief adds an account and
/// changes nothing else**. Time on the job, the tasks, the equipment and whatever a customer
/// signed are all compared before and after.
@MainActor
final class JobDebriefFlowTests: XCTestCase {

    private var sessionsRoot: URL!
    private var storeDirectory: URL!
    private var service: FieldSessionService!
    private var store: ConversationStore!
    private var flow: GuidedJobFlow!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    private var spoken: [String] = []
    /// What the model would answer, keyed in order of the calls made.
    private var summaries: [[String: Any]?] = []
    private var summaryCalls: [(system: String, user: String)] = []

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Debrief-sessions-\(unique)", isDirectory: true)
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Debrief-store-\(unique)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()

        service = FieldSessionService(sessionsRoot: sessionsRoot)
        store = ConversationStore(directory: storeDirectory)
        flow = makeFlow()
    }

    override func tearDown() {
        LLMService.debriefContext = { nil }
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

    private func makeFlow() -> GuidedJobFlow {
        GuidedJobFlow(sessions: service, store: store, seams: .init(
            speak: { [weak self] line in self?.spoken.append(line) },
            loadHistory: { _ in },
            clearHistory: {},
            threadMode: { AppMode.direct.rawValue },
            personaId: { nil },
            persistenceEnabled: { true },
            summarise: { [weak self] system, user, _ in
                guard let self else { return nil }
                self.summaryCalls.append((system, user))
                return self.summaries.isEmpty ? nil : self.summaries.removeFirst()
            },
            provenance: {
                AIProvenance(modelIdentifier: "test-model", providerClass: .cloud,
                             promptVersionDigest: "sha256:test")
            }))
    }

    /// One finished job, with a task, a signature and some time on it.
    @discardableResult
    private func finishedJob(reference: String, note: String = "New trap fitted and tested.")
        throws -> FieldSession {
        _ = try flow.startJob(vaultId: "refrigeration", jobReference: reference)
        let task = try XCTUnwrap(try service.addOperatorTask(title: "Replaced the condensate trap",
                                                             why: "Blocked"))
        _ = try service.completeTask(id: task.id, note: note)
        if let record = service.workRecord() {
            service.recordSignOff(CustomerSignOff(customerName: "Dana Okafor", method: .typed,
                                                  summaryLines: record.customerSummaryLines))
        }
        return try flow.closeJob(outcome: .resolved)
    }

    /// A debrief turn as it arrives from the microphone.
    private func say(_ text: String) async {
        let consumed = await flow.handleUtterance(text)
        if !consumed, flow.debrief?.state.isListening == true {
            // The ordinary path: an account line reaches the model *and* the job's conversation.
            flow.prepareThreadForDebriefTurn()
            if store.activeThreadId != nil { store.appendMessage(role: "user", content: text) }
        }
    }

    private func summaryJSON(_ text: String, turn: String,
                             category: String = "findings") -> [String: Any] {
        [category: [["text": text, "source_turn_ids": [turn]]]]
    }

    // MARK: - A debrief lands on its own job, and writes nothing until a save

    func testTheTurnsLandInTheJobsThreadAndNothingReachesTheRecordUntilSave() async throws {
        let job = try finishedJob(reference: "1004")
        let started = await flow.startDebrief(jobId: job.id)
        XCTAssertTrue(started)

        await say("the drier looked wet")
        await say("base should send somebody back")

        let debrief = try XCTUnwrap(flow.debrief)
        XCTAssertEqual(debrief.turns.count, 2)
        XCTAssertTrue(service.debriefs(sessionId: job.id).isEmpty,
                      "nothing is on the record while the debrief is only being said")

        // The turns are in a conversation, and it is the one bound to *this* job.
        let threadId = try XCTUnwrap(flow.debrief?.threadId)
        XCTAssertEqual(service.history.first { $0.id == job.id }?.conversationThreadId, threadId)
        let messages = store.threads.first { $0.id == threadId }?.messages ?? []
        XCTAssertTrue(messages.contains { $0.content == "the drier looked wet" })

        summaries = [summaryJSON("Drier looks wet", turn: debrief.turns[0].id)]
        await say("that's it")
        await say("save it")

        let saved = service.debriefs(sessionId: job.id)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.entries.first?.text, "Drier looks wet")
        XCTAssertEqual(saved.first?.provenance?.modelIdentifier, "test-model")
        XCTAssertEqual(saved.first?.threadId, threadId)
    }

    func testScrappingADebriefLeavesTheRecordUntouchedAndTheTurnsInPlace() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("compressor sounded rough")

        let turnCount = flow.debrief?.turns.count ?? 0
        summaries = [summaryJSON("Compressor sounded rough", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("scrap it")

        XCTAssertTrue(service.debriefs(sessionId: job.id).isEmpty)
        XCTAssertEqual(turnCount, 1, "what was said is still what was said")
        let events = SessionLogger.readEvents(
            at: sessionsRoot.appendingPathComponent(job.id, isDirectory: true))
        XCTAssertTrue(events.contains { $0.kind == .debriefDiscarded })
        XCTAssertFalse(events.contains { $0.kind == .debriefSaved })
    }

    /// The invariant §6 names first: a debrief is not a re-opening of the job.
    func testSavingADebriefChangesNothingElseOnTheRecord() async throws {
        let job = try finishedJob(reference: "1004")
        let before = try XCTUnwrap(service.history.first { $0.id == job.id })

        _ = await flow.startDebrief(jobId: job.id)
        await say("I'd flag the drier for next time")
        summaries = [summaryJSON("Flag the drier for next time", turn: "\(flow.debrief!.id)-t1",
                                 category: "follow_ups")]
        await say("that's it")
        await say("save it")

        let after = try XCTUnwrap(service.history.first { $0.id == job.id })
        XCTAssertEqual(after.billableSeconds, before.billableSeconds, "time on the job cannot restart")
        XCTAssertEqual(after.tasks, before.tasks, "a debrief does not re-scope the work")
        XCTAssertEqual(after.equipment, before.equipment)
        XCTAssertEqual(after.endedAt, before.endedAt)
        XCTAssertEqual(after.signOff?.summaryDigest, before.signOff?.summaryDigest,
                       "what the customer put their name to is frozen at the moment of signing")
        XCTAssertEqual(after.signOff?.summaryLines, before.signOff?.summaryLines)
        XCTAssertEqual(after.debriefs.count, 1, "the one thing that changed")
    }

    // MARK: - Several jobs on one journey

    func testTwoDebriefsOnOneJourneyEachLandOnTheirOwnJob() async throws {
        let first = try finishedJob(reference: "1004", note: "Trap replaced.")
        let second = try finishedJob(reference: "1005", note: "Sensor cleaned.")

        _ = await flow.startDebrief(jobId: first.id)
        await say("the trap was solid")
        summaries = [summaryJSON("The trap was solid", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")

        // …then by voice, mid-drive.
        await say("next job")
        XCTAssertEqual(flow.debrief?.sessionId, first.id,
                       "\"next\" from the newest job walks backwards in time")

        _ = await flow.switchDebrief(to: "debrief job 1005")
        XCTAssertEqual(flow.debrief?.sessionId, second.id)
        await say("the sensor was filthy")
        summaries = [summaryJSON("The sensor was filthy", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")

        XCTAssertEqual(service.debriefs(sessionId: first.id).count, 1)
        XCTAssertEqual(service.debriefs(sessionId: second.id).count, 1)
        XCTAssertEqual(service.debriefs(sessionId: first.id).first?.entries.first?.text,
                       "The trap was solid")
        XCTAssertEqual(service.debriefs(sessionId: second.id).first?.entries.first?.text,
                       "The sensor was filthy",
                       "nothing said about one job may land on another")
    }

    func testTheAppNamesTheJobOnEverySwitch() async throws {
        _ = try finishedJob(reference: "1004")
        let second = try finishedJob(reference: "1005")
        spoken.removeAll()

        _ = await flow.startDebrief(jobId: second.id)
        XCTAssertTrue(spoken.first?.contains("Job 1005") == true, spoken.description)

        _ = await flow.switchDebrief(to: "debrief job 1004")
        XCTAssertTrue(spoken.last?.contains("Job 1004") == true, spoken.description)
    }

    func testAnAmbiguousJobIsAskedAboutRatherThanGuessed() async throws {
        _ = try finishedJob(reference: "1004")
        _ = try finishedJob(reference: "1004")
        spoken.removeAll()

        let resolution = await flow.switchDebrief(to: "debrief job 1004")
        guard case .ambiguous = resolution else {
            return XCTFail("two jobs numbered 1004 must produce a question")
        }
        XCTAssertNil(flow.debrief, "nothing is opened on a guess")
        XCTAssertTrue(spoken.last?.lowercased().contains("which one") == true, spoken.description)
    }

    // MARK: - When the model cannot be asked

    func testAFailedSummaryOffersTheRawAccountAndLabelsIt() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("the fan was wobbling badly")

        summaries = [nil]           // the model call fails
        await say("that's it")
        guard case .failed = flow.debrief?.state else {
            return XCTFail("a failed summary is its own state, not a silent save")
        }
        XCTAssertTrue(service.debriefs(sessionId: job.id).isEmpty)

        await say("keep what i said")
        let saved = try XCTUnwrap(service.debriefs(sessionId: job.id).first)
        XCTAssertTrue(saved.unsummarised)
        XCTAssertTrue(saved.entries.isEmpty)
        XCTAssertEqual(saved.turns.first?.text, "the fan was wobbling badly")
        XCTAssertEqual(saved.summaryLines.first, JobDebrief.unsummarisedNote)
    }

    func testASummaryCitingATurnThatNeverHappenedIsRefused() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("the drier looked wet")

        summaries = [summaryJSON("Drier looks wet", turn: "made-up-turn")]
        await say("that's it")
        guard case .failed = flow.debrief?.state else {
            return XCTFail("a summary that does not line up with what was said must be thrown away")
        }
        XCTAssertTrue(service.debriefs(sessionId: job.id).isEmpty)
    }

    func testTheModelIsToldWhichJobAndWhatItMayNotDo() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        let block = try XCTUnwrap(flow.debriefBlock())
        XCTAssertTrue(block.contains("Job 1004"))
        XCTAssertTrue(block.contains("Replaced the condensate trap"),
                      "the model is told what the job already recorded")
        XCTAssertTrue(block.contains("Time on the job does not restart"))
        XCTAssertTrue(block.contains("CUSTOMER SIGN-OFF"))

        await say("something")
        summaries = [summaryJSON("Something", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        let call = try XCTUnwrap(summaryCalls.last)
        XCTAssertTrue(call.user.contains("[\(flow.debrief!.turns[0].id)]"),
                      "the model is handed the turn ids it must cite")
        XCTAssertTrue(call.system.contains("must cite"))
    }

    // MARK: - The block reaches the model in every mode

    /// Direct mode: the system prompt carries the block while the debrief runs — on a finished
    /// job, with no session open — and drops it once the debrief is saved.
    func testADebriefInProgressIsInTheDirectModePromptUntilItIsSaved() async throws {
        LLMService.debriefContext = { [weak self] in self?.flow?.debriefBlock() }
        let job = try finishedJob(reference: "1004")
        XCTAssertNil(service.activeSession, "a debrief is on a finished job, with nothing open")

        var prompt = await directPrompt()
        XCTAssertFalse(prompt.contains(DebriefContract.heading), "no debrief, no block")

        _ = await flow.startDebrief(jobId: job.id)
        prompt = await directPrompt()
        XCTAssertTrue(prompt.contains(DebriefContract.heading))
        XCTAssertTrue(prompt.contains(DebriefContract.lede))
        XCTAssertTrue(prompt.contains("DEBRIEF SUBJECT: \"Job 1004"), prompt)

        await say("the drier looked wet")
        summaries = [summaryJSON("Drier looks wet", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")
        XCTAssertEqual(service.debriefs(sessionId: job.id).count, 1)
        prompt = await directPrompt()
        XCTAssertFalse(prompt.contains(DebriefContract.heading), "a saved debrief is over")
    }

    func testAScrappedDebriefLeavesNoBlockInTheDirectModePrompt() async throws {
        LLMService.debriefContext = { [weak self] in self?.flow?.debriefBlock() }
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("compressor sounded rough")
        let running = await directPrompt()
        XCTAssertTrue(running.contains(DebriefContract.heading))

        summaries = [summaryJSON("Compressor sounded rough", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("scrap it")
        let scrapped = await directPrompt()
        XCTAssertFalse(scrapped.contains(DebriefContract.heading))

        // Put away without settling is the same: nothing is running, so nothing is said.
        _ = await flow.startDebrief(jobId: job.id)
        flow.endDebrief()
        let ended = await directPrompt()
        XCTAssertFalse(ended.contains(DebriefContract.heading))
    }

    /// Live backends: the bridge both managers own takes the block from the real flow — at setup,
    /// when the debrief starts, when it moves to another job, and once more when it settles.
    func testTheLiveBridgeFollowsTheDebriefThroughItsSeam() async throws {
        let first = try finishedJob(reference: "1004", note: "Trap replaced.")
        _ = try finishedJob(reference: "1005", note: "Sensor cleaned.")
        var injected: [String] = []
        let bridge = LiveJobBridge()
        bridge.connect(.init(
            generation: { 1 },
            canInject: { true },
            isBusy: { false },
            injectText: { injected.append($0) },
            debriefBlock: { [weak self] in self?.flow?.debriefBlock() }))
        XCTAssertNil(bridge.setupDebriefBlock())

        _ = await flow.startDebrief(jobId: first.id)
        XCTAssertNotNil(bridge.refreshDebrief())
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected[0].hasPrefix(DebriefContract.heading))
        XCTAssertTrue(injected[0].contains("Job 1004"))

        // A line of the account changes nothing the model can see.
        await say("the drier looked wet")
        XCTAssertNil(bridge.refreshDebrief())
        XCTAssertEqual(injected.count, 1)

        _ = await flow.switchDebrief(to: "debrief job 1005")
        XCTAssertEqual(flow.debrief?.jobNumber, "Job 1005")
        XCTAssertNotNil(bridge.refreshDebrief())
        XCTAssertEqual(injected.count, 2)
        XCTAssertTrue(injected[1].contains("Job 1005"))

        await say("the sensor was filthy")
        summaries = [summaryJSON("Sensor was filthy", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")
        XCTAssertNil(flow.debriefBlock())
        XCTAssertNotNil(bridge.refreshDebrief())
        XCTAssertEqual(injected.last, DebriefContract.endedBlock)
        XCTAssertNil(bridge.refreshDebrief(), "the end of a debrief is said once")
        XCTAssertEqual(injected.count, 3)
    }

    private func directPrompt() async -> String {
        await LLMService.leanOnDevicePrompt(locationContext: nil, memoryContext: nil,
                                            hasImage: false, turn: "the drier looked wet")
    }

    // MARK: - An unrelated question is still a question

    func testAnUnrelatedUtteranceDuringTheDecisionReachesTheModel() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("the drier looked wet")
        summaries = [summaryJSON("Drier looks wet", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")

        let consumed = await flow.handleUtterance("what's the superheat target on an SLP99")
        XCTAssertFalse(consumed, "a question must reach the model, not the state machine")
        XCTAssertTrue(service.debriefs(sessionId: job.id).isEmpty)
    }

    // MARK: - The documents

    func testTheWorkOrderGainsADebriefSectionBeforeTheReportHasGone() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("the drier looked wet")
        summaries = [summaryJSON("Drier looks wet", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")

        let text = try pdfText(sessionId: job.id, reportAlreadySent: false)
        XCTAssertTrue(text.contains(JobDebrief.blockTitle), text)
        XCTAssertTrue(text.contains("Drier looks wet"), text)
    }

    /// The promise a customer's PDF depends on: an addendum is a second document, and the work
    /// order that already went re-renders with exactly the same words it had.
    func testAWorkOrderAlreadySentIsUnchangedByAnAddendum() async throws {
        let job = try finishedJob(reference: "1004")
        let before = try pdfText(sessionId: job.id, reportAlreadySent: true)

        _ = await flow.startDebrief(jobId: job.id)
        await say("the drier looked wet")
        summaries = [summaryJSON("Drier looks wet", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")

        let after = try pdfText(sessionId: job.id, reportAlreadySent: true)
        XCTAssertEqual(after, before,
                       "a work order a customer already holds must not gain a line")
        XCTAssertFalse(after.contains("Drier looks wet"))
    }

    func testTheAddendumIsItsOwnDocumentAndRendersTheSameTwice() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("the drier looked wet")
        summaries = [summaryJSON("Drier looks wet", turn: "\(flow.debrief!.id)-t1")]
        await say("that's it")
        await say("save it")

        let session = try XCTUnwrap(service.history.first { $0.id == job.id })
        let record = WorkRecord(session: session, vaultName: "Refrigeration")
        let first = try addendumText(record: record, debriefs: session.debriefs)
        let second = try addendumText(record: record, debriefs: session.debriefs)
        XCTAssertEqual(first, second, "the same addendum twice is the same document twice")
        XCTAssertTrue(first.contains(DebriefDocumentPolicy.addendumTitle))
        XCTAssertTrue(first.contains("Drier looks wet"))
        XCTAssertTrue(first.contains("Nothing in the original"))
    }

    func testTheJSONRecordCarriesTheDebriefAndItsCitations() async throws {
        let job = try finishedJob(reference: "1004")
        _ = await flow.startDebrief(jobId: job.id)
        await say("the drier looked wet")
        let turnId = "\(flow.debrief!.id)-t1"
        summaries = [summaryJSON("Drier looks wet", turn: turnId)]
        await say("that's it")
        await say("save it")

        let session = try XCTUnwrap(service.history.first { $0.id == job.id })
        let json = WorkRecord(session: session, vaultName: "Refrigeration").jsonString
        XCTAssertTrue(json.contains("\"debriefs\""), json)
        XCTAssertTrue(json.contains("source_turn_ids"))
        XCTAssertTrue(json.contains(turnId))
    }

    // MARK: - Helpers

    /// The provenance is **pinned**, as P2b's determinism tests pin it: the block carries the
    /// moment it was generated, so two renders a second apart differ by a timestamp and by nothing
    /// else. Pinning it is what makes "unchanged" mean unchanged by the debrief.
    private static let pinnedProvenance = AIProvenance(
        modelIdentifier: "pinned-model", providerClass: .cloud,
        promptVersionDigest: "sha256:pinned",
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func pdfText(sessionId: String, reportAlreadySent: Bool) throws -> String {
        let directory = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        let document = try XCTUnwrap(SessionExporter.buildExport(
            sessionDir: directory, provenance: Self.pinnedProvenance))
        let placement = DebriefDocumentPolicy.placement(
            debriefs: document.workRecord?.debriefs ?? [],
            reportAlreadySent: reportAlreadySent)
        let url = sessionsRoot.appendingPathComponent("\(UUID().uuidString).pdf")
        try SessionExporter.writePDF(document, to: url,
                                     photosDirectory: directory.appendingPathComponent("photos"),
                                     debriefs: placement.workOrderDebriefs)
        return try XCTUnwrap(PDFDocument(url: url)?.string)
    }

    private func addendumText(record: WorkRecord, debriefs: [JobDebrief]) throws -> String {
        let url = sessionsRoot.appendingPathComponent("\(UUID().uuidString)-addendum.pdf")
        try SessionExporter.writeAddendumPDF(record: record, debriefs: debriefs, to: url,
                                             provenance: Self.pinnedProvenance)
        return try XCTUnwrap(PDFDocument(url: url)?.string)
    }
}
