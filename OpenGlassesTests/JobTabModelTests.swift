import XCTest
@testable import OpenGlasses

/// What the Job tab draws and what its controls do (Plan FO P2).
///
/// A real `FieldSessionService` in a temp directory, a real `ConversationStore` in another, and a
/// real `GuidedJobFlow` over both — the same shape `GuidedJobFlowTests` uses, because the point of
/// the tab is that it *delegates* to the shipped flow rather than reimplementing it, and only a
/// real flow proves that. `RecordingJobFlow` wraps the real one where a test needs to count calls.
@MainActor
final class JobTabModelTests: XCTestCase {

    private var sessionsRoot: URL!
    private var storeDirectory: URL!
    private var service: FieldSessionService!
    private var store: ConversationStore!
    private var flow: RecordingJobFlow!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    private static let vaultId = "refrigeration"

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobTabModel-sessions-\(unique)", isDirectory: true)
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobTabModel-store-\(unique)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()

        service = FieldSessionService(sessionsRoot: sessionsRoot)
        store = ConversationStore(directory: storeDirectory)
        flow = RecordingJobFlow(GuidedJobFlow(sessions: service, store: store))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sessionsRoot)
        try? FileManager.default.removeItem(at: storeDirectory)
        if let previousEnabled {
            UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// Vault vocabulary stated rather than looked up, so a row's wording does not depend on which
    /// packs happen to be installed on the machine running the suite.
    private func makeModel(vaultUnlocked: Bool = true) -> JobTabModel {
        JobTabModel(host: service, flow: flow, defaults: .init(
            vaultId: { Self.vaultId },
            mode: { .aiOnly },
            vaultName: { _ in "Refrigeration" },
            vaultUnlocked: { _ in vaultUnlocked }))
    }

    // MARK: - The three states

    func testNoJobIsTheStateBeforeAnythingStarts() throws {
        let model = makeModel()
        guard case .noJob(let empty) = model.state else {
            return XCTFail("expected the empty state, got \(model.state)")
        }
        XCTAssertEqual(empty.vaultId, Self.vaultId)
        XCTAssertEqual(empty.vaultName, "Refrigeration")
        XCTAssertTrue(empty.canStart)
        XCTAssertNil(empty.startBlockedReason)
    }

    /// A disabled Start button with no reason beside it is a dead end; the reason names the vault.
    func testALockedVaultBlocksStartingAndSaysWhy() throws {
        let model = makeModel(vaultUnlocked: false)
        guard case .noJob(let empty) = model.state else {
            return XCTFail("expected the empty state, got \(model.state)")
        }
        XCTAssertFalse(empty.canStart)
        XCTAssertEqual(empty.startBlockedReason?.contains("Refrigeration"), true)
    }

    func testStartingAJobMovesToTheRunningState() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")

        guard case .running(let job) = model.state else {
            return XCTFail("expected a running job, got \(model.state)")
        }
        XCTAssertEqual(job.jobNumber, "1005")
        XCTAssertFalse(job.isPaused)
        XCTAssertEqual(job.intake.headline, "Job 1005")
        XCTAssertFalse(job.intake.isOutstanding)
    }

    /// A paused job is still the job — the state says paused, not "no job", and everything about
    /// the job is still on the screen.
    func testPausingKeepsTheJobAndSaysSo() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        _ = try model.pauseOrResume()

        guard case .paused(let job) = model.state else {
            return XCTFail("expected a paused job, got \(model.state)")
        }
        XCTAssertTrue(job.isPaused)
        XCTAssertEqual(job.jobNumber, "1005")
        XCTAssertEqual(job.pauseButtonTitle, "Resume job")
        XCTAssertTrue(job.pauseFootnote.contains("stopped counting"))

        _ = try model.pauseOrResume()
        guard case .running(let resumed) = model.state else {
            return XCTFail("expected the job to resume, got \(model.state)")
        }
        XCTAssertEqual(resumed.pauseButtonTitle, "Pause job")
    }

    /// Closing takes the tab back to the empty state, and the job reappears as a past job.
    func testClosingReturnsToNoJobAndTheJobBecomesPast() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        _ = try model.closeJob()

        guard case .noJob = model.state else {
            return XCTFail("expected the empty state after closing, got \(model.state)")
        }
        XCTAssertEqual(model.pastJobs.map(\.jobNumber), ["Job 1005"])
    }

    /// The open job is the job, not a past job — it must not appear in the list underneath itself.
    func testTheOpenJobIsNotInThePastJobList() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        XCTAssertTrue(model.pastJobs.isEmpty)
        XCTAssertFalse(model.hasPastJobs)
    }

    // MARK: - Starting

    func testStartingWithoutANumberLeavesTheIntakeOwingOne() throws {
        let model = makeModel()
        try model.startJob()

        guard let job = model.state.active else { return XCTFail("expected a job") }
        XCTAssertNil(job.jobNumber)
        XCTAssertTrue(job.intake.isOutstanding)
        XCTAssertTrue(job.intake.offersDecline)
        XCTAssertEqual(flow.intakeState, .needsReference)
    }

    /// "Start job 1005" in one step: the number is recorded as the job starts, so nothing is asked.
    func testStartingWithANumberRecordsItImmediately() throws {
        let model = makeModel()
        try model.startJob(jobReference: "  1005 ")

        XCTAssertEqual(flow.intakeState, .recorded(reference: "1005"))
        XCTAssertEqual(model.state.active?.jobNumber, "1005")
    }

    /// A blank field is not a job number. Starting with one must be the same as starting without.
    func testStartingWithABlankNumberIsStartingWithoutOne() throws {
        let model = makeModel()
        try model.startJob(jobReference: "   ")
        XCTAssertEqual(flow.intakeState, .needsReference)
    }

    func testStartingGoesThroughTheFlow() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        XCTAssertEqual(flow.startCount, 1)
        XCTAssertEqual(flow.startedVaultIds, [Self.vaultId])
    }

    // MARK: - Editing the job number

    func testTypingANumberRecordsItExactlyAsTyped() throws {
        let model = makeModel()
        try model.startJob()
        model.supplyJobReference("WO-22/b")

        XCTAssertEqual(flow.intakeState, .recorded(reference: "WO-22/b"))
        XCTAssertEqual(model.state.active?.jobNumber, "WO-22/b")
        XCTAssertEqual(model.state.active?.intake.headline, "Job WO-22/b")
    }

    /// A stray tap on Done must not overwrite a good number with nothing.
    func testABlankEditIsIgnored() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        model.supplyJobReference("   ")
        XCTAssertEqual(flow.intakeState, .recorded(reference: "1005"))
    }

    func testDecliningIsRecordedAndStopsOffering() throws {
        let model = makeModel()
        try model.startJob()
        model.declineJobReference()

        XCTAssertEqual(flow.intakeState, .declined)
        guard let job = model.state.active else { return XCTFail("expected a job") }
        XCTAssertEqual(job.intake.headline, JobTabModel.noJobNumber)
        XCTAssertFalse(job.intake.isOutstanding)
        XCTAssertFalse(job.intake.offersDecline, "a declined job must not keep offering to decline")
    }

    // MARK: - Intake copy, one line per state

    /// Every `JobIntakeState` has to say something, and none of them may say nothing: a technician
    /// always needs to know whether the app is waiting on them or the other way round.
    func testEveryIntakeStateHasCopy() {
        let states: [JobIntakeState] = [
            .notRequired, .needsReference, .asked(attempts: 1), .asked(attempts: 2),
            .confirming(candidate: "1005", attempts: 1), .recorded(reference: "1005"),
            .declined, .outstanding
        ]
        for state in states {
            let copy = JobTabModel.IntakeCopy.make(state)
            XCTAssertFalse(copy.headline.isEmpty, "\(state) rendered a blank headline")
            XCTAssertFalse(copy.spoken.isEmpty, "\(state) rendered nothing for VoiceOver")
            XCTAssertFalse(copy.fieldPrompt.isEmpty, "\(state) left the text field unlabelled")
            XCTAssertEqual(copy.isOutstanding, state.isOutstanding,
                           "\(state) disagreed with the state machine about being outstanding")
        }
    }

    func testAskedAndWaitingSaysSo() {
        let copy = JobTabModel.IntakeCopy.make(.asked(attempts: 1))
        XCTAssertEqual(copy.headline, "Job number — asked, waiting")
        XCTAssertTrue(copy.isOutstanding)
        XCTAssertTrue(copy.offersDecline)
    }

    /// Declined is a real answer, not a blank. It says what was recorded and that the report still
    /// goes out, which is the thing a technician would otherwise have to ask.
    func testDeclinedReadsAsAnAnswerRatherThanAnAbsence() {
        let copy = JobTabModel.IntakeCopy.make(.declined)
        XCTAssertEqual(copy.headline, JobTabModel.noJobNumber)
        XCTAssertFalse(copy.isOutstanding)
        XCTAssertEqual(copy.detail?.isEmpty, false)
    }

    func testConfirmingShowsWhatWasHeard() {
        let copy = JobTabModel.IntakeCopy.make(.confirming(candidate: "1005", attempts: 1))
        XCTAssertTrue(copy.headline.contains("1005"))
        XCTAssertTrue(copy.isOutstanding)
    }

    func testOutstandingOffersTyping() {
        let copy = JobTabModel.IntakeCopy.make(.outstanding)
        XCTAssertTrue(copy.isOutstanding)
        XCTAssertEqual(copy.detail?.contains("Type it here"), true)
    }

    // MARK: - The change-of-unit question

    func testNoQuestionCardWhenNothingIsPending() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        XCTAssertNil(model.unitQuestion)
    }

    /// The card's message is the sentence the app speaks, verbatim — a technician who half-heard it
    /// finds the same words, not a paraphrase.
    func testTheUnitQuestionCardCarriesTheSpokenWording() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        let question = try raiseUnitQuestion()

        guard let card = model.unitQuestion else { return XCTFail("expected a question card") }
        XCTAssertEqual(card.message, question.spoken)
        XCTAssertEqual(card.actions.map(\.answer), [.sameJob, .jobFinished, .unsure])
        XCTAssertEqual(card.actions.filter(\.isDestructive).map(\.answer), [.jobFinished],
                       "only the answer that ends a job is destructive")
        XCTAssertTrue(card.actions.allSatisfy { !$0.title.isEmpty })
    }

    func testAnsweringTheCardGoesThroughTheFlow() async throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        _ = try raiseUnitQuestion()

        guard let card = model.unitQuestion,
              let same = card.actions.first(where: { $0.answer == .sameJob }) else {
            return XCTFail("expected a same-job action")
        }
        await model.answer(same)

        XCTAssertEqual(flow.unitAnswers, [.sameJob])
        XCTAssertNil(model.unitQuestion, "the card must go once it has been answered")
    }

    /// "That job's finished" is the one that ends a job, and it does it through the flow — which
    /// closes the old one and opens a new one on the machine that raised the question.
    func testAnsweringFinishedClosesTheJobThroughTheFlow() async throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        _ = try raiseUnitQuestion()

        guard let card = model.unitQuestion,
              let finished = card.actions.first(where: { $0.answer == .jobFinished }) else {
            return XCTFail("expected a job-finished action")
        }
        await model.answer(finished)

        XCTAssertEqual(flow.unitAnswers, [.jobFinished])
        XCTAssertEqual(model.pastJobs.map(\.jobNumber), ["Job 1005"],
                       "the finished job should be in the past-job list")
    }

    // MARK: - The leave-the-job's-conversation question

    func testLeavingTheJobThreadAsksFirstAndUsesTheSpokenWording() throws {
        let model = makeModel()
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "Start a job")
        try model.startJob(jobReference: "1005")

        guard let card = model.leaveThreadQuestion() else {
            return XCTFail("expected a question before leaving the job's conversation")
        }
        XCTAssertTrue(card.message.contains("1005"))
        XCTAssertEqual(card.keepTitle, "Keep it in the job")
        XCTAssertEqual(card.leaveTitle, "Start a separate chat")
    }

    /// Confirming detaches. The job keeps the id so it can still be reviewed under the job; turns
    /// simply stop landing in it (Plan FO P1).
    func testConfirmingTheSeparateChatDetachesRatherThanUnbinds() throws {
        let model = makeModel()
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "Start a job")
        try model.startJob(jobReference: "1005")
        let bound = flow.boundThreadId

        _ = model.leaveThreadQuestion()
        model.confirmLeaveThread()

        XCTAssertEqual(service.activeSession?.conversationThreadId, bound,
                       "the job must keep the id so it can still be reviewed")
        XCTAssertEqual(service.activeSession?.conversationThreadDetached, true)
        XCTAssertEqual(flow.confirmLeaveCount, 1)
    }

    // MARK: - Opening the job's conversation

    /// Never by assigning `activeThreadId`: that is the id without the history, which is exactly
    /// the defect P1 fixed on CarPlay and the watch.
    func testOpenConversationGoesThroughTheChokepoint() throws {
        let model = makeModel()
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "Start a job")
        try model.startJob(jobReference: "1005")

        guard let bound = flow.boundThreadId else { return XCTFail("expected a bound thread") }
        XCTAssertEqual(model.openConversation(), .open(threadId: bound))
        XCTAssertEqual(flow.resumeRequests.map(\.threadId), [bound],
                       "the tab must ask the flow to resume, never set the id itself")
        XCTAssertEqual(flow.resumeRequests.map(\.confirmed), [false])
    }

    func testOpenConversationSaysSoWhenTheJobHasNoneYet() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        XCTAssertEqual(model.openConversation(), .none)
        XCTAssertEqual(model.state.active?.hasConversation, false)
        XCTAssertTrue(flow.resumeRequests.isEmpty)
    }

    // MARK: - Closing

    /// The button closes one job, once. A second close on a screen that has already gone is the
    /// shape of bug that ends two visits.
    func testCloseDelegatesToTheFlowExactlyOnce() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")

        let closed = try model.closeJob()
        XCTAssertEqual(flow.closeCount, 1)
        XCTAssertEqual(closed.session.jobReference, "1005")
        XCTAssertNotNil(closed.session.endedAt)
    }

    /// The record has to be taken before the close: afterwards there is no active session to build
    /// one from, and the whole point of closing is to have a record to send.
    func testCloseReturnsTheRecordTakenBeforeTheSessionEnded() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        _ = try service.addOperatorTask(title: "Cleaned the flame sensor")

        let closed = try model.closeJob()
        XCTAssertEqual(closed.record?.jobReference, "1005")
        XCTAssertEqual(closed.record?.tasks.count, 1)
        XCTAssertNil(model.readBackLines, "there is no active job to read back once it is closed")
    }

    func testCloseCarriesTheOutcomeThroughToTheRecord() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        let closed = try model.closeJob(outcome: .deferred)
        XCTAssertEqual(closed.session.outcome, .deferred)
        XCTAssertEqual(model.pastJobs.first?.outcomeLabel, "Deferred")
    }

    // MARK: - Read back

    func testReadBackIsTheRecordsOwnLines() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        _ = try service.addOperatorTask(title: "Cleaned the flame sensor")

        XCTAssertEqual(model.readBackLines, service.workRecord()?.summaryLines)
        XCTAssertEqual(model.readBackSpeech, service.workRecord()?.summary)
        XCTAssertEqual(model.state.active?.hasRecord, true)
    }

    // MARK: - Past jobs

    func testPastJobsAreNewestFirst() throws {
        let model = makeModel()
        try runJob(reference: "1001")
        try runJob(reference: "1002")
        try runJob(reference: "1003")

        XCTAssertEqual(model.pastJobs.map(\.jobNumber), ["Job 1003", "Job 1002", "Job 1001"])
    }

    /// A visit with no number is a real visit. The row says so rather than rendering a blank line
    /// nobody can tap with confidence.
    func testADeclinedJobNumberShowsAsNoJobNumberRatherThanBlank() throws {
        let model = makeModel()
        try model.startJob()
        model.declineJobReference()
        _ = try model.closeJob()

        guard let row = model.pastJobs.first else { return XCTFail("expected a past job") }
        XCTAssertEqual(row.jobNumber, JobTabModel.noJobNumber)
        XCTAssertFalse(row.hasJobNumber)
        XCTAssertFalse(row.jobNumber.isEmpty)
        XCTAssertFalse(row.spoken.isEmpty)
    }

    /// A job that was never asked for a number renders the same way — the row is about what is
    /// known, not about which state machine produced it.
    func testAJobWithNoNumberAtAllShowsTheSameLabel() throws {
        let model = makeModel()
        try model.startJob()
        _ = try model.closeJob()
        XCTAssertEqual(model.pastJobs.first?.jobNumber, JobTabModel.noJobNumber)
    }

    func testSearchFindsAJobByItsNumber() throws {
        let model = makeModel()
        try runJob(reference: "1001")
        try runJob(reference: "1002")

        XCTAssertEqual(model.pastJobs(matching: "1002").map(\.jobNumber), ["Job 1002"])
        XCTAssertEqual(model.pastJobs(matching: " 1002 ").map(\.jobNumber), ["Job 1002"])
    }

    func testAnEmptySearchIsEveryJob() throws {
        let model = makeModel()
        try runJob(reference: "1001")
        try runJob(reference: "1002")
        XCTAssertEqual(model.pastJobs(matching: "").count, 2)
        XCTAssertEqual(model.pastJobs(matching: "   ").count, 2)
    }

    /// The absence is asserted on a value that is in no row at all, so a match on the word the
    /// search happens to echo cannot make this pass.
    func testSearchFiltersEverythingOutWhenNothingMatches() throws {
        let model = makeModel()
        try runJob(reference: "1001")
        XCTAssertTrue(model.pastJobs(matching: "zzq9").isEmpty)
    }

    // MARK: - One past job

    func testAPastJobCarriesItsRecordAndItsConversation() throws {
        let model = makeModel()
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "Start a job")
        try model.startJob(jobReference: "1005")
        let bound = flow.boundThreadId
        _ = try service.addOperatorTask(title: "Cleaned the flame sensor")
        let closed = try model.closeJob()

        guard let past = model.pastJob(id: closed.session.id) else {
            return XCTFail("expected the closed job to be readable as a past job")
        }
        XCTAssertEqual(past.jobNumber, "Job 1005")
        XCTAssertEqual(past.threadId, bound)
        XCTAssertEqual(past.record.jobReference, "1005")
        XCTAssertFalse(past.summaryLines.isEmpty)
        XCTAssertEqual(past.summaryLines, past.record.summaryLines,
                       "the page must print the record's own lines, not a second summary")
    }

    /// Reading a past job must not make its conversation the live one. A technician reviewing last
    /// Tuesday and then talking to the glasses would otherwise append to last Tuesday.
    func testReadingAPastJobDoesNotTouchTheActiveThread() throws {
        let model = makeModel()
        store.startThread(mode: AppMode.direct.rawValue)
        store.appendMessage(role: "user", content: "Start a job")
        try model.startJob(jobReference: "1005")
        let closed = try model.closeJob()

        let activeBefore = store.activeThreadId
        let resumesBefore = flow.resumeRequests.count
        _ = model.pastJob(id: closed.session.id)

        XCTAssertEqual(store.activeThreadId, activeBefore)
        XCTAssertEqual(flow.resumeRequests.count, resumesBefore,
                       "a past job's page must never resume its thread")
    }

    func testAnOpenJobIsNotReadableAsAPastJob() throws {
        let model = makeModel()
        let session = try model.startJob(jobReference: "1005")
        XCTAssertNil(model.pastJob(id: session.id))
    }

    func testAnUnknownIdIsNotAPastJob() {
        XCTAssertNil(makeModel().pastJob(id: "not-a-session"))
    }

    // MARK: - Photos (Plan FO P2a)

    func testAJobWithNoPhotosSaysSoAndOffersNoReview() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")

        XCTAssertEqual(model.state.active?.photoCount, 0)
        let review = try XCTUnwrap(model.evidenceReview)
        XCTAssertTrue(review.isEmpty)
        XCTAssertTrue(model.evidenceSelection().entries.isEmpty)
    }

    func testThePhotosSectionCountsWhatTheJobHasCollected() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        attach(origin: .photoLog, caption: "leak site")
        attach(origin: .capture, caption: "the coil")

        XCTAssertEqual(model.state.active?.photoCount, 2)
        let review = try XCTUnwrap(model.evidenceReview)
        XCTAssertEqual(review.count, 2)
        XCTAssertEqual(review.groups.map(\.title), [EvidenceRenderPlan.jobLevelTitle])
        XCTAssertEqual(model.evidenceSelection().includedCount, 1,
                       "only the logged one is ticked to start with")
    }

    /// The face-blur line is not in P2 on purpose: it arrives with the photos it describes.
    func testTheFaceBlurLineFollowsTheGlobalSetting() throws {
        let previous = Config.privacyFilterEnabled
        defer { Config.setPrivacyFilterEnabled(previous) }
        let model = makeModel()
        try model.startJob(jobReference: "1005")

        Config.setPrivacyFilterEnabled(true)
        XCTAssertEqual(model.evidenceReview?.faceBlurLine, "Face blur: On")
        Config.setPrivacyFilterEnabled(false)
        XCTAssertEqual(model.evidenceReview?.faceBlurLine, "Face blur: Off")
    }

    /// The ordering P2 left room for: the selection is written while the session is still open, so
    /// the record the close takes already carries it.
    func testClosingWritesTheSelectionOntoTheRecordBeforeTheSessionEnds() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        attach(origin: .photoLog, caption: "leak site")
        var selection = model.evidenceSelection()
        selection.setRole(.fault, for: selection.entries[0].itemId)

        let closed = try model.closeJob(evidence: selection.confirmed())

        let record = try XCTUnwrap(closed.record)
        XCTAssertTrue(record.evidenceSelection?.reviewed == true)
        XCTAssertEqual(record.evidenceSelection?.entries.first?.role, .fault)
        XCTAssertEqual(record.media.count, 1)
        XCTAssertEqual(flow.closeCount, 1, "closing still goes through the flow exactly once")
        XCTAssertEqual(record.evidencePlan.itemIds, record.media.map(\.id))
    }

    /// Skipping is one tap, and it sends today's record: `reviewed` stays false, so the export
    /// takes its unchanged path.
    func testSkippingLeavesTheRecordUnreviewed() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        attach(origin: .photoLog, caption: "leak site")

        let closed = try model.closeJob(evidence: EvidenceSelection.skipped())

        let record = try XCTUnwrap(closed.record)
        XCTAssertFalse(record.evidenceSelection?.reviewed ?? true)
        XCTAssertTrue(record.evidencePlan.isEmpty)
    }

    /// Closing without going through the review at all — the path a job with no photos takes —
    /// leaves the record exactly as it was.
    func testClosingWithNoEvidenceArgumentTouchesNothing() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        attach(origin: .photoLog, caption: "leak site")

        let closed = try model.closeJob()
        XCTAssertNil(try XCTUnwrap(closed.record).evidenceSelection)
    }

    /// A past job shows the selection that went out, not a fresh proposal — which is what makes
    /// "Share full-size photos" hand out the files the customer's PDF was made from.
    func testAPastJobCarriesTheSelectionThatWentOut() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        attach(origin: .photoLog, caption: "leak site")
        attach(origin: .capture, caption: "the van")
        var selection = model.evidenceSelection()
        selection.setIncluded(false, for: selection.entries[0].itemId)
        selection.setIncluded(true, for: selection.entries[1].itemId)
        let closed = try model.closeJob(evidence: selection.confirmed())

        let past = try XCTUnwrap(model.pastEvidence(sessionId: closed.session.id))
        XCTAssertEqual(past.review.count, 2)
        XCTAssertEqual(past.selection.includedItemIds.count, 1)
        XCTAssertEqual(past.review.shareURLs(for: past.selection).map(\.lastPathComponent),
                       past.selection.includedItemIds)
    }

    func testAPastJobWithNoPhotosHasNoPhotosSection() throws {
        let model = makeModel()
        try model.startJob(jobReference: "1005")
        let closed = try model.closeJob()
        XCTAssertNil(model.pastEvidence(sessionId: closed.session.id))
    }

    // MARK: - Helpers

    /// One photograph on the open job. The bytes do not matter here — what is under test is the
    /// catalogue, the selection and the ordering, all of which are metadata.
    private func attach(origin: JobMediaItem.Origin, caption: String?) {
        service.attachPhoto(Data([0xFF, 0xD8, 0xFF]), caption: caption, origin: origin,
                            filterWasOn: false)
    }

    private func runJob(reference: String) throws {
        let model = makeModel()
        try model.startJob(jobReference: reference)
        _ = try model.closeJob()
    }

    /// Put a second machine in front of the session so the flow raises its change-of-unit question.
    @discardableResult
    private func raiseUnitQuestion() throws -> JobUnitChangeQuestion {
        service.setEquipment(EquipmentIdentity(modelToken: "AAA-1", heading: "AAA-1 Condenser",
                                               file: "models.md", source: .spoken))
        let candidate = EquipmentIdentity(modelToken: "BBB-2", heading: "BBB-2 Condenser",
                                          file: "models.md", source: .spoken)
        guard let question = flow.inner.proposeEquipment(.model(candidate)) else {
            throw XCTSkip("the flow raised no question for a second machine")
        }
        return question
    }
}

