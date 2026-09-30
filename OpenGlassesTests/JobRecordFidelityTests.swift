import UIKit
import XCTest
@testable import OpenGlasses

/// Plan GB P3 — the saved job says what happened: the time worked, the photos kept, the checks
/// still owed, the readings as corrected, and one close however it was asked for.
@MainActor
final class JobRecordFidelityTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobRecordFidelityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(resumedAt: Date? = nil, pausedAt: Date? = nil, billable: TimeInterval = 0,
                         checkpoint: Date? = nil) -> FieldSession {
        var session = FieldSession(id: "s", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: t0, endedAt: nil, pausedAt: pausedAt, resumedAt: resumedAt,
                                   outcome: pausedAt == nil ? .inProgress : .paused, escalations: [],
                                   billableSeconds: billable)
        session.billableCheckpointAt = checkpoint
        return session
    }

    // MARK: - BillableClock

    func testANeverPausedJobIsCreditedFromItsStartToItsLastSignOfLife() {
        let recovery = BillableClock.recover(session: session(), lastEvidenceOfLife: t0 + 1_200,
                                             now: t0 + 1_500)
        XCTAssertEqual(recovery.creditedSeconds, 1_200)
        XCTAssertEqual(recovery.pausedAt, t0 + 1_200)
        XCTAssertEqual(recovery.uncountedSeconds, 300)
        XCTAssertTrue(recovery.wasRunning)
    }

    func testAJobPausedBeforeTheAppDiedGainsAndLosesNothing() {
        let recovery = BillableClock.recover(session: session(pausedAt: t0 + 600, billable: 600),
                                             lastEvidenceOfLife: t0 + 900, now: t0 + 2_000)
        XCTAssertEqual(recovery, .init(creditedSeconds: 0, pausedAt: t0 + 600, uncountedSeconds: 0,
                                       wasRunning: false))
    }

    func testAResumedJobIsCreditedFromTheResume() {
        let recovery = BillableClock.recover(session: session(resumedAt: t0 + 1_000, billable: 540),
                                             lastEvidenceOfLife: t0 + 1_900, now: t0 + 3_000)
        XCTAssertEqual(recovery.creditedSeconds, 900)
    }

    func testAHeartbeatBeforeTheAnchorCreditsNothing() {
        let recovery = BillableClock.recover(session: session(resumedAt: t0 + 1_000),
                                             lastEvidenceOfLife: t0 + 400, now: t0 + 1_600)
        XCTAssertEqual(recovery.creditedSeconds, 0)
        XCTAssertEqual(recovery.pausedAt, t0 + 1_000)
    }

    func testACheckpointIsAlreadyCountedAndNotCountedTwice() {
        let recovery = BillableClock.recover(session: session(billable: 1_000, checkpoint: t0 + 1_000),
                                             lastEvidenceOfLife: t0 + 900, now: t0 + 1_800)
        XCTAssertEqual(recovery.creditedSeconds, 0, "the checkpoint already folded it in")
        XCTAssertEqual(recovery.pausedAt, t0 + 1_000)
    }

    func testALegacySessionWithNoResumeCountsFromItsStart() throws {
        let legacy = #"{"id":"s0","vaultId":"refrigeration","mode":"ai_only","startedAt":"2026-09-30T17:00:00Z","outcome":"in_progress","escalations":[],"billableSeconds":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FieldSession.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.billableCheckpointAt)
        XCTAssertTrue(decoded.spokenReadings.isEmpty)
        let recovery = BillableClock.recover(session: decoded,
                                             lastEvidenceOfLife: decoded.startedAt + 600,
                                             now: decoded.startedAt + 900)
        XCTAssertEqual(recovery.creditedSeconds, 600)
    }

    /// Job 1011: 540 s saved, resumed at 17:20:44, last sign of life twenty minutes later, then
    /// the app was killed. The restore used to add nothing.
    func testJob1011sTwentyMinutesAreCreditedOnRelaunch() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let resumed = try XCTUnwrap(service.activeSession?.startedAt)
        service.recoverBillableTime(lastEvidenceOfLife: resumed + 1_200, now: resumed + 1_500)
        let session = try XCTUnwrap(service.activeSession)
        XCTAssertEqual(session.billableSeconds, 1_200, accuracy: 0.001)
        XCTAssertEqual(session.pausedAt, resumed + 1_200)
        XCTAssertEqual(session.outcome, .paused, "a paused job is still the job")
        XCTAssertEqual(session.appClosedPause?.uncountedSeconds, 300)
        XCTAssertTrue(BillableClock.note(pausedAt: resumed + 1_200, uncountedSeconds: 300)
            .hasSuffix("; 5 minutes not counted."))

        _ = try service.resumeSession()
        XCTAssertNil(service.activeSession?.appClosedPause)
    }

    // MARK: - Evidence

    private func jobWithTwoPhotos() throws -> FieldSessionService {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let jpeg = UIImage(systemName: "wrench")!.jpegData(compressionQuality: 0.5)!
        service.attachPhoto(jpeg, caption: "sharp", origin: .photoLog)
        service.attachPhoto(jpeg, caption: "blurry", origin: .photoLog)
        return service
    }

    func testAnUnreviewedSelectionWithADecisionIsHonoured() {
        var selection = EvidenceSelection(reviewed: false, entries: [
            .init(itemId: "a", included: true, order: 0), .init(itemId: "b", included: true, order: 1)])
        XCTAssertNil(EvidenceSelectionPolicy.effective(selection), "nothing chosen: the text-only record")
        selection.decide("b", included: false)
        let effective = try? XCTUnwrap(EvidenceSelectionPolicy.effective(selection))
        XCTAssertEqual(effective?.includedItemIds, ["a"])
    }

    func testAPhotoLeftOutByVoiceIsAbsentFromTheRecordWithoutAnyReview() async throws {
        let service = try jobWithTwoPhotos()
        let reply = try await EvidenceTool(sessionService: service).execute(args: ["action": "exclude"])
        XCTAssertEqual(reply, "That photo is left out of the report.")
        let record = try XCTUnwrap(service.workRecord())
        XCTAssertFalse(record.evidenceSelection?.reviewed ?? true, "no review happened")
        let planned = record.evidencePlan.groups.flatMap(\.entries).map(\.item.caption)
        XCTAssertEqual(planned, ["sharp"])

        let id = try XCTUnwrap(service.activeSession?.id)
        _ = try service.endSession()
        let export = try XCTUnwrap(SessionExporter.buildExport(
            sessionDir: tempRoot.appendingPathComponent(id)))
        XCTAssertEqual(export.photos.filter { $0.included == true }.count, 1, "the JSON says which went")
    }

    // MARK: - Verification

    private func retestProcedure() -> Procedure {
        Procedure(id: "clear_and_retest_demo", title: "Clear and retest", version: "1", steps: [
            .init(id: "fix", title: "Fix", instruction: "Correct what you found.", defaultNext: "retest"),
            .init(id: "retest", title: "Correct, clear and retest",
                  instruction: "Run a full heat cycle on low and high fire. Clear the history only after the retest passes.",
                  terminal: true, outcome: "resolved", requiresConfirmation: true)
        ])
    }

    func testArrivingAtTheLastStepCompletesNothing() throws {
        let logger = SessionLogger(session: session(), root: tempRoot.appendingPathComponent("r"))
        let runner = try ProcedureRunner(starting: retestProcedure(), logger: logger)
        guard case .arrivedAtTerminal(let step) = try runner.advance(choice: nil) else {
            return XCTFail("entering the last step is not completing it")
        }
        XCTAssertTrue(step.instruction.hasPrefix("Run a full heat cycle"))
        XCTAssertThrowsError(try runner.advance(choice: nil), "'next' cannot skip the confirmation")
        XCTAssertTrue(runner.promptContext().contains("Not yet verified. Do not say resolved."))
    }

    func testTheRetestSchemaKeyIsOptionalAndReadWhenPresent() throws {
        let legacy = #"{"id":"a","title":"A","instruction":"Do it.","terminal":true}"#
        let step = try JSONDecoder().decode(Procedure.Step.self, from: Data(legacy.utf8))
        XCTAssertFalse(step.needsConfirmation)
        let marked = #"{"id":"a","title":"A","instruction":"Do it.","terminal":true,"requires_confirmation":true}"#
        XCTAssertTrue(try JSONDecoder().decode(Procedure.Step.self, from: Data(marked.utf8)).needsConfirmation)
    }

    func testClosingAFixThatNeedsARetestLeavesAVerifyTaskOpen() throws {
        let fix = FieldSession.Task(title: "Clear and retest", origin: .operatorAdded, status: .inProgress,
                                    verification: .init(instruction: "Run a full heat cycle on low and high fire."))
        XCTAssertEqual(TaskClosePolicy.decide(task: fix, status: .done, confirmed: false),
                       .closeSpawningVerification(title: "Verify: run a full heat cycle on low and high fire"))
        XCTAssertEqual(TaskClosePolicy.decide(task: fix, status: .done, confirmed: true), .close)
        XCTAssertEqual(TaskClosePolicy.decide(task: fix, status: .abandoned, confirmed: false), .close)
        let check = FieldSession.Task(title: "Verify: run a full heat cycle", origin: .operatorAdded,
                                      status: .accepted, verification: fix.verification)
        guard case .refuse = TaskClosePolicy.decide(task: check, status: .done, confirmed: false) else {
            return XCTFail("the check itself closes only when it passed")
        }
        let plain = FieldSession.Task(title: "Cleaned trap", origin: .operatorAdded, status: .inProgress)
        XCTAssertEqual(TaskClosePolicy.decide(task: plain, status: .done, confirmed: false), .close)
    }

    func testTheServiceKeepsTheCheckOpenAndTheJobOffResolved() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let fix = try service.addOperatorTask(title: "Cleared the pressure switch tubing")
        try service.requireVerification(taskId: fix.id,
                                           .init(instruction: "Run a full heat cycle on low and high fire."))
        _ = try service.completeTask(id: fix.id)
        let open = try XCTUnwrap(service.activeSession?.openVerifications.first)
        XCTAssertEqual(open.title, "Verify: run a full heat cycle on low and high fire")
        XCTAssertThrowsError(try service.completeTask(id: open.id), "no unconfirmed close for the check")

        let record = try XCTUnwrap(service.workRecord())
        XCTAssertTrue(record.summaryLines.contains {
            $0.hasPrefix("Not yet verified: Verify: run a full heat cycle")
        }, record.summary)

        // Closing from the screen with the check owed records deferred, never resolved.
        let flow = GuidedJobFlow(sessions: service, store: ConversationStore(
            directory: tempRoot.appendingPathComponent("chat")))
        let closed = try flow.closeJob(outcome: .resolved, route: .screen)
        XCTAssertEqual(closed.outcome, .deferred)
    }

    // MARK: - Readings

    func testACorrectionRendersAsOneReading() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 30; parts.hour = 17; parts.minute = 20
        let first = try XCTUnwrap(Calendar.current.date(from: parts))
        parts.minute = 28
        let second = try XCTUnwrap(Calendar.current.date(from: parts))
        let reading = try XCTUnwrap(service.recordReading(quantity: "supply air", value: "140",
                                                          unit: "F", at: first))
        _ = service.correctReading(value: "135", unit: nil, at: second)

        let record = try XCTUnwrap(service.workRecord())
        XCTAssertTrue(record.summaryLines.contains("  Supply air 140 °F (corrected to 135 °F at 5:28 PM)"),
                      record.summary)
        XCTAssertEqual(record.readings, [reading.id], "one reading, not two")
        XCTAssertTrue(record.tasks.isEmpty, "and no finished task at all")
    }

    func testAReadingCitesOnlyAVerifiedPage() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let unverified = service.recordReading(quantity: "rise", value: "45", unit: "F",
                                               page: "Service Manual, page 30")
        XCTAssertNil(unverified?.citation)

        service.pageDidOpen(.init(title: "Service Manual", page: 30, figure: nil, origin: .requested,
                                  source: .extractedText))
        service.confirmOpenPage(.tap)
        let verified = service.recordReading(quantity: "rise", value: "45", unit: "F",
                                             page: "Service Manual, page 30")
        XCTAssertEqual(verified?.citation, "Service Manual, page 30")
    }

    // MARK: - One close

    func testVoiceCloseAsksWhatTheScreenAlreadyAnswered() {
        let base = JobCloseSequence.Inputs(requestedOutcome: .resolved, openVerifications: [],
                                           evidenceCount: 2, evidenceDecided: false,
                                           signOff: .allowed, route: .voice)
        guard case .ask = JobCloseSequence.decide(base) else { return XCTFail("undecided photos are asked about") }
        var decided = base
        decided.evidenceDecided = true
        XCTAssertEqual(JobCloseSequence.decide(decided), .proceed(outcome: .resolved))
        var owed = decided
        owed.openVerifications = ["Verify: run a full heat cycle"]
        guard case .ask = JobCloseSequence.decide(owed) else { return XCTFail("an owed check is asked about") }
        owed.requestedOutcome = .deferred
        XCTAssertEqual(JobCloseSequence.decide(owed), .proceed(outcome: .deferred))
        var blocked = decided
        blocked.signOff = .blocked("sign")
        XCTAssertEqual(JobCloseSequence.decide(blocked), .refuse("sign"))
        var screen = base
        screen.route = .screen
        XCTAssertEqual(JobCloseSequence.decide(screen), .proceed(outcome: .resolved))
    }

    func testVoiceCloseAndTabCloseProduceTheSameRecord() async throws {
        func run(voice: Bool) async throws -> WorkRecord {
            let root = tempRoot.appendingPathComponent(voice ? "voice" : "tab")
            let service = FieldSessionService(sessionsRoot: root)
            _ = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "1011")
            let task = try service.addOperatorTask(title: "Cleaned the trap")
            _ = try service.completeTask(id: task.id)
            let flow = GuidedJobFlow(sessions: service, store: ConversationStore(
                directory: root.appendingPathComponent("chat")))
            let id = try XCTUnwrap(service.activeSession?.id)
            if voice {
                _ = try await FieldSessionTool(service: service, flow: flow).execute(args: ["action": "end"])
            } else {
                _ = try JobTabModel(host: service, flow: flow).closeJob(outcome: .resolved)
            }
            return try XCTUnwrap(service.workRecord(sessionId: id))
        }
        let voice = try await run(voice: true)
        let tab = try await run(voice: false)
        XCTAssertEqual(voice.summaryLines.dropLast(), tab.summaryLines.dropLast(),
                       "the same lines, the time aside")
        XCTAssertEqual(voice.tasks.map(\.status), tab.tasks.map(\.status))
    }
}
