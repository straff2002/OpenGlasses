import XCTest
@testable import OpenGlasses

/// The three read-only surfaces the guided job flow reaches in Plan FO P3a: the lens cue, the
/// CarPlay Jobs list, and the watch payload. All pure — no glasses, no car, no watch.
@MainActor
final class JobSurfacesTests: XCTestCase {

    // MARK: - Fixtures

    private func job(reference: String? = nil,
                     intake: JobIntakeState = .needsReference,
                     pendingUnit: PendingUnitChange? = nil,
                     equipment: EquipmentIdentity? = nil,
                     paused: Bool = false,
                     ended: Date? = nil,
                     outcome: FieldSession.Outcome = .inProgress,
                     id: String = "s1",
                     startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FieldSession {
        var session = FieldSession(id: id, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: startedAt, endedAt: ended, pausedAt: paused ? Date() : nil,
                                   resumedAt: nil, outcome: outcome, startLocation: nil,
                                   endLocation: nil, escalations: [], billableSeconds: 0)
        session.jobReference = reference
        session.jobIntake = intake
        session.pendingUnitChange = pendingUnit
        session.equipment = equipment
        return session
    }

    private func identity(_ token: String) -> EquipmentIdentity {
        EquipmentIdentity(modelToken: token, heading: token, file: "models.md", source: .spoken)
    }

    // MARK: - The lens cue

    func testNoCueWithoutAnOpenJobOrAnOutstandingQuestion() {
        XCTAssertNil(JobQuestionHUDCue.cue(for: nil))
        XCTAssertNil(JobQuestionHUDCue.cue(for: job(intake: .recorded(reference: "1005"))))
        XCTAssertNil(JobQuestionHUDCue.cue(for: job(intake: .declined)))
        XCTAssertNil(JobQuestionHUDCue.cue(for: job(intake: .notRequired)))
        // "needsReference" is a question the app has not asked yet. Flashing it before it is
        // spoken would put the lens ahead of the voice.
        XCTAssertNil(JobQuestionHUDCue.cue(for: job(intake: .needsReference)))
        XCTAssertNil(JobQuestionHUDCue.cue(for: job(intake: .asked(attempts: 1),
                                                    ended: Date(), outcome: .resolved)))
    }

    func testTheReadBackCueCarriesTheNumberAndTheLongerWindow() throws {
        let cue = try XCTUnwrap(JobQuestionHUDCue.cue(
            for: job(intake: .confirming(candidate: "1005", attempts: 1))))
        XCTAssertEqual(cue.line, "Job 1005 — right?")
        XCTAssertEqual(cue.kind, JobQuestionHUDCue.Cue.Kind.readBack("1005"))
        XCTAssertEqual(cue.duration, JobQuestionHUDCue.questionSeconds)
    }

    func testTheOutstandingCueIsAReminderNotAQuestion() throws {
        let cue = try XCTUnwrap(JobQuestionHUDCue.cue(for: job(intake: .asked(attempts: 1))))
        XCTAssertEqual(cue.line, "Job number outstanding")
        XCTAssertEqual(cue.duration, JobQuestionHUDCue.reminderSeconds)
        XCTAssertEqual(JobQuestionHUDCue.cue(for: job(intake: .outstanding))?.kind,
                       JobQuestionHUDCue.Cue.Kind.jobNumberOutstanding)
    }

    func testTheUnitQuestionOutranksTheIntakeAndNamesTheJob() throws {
        let pending = PendingUnitChange(candidate: identity("SLP99"))
        let withNumber = try XCTUnwrap(JobQuestionHUDCue.cue(
            for: job(reference: "1005", intake: .confirming(candidate: "9", attempts: 1),
                     pendingUnit: pending)))
        XCTAssertEqual(withNumber.line, "Different unit — Job 1005 finished?")
        XCTAssertEqual(withNumber.kind, JobQuestionHUDCue.Cue.Kind.unitChange(jobReference: "1005"))

        let without = try XCTUnwrap(JobQuestionHUDCue.cue(for: job(pendingUnit: pending)))
        XCTAssertEqual(without.line, "Different unit — This job finished?")
    }

    /// Every cue fits what the lens can actually draw without being truncated by the shaper.
    func testEveryCueFitsTheLens() {
        let cues = [
            JobQuestionHUDCue.cue(for: job(intake: .confirming(candidate: "WO-1005/B", attempts: 1))),
            JobQuestionHUDCue.cue(for: job(intake: .asked(attempts: 1))),
            JobQuestionHUDCue.cue(for: job(reference: "1005",
                                           pendingUnit: PendingUnitChange(candidate: identity("SLP99")))),
        ].compactMap { $0 }
        XCTAssertEqual(cues.count, 3)
        for cue in cues {
            XCTAssertEqual(HUDTextShaper.condense(cue.line), cue.line,
                           "\(cue.line) would be shortened on the lens")
        }
    }

    // MARK: - CarPlay

    func testTheActiveJobIsFirstAndResumesThroughTheChokepoint() throws {
        let rows = CarPlayJobsList.rows(active: job(reference: "1005"),
                                        history: [job(ended: Date(), outcome: .resolved, id: "old")],
                                        boundThreadId: "thread-1")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].title, "Job 1005")
        XCTAssertEqual(rows[0].detail, "In progress")
        XCTAssertTrue(rows[0].isActiveJob)
        XCTAssertEqual(rows[0].selection, CarPlayJobsList.Selection.resumeActiveJob(threadId: "thread-1"))
    }

    func testAPausedJobSaysSoAndIsStillTheJob() throws {
        let rows = CarPlayJobsList.rows(active: job(reference: "1005", paused: true),
                                        history: [], boundThreadId: nil)
        XCTAssertEqual(rows.first?.detail, "Paused")
        XCTAssertEqual(rows.first?.selection, CarPlayJobsList.Selection.resumeActiveJob(threadId: nil))
    }

    func testAClosedOrCancelledJobIsNotTheActiveRow() {
        XCTAssertTrue(CarPlayJobsList.rows(active: job(ended: Date(), outcome: .resolved),
                                           history: [], boundThreadId: nil).isEmpty)
        XCTAssertTrue(CarPlayJobsList.rows(active: job(outcome: .cancelled),
                                           history: [], boundThreadId: nil).isEmpty)
    }

    func testPastJobsAreNewestFirstWithNumberDateAndOutcomeOnly() throws {
        let older = job(reference: "1001", ended: Date(), outcome: .resolved, id: "a",
                        startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        let newer = job(reference: "1002", ended: Date(), outcome: .escalated, id: "b",
                        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let rows = CarPlayJobsList.rows(active: nil, history: [older, newer], boundThreadId: nil)
        XCTAssertEqual(rows.map(\.title), ["Job 1002", "Job 1001"])
        XCTAssertEqual(rows[0].selection, CarPlayJobsList.Selection.speakPastJob(sessionId: "b"))
        // Date and outcome, and nothing from the work record.
        XCTAssertTrue(rows[0].detail.contains(FieldSession.Outcome.escalated.displayName))
        XCTAssertFalse(rows[0].detail.contains("minute"))
    }

    func testADeclinedNumberReadsAsNoJobNumberOnBothScreens() {
        let rows = CarPlayJobsList.rows(active: nil,
                                        history: [job(ended: Date(), outcome: .resolved)],
                                        boundThreadId: nil)
        XCTAssertEqual(rows.first?.title, CarPlayJobsList.noJobNumber)
        XCTAssertEqual(CarPlayJobsList.noJobNumber, JobTabModel.noJobNumber)
    }

    func testTheListIsBounded() {
        let history = (0..<40).map {
            job(reference: "\($0)", ended: Date(), outcome: .resolved, id: "s\($0)",
                startedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double($0)))
        }
        let rows = CarPlayJobsList.rows(active: nil, history: history, boundThreadId: nil)
        XCTAssertEqual(rows.count, CarPlayJobsList.pastJobLimit)
    }

    func testAnEmptyListSaysWhichOfTheTwoReasonsItIs() {
        XCTAssertEqual(CarPlayJobsList.emptyMessage(fieldAssistActive: false), "Field Assist is off.")
        XCTAssertTrue(CarPlayJobsList.emptyMessage(fieldAssistActive: true).contains("No jobs yet"))
    }

    func testARowSpeaksItsOwnTitleAndDetail() {
        let rows = CarPlayJobsList.rows(active: nil,
                                        history: [job(reference: "1005", ended: Date(),
                                                      outcome: .resolved)],
                                        boundThreadId: nil)
        XCTAssertTrue(rows[0].spoken.hasPrefix("Job 1005, "))
    }

    // MARK: - The watch

    func testNoPayloadWithoutAnOpenJob() {
        XCTAssertNil(JobWatchPayload.payload(for: nil))
        XCTAssertNil(JobWatchPayload.payload(for: job(ended: Date(), outcome: .resolved)))
        XCTAssertNil(JobWatchPayload.payload(for: job(outcome: .cancelled)))
    }

    func testThePayloadIsTheFourFieldsTheWristNeeds() throws {
        let payload = try XCTUnwrap(JobWatchPayload.payload(
            for: job(reference: "1005", intake: .recorded(reference: "1005"),
                     equipment: identity("SLP99"))))
        XCTAssertEqual(payload.jobNumber, "Job 1005")
        XCTAssertEqual(payload.state, "Running")
        XCTAssertEqual(payload.unit, "SLP99")
        XCTAssertEqual(payload.nextAction, "")
        XCTAssertEqual(Set(payload.dictionary.keys), ["jobNumber", "state", "unit", "nextAction"])
    }

    func testTheNextActionIsWhateverTheAppIsWaitingOn() throws {
        XCTAssertEqual(JobWatchPayload.nextAction(for: job(intake: .asked(attempts: 1))),
                       "Job number needed")
        XCTAssertEqual(JobWatchPayload.nextAction(
            for: job(intake: .confirming(candidate: "1005", attempts: 1))), "Confirm job 1005")
        XCTAssertEqual(JobWatchPayload.nextAction(for: job(intake: .outstanding)),
                       "Job number can be typed in")
        // The unit question outranks the number, as it does on the lens.
        XCTAssertEqual(JobWatchPayload.nextAction(
            for: job(intake: .asked(attempts: 1),
                     pendingUnit: PendingUnitChange(candidate: identity("SLP99")))),
                       "Answer: same job, or finished?")
    }

    func testATaskInHandIsReportedOnlyWhenNothingIsBeingAsked() throws {
        var open = job(intake: .recorded(reference: "1005"), equipment: identity("SLP99"))
        open.tasks = [FieldSession.Task(id: "t1", title: "Check the pressure switch",
                                        origin: .recommended, status: .inProgress)]
        XCTAssertEqual(JobWatchPayload.nextAction(for: open), "On: Check the pressure switch")
    }

    func testAPausedJobSaysPausedOnTheWrist() throws {
        XCTAssertEqual(JobWatchPayload.payload(for: job(paused: true))?.state, "Paused")
    }

    func testEveryValueIsBounded() throws {
        let long = String(repeating: "A", count: 500)
        var open = job(reference: long, intake: .recorded(reference: long), equipment: identity(long))
        open.tasks = [FieldSession.Task(id: "t1", title: long, origin: .recommended, status: .inProgress)]
        let payload = try XCTUnwrap(JobWatchPayload.payload(for: open))
        for value in payload.dictionary.values {
            XCTAssertLessThanOrEqual(value.count, JobWatchPayload.valueLimit)
        }
    }

    // MARK: - The trigger set

    /// One publisher drives all three surfaces, and the key it is de-duplicated on changes exactly
    /// when one of them would draw something different — the plan's three triggers (a tool
    /// mutation, an equipment change, an intake change) and nothing else.
    func testTheRefreshKeyMovesOnEveryTriggerAndOnNothingElse() {
        let base = job(reference: "1005", intake: .recorded(reference: "1005"))
        let unchanged = JobSurfaceRefresh.key(for: base)
        XCTAssertEqual(JobSurfaceRefresh.key(for: base), unchanged)

        // A tool mutation that nothing shows: billing seconds tick on their own.
        var billing = base
        billing.billableSeconds = 400
        XCTAssertEqual(JobSurfaceRefresh.key(for: billing), unchanged)

        // Equipment change.
        var equipment = base
        equipment.equipment = identity("SLP99")
        XCTAssertNotEqual(JobSurfaceRefresh.key(for: equipment), unchanged)

        // Intake change.
        var intake = base
        intake.jobIntake = .confirming(candidate: "1006", attempts: 1)
        XCTAssertNotEqual(JobSurfaceRefresh.key(for: intake), unchanged)

        // A tool mutation that shows: a task started.
        var task = base
        task.tasks = [FieldSession.Task(id: "t", title: "Check the flue", origin: .recommended,
                                        status: .inProgress)]
        XCTAssertNotEqual(JobSurfaceRefresh.key(for: task), unchanged)

        // The unit question being raised, and the job closing.
        var unit = base
        unit.pendingUnitChange = PendingUnitChange(candidate: identity("SLP99"))
        XCTAssertNotEqual(JobSurfaceRefresh.key(for: unit), unchanged)
        var closed = base
        closed.endedAt = Date()
        closed.outcome = .resolved
        XCTAssertNotEqual(JobSurfaceRefresh.key(for: closed), unchanged)
        XCTAssertEqual(JobSurfaceRefresh.key(for: closed), JobSurfaceRefresh.key(for: nil))
    }
}
