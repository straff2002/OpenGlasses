import XCTest
@testable import OpenGlasses

/// Plan HB — the job-day card's composition: today's jobs in time order, the job admin still owed,
/// My Day folded below, the empty day and the summary line. Pure; a fixed clock and calendar.
final class JobDayComposerTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-10-02 08:00 UTC.
    private var now: Date { at(day: 2, hour: 8) }

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func time(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    private func dayTime(_ date: Date) -> String {
        "day \(calendar.component(.day, from: date)) \(time(date))"
    }

    private func inputs(upcoming: [UpcomingJob] = [], sessions: [JobDaySession] = [],
                        queue: [QueuedSend] = [], debrief: JobDayDebrief? = nil,
                        signOffRequired: Bool = false, recordings: [JobDayRecording] = [],
                        personal: [MyDayItem]? = nil) -> JobDayInputs {
        JobDayInputs(now: now, calendar: calendar, upcoming: upcoming, sessions: sessions, queue: queue,
                     debrief: debrief, signOffRequired: signOffRequired, recordings: recordings,
                     personal: personal, timeText: time, dayTimeText: dayTime)
    }

    private func upcoming(_ id: String, ref: String?, customer: String?, at date: Date?) -> UpcomingJob {
        UpcomingJob(id: id, jobReference: ref, site: JobSite(customer: customer, address: "1 High St"),
                    scheduledFor: date, origin: .typed, createdAt: at(day: 1, hour: 9))
    }

    private func session(_ id: String, ref: String?, started: Date, ended: Date? = nil,
                         paused: Bool = false, cancelled: Bool = false, reportSent: Bool = false,
                         signedOff: Bool = false, parts: Int = 0, customer: String? = nil) -> JobDaySession {
        JobDaySession(id: id, jobReference: ref, customer: customer,
                      siteHeadline: customer.map { "\($0), 1 High St" }, startedAt: started, endedAt: ended,
                      isPaused: paused, cancelled: cancelled, reportSent: reportSent, signedOff: signedOff,
                      openPartsRequests: parts)
    }

    private func send(_ id: String, session: String, state: QueuedSend.State, created: Date,
                      updated: Date? = nil, kind: QueuedSend.DocumentKind = .report,
                      reason: String? = nil) -> QueuedSend {
        QueuedSend(id: id, sessionId: session, jobNumber: "Job \(session)", documentKind: kind,
                   channel: .email, recipients: ["office@example.com"], recipientSource: .deliverySettings,
                   createdAt: created, updatedAt: updated, state: state, failureReason: reason)
    }

    // MARK: - Jobs

    func testTodaysJobsAreInTimeOrderWithTheirStatus() {
        let day = JobDayComposer.compose(inputs(
            upcoming: [upcoming("u2", ref: "1007", customer: "Harbour", at: at(day: 2, hour: 14)),
                       upcoming("u1", ref: "1006", customer: "Smith & Co", at: at(day: 2, hour: 10, minute: 30)),
                       upcoming("u3", ref: "1008", customer: "Acme", at: at(day: 3, hour: 9)),
                       upcoming("u4", ref: "1009", customer: "Nobody", at: nil)],
            sessions: [session("s1", ref: "1005", started: at(day: 2, hour: 7, minute: 15)),
                       session("s0", ref: "1004", started: at(day: 2, hour: 6),
                               ended: at(day: 2, hour: 7), reportSent: true)]))

        XCTAssertEqual(day.jobs.map(\.title), ["Job 1004", "Job 1005", "Job 1006", "Job 1007"],
                       "tomorrow's job and an unscheduled one are not today's")
        XCTAssertEqual(day.jobs.map(\.status), [.done, .inProgress, .scheduled, .scheduled])
        XCTAssertEqual(day.jobs.map(\.timeText), ["06:00", "07:15", "10:30", "14:00"])
        XCTAssertEqual(day.jobs[2].site, "Smith & Co, 1 High St")
        XCTAssertEqual(day.jobs.map(\.destination),
                       [.pastJob(sessionId: "s0"), .openJob, .upcomingJob(id: "u1"), .upcomingJob(id: "u2")])
        XCTAssertNil(day.next, "a day with jobs has no 'next job' line")
    }

    func testAJobScheduledEarlierAndNeverStartedIsOverdueNotDropped() {
        let day = JobDayComposer.compose(inputs(
            upcoming: [upcoming("u0", ref: "1001", customer: "Late Ltd", at: at(day: 1, hour: 15))]))
        XCTAssertEqual(day.jobs.map(\.status), [.overdue])
        XCTAssertEqual(day.jobs.first?.timeText, "day 1 15:00", "another day's time says which day")
        XCTAssertEqual(day.summary, "1 job · Late Ltd overdue")
    }

    func testAPausedJobOpenSinceYesterdayIsStillToday() {
        let day = JobDayComposer.compose(inputs(
            sessions: [session("s1", ref: "1005", started: at(day: 1, hour: 16), paused: true)]))
        XCTAssertEqual(day.jobs.map(\.status), [.paused])
        XCTAssertEqual(day.summary, "1 job · Job 1005 paused")
    }

    func testCancelledAndOlderFinishedJobsAreLeftOut() {
        let day = JobDayComposer.compose(inputs(sessions: [
            session("c", ref: "1", started: at(day: 2, hour: 6), ended: at(day: 2, hour: 6, minute: 5), cancelled: true),
            session("old", ref: "2", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10)),
        ]))
        XCTAssertTrue(day.jobs.isEmpty)
        XCTAssertTrue(day.todos.isEmpty, "yesterday's unsent report is the Jobs tab's, not today's card's")
    }

    func testAJobWithNoNumberIsNamedAsSuch() {
        let day = JobDayComposer.compose(inputs(sessions: [session("s", ref: nil, started: at(day: 2, hour: 7))]))
        XCTAssertEqual(day.jobs.first?.title, JobTabModel.noJobNumber)
    }

    // MARK: - Still to do

    func testTheStillToDoStripInItsOrderWithRoutes() {
        let day = JobDayComposer.compose(inputs(
            sessions: [session("open", ref: "1005", started: at(day: 2, hour: 7), parts: 2),
                       session("done", ref: "1004", started: at(day: 2, hour: 5),
                               ended: at(day: 2, hour: 6), parts: 1)],
            queue: [send("q1", session: "x", state: .staged, created: at(day: 1, hour: 18)),
                    send("q2", session: "y", state: .failed, created: at(day: 2, hour: 6),
                         updated: at(day: 2, hour: 6, minute: 30), reason: "no mail account")],
            debrief: JobDayDebrief(sessionId: "done", label: "Job 1004"),
            signOffRequired: true))

        XCTAssertEqual(day.todos.map(\.kind),
                       [.debrief, .reportFailed, .reportStaged, .reportNotSent, .signOff, .parts, .parts])
        XCTAssertEqual(day.todos.map(\.destination), [
            .pastJob(sessionId: "done"),
            .send(queuedId: "q2"),
            .send(queuedId: "q1"),
            .pastJob(sessionId: "done"),
            .pastJob(sessionId: "done"),
            .pastJob(sessionId: "done"),
            .openJob,
        ], "parts follow the jobs' own order: the 5:00 job, then the open one")
        XCTAssertEqual(day.todos[1].detail, "Work order · Job y — no mail account")
        XCTAssertEqual(day.todos[5].title, "Parts request waiting")
        XCTAssertEqual(day.todos[6].title, "2 parts requests waiting")
    }

    func testEachKindAppearsOnlyWhenThereIsSomethingOwed() {
        let day = JobDayComposer.compose(inputs(
            sessions: [session("done", ref: "1004", started: at(day: 2, hour: 5), ended: at(day: 2, hour: 6),
                               reportSent: true, signedOff: true)],
            signOffRequired: true))
        XCTAssertTrue(day.todos.isEmpty)
        XCTAssertEqual(day.summary, "1 job · all done")
    }

    func testSignOffIsOwedOnlyWhenTheOrganisationRequiresItAndTheReportHasNotGone() {
        let unsigned = session("done", ref: "1004", started: at(day: 2, hour: 5), ended: at(day: 2, hour: 6))
        XCTAssertFalse(JobDayComposer.compose(inputs(sessions: [unsigned], signOffRequired: false))
            .todos.contains { $0.kind == .signOff })
        XCTAssertTrue(JobDayComposer.compose(inputs(sessions: [unsigned], signOffRequired: true))
            .todos.contains { $0.kind == .signOff })
        var sent = unsigned; sent.reportSent = true
        XCTAssertFalse(JobDayComposer.compose(inputs(sessions: [sent], signOffRequired: true))
            .todos.contains { $0.kind == .signOff },
                       "a signature after the work order left would describe a document nobody holds")
    }

    func testAReportAlreadyInTheQueueIsNotAlsoNotSent() {
        let done = session("done", ref: "1004", started: at(day: 2, hour: 5), ended: at(day: 2, hour: 6))
        let day = JobDayComposer.compose(inputs(
            sessions: [done], queue: [send("q", session: "done", state: .staged, created: at(day: 2, hour: 6))]))
        XCTAssertEqual(day.todos.map(\.kind), [.reportStaged])
        XCTAssertEqual(day.summary, "1 job · all done — 1 report to send")
    }

    func testAFailedSendIsOwedForAWeekAndUntilSomethingLaterGoes() {
        let old = send("old", session: "a", state: .failed, created: at(day: 20, hour: 9).addingTimeInterval(-30 * 86_400),
                       updated: at(day: 20, hour: 9).addingTimeInterval(-30 * 86_400))
        let recent = send("recent", session: "b", state: .failed, created: at(day: 1, hour: 9))
        let superseded = send("sup", session: "c", state: .failed, created: at(day: 1, hour: 9))
        let resent = send("resent", session: "c", state: .sent, created: at(day: 1, hour: 10))
        let addendumFailed = send("add", session: "c", state: .failed, created: at(day: 1, hour: 11), kind: .addendum)
        let owed = JobDayComposer.owedFailures([old, recent, superseded, resent, addendumFailed], now: now)
        XCTAssertEqual(owed.map(\.id), ["recent", "add"],
                       "a month-old failure is history; a re-sent report is not owed; another document is")
    }

    func testInFlightAndCancelledSendsAreNotToDos() {
        let day = JobDayComposer.compose(inputs(queue: [
            send("a", session: "x", state: .sending, created: at(day: 2, hour: 7)),
            send("b", session: "x", state: .cancelled, created: at(day: 2, hour: 7)),
            send("c", session: "x", state: .sent, created: at(day: 2, hour: 7)),
        ]))
        XCTAssertTrue(day.todos.isEmpty)
    }

    func testADebriefOnTheOpenJobRoutesToTheJobsTab() {
        let day = JobDayComposer.compose(inputs(
            sessions: [session("open", ref: "1005", started: at(day: 2, hour: 7))],
            debrief: JobDayDebrief(sessionId: "open", label: "Job 1005")))
        XCTAssertEqual(day.todos.first?.destination, .openJob)
        XCTAssertEqual(day.todos.first?.detail, "Job 1005 — not saved yet")
    }

    // MARK: - A recording not yet with the office (Plan HE)

    private func recordingRow(_ phase: BundleSyncState.Phase, session: String = "done",
                              outcome: JobRecordingBundleStore.Outcome? = nil) -> JobRecordingSyncService.Row {
        .init(id: "b-\(session)", sessionID: session, phase: phase, sentBytes: 50, totalBytes: 200, outcome: outcome)
    }

    /// The day with one finished job, and that job's recording standing where `phase` says.
    private func dayWithRecording(_ phase: BundleSyncState.Phase) -> JobDay {
        let done = session("done", ref: "1004", started: at(day: 2, hour: 5), ended: at(day: 2, hour: 6),
                           reportSent: true)
        return JobDayComposer.compose(inputs(
            sessions: [done],
            recordings: [JobRecordingOwed.sealed(recordingRow(phase), label: done.label)].compactMap { $0 }))
    }

    func testAJobWithNoRecordingOwesNothingForOne() {
        let done = session("done", ref: "1004", started: at(day: 2, hour: 5), ended: at(day: 2, hour: 6),
                           reportSent: true)
        let day = JobDayComposer.compose(inputs(sessions: [done]))
        XCTAssertTrue(day.todos.isEmpty)
        XCTAssertEqual(day.summary, "1 job · all done", "nothing changes for a job that was not recorded")
    }

    /// With no office transport in the build neither service exists, and nothing is gathered.
    @MainActor
    func testWithNoOfficeToRecordForNothingIsGathered() {
        XCTAssertEqual(JobRecordingOwed.gather(coordinator: nil, sync: nil, label: { _ in "Job 1004" }), [])
    }

    func testNothingIsOwedOnceTheOfficeHasConfirmedTheRecording() {
        let published = JobRecordingBundleStore.Outcome(status: "published", vaultID: "v", vaultVersion: "1", at: 0)
        for phase in [BundleSyncState.Phase.acknowledged, .trimmed] {
            XCTAssertNil(JobRecordingOwed.sealed(recordingRow(phase), label: "Job 1004"))
            XCTAssertNil(JobRecordingOwed.sealed(recordingRow(phase, outcome: published), label: "Job 1004"))
            XCTAssertTrue(dayWithRecording(phase).todos.isEmpty)
        }
    }

    func testAWaitingRecordingIsOwedAndSaysWhy() {
        let expected: [(SyncEligibility.Reason, String)] = [
            (.noNetwork, "Waiting for Wi-Fi."),
            (.waitingForWiFi, "Waiting for Wi-Fi. Recordings aren't sent over mobile data unless you allow it."),
            (.waitingForPower, "Waiting for power. Plug the phone in to send the recording."),
            (.officeNotReachable, "The office can't be reached from here. The recording will be sent when it can."),
            (.smallerItemsFirst, "Job reports are being sent first."),
        ]
        for (reason, sentence) in expected {
            let todo = dayWithRecording(.waiting(.notEligible(reason))).todos.first
            XCTAssertEqual(todo?.kind, .recording)
            XCTAssertEqual(todo?.title, "Recording waiting to sync")
            XCTAssertEqual(todo?.detail, "Job 1004 — \(sentence)")
            XCTAssertEqual(todo?.destination, .pastJob(sessionId: "done"))
            XCTAssertEqual(todo?.sessionId, "done")
        }
        // Every reason there is has its own sentence, and is the one shown.
        for reason in SyncEligibility.Reason.allCases where reason != .blurRequired {
            XCTAssertEqual(dayWithRecording(.waiting(.notEligible(reason))).todos.first?.detail,
                           "Job 1004 — \(reason.explanation)")
        }
        // Just sealed, before a pass has said why it waits: owed, with no reason invented.
        let sealed = dayWithRecording(.sealed).todos.first
        XCTAssertEqual(sealed?.title, "Recording waiting to sync")
        XCTAssertEqual(sealed?.detail, "Job 1004")
        XCTAssertEqual(dayWithRecording(.sealed).summary, "1 job · all done — 1 recording not yet with the office")
    }

    /// A recording that has stopped and is not sealed has never left the phone: it is owed too.
    func testARecordingWaitingToBePreparedIsOwedAndSaysToOpenTheApp() {
        func todo(_ waiting: JobRecordingCoordinator.Waiting) -> JobDay.Todo? {
            JobDayComposer.compose(inputs(
                sessions: [session("open", ref: "1005", started: at(day: 2, hour: 7))],
                recordings: [JobRecordingOwed.unsealed(sessionId: "open", waiting: waiting, label: "Job 1005")]))
                .todos.first
        }
        let blur = todo(.forTheAppToBeOpen)
        XCTAssertEqual(blur?.kind, .recording)
        XCTAssertEqual(blur?.title, "Recording waiting to sync")
        XCTAssertEqual(blur?.detail, "Job 1005 — Open Avenkin to prepare the recording.")
        XCTAssertEqual(blur?.destination, .openJob, "the job is the open one")

        XCTAssertEqual(todo(.beingPrepared)?.detail, "Job 1005 — Preparing the recording.")
        XCTAssertEqual(todo(.toBePrepared)?.detail,
                       "Job 1005 — The recording is saved on this phone, and will be prepared for the office later.")
        XCTAssertEqual(todo(.interrupted)?.detail,
                       "Job 1005 — A recording of this job was interrupted. What had been recorded is saved.")
        // The sync state's own wait for the app says the same thing.
        XCTAssertEqual(dayWithRecording(.waiting(.openAppToPrepare)).todos.first?.detail,
                       "Job 1004 — Open Avenkin to prepare the recording.")
        XCTAssertEqual(dayWithRecording(.preparing).todos.first?.detail, "Job 1004 — Preparing the recording.")
    }

    func testARecordingOnItsWaySaysHowFarAndOneAllServedIsSentNotReceived() {
        let going = dayWithRecording(.transferring(sentBytes: 50, totalBytes: 200)).todos.first
        XCTAssertEqual(going?.title, "Sending the recording to the office")
        XCTAssertEqual(going?.detail, "Job 1004 — 25% of 200 bytes.")

        let sent = dayWithRecording(.delivered).todos.first
        XCTAssertEqual(sent?.kind, .recording, "sent is still owed: the office has not said it has it")
        XCTAssertEqual(sent?.title, "Recording sent")
        XCTAssertEqual(sent?.detail, "Job 1004 — Waiting for the office to confirm it.")
    }

    func testARecordingTheTechnicianHasToDecideAboutIsAWarning() {
        let stuck: [(BundleSyncState.Phase, String)] = [
            (.failed(.tooLarge), "The office didn't accept the recording (it is too large). It is still on this phone."),
            (.expired, "The office hasn't confirmed this recording in a long time. It is still on this phone."),
            (.waiting(.notEligible(.blurRequired)), SyncEligibility.Reason.blurRequired.explanation),
        ]
        for (phase, sentence) in stuck {
            let day = dayWithRecording(phase)
            let todo = day.todos.first
            XCTAssertEqual(todo?.kind, .recordingAttention)
            XCTAssertEqual(todo?.kind.isWarning, true)
            XCTAssertEqual(todo?.title, "Recording needs attention")
            XCTAssertEqual(todo?.detail, "Job 1004 — \(sentence)")
            XCTAssertEqual(day.summary, "1 job · all done — 1 recording needs attention")
        }
    }

    /// "Received" is the office's word, said on its verified receipt and on the job's page. No
    /// owed item says it, in any state.
    func testNoOwedRecordingIsEverSaidToBeReceived() {
        var phases: [BundleSyncState.Phase] = [.recording, .preparing, .sealed, .waiting(.openAppToPrepare),
                                               .transferring(sentBytes: 10, totalBytes: 100), .delivered, .expired]
        phases += SyncEligibility.Reason.allCases.map { .waiting(.notEligible($0)) }
        phases += BundleSyncState.RefusalReason.allCases.map { .failed($0) }
        for phase in phases {
            let item = JobRecordingOwed.sealed(recordingRow(phase), label: "Job 1004")
            XCTAssertNotNil(item, "\(phase) is not with the office, so it is owed")
            XCTAssertFalse(item?.sentence.lowercased().contains("received") ?? true, item?.sentence ?? "")
        }
        for waiting in [JobRecordingCoordinator.Waiting.beingPrepared, .forTheAppToBeOpen, .interrupted, .toBePrepared] {
            let item = JobRecordingOwed.unsealed(sessionId: "s", waiting: waiting, label: "Job 1004")
            XCTAssertFalse(item.sentence.lowercased().contains("received"), item.sentence)
            XCTAssertFalse(item.needsAttention)
        }
    }

    /// The only copy of a recording is owed for as long as it is the only copy, whichever day its
    /// job was — and it comes after the admin a technician can act on now.
    func testARecordingOfAnEarlierJobIsStillOwedAndComesLast() {
        let day = JobDayComposer.compose(inputs(
            sessions: [session("open", ref: "1005", started: at(day: 2, hour: 7), parts: 1)],
            recordings: [
                JobDayRecording(sessionId: "last-week", label: "Job 0990", title: JobDayRecording.waitingTitle,
                                reason: "Waiting for Wi-Fi."),
                JobDayRecording(sessionId: "last-week", label: "Job 0990", title: JobDayRecording.sentTitle,
                                reason: nil),
                JobDayRecording(sessionId: "open", label: "Job 1005", title: JobDayRecording.attentionTitle,
                                reason: "Held.", needsAttention: true),
            ]))
        XCTAssertEqual(day.todos.map(\.kind), [.parts, .recordingAttention, .recording],
                       "one row a job, and the one that needs a decision before the one that only waits")
        XCTAssertEqual(day.todos.map(\.destination), [.openJob, .openJob, .pastJob(sessionId: "last-week")])
        XCTAssertEqual(day.todos.last?.detail, "Job 0990 — Waiting for Wi-Fi.")
        XCTAssertEqual(day.todos.last?.spoken, "Recording waiting to sync, Job 0990 — Waiting for Wi-Fi.")
        XCTAssertEqual(JobDayComposer.todoPhrase(Array(day.todos.suffix(1))), "1 recording not yet with the office")
        XCTAssertEqual(JobDayComposer.todoPhrase(day.todos), "3 things to do")
    }

    // MARK: - My Day folded in

    func testPersonalItemsOnlyWhenAsked() {
        let item = MyDayItem(id: MyDayItemID(source: .calendar, rawValue: "e1"), kind: .event,
                             title: "Dentist", detail: "4:00 PM", dueAt: nil, urgency: .routine, actions: [])
        let shown = JobDayComposer.compose(inputs(personal: [item]))
        XCTAssertTrue(shown.showsPersonal)
        XCTAssertEqual(shown.personal.map(\.title), ["Dentist"])
        XCTAssertEqual(shown.summary, "No jobs", "the summary line is the job day's, not the personal part's")

        let hidden = JobDayComposer.compose(inputs(personal: nil))
        XCTAssertFalse(hidden.showsPersonal)
        XCTAssertTrue(hidden.personal.isEmpty)
    }

    // MARK: - The empty day

    func testAnEmptyDayNamesTheNextScheduledJob() {
        let day = JobDayComposer.compose(inputs(
            upcoming: [upcoming("later", ref: "1009", customer: "Later Co", at: at(day: 5, hour: 8)),
                       upcoming("next", ref: "1008", customer: "Acme", at: at(day: 3, hour: 9)),
                       upcoming("none", ref: "1010", customer: "Whenever", at: nil)]))
        XCTAssertTrue(day.isEmptyDay)
        XCTAssertEqual(day.next, JobDay.Next(id: "next", title: "Acme", whenText: "day 3 09:00",
                                             destination: .upcomingJob(id: "next")))
        XCTAssertEqual(day.summary, "No jobs · next day 3 09:00 Acme")
    }

    func testANothingScheduledDay() {
        let day = JobDayComposer.compose(inputs())
        XCTAssertTrue(day.isEmptyDay)
        XCTAssertNil(day.next)
        XCTAssertEqual(day.summary, "No jobs")
        XCTAssertEqual(day.spokenSummary, "Today, no jobs.")
    }

    // MARK: - The summary line

    func testTheSummaryLineGreigDescribed() {
        let day = JobDayComposer.compose(inputs(
            upcoming: [upcoming("u1", ref: "1006", customer: "Smith & Co", at: at(day: 2, hour: 10, minute: 30)),
                       upcoming("u2", ref: "1007", customer: "Harbour", at: at(day: 2, hour: 14))],
            sessions: [session("s0", ref: "1004", started: at(day: 2, hour: 6), ended: at(day: 2, hour: 7),
                               reportSent: true)],
            queue: [send("q1", session: "s0", state: .staged, created: at(day: 2, hour: 7), kind: .addendum)]))
        XCTAssertEqual(day.summary, "3 jobs · next 10:30 Smith & Co — 1 report to send")
        XCTAssertEqual(day.spokenSummary, "Today, 3 jobs, next at 10:30, Smith & Co. 1 report to send.")
    }

    func testTheOpenJobLeadsTheSummary() {
        let day = JobDayComposer.compose(inputs(
            upcoming: [upcoming("u1", ref: "1006", customer: "Smith & Co", at: at(day: 2, hour: 10))],
            sessions: [session("s1", ref: "1005", started: at(day: 2, hour: 7))]))
        XCTAssertEqual(day.summary, "2 jobs · on Job 1005")
    }

    func testTheToDoPhrase() {
        func todo(_ kind: JobDay.Todo.Kind, _ id: String) -> JobDay.Todo {
            .init(id: id, kind: kind, title: "", detail: nil, destination: .openJob)
        }
        XCTAssertNil(JobDayComposer.todoPhrase([]))
        XCTAssertEqual(JobDayComposer.todoPhrase([todo(.signOff, "a")]), "1 sign-off owed")
        XCTAssertEqual(JobDayComposer.todoPhrase([todo(.parts, "a"), todo(.parts, "b")]), "2 parts requests waiting")
        XCTAssertEqual(JobDayComposer.todoPhrase([todo(.reportFailed, "a"), todo(.reportStaged, "b")]),
                       "2 reports to send")
        XCTAssertEqual(JobDayComposer.todoPhrase([todo(.debrief, "a"), todo(.parts, "b"), todo(.signOff, "c")]),
                       "3 things to do")
    }

    func testRowsSpeakAsOneSentence() {
        let day = JobDayComposer.compose(inputs(
            upcoming: [upcoming("u1", ref: "1006", customer: "Smith & Co", at: at(day: 2, hour: 10, minute: 30))]))
        XCTAssertEqual(day.jobs.first?.spoken, "10:30, Job 1006, Smith & Co, 1 High St, Scheduled")
    }
}
