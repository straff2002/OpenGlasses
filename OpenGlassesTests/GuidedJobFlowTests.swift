import XCTest
@testable import OpenGlasses

/// The guided job flow against real services: a real `FieldSessionService` on a temp sessions
/// root, a real `ConversationStore` on a temp directory, and the bundled refrigeration vault. Only
/// the three device-facing things — speech, the model's history, the model's context — are seams,
/// so what these exercise is the actual persistence, the actual audit log and the actual thread
/// moves rather than a paraphrase of them.
@MainActor
final class GuidedJobFlowTests: XCTestCase {

    private var sessionsRoot: URL!
    private var storeDirectory: URL!
    private var service: FieldSessionService!
    private var store: ConversationStore!
    private var flow: GuidedJobFlow!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    /// What the flow said, in order.
    private var spoken: [String] = []
    /// The history handed to the model by the last resume. Nil until a resume happens — which is
    /// the whole point of the tests that assert on it.
    private var loadedHistory: [(role: String, content: String)]?
    private var clearHistoryCalls = 0
    /// How far the flow's clock runs ahead of the wall clock — the idle gap without the wait.
    private var clockOffset: TimeInterval = 0
    private var persistenceEnabled = true

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidedJobFlow-sessions-\(unique)", isDirectory: true)
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidedJobFlow-store-\(unique)", isDirectory: true)
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
            loadHistory: { [weak self] history in self?.loadedHistory = history },
            clearHistory: { [weak self] in self?.clearHistoryCalls += 1 },
            threadMode: { AppMode.direct.rawValue },
            personaId: { nil },
            persistenceEnabled: { [weak self] in self?.persistenceEnabled ?? true },
            now: { [weak self] in Date().addingTimeInterval(self?.clockOffset ?? 0) }))
    }

    /// Everything a cold launch rebuilds, from the same directories.
    private func relaunch() {
        service = FieldSessionService(sessionsRoot: sessionsRoot)
        store = ConversationStore(directory: storeDirectory)
        loadedHistory = nil
        flow = makeFlow()
        flow.restoreOnLaunch()
    }

    /// One wake-word turn: the flow picks the thread, the store records the exchange, the turn ends.
    private func turn(_ user: String, assistant: String = "Right you are.",
                      source: JobThreadPolicy.TurnSource = .wakeWord) async {
        if await flow.handleUtterance(user) { return }
        flow.prepareThreadForTurn(source)
        if store.activeThreadId == nil { store.startThread(mode: AppMode.direct.rawValue) }
        store.appendMessage(role: "user", content: user)
        store.appendMessage(role: "assistant", content: assistant)
        await flow.speakPendingQuestionIfDue()
        flow.endThreadForVoiceReturn()
    }

    private func startJob(reference: String? = nil) throws -> FieldSession {
        try flow.startJob(vaultId: "refrigeration", jobReference: reference)
    }

    private func equipment(_ token: String) -> EquipmentIdentity {
        EquipmentIdentity(modelToken: token, heading: token, file: "models.md", source: .spoken)
    }

    private func auditKinds() -> [SessionLogger.Event.Kind] {
        guard let id = service.activeSession?.id else { return [] }
        let url = sessionsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("log.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(SessionLogger.Event.self, from: Data($0.utf8)).kind
        }
    }

    // MARK: - One conversation per job

    func testEveryWakeWordCycleLandsInTheSameConversation() async throws {
        _ = try startJob(reference: "1005")
        await turn("what's the superheat target")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)

        await turn("and the subcooling")
        await turn("write that down")

        XCTAssertEqual(store.threads.count, 1, "three wake-word turns, one saved conversation")
        XCTAssertEqual(service.activeSession?.conversationThreadId, threadId)
        XCTAssertEqual(store.threads[0].messages.count, 6)
    }

    // MARK: - One conversation across voice turns

    /// The reported defect: every Tap & Talk started a new conversation. Consecutive turns now
    /// continue the same one.
    func testWithoutAJobConsecutiveTurnsContinueOneConversation() async throws {
        await turn("what's the weather", source: .tapToTalk)
        let threadId = try XCTUnwrap(store.activeThreadId, "the end of a turn ends nothing")
        await turn("and tomorrow", source: .tapToTalk)
        await turn("and the weekend", source: .wakeWord)

        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.activeThreadId, threadId)
        XCTAssertEqual(store.threads[0].messages.map(\.content).filter { $0 != "Right you are." },
                       ["what's the weather", "and tomorrow", "and the weekend"])
        XCTAssertEqual(clearHistoryCalls, 0, "the model keeps the conversation's context")
    }

    func testTwentyNineQuietMinutesStillContinueTheConversation() async {
        await turn("what's the weather")
        clockOffset = 29 * 60
        await turn("and tomorrow")
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(clearHistoryCalls, 0)
    }

    func testThirtyQuietMinutesStartANewConversation() async throws {
        await turn("what's the weather")
        let first = try XCTUnwrap(store.activeThreadId)
        clockOffset = 30 * 60
        await turn("remind me about the dentist")

        XCTAssertEqual(store.threads.count, 2)
        XCTAssertNotEqual(store.activeThreadId, first)
        XCTAssertEqual(clearHistoryCalls, 1, "a new conversation is new to the model as well")
        let ended = try XCTUnwrap(store.threads.first { $0.id == first })
        XCTAssertEqual(ended.messages.count, 2, "the quiet conversation is kept, not emptied")
        XCTAssertNotNil(ended.summary, "ended like any other — titled and summarised")
    }

    /// Opening a conversation is choosing to carry on with it, however old it is.
    func testResumingAnOldConversationIsActivity() async throws {
        await turn("about the roof")
        let roof = try XCTUnwrap(store.activeThreadId)
        flow.requestNewChat()
        await turn("about the fence")
        let idx = try XCTUnwrap(store.threads.firstIndex { $0.id == roof })
        store.threads[idx].updatedAt = Date().addingTimeInterval(-3 * 60 * 60)

        flow.requestResume(threadId: roof)
        await turn("and the gutters?")
        XCTAssertEqual(store.activeThreadId, roof)
        XCTAssertEqual(store.threads.first { $0.id == roof }?.messages.count, 4)
    }

    func testAJobsConversationIsNeverEndedForBeingQuiet() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)
        clockOffset = 3 * 60 * 60
        await turn("back after lunch")
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.activeThreadId, threadId)
        XCTAssertEqual(clearHistoryCalls, 0)
    }

    func testNewConversationStillStartsAFreshOne() async {
        await turn("what's the weather")
        XCTAssertNil(flow.requestNewChat())
        XCTAssertNil(store.activeThreadId)
        await turn("something else entirely")
        XCTAssertEqual(store.threads.count, 2)
    }

    func testWithoutPersistenceTheIdleGapTouchesNothing() async throws {
        await turn("what's the weather")
        let threadId = try XCTUnwrap(store.activeThreadId)
        persistenceEnabled = false
        clockOffset = 3 * 60 * 60
        flow.prepareThreadForTurn(.wakeWord)
        flow.endThreadForVoiceReturn()
        XCTAssertEqual(store.activeThreadId, threadId)
        XCTAssertEqual(clearHistoryCalls, 0)
    }

    /// Push-to-talk: the release delivers the transcript and returns to the wake word at once, so
    /// `returnToWakeWord()` runs before the model has answered. The reply must still land with its
    /// question — on device it used to land nowhere, because the thread had already been ended.
    func testAPushToTalkReplyLandsInTheQuestionsThread() async throws {
        flow.prepareThreadForTurn(.tapToTalk)
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "how far to the coast")
        let questionThread = try XCTUnwrap(store.activeThreadId)

        flow.endThreadForVoiceReturn()          // the release, before the reply
        store.appendMessage(role: "assistant", content: "About forty minutes.",
                            toThread: questionThread)

        XCTAssertEqual(store.activeThreadId, questionThread)
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.threads[0].messages.map(\.role), ["user", "assistant"])

        // Even if the wearer starts a new conversation while the model is still thinking, the
        // answer is filed with the question that asked for it.
        await turn("and to the airport?", source: .tapToTalk)
        store.appendMessage(role: "user", content: "and the station?")
        let secondQuestion = try XCTUnwrap(store.activeThreadId)
        flow.requestNewChat()
        store.appendMessage(role: "assistant", content: "Ten minutes.", toThread: secondQuestion)
        XCTAssertEqual(store.threads.first { $0.id == secondQuestion }?.messages.last?.content,
                       "Ten minutes.")
    }

    func testStartingAJobAdoptsTheConversationItWasStartedIn() async throws {
        await turn("hello")
        _ = store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "start a job")
        let adopted = try XCTUnwrap(store.activeThreadId)
        _ = try startJob(reference: "1005")
        XCTAssertEqual(service.activeSession?.conversationThreadId, adopted)
    }

    func testPuttingTheGlassesDownKeepsTheJobsConversation() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)
        flow.endThreadForDisconnect()
        XCTAssertEqual(store.activeThreadId, threadId, "a disconnect is not finishing the job")

        await turn("back on it")
        XCTAssertEqual(store.threads.count, 1)
    }

    func testFinishingTheJobClosesItsConversation() async throws {
        _ = try startJob(reference: "1005")
        await turn("done here")
        _ = try flow.closeJob()
        XCTAssertNil(store.activeThreadId)
        await turn("what's the time")
        XCTAssertEqual(store.threads.count, 2, "the next conversation is its own")
    }

    // MARK: - Restart

    func testARestoredJobPicksItsConversationBackUpWithItsHistory() async throws {
        _ = try startJob(reference: "1005")
        await turn("the compressor is short cycling")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)

        relaunch()

        XCTAssertEqual(service.activeSession?.conversationThreadId, threadId,
                       "the binding is part of the session record")
        XCTAssertEqual(store.activeThreadId, threadId)
        let history = try XCTUnwrap(loadedHistory, "a rebound job thread must carry its context")
        XCTAssertTrue(history.contains { $0.content.contains("short cycling") })

        // The restore auto-pauses a recovered session; work continues once it is resumed.
        XCTAssertNotNil(service.activeSession?.pausedAt)
        _ = try service.resumeSession()
        await turn("carrying on")
        XCTAssertEqual(store.threads.count, 1)
    }

    /// The launch-restore half of the two-step resume, with no job in sight: the id used to come
    /// back and the history never did, so the first sentence after a relaunch carried on a
    /// conversation the model had never been shown.
    func testARestoredPlainConversationAlsoGetsItsHistoryBack() async {
        _ = store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "remind me about the roof access code")
        store.appendMessage(role: "assistant", content: "It's 4471.")

        relaunch()

        let history = loadedHistory
        XCTAssertNotNil(history)
        XCTAssertTrue(history?.contains { $0.content.contains("4471") } == true)
    }

    func testAJobWhoseConversationWasDeletedRebindsRatherThanStranding() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)

        store.deleteThread(threadId)
        await turn("still here?")

        let rebound = try XCTUnwrap(service.activeSession?.conversationThreadId)
        XCTAssertNotEqual(rebound, threadId)
        XCTAssertTrue(store.threads.contains { $0.id == rebound })
        XCTAssertTrue(auditKinds().contains(.jobThreadBound))
    }

    func testADeletedThreadIsForgottenAtLaunchWithoutCreatingOne() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)
        store.deleteThread(threadId)

        relaunch()

        XCTAssertNil(service.activeSession?.conversationThreadId)
        XCTAssertTrue(store.threads.isEmpty, "nothing is created at launch; the next turn rebinds")
    }

    // MARK: - Leaving the job's conversation

    func testAnExplicitNewChatDuringAJobAsksFirst() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)

        let question = try XCTUnwrap(flow.requestNewChat(), "must not leave the job silently")
        XCTAssertTrue(question.spoken.contains("1005"))
        XCTAssertEqual(store.activeThreadId, threadId, "nothing moved while the question stands")

        flow.requestNewChat(confirmed: true)
        XCTAssertEqual(service.activeSession?.conversationThreadDetached, true)
        XCTAssertEqual(service.activeSession?.conversationThreadId, threadId,
                       "the job keeps the id so it can still be reviewed")

        await turn("something else entirely")
        XCTAssertNotEqual(store.threads.first?.id, threadId)
    }

    func testOpeningAnotherConversationDuringAJobAsksFirst() async throws {
        _ = store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "an older conversation")
        let older = try XCTUnwrap(store.activeThreadId)
        store.endThread()

        _ = try startJob(reference: "1005")
        await turn("on the job now")
        let jobThread = try XCTUnwrap(service.activeSession?.conversationThreadId)

        XCTAssertNotNil(flow.requestResume(threadId: older))
        XCTAssertEqual(store.activeThreadId, jobThread, "unanswered, nothing moves")

        XCTAssertNil(flow.requestResume(threadId: older, confirmed: true))
        XCTAssertEqual(store.activeThreadId, older)
        XCTAssertTrue(loadedHistory?.contains { $0.content.contains("older conversation") } == true,
                      "a resume is the id and the history, always")
    }

    func testReopeningTheJobsOwnConversationIsNeverAQuestion() async throws {
        _ = try startJob(reference: "1005")
        await turn("on the job")
        let jobThread = try XCTUnwrap(service.activeSession?.conversationThreadId)
        store.endThread()

        XCTAssertNil(flow.requestResume(threadId: jobThread))
        XCTAssertEqual(store.activeThreadId, jobThread)
        XCTAssertNotNil(loadedHistory)
    }

    /// The watch and CarPlay have nowhere to put the question, so they ask the flow and leave the
    /// job alone when the answer is that there is one.
    func testTheWatchAndCarPlayAreToldNotToLeaveTheJob() async throws {
        _ = store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "an older conversation")
        let older = try XCTUnwrap(store.activeThreadId)
        store.endThread()

        _ = try startJob(reference: "1005")
        await turn("on the job")

        XCTAssertNotNil(flow.leaveJobThreadQuestion(switchingTo: older))
        XCTAssertNotNil(flow.leaveJobThreadQuestion())
        XCTAssertNil(flow.leaveJobThreadQuestion(switchingTo: service.activeSession?.conversationThreadId))
    }

    /// The query said it was a query and wrote an audit event on every call. The surfaces that
    /// only *consult* it — CarPlay, the watch — would otherwise have logged a question nobody was
    /// ever put, and a view body asking it during a render would have filled the log.
    func testAskingWhetherThereIsAQuestionWritesNothingToTheLog() async throws {
        _ = try startJob(reference: "1005")
        await turn("on the job")
        let before = auditKinds().filter { $0 == .jobQuestionAsked }.count

        for _ in 0..<5 { _ = flow.leaveJobThreadQuestion() }

        XCTAssertEqual(auditKinds().filter { $0 == .jobQuestionAsked }.count, before,
                       "the query must not write to the audit log")
    }

    /// Putting the question to the technician still records that it was put — that is a fact about
    /// the visit, and it is what `confirmLeaveJobThread` later answers.
    func testRaisingTheQuestionIsWhatRecordsIt() async throws {
        _ = try startJob(reference: "1005")
        await turn("on the job")
        let before = auditKinds().filter { $0 == .jobQuestionAsked }.count

        XCTAssertNotNil(flow.raiseLeaveJobThreadQuestion())

        XCTAssertEqual(auditKinds().filter { $0 == .jobQuestionAsked }.count, before + 1)
    }

    // MARK: - The evidence review (Plan FO P2a)

    private func evidenceItems(_ count: Int) -> [JobMediaItem] {
        (0..<count).map {
            JobMediaItem(id: "p\($0)", capturedAt: Date(timeIntervalSince1970: TimeInterval($0)),
                         origin: .capture, caption: "picture \($0)", filterWasOn: false)
        }
    }

    // MARK: - The evidence review's spoken half

    /// "Include all" and "skip photos" are app behaviour, not something the model has to be
    /// trusted to understand — so the utterance is taken before it reaches the model.
    func testIncludeAllIsAnsweredByTheAppWhileTheReviewIsOpen() async throws {
        _ = try startJob(reference: "1005")
        let items = evidenceItems(3)
        flow.beginEvidenceReview(selection: EvidenceSelection.proposed(for: items), items: items)

        let consumed = await flow.handleUtterance("include all")

        XCTAssertTrue(consumed, "the utterance must not reach the model")
        XCTAssertEqual(flow.evidenceReview?.outcome.includedCount, 3)
        XCTAssertTrue(flow.evidenceReview?.isSettled == true)
        XCTAssertTrue(spoken.contains { $0.contains("going with the report") })
    }

    func testSkipPhotosSettlesOnTheTextOnlyRecord() async throws {
        _ = try startJob(reference: "1005")
        let items = evidenceItems(2)
        flow.beginEvidenceReview(selection: EvidenceSelection.proposed(for: items), items: items)

        let skipped = await flow.handleUtterance("skip photos")
        XCTAssertTrue(skipped)
        XCTAssertEqual(flow.evidenceReview?.outcome, EvidenceSelection.skipped())
    }

    func testTheReadOutWalksThePicturesOneAtATime() async throws {
        _ = try startJob(reference: "1005")
        let items = evidenceItems(2)
        flow.beginEvidenceReview(selection: EvidenceSelection.proposed(for: items), items: items)

        await flow.readEvidenceOutLoud()
        XCTAssertEqual(spoken.last, "Photo 1 of 2, picture 0. Include it?")

        let keptIt = await flow.handleUtterance("yes")
        XCTAssertTrue(keptIt)
        XCTAssertEqual(spoken.last, "Keeping it. Photo 2 of 2, picture 1. Include it?")

        let leftOut = await flow.handleUtterance("no")
        XCTAssertTrue(leftOut)
        XCTAssertEqual(flow.evidenceReview?.outcome.includedItemIds, ["p0"])
    }

    /// The technician asking a question mid-review is asking a question. It reaches the model and
    /// the review is still there afterwards.
    func testAnUnrelatedUtteranceDuringTheReviewReachesTheModel() async throws {
        _ = try startJob(reference: "1005")
        let items = evidenceItems(2)
        flow.beginEvidenceReview(selection: EvidenceSelection.proposed(for: items), items: items)

        let passedThrough = await flow.handleUtterance("what's the superheat target?")
        XCTAssertFalse(passedThrough)
        XCTAssertNotNil(flow.evidenceReview)
        XCTAssertFalse(flow.evidenceReview?.isSettled == true)
    }

    /// "Yes" means nothing here once the review has gone, which is what stops it stealing an
    /// answer from an ordinary turn.
    func testYesMeansNothingOnceTheReviewIsClosed() async throws {
        _ = try startJob(reference: "1005")
        let items = evidenceItems(1)
        flow.beginEvidenceReview(selection: EvidenceSelection.proposed(for: items), items: items)
        flow.endEvidenceReview()

        XCTAssertNil(flow.evidenceReview)
        let notAnAnswer = await flow.handleUtterance("yes")
        XCTAssertFalse(notAnAnswer)
    }

    // MARK: - The job number

    func testStartingAJobWithItsNumberAsksNothing() async throws {
        _ = try startJob(reference: "1005")
        await turn("what's the superheat target")
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
        XCTAssertEqual(flow.intakeState, .recorded(reference: "1005"))
        XCTAssertFalse(spoken.contains { $0.contains("job number") })
    }

    func testTheAppAsksReadsBackAndRecordsTheNumber() async throws {
        _ = try startJob()
        await turn("start looking at this unit")
        XCTAssertEqual(spoken.last, JobIntakePrompt.ask.spoken)
        XCTAssertEqual(flow.intakeState, .asked(attempts: 1))

        await turn("job 1005")
        XCTAssertEqual(spoken.last, JobIntakePrompt.readBack("1005").spoken)
        XCTAssertNil(service.activeSession?.jobReference, "nothing is written down before the read-back")

        await turn("yes that's right")
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
        XCTAssertEqual(flow.intakeState, .recorded(reference: "1005"))
        let kinds = auditKinds()
        XCTAssertTrue(kinds.contains(.jobQuestionAsked))
        XCTAssertTrue(kinds.contains(.jobQuestionAnswered))
        XCTAssertTrue(kinds.contains(.jobReferenceSet))
    }

    func testMisheardDigitsAreCorrectedBeforeAnythingIsRecorded() async throws {
        _ = try startJob()
        await turn("looking at it now")
        await turn("ten oh 5")
        await turn("no, it's 1005")
        XCTAssertEqual(spoken.last, JobIntakePrompt.readBack("1005").spoken)
        await turn("yep")
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
    }

    /// "I don't have one" flags the record. It never blocks the work going out.
    func testDecliningIsRecordedAndDeliveryStillHappens() async throws {
        _ = try startJob()
        await turn("looking at it now")
        await turn("I don't have one")

        XCTAssertEqual(flow.intakeState, .declined)
        XCTAssertNil(service.activeSession?.jobReference)
        XCTAssertNotNil(service.workRecord(), "a declined number must not stop the record existing")
        XCTAssertTrue(auditKinds().contains(.jobQuestionAnswered))

        // And it is not asked again, however many more turns there are.
        let asksBefore = spoken.filter { $0 == JobIntakePrompt.ask.spoken }.count
        await turn("carrying on")
        await turn("still carrying on")
        XCTAssertEqual(spoken.filter { $0 == JobIntakePrompt.ask.spoken }.count, asksBefore)

        let record = try XCTUnwrap(service.workRecord())
        XCTAssertNil(record.jobReference)
        _ = try flow.closeJob()
        XCTAssertNotNil(try? service.exportSession(formats: [.json]))
    }

    func testAnUnrelatedUtteranceReachesTheModelAndTheQuestionStands() async throws {
        _ = try startJob()
        await turn("looking at it now")
        XCTAssertEqual(flow.intakeState, .asked(attempts: 1))

        let consumed = await flow.handleUtterance("what's this error code?")
        XCTAssertFalse(consumed, "a question about the machine is the technician's turn, not an answer")
        XCTAssertEqual(flow.intakeState, .asked(attempts: 1))
    }

    func testTheAppStopsAskingAfterTwoGoes() async throws {
        _ = try startJob()
        await turn("looking at it now")
        await turn("what's the model of this thing")
        XCTAssertEqual(spoken.filter { $0 == JobIntakePrompt.askAgain.spoken }.count, 1)
        await turn("still nothing")
        await turn("and again")
        XCTAssertLessThanOrEqual(
            spoken.filter { $0 == JobIntakePrompt.ask.spoken || $0 == JobIntakePrompt.askAgain.spoken }.count,
            JobIntakeState.maximumAsks,
            "the question has an ask budget; a technician who ignores it is not nagged")
    }

    func testTheOutstandingNumberSurvivesARestart() async throws {
        _ = try startJob()
        await turn("looking at it now")
        XCTAssertEqual(flow.intakeState, .asked(attempts: 1))

        relaunch()

        XCTAssertEqual(flow.intakeState, .asked(attempts: 1))
        XCTAssertTrue(flow.intakeState.isOutstanding)
    }

    func testTheJobsConversationTakesTheJobsName() async throws {
        _ = try startJob()
        await turn("start on this one")
        await turn("1005")
        await turn("yes")
        XCTAssertEqual(store.threads.first?.title, "Job 1005")

        service.setEquipment(equipment("SLP99UH"))
        flow.supplyJobReference("1005")
        XCTAssertEqual(store.threads.first?.title, "Job 1005 — SLP99UH")
    }

    func testAWearerRenamedConversationIsNotTakenOver() async throws {
        _ = try startJob()
        await turn("start on this one")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }) else {
            return XCTFail("thread went missing")
        }
        store.threads[idx].title = "Roof plant — Tuesday"

        flow.supplyJobReference("1005")
        XCTAssertEqual(store.threads[idx].title, "Roof plant — Tuesday")
    }

    // MARK: - A different machine

    func testADifferentUnitIsHeldAndAskedAbout() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))
        let scopeBefore = try XCTUnwrap(service.activeSession?.continuityScope)

        let question = try XCTUnwrap(flow.proposeEquipment(.model(equipment("MODEL090"))))
        XCTAssertTrue(question.spoken.contains("1005"))
        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL070",
                       "the re-scope is held until the technician answers")
        XCTAssertEqual(service.activeSession?.continuityScope, scopeBefore)
        XCTAssertNotNil(service.activeSession?.pendingUnitChange)
    }

    func testSameJobRescopesExactlyAsBeforeAndRecordsTheUnit() async throws {
        let started = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))
        _ = try service.proposeTask(title: "Check the trap", citation: "manual, page 4")
        let scopeBefore = try XCTUnwrap(service.activeSession?.continuityScope)

        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        await flow.speakPendingQuestionIfDue()
        let consumed = await flow.handleUtterance("same job, another unit")
        XCTAssertTrue(consumed)

        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL090")
        XCTAssertNotEqual(service.activeSession?.continuityScope, scopeBefore,
                          "FM's scope partition is exactly what it always was")
        XCTAssertEqual(service.activeSession?.id, started.id, "same job, same session")
        XCTAssertNil(service.activeSession?.pendingUnitChange)
        XCTAssertEqual(service.activeSession?.visitedUnits.map(\.modelToken),
                       ["MODEL070", "MODEL090"], "both units are on the one job")
        // The earlier task belongs to the earlier unit and no longer reads as current work.
        XCTAssertNil(service.activeSession?.activeTask)
    }

    func testFinishedClosesTheJobAndStartsANewOneWhoseNumberIsAskedFor() async throws {
        let first = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))

        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        await flow.speakPendingQuestionIfDue()
        _ = await flow.handleUtterance("that one's finished")

        let second = try XCTUnwrap(service.activeSession)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(second.jobReference)
        XCTAssertEqual(second.jobIntake, .needsReference)
        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL090")

        let closed = try XCTUnwrap(service.history.first { $0.id == first.id })
        XCTAssertNotNil(closed.endedAt)
        XCTAssertEqual(closed.outcome, .resolved)
    }

    /// The time on the finished job must not also be charged to the new one.
    func testClosingAndStartingDoesNotDoubleCountBillableTime() async throws {
        let first = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))
        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        await flow.speakPendingQuestionIfDue()
        _ = await flow.handleUtterance("that one's finished")

        let closed = try XCTUnwrap(service.history.first { $0.id == first.id })
        let opened = try XCTUnwrap(service.activeSession)
        XCTAssertEqual(opened.billableSeconds, 0, accuracy: 0.001,
                       "the new job starts its own clock")
        XCTAssertLessThan(closed.billableSeconds, 5,
                          "and the finished one keeps only the time it actually ran")
        XCTAssertGreaterThanOrEqual(closed.billableSeconds, 0)
    }

    func testNotSureChangesNothingAndIsNotAskedAgain() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))
        let scopeBefore = try XCTUnwrap(service.activeSession?.continuityScope)

        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        await flow.speakPendingQuestionIfDue()
        let asksAfterFirst = spoken.filter { $0.contains("different unit") }.count
        _ = await flow.handleUtterance("not sure")

        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL070")
        XCTAssertEqual(service.activeSession?.continuityScope, scopeBefore)

        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        await flow.speakPendingQuestionIfDue()
        XCTAssertEqual(spoken.filter { $0.contains("different unit") }.count, asksAfterFirst,
                       "once per candidate")
    }

    func testAnUnclearReadNeverRaisesTheQuestion() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))

        XCTAssertNil(flow.proposeEquipment(.unclear(reason: .severalModels)))
        XCTAssertNil(flow.proposeEquipment(.unclear(reason: .notAModel)))
        XCTAssertNil(flow.proposeEquipment(.none))
        XCTAssertNil(service.activeSession?.pendingUnitChange)
        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL070")
    }

    func testTheFirstMachineOfAJobIsAppliedWithoutAQuestion() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        XCTAssertNil(flow.proposeEquipment(.model(equipment("MODEL070"))))
        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL070")
        XCTAssertEqual(service.activeSession?.visitedUnits.map(\.modelToken), ["MODEL070"])
    }

    func testAHeldQuestionSurvivesARestart() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        service.setEquipment(equipment("MODEL070"))
        _ = flow.proposeEquipment(.model(equipment("MODEL090")))

        relaunch()

        let question = try XCTUnwrap(flow.pendingUnitQuestion,
                                     "a question the app forgot it asked is worse than one it never asked")
        XCTAssertEqual(question.candidate.modelToken, "MODEL090")
        XCTAssertEqual(service.activeEquipment?.modelToken, "MODEL070")
    }

    // MARK: - What the model is told

    func testAHundredTurnJobStillTransmitsTheOutstandingNumberAndTheHeldQuestion() async throws {
        _ = try startJob()
        await turn("looking at it now")
        service.setEquipment(equipment("MODEL070"))
        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        for n in 0..<100 {
            service.recordConversationTurn("Check \(n): " + String(repeating: "observed ", count: 40),
                                           sourceID: "turn-\(n)")
        }

        let instructions = try XCTUnwrap(service.promptContext())
        let history: [[String: Any]] = (0..<100).flatMap { n in
            [["role": "user", "content": "Question \(n) " + String(repeating: "old context ", count: 100)],
             ["role": "assistant", "content": "Historical answer \(n)"]]
        }
        let selection = try RequestContextBudget.build(
            model: "test", instructions: instructions,
            history: history + [["role": "user", "content": "what next?"]],
            tools: nil, protectedStart: history.count, allowance: 100_000)
        XCTAssertGreaterThan(selection.omittedMessages, 0, "the request really was compacted")
        let sent = try XCTUnwrap(selection.body["instructions"] as? String)
        XCTAssertTrue(sent.contains("JOB NUMBER: outstanding"))
        XCTAssertTrue(sent.contains("PENDING APP QUESTION"))
        XCTAssertTrue(sent.contains("MODEL090"))
    }

    func testTheModelIsToldWhenTheNumberIsRecordedAndWhenItWasDeclined() async throws {
        _ = try startJob(reference: "1005")
        XCTAssertTrue(try XCTUnwrap(service.promptContext()).contains("JOB NUMBER: \"1005\""))

        _ = try flow.closeJob()
        _ = try startJob()
        flow.declineJobReference()
        let context = try XCTUnwrap(service.promptContext())
        XCTAssertTrue(context.contains("do not have one"))
        XCTAssertFalse(context.contains("JOB NUMBER: outstanding"))
    }

    // MARK: - Gates

    /// A lapse refuses new actions and leaves an open job exactly where it was.
    func testALicenceLapseMidJobDoesNotStrandTheOpenJob() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)

        UserDefaults.standard.set(false, forKey: "fieldAssistEnabled")
        defer { UserDefaults.standard.set(true, forKey: "fieldAssistEnabled") }
        XCTAssertFalse(Config.fieldAssistActive)

        let tool = FieldSessionTool(service: service, flow: flow)
        let refused = try await tool.execute(args: ["action": "start", "vault": "refrigeration"])
        XCTAssertTrue(refused.contains("disabled"))

        XCTAssertNotNil(service.activeSession, "the open job is untouched")
        XCTAssertEqual(service.activeSession?.conversationThreadId, threadId)
        await turn("still working")
        XCTAssertEqual(store.threads.count, 1, "and its conversation is still the job's")
    }

    // MARK: - The tool

    func testTheToolStartsAJobWithItsNumberInOneStep() async throws {
        let tool = FieldSessionTool(service: service, flow: flow)
        let result = try await tool.execute(args: ["action": "start", "vault": "refrigeration",
                                                   "job_reference": "1005"])
        XCTAssertTrue(result.contains("Job 1005 is recorded"))
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
        XCTAssertEqual(flow.intakeState, .recorded(reference: "1005"))
    }

    func testTheToolSaysTheNumberIsOutstandingAndThatTheAppAsks() async throws {
        let tool = FieldSessionTool(service: service, flow: flow)
        let result = try await tool.execute(args: ["action": "start", "vault": "refrigeration"])
        XCTAssertTrue(result.contains("No job number yet"))
        XCTAssertTrue(result.contains("do not ask for one"))
        XCTAssertEqual(flow.intakeState, .needsReference)
    }

    func testTheToolsJobNumberGoesThroughTheIntake() async throws {
        let tool = FieldSessionTool(service: service, flow: flow)
        _ = try await tool.execute(args: ["action": "start", "vault": "refrigeration"])
        _ = try await tool.execute(args: ["action": "set_job_reference", "job_reference": "WO-1005"])
        XCTAssertEqual(flow.intakeState, .recorded(reference: "WO-1005"))
        XCTAssertFalse(flow.intakeState.isOutstanding)
    }

    func testEndingThroughTheToolClosesTheJobsConversation() async throws {
        let tool = FieldSessionTool(service: service, flow: flow)
        _ = try await tool.execute(args: ["action": "start", "vault": "refrigeration",
                                          "job_reference": "1005"])
        await turn("on the job")
        _ = try await tool.execute(args: ["action": "end"])
        XCTAssertNil(store.activeThreadId)
        XCTAssertNil(service.activeSession)
    }

    // MARK: - Sessions written before any of this existed

    func testALegacySessionDecodesAndIsNotAskedForANumberYearsLater() throws {
        let legacy = """
        {"id":"legacy-1","vaultId":"refrigeration","mode":"ai_only",
         "startedAt":"2026-01-02T03:04:05Z","outcome":"resolved","escalations":[],
         "billableSeconds":900}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(FieldSession.self, from: Data(legacy.utf8))

        XCTAssertNil(session.conversationThreadId)
        XCTAssertFalse(session.conversationThreadDetached)
        XCTAssertNil(session.pendingUnitChange)
        XCTAssertTrue(session.visitedUnits.isEmpty)
        XCTAssertEqual(session.jobIntake, .notRequired,
                       "asking for the number of a visit that finished months ago would be nonsense")
        XCTAssertFalse(session.jobIntake.isOutstanding)
    }

    func testALegacySessionThatAlreadyHadItsNumberKeepsIt() throws {
        let legacy = """
        {"id":"legacy-2","vaultId":"refrigeration","mode":"ai_only",
         "startedAt":"2026-01-02T03:04:05Z","outcome":"in_progress","escalations":[],
         "billableSeconds":60,"jobReference":"884"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(FieldSession.self, from: Data(legacy.utf8))
        XCTAssertEqual(session.jobIntake, .recorded(reference: "884"))
    }

    func testANewSessionRoundTripsEveryNewField() async throws {
        _ = try startJob()
        await turn("looking at it now")
        service.setEquipment(equipment("MODEL070"))
        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        let original = try XCTUnwrap(service.activeSession)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(FieldSession.self, from: encoder.encode(original))

        XCTAssertEqual(restored.conversationThreadId, original.conversationThreadId)
        XCTAssertEqual(restored.jobIntake, original.jobIntake)
        XCTAssertEqual(restored.conversationThreadDetached, original.conversationThreadDetached)
        // Dates compare by field: ISO8601 encoding drops sub-second precision, so whole-value
        // equality would be asserting on the encoder rather than on what was carried.
        XCTAssertEqual(restored.pendingUnitChange?.candidate.heading,
                       original.pendingUnitChange?.candidate.heading)
        XCTAssertEqual(restored.pendingUnitChange?.candidateSerial,
                       original.pendingUnitChange?.candidateSerial)
        XCTAssertEqual(restored.pendingUnitChange?.asked, original.pendingUnitChange?.asked)
        XCTAssertEqual(restored.visitedUnits.map(\.heading), original.visitedUnits.map(\.heading))
        XCTAssertEqual(restored.visitedUnits.map(\.continuityScope),
                       original.visitedUnits.map(\.continuityScope))
    }

    // MARK: - Regressions

    /// A **paused** job is still the job. The launch restore pauses every recovered session, so
    /// reading the binding through `FieldSession.isActive` made a crash-restored job look like no
    /// job at all — its conversation orphaned by the first tap, its outstanding number forgotten.
    ///
    /// What it no longer does while paused is hold the conversation (2026-10-03): leaving its
    /// thread is not a question, and is not a detach either — the job keeps the thread, and the
    /// first turn after resuming is back in it. (This test used to assert the question was asked.)
    func testAPausedJobStillOwnsItsThreadAndQuestionsButDoesNotHoldTheWearerInIt() async throws {
        _ = try startJob()
        await turn("looking at it now")
        let threadId = try XCTUnwrap(service.activeSession?.conversationThreadId)
        service.setEquipment(equipment("MODEL070"))
        _ = flow.proposeEquipment(.model(equipment("MODEL090")))

        _ = try service.pauseSession()
        XCTAssertFalse(service.isSessionActive, "paused is not accepting input…")

        // …but the job still holds everything that is the job's.
        XCTAssertEqual(flow.intakeState, .asked(attempts: 1))
        XCTAssertNotNil(flow.pendingUnitQuestion)
        flow.endThreadForVoiceReturn()
        XCTAssertEqual(store.activeThreadId, threadId, "…and its conversation is not closed")
        XCTAssertNil(flow.requestNewChat(), "…but leaving it is not a question while paused")
        XCTAssertNil(store.activeThreadId)
        XCTAssertEqual(service.activeSession?.conversationThreadId, threadId, "the job keeps its thread")
        XCTAssertEqual(service.activeSession?.conversationThreadDetached, false, "and it is not a detach")

        _ = try service.resumeSession()
        await turn("1005")
        await turn("yes")
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
        await turn("back on the unit")
        XCTAssertEqual(store.activeThreadId, threadId, "resumed, the job's turn is back in its thread")
        XCTAssertEqual(store.threads.count, 1)
    }

    // MARK: - A paused job claims nothing (2026-10-03)

    /// A turn the way the app makes one: thread first, then both sides of the exchange written to
    /// the open job's log by the service's own recorders.
    private func loggedTurn(_ user: String, assistant: String = "Right you are.",
                            source: JobThreadPolicy.TurnSource = .wakeWord) async {
        if await flow.handleUtterance(user) { return }
        flow.prepareThreadForTurn(source)
        if store.activeThreadId == nil { store.startThread(mode: AppMode.direct.rawValue) }
        let sourceID = UUID().uuidString
        store.appendMessage(role: "user", content: user)
        service.recordConversationTurn(user, sourceID: sourceID)
        store.appendMessage(role: "assistant", content: assistant)
        service.recordAssistantReply(assistant, sourceID: sourceID)
        await flow.speakPendingQuestionIfDue()
        flow.endThreadForVoiceReturn()
    }

    /// The device record, end to end. A procedure tap opened a job before anybody had said
    /// anything; the app closed, which paused it; the next launch restored it paused; and hours
    /// later a brand-new conversation about the weather became the job's conversation and was
    /// written into its record. Now the paused job takes neither.
    func testAPausedJobDoesNotAdoptTheNextConversationOrRecordIt() async throws {
        _ = try startJob()
        XCTAssertNil(service.activeSession?.conversationThreadId, "nothing to bind yet")

        relaunch()
        XCTAssertNotNil(service.activeSession?.pausedAt, "the restore pauses what it recovers")
        let before = auditKinds()

        await loggedTurn("what's the weather tomorrow", assistant: "Sunny, twenty-two degrees.")
        await loggedTurn("and the weekend?", assistant: "Showers on Sunday.")

        XCTAssertNil(service.activeSession?.conversationThreadId,
                     "the weather is not the job's conversation")
        XCTAssertEqual(store.threads.count, 1, "it is an ordinary conversation of its own")
        let after = auditKinds()
        XCTAssertFalse(after.contains(.userMessage), "nothing the wearer said reached the job's log")
        XCTAssertFalse(after.contains(.assistantMessage))
        XCTAssertFalse(after.contains(.jobThreadBound))
        XCTAssertEqual(after, before, "the paused job's record is exactly as the restore left it")
    }

    /// Resumed, lazy binding is exactly what it was: the next turn adopts the open conversation,
    /// and from then on the job's turns are recorded.
    func testResumingAPausedJobBindsAndRecordsAgain() async throws {
        _ = try startJob(reference: "1005")
        relaunch()
        await loggedTurn("what's the weather tomorrow")
        let open = try XCTUnwrap(store.activeThreadId)
        XCTAssertNil(service.activeSession?.conversationThreadId)

        _ = try service.resumeSession()
        await loggedTurn("right, back to the unit")

        XCTAssertEqual(service.activeSession?.conversationThreadId, open)
        XCTAssertEqual(auditKinds().filter { $0 == .userMessage }.count, 1,
                       "only the turn made after resuming")
        XCTAssertEqual(auditKinds().filter { $0 == .assistantMessage }.count, 1)
    }

    /// Paused with a thread of its own: a turn is not pulled back into it, the end of a turn does
    /// not close the thread the wearer is in, and the job's own thread is never idle-ended.
    func testAPausedJobNeitherPullsATurnBackNorLetsItsThreadGoIdle() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")
        let jobThread = try XCTUnwrap(service.activeSession?.conversationThreadId)
        _ = try service.pauseSession()

        clockOffset = 3 * 60 * 60
        await turn("what's the weather")
        XCTAssertEqual(store.activeThreadId, jobThread, "the job's own thread is never idle-ended")
        XCTAssertEqual(clearHistoryCalls, 0)
        clockOffset = 0

        XCTAssertNil(flow.requestNewChat())
        await turn("and the weekend")
        let elsewhere = try XCTUnwrap(store.activeThreadId)
        XCTAssertNotEqual(elsewhere, jobThread)
        await turn("and next week")
        XCTAssertEqual(store.activeThreadId, elsewhere,
                       "not pulled back into the job's thread, and not closed at the turn's end")
        XCTAssertEqual(service.activeSession?.conversationThreadId, jobThread)
        XCTAssertTrue(store.threads.contains { $0.id == jobThread })

        _ = try service.resumeSession()
        await turn("back to the unit")
        XCTAssertEqual(store.activeThreadId, jobThread, "resumed, the job takes its turn back")
    }

    func testLeavingAPausedJobsConversationAsksNothingAndRecordsNothing() async throws {
        _ = store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "an older conversation")
        let older = try XCTUnwrap(store.activeThreadId)
        store.endThread()
        _ = try startJob(reference: "1005")
        await turn("on the job")
        _ = try service.pauseSession()
        let asked = auditKinds().filter { $0 == .jobQuestionAsked }.count

        XCTAssertNil(flow.leaveJobThreadQuestion())
        XCTAssertNil(flow.leaveJobThreadQuestion(switchingTo: older))
        XCTAssertNil(flow.requestResume(threadId: older))
        XCTAssertEqual(store.activeThreadId, older)
        XCTAssertEqual(service.activeSession?.conversationThreadDetached, false)
        XCTAssertEqual(auditKinds().filter { $0 == .jobQuestionAsked }.count, asked,
                       "no question was put, so none is recorded")
    }

    /// The record's edges. The turn that pauses the job was made while it ran, so its answer is
    /// kept beside it; what is said while paused is not; and "resume the job", which arrives
    /// paused, still makes the record when the next tool round re-records it after the resume.
    func testOnlyTheTurnsAJobIsRunningForReachItsRecord() throws {
        _ = try startJob(reference: "1005")
        service.recordConversationTurn("pause the job", sourceID: "t1")
        _ = try service.pauseSession()
        service.recordAssistantReply("Paused.", sourceID: "t1")

        service.recordConversationTurn("what's the weather", sourceID: "t2")
        service.recordAssistantReply("Sunny.", sourceID: "t2")
        XCTAssertEqual(auditKinds().filter { $0 == .userMessage }.count, 1)
        XCTAssertEqual(auditKinds().filter { $0 == .assistantMessage }.count, 1)

        service.recordConversationTurn("resume the job", sourceID: "t3")
        _ = try service.resumeSession()
        service.recordConversationTurn("resume the job", sourceID: "t3")
        service.recordAssistantReply("Resumed.", sourceID: "t3")
        XCTAssertEqual(auditKinds().filter { $0 == .userMessage }.count, 2)
        XCTAssertEqual(auditKinds().filter { $0 == .assistantMessage }.count, 2)
    }

    /// Every route that sets equipment writes the unit onto the job — a spoken correction and a tap
    /// on the phone's model list reach `setEquipment` without passing the guided flow, and a list
    /// only one of the four routes fills is not a record of the job.
    func testEveryEquipmentRouteRecordsTheUnitOnTheJob() async throws {
        _ = try startJob(reference: "1005")
        await turn("first look")

        service.setEquipment(equipment("MODEL070"))          // a correction, straight to the service
        _ = flow.proposeEquipment(.model(equipment("MODEL090")))
        await flow.speakPendingQuestionIfDue()
        _ = await flow.handleUtterance("same job, another unit")   // through the flow

        XCTAssertEqual(service.activeSession?.visitedUnits.map(\.modelToken),
                       ["MODEL070", "MODEL090"])
        XCTAssertEqual(Set(service.activeSession?.visitedUnits.map(\.continuityScope) ?? []).count, 2,
                       "each unit's work is partitioned by its own FM scope")

        // Recognising the same machine again does not add it twice.
        service.setEquipment(equipment("MODEL090"))
        XCTAssertEqual(service.activeSession?.visitedUnits.count, 2)
    }

    /// The correction the read-back exists for, end to end through the real classifier: the
    /// recogniser's comma used to stop "no it's" being a carrier phrase at all.
    func testAPunctuatedSpokenCorrectionReachesTheRightNumber() async throws {
        _ = try startJob()
        await turn("looking at it now")
        await turn("ten oh 5")
        await turn("No, it's 1005.")
        XCTAssertEqual(spoken.last, JobIntakePrompt.readBack("1005").spoken)
        await turn("That's right.")
        XCTAssertEqual(service.activeSession?.jobReference, "1005")
    }
}