// MARK: - A flow that counts

/// The real `GuidedJobFlow`, with a tally.
///
/// Wrapping rather than faking is deliberate: the behaviour under test stays the shipped one — the
/// binding, the intake, the detach, the close — and what the tally adds is the ability to assert
/// that the Job tab went *through* it, and how many times. A hand-written fake would prove the tab
/// calls something, not that it calls the chokepoint.
@MainActor
final class RecordingJobFlow: JobFlowHosting {
    let inner: GuidedJobFlow

    private(set) var startCount = 0
    private(set) var startedVaultIds: [String] = []
    private(set) var closeCount = 0
    private(set) var confirmLeaveCount = 0
    private(set) var unitAnswers: [JobUnitChangeAnswer] = []
    private(set) var resumeRequests: [(threadId: String, confirmed: Bool)] = []

    init(_ inner: GuidedJobFlow) { self.inner = inner }

    var intakeState: JobIntakeState { inner.intakeState }
    var boundThreadId: String? { inner.boundThreadId }
    var pendingUnitQuestion: JobUnitChangeQuestion? { inner.pendingUnitQuestion }

    @discardableResult
    func startJob(vaultId: String, assetId: String?, mode: FieldSession.Mode,
                  jobReference: String?) throws -> FieldSession {
        startCount += 1
        startedVaultIds.append(vaultId)
        return try inner.startJob(vaultId: vaultId, assetId: assetId, mode: mode,
                                  jobReference: jobReference)
    }

    @discardableResult
    func closeJob(outcome: FieldSession.Outcome) throws -> FieldSession {
        closeCount += 1
        return try inner.closeJob(outcome: outcome)
    }

    func supplyJobReference(_ text: String) { inner.supplyJobReference(text) }

    func declineJobReference() { inner.declineJobReference() }

    func answerUnitChange(_ answer: JobUnitChangeAnswer) async {
        unitAnswers.append(answer)
        await inner.answerUnitChange(answer)
    }

    /// P2a split the pure query from the act of putting the question; the tab's card is raised by
    /// a tap, so it forwards the raising half. Same return value, same behaviour — what changed is
    /// that the *query* beside it no longer writes an audit event.
    func raiseLeaveJobThreadQuestion(switchingTo threadId: String?) -> JobThreadQuestion? {
        inner.raiseLeaveJobThreadQuestion(switchingTo: threadId)
    }

    func confirmLeaveJobThread() {
        confirmLeaveCount += 1
        inner.confirmLeaveJobThread()
    }

    @discardableResult
    func requestResume(threadId: String, confirmed: Bool) -> JobThreadQuestion? {
        resumeRequests.append((threadId, confirmed))
        return inner.requestResume(threadId: threadId, confirmed: confirmed)
    }
}
