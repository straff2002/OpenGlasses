import XCTest
@testable import OpenGlasses

/// Plan HC — the Jobs list: its sections and their order, the badges (the job-day card's own
/// to-do rules over a wider scope), search, the empty list and the older-jobs paging. Pure; a fixed
/// clock and calendar.
final class JobListComposerTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-10-02 08:00 UTC, a Friday.
    private var now: Date { at(day: 2, hour: 8) }

    private func at(day: Int, hour: Int, minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func time(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    private func date(_ date: Date) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month!)/\(c.day!) \(time(date))"
    }

    private func inputs(open: JobListSession? = nil, finished: [JobListSession] = [],
                        upcoming: [UpcomingJob] = [], queue: [QueuedSend] = [],
                        debrief: JobDayDebrief? = nil, signOffRequired: Bool = false,
                        query: String = "") -> JobListInputs {
        JobListInputs(now: now, calendar: calendar, open: open, finished: finished, upcoming: upcoming,
                      queue: queue, debrief: debrief, signOffRequired: signOffRequired, query: query,
                      dateText: date, timeText: time)
    }

    private func session(_ id: String, ref: String?, started: Date, ended: Date? = nil,
                         paused: Bool = false, cancelled: Bool = false, reportSent: Bool = true,
                         signedOff: Bool = false, parts: Int = 0, customer: String? = nil,
                         equipment: String? = nil, outcome: String = "Resolved") -> JobListSession {
        JobListSession(
            facts: JobDaySession(id: id, jobReference: ref, customer: customer,
                                 siteHeadline: customer.map { "\($0), 1 High St" }, startedAt: started,
                                 endedAt: ended, isPaused: paused, cancelled: cancelled,
                                 reportSent: reportSent, signedOff: signedOff, openPartsRequests: parts),
            vaultName: "Lennox", equipment: equipment, outcomeLabel: outcome, billingLine: "1 h billable")
    }

    private func upcoming(_ id: String, ref: String?, customer: String?, at date: Date?,
                          provenance: JobFileProvenance? = nil) -> UpcomingJob {
        var job = UpcomingJob(id: id, jobReference: ref, site: JobSite(customer: customer, address: "1 High St"),
                              scheduledFor: date, origin: .typed, createdAt: at(day: 1, hour: 9))
        job.provenance = provenance
        return job
    }

    private func send(_ id: String, session: String, state: QueuedSend.State, created: Date,
                      kind: QueuedSend.DocumentKind = .report) -> QueuedSend {
        QueuedSend(id: id, sessionId: session, jobNumber: "Job \(session)", documentKind: kind,
                   channel: .email, recipients: ["office@example.com"], recipientSource: .deliverySettings,
                   createdAt: created, updatedAt: created, state: state, failureReason: nil)
    }

    private func badges(_ item: JobList.Item?) -> [JobList.Badge.Kind] { item?.badges.map(\.kind) ?? [] }

    // MARK: - Empty

    func testNothingAtAllIsTheEmptyList() {
        let list = JobListComposer.compose(inputs())
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(list.open)
        XCTAssertNil(list.results, "no search typed is no results section")
        XCTAssertEqual(JobList.emptyTitle, "No jobs yet")
        XCTAssertTrue(JobList.emptyMessage.contains("start a job"),
                      "the empty list says the voice route too")
    }

    func testOneScheduledJobIsNotEmpty() {
        XCTAssertFalse(JobListComposer.compose(inputs(
            upcoming: [upcoming("u1", ref: "1006", customer: "Acme", at: nil)])).isEmpty)
    }

    // MARK: - Sections and order

    func testTheSectionsAndTheirOrder() {
        let list = JobListComposer.compose(inputs(
            open: session("s9", ref: "1009", started: at(day: 2, hour: 7)),
            finished: [session("s1", ref: "1001", started: at(day: 20, hour: 9, month: 9),
                               ended: at(day: 20, hour: 10, month: 9)),
                       session("s3", ref: "1003", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10)),
                       session("s2", ref: "1002", started: at(day: 28, hour: 9, month: 9),
                               ended: at(day: 28, hour: 10, month: 9))],
            upcoming: [upcoming("later", ref: "1012", customer: "Acme", at: at(day: 5, hour: 9)),
                       upcoming("undated", ref: "1013", customer: "Nobody", at: nil),
                       upcoming("today", ref: "1011", customer: "Smith & Co", at: at(day: 2, hour: 14)),
                       upcoming("late", ref: "1010", customer: "Harbour", at: at(day: 30, hour: 9, month: 9))]))

        XCTAssertEqual(list.open?.title, "Job 1009")
        XCTAssertEqual(list.open?.route, .currentJob)
        XCTAssertEqual(list.scheduled.map(\.title), ["Job 1010", "Job 1011", "Job 1012", "Job 1013"],
                       "overdue first (the earliest), then soonest, the undated last")
        XCTAssertEqual(list.scheduled.map(\.status), [.overdue, .scheduled, .scheduled, .unscheduled])
        XCTAssertEqual(list.scheduled.map(\.route), [.upcomingJob(id: "late"), .upcomingJob(id: "today"),
                                                    .upcomingJob(id: "later"), .upcomingJob(id: "undated")])
        XCTAssertEqual(list.recent.map(\.title), ["Job 1003", "Job 1002"],
                       "finished in the last seven days, newest first")
        XCTAssertEqual(list.older.map(\.title), ["Job 1001"])
        XCTAssertEqual(list.recent.first?.route, .pastJob(sessionId: "s3"))
    }

    func testRecentMeansTodayAndTheSixDaysBefore() {
        // Six days back at midnight is recent; a minute before it is not.
        let list = JobListComposer.compose(inputs(finished: [
            session("in", ref: "1", started: at(day: 26, hour: 0, month: 9), ended: at(day: 26, hour: 0, month: 9)),
            session("out", ref: "2", started: at(day: 25, hour: 23, month: 9),
                    ended: at(day: 25, hour: 23, minute: 59, month: 9)),
        ]))
        XCTAssertEqual(list.recent.map(\.title), ["Job 1"])
        XCTAssertEqual(list.older.map(\.title), ["Job 2"])
    }

    func testAPausedOpenJobSaysSo() {
        let list = JobListComposer.compose(inputs(
            open: session("s1", ref: "1005", started: at(day: 2, hour: 7, minute: 15), paused: true,
                          customer: "Smith & Co", equipment: "SLP99")))
        XCTAssertEqual(list.open?.status, .paused)
        XCTAssertEqual(list.open?.status.label, "Paused")
        XCTAssertEqual(list.open?.detail, "Started 07:15 · Smith & Co · SLP99")
    }

    func testAJobWithNoNumberIsNeverBlank() {
        let list = JobListComposer.compose(inputs(
            open: session("s1", ref: nil, started: at(day: 2, hour: 7)),
            finished: [session("s0", ref: "", started: at(day: 1, hour: 7), ended: at(day: 1, hour: 8))]))
        XCTAssertEqual(list.open?.title, JobTabModel.noJobNumber)
        XCTAssertEqual(list.recent.first?.title, JobTabModel.noJobNumber)
    }

    func testAScheduledRowSaysWhenAndWhere() {
        let signed = JobFileProvenance(fileName: "1011.ogjob", signature: .signed,
                                       signer: "Smith Refrigeration", receivedAt: at(day: 1, hour: 9),
                                       digest: "abc")
        let list = JobListComposer.compose(inputs(upcoming: [
            upcoming("today", ref: "1011", customer: "Smith & Co", at: at(day: 2, hour: 14), provenance: signed),
            upcoming("late", ref: nil, customer: "Harbour", at: at(day: 30, hour: 9, month: 9)),
            upcoming("undated", ref: "1013", customer: nil, at: nil),
        ]))
        let byId = Dictionary(uniqueKeysWithValues: list.scheduled.map { ($0.id, $0) })
        XCTAssertEqual(byId["upcoming-today"]?.detail, "Smith & Co, 1 High St · Today 14:00")
        XCTAssertEqual(byId["upcoming-today"]?.note, "Signed by Smith Refrigeration")
        XCTAssertEqual(byId["upcoming-today"]?.noteIsWarning, false)
        XCTAssertEqual(byId["upcoming-late"]?.title, "Harbour, 1 High St", "no number: the site is the title")
        XCTAssertEqual(byId["upcoming-late"]?.detail, "Was due 9/30 09:00", "and is not said twice")
        XCTAssertEqual(byId["upcoming-late"]?.badges.map(\.kind), [.overdue])
        XCTAssertEqual(byId["upcoming-undated"]?.detail, "1 High St · No date set")
    }

    func testAFinishedRowCarriesItsDateMachineAndBilling() {
        let list = JobListComposer.compose(inputs(finished: [
            session("s1", ref: "1004", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10),
                    customer: "Acme", equipment: "SLP99", outcome: "Deferred"),
            session("s2", ref: "1003", started: at(day: 1, hour: 7), ended: at(day: 1, hour: 8)),
        ]))
        XCTAssertEqual(list.recent[0].detail, "10/1 09:00 · Acme · SLP99 · 1 h billable")
        XCTAssertEqual(list.recent[0].status, .finished(outcome: "Deferred"))
        XCTAssertEqual(list.recent[1].detail, "10/1 07:00 · Lennox · 1 h billable",
                       "no machine: the vault stands in, as the old past-job row did")
    }

    // MARK: - Badges — the card's rules, the list's scope

    func testARecentJobWhoseReportWasNotSentIsFlagged() {
        let list = JobListComposer.compose(inputs(finished: [
            session("unsent", ref: "1", started: at(day: 30, hour: 9, month: 9),
                    ended: at(day: 30, hour: 10, month: 9), reportSent: false),
            session("sent", ref: "2", started: at(day: 30, hour: 11, month: 9),
                    ended: at(day: 30, hour: 12, month: 9), reportSent: true),
        ]))
        let byTitle = Dictionary(uniqueKeysWithValues: list.recent.map { ($0.title, $0) })
        XCTAssertEqual(badges(byTitle["Job 1"]), [.reportNotSent])
        XCTAssertEqual(byTitle["Job 1"]?.badges.first?.label, "Report not sent")
        XCTAssertEqual(badges(byTitle["Job 2"]), [])
        XCTAssertEqual(list.recentAttention, 1)
        XCTAssertEqual(list.recentFooter, "Finished in the last 7 days. 1 still has something to do.")
    }

    func testAnOlderUnsentJobIsNotFlaggedButAFailedSendStillIs() {
        // Many organisations never send some jobs; history must not grow into a to-do list. A send
        // that failed this week is owed wherever its job sits.
        let list = JobListComposer.compose(inputs(
            finished: [session("old", ref: "1", started: at(day: 1, hour: 9, month: 9),
                               ended: at(day: 1, hour: 10, month: 9), reportSent: false),
                       session("oldFailed", ref: "2", started: at(day: 2, hour: 9, month: 9),
                               ended: at(day: 2, hour: 10, month: 9), reportSent: false)],
            queue: [send("q1", session: "oldFailed", state: .failed, created: at(day: 1, hour: 9))]))
        let byTitle = Dictionary(uniqueKeysWithValues: list.older.map { ($0.title, $0) })
        XCTAssertEqual(badges(byTitle["Job 1"]), [])
        XCTAssertEqual(badges(byTitle["Job 2"]), [.reportFailed])
        XCTAssertTrue(byTitle["Job 2"]?.badges.first?.isWarning ?? false)
        XCTAssertEqual(list.olderTitle, "Older jobs (2) · 1 to do")
    }

    func testAStagedReportIsReadyToSendNotAlsoNotSent() {
        let list = JobListComposer.compose(inputs(
            finished: [session("s1", ref: "1", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10),
                               reportSent: false)],
            queue: [send("q1", session: "s1", state: .staged, created: at(day: 1, hour: 11))]))
        XCTAssertEqual(badges(list.recent.first), [.reportStaged])
    }

    func testAFailedWorkOrderAndAFailedAddendumAreOneBadge() {
        let list = JobListComposer.compose(inputs(
            finished: [session("s1", ref: "1", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10))],
            queue: [send("q1", session: "s1", state: .failed, created: at(day: 1, hour: 11)),
                    send("q2", session: "s1", state: .failed, created: at(day: 1, hour: 12), kind: .addendum)]))
        XCTAssertEqual(badges(list.recent.first), [.reportFailed])
    }

    func testSignOffIsOwedOnlyWhenTheOrganisationRequiresIt() {
        let finished = [session("s1", ref: "1", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10),
                                reportSent: false, signedOff: false)]
        XCTAssertEqual(badges(JobListComposer.compose(inputs(finished: finished, signOffRequired: true)).recent.first),
                       [.reportNotSent, .signOff])
        XCTAssertEqual(badges(JobListComposer.compose(inputs(finished: finished)).recent.first),
                       [.reportNotSent])
    }

    func testPartsWaitingCountOnAnyJobIncludingTheOpenOne() {
        let list = JobListComposer.compose(inputs(
            open: session("open", ref: "9", started: at(day: 2, hour: 7), parts: 2),
            finished: [session("old", ref: "1", started: at(day: 1, hour: 9, month: 9),
                               ended: at(day: 1, hour: 10, month: 9), parts: 1)]))
        XCTAssertEqual(list.open?.badges.map(\.label), ["2 parts requests waiting"])
        XCTAssertEqual(list.older.first?.badges.map(\.label), ["Parts request waiting"])
    }

    func testAnUnsavedDebriefIsFlaggedOnItsJob() {
        let list = JobListComposer.compose(inputs(
            finished: [session("s1", ref: "1004", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10))],
            debrief: JobDayDebrief(sessionId: "s1", label: "Job 1004")))
        XCTAssertEqual(badges(list.recent.first), [.debrief])
    }

    func testACancelledVisitOwesNoReport() {
        let list = JobListComposer.compose(inputs(finished: [
            session("c", ref: "1", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 9, minute: 5),
                    cancelled: true, reportSent: false, outcome: "Cancelled"),
        ]))
        XCTAssertEqual(list.recent.map(\.title), ["Job 1"], "a cancelled visit is still listed")
        XCTAssertEqual(badges(list.recent.first), [])
    }

    func testBadgesAreInTheCardsOrderAndSpoken() {
        let list = JobListComposer.compose(inputs(
            finished: [session("s1", ref: "1004", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10),
                               reportSent: false, parts: 1)],
            debrief: JobDayDebrief(sessionId: "s1", label: "Job 1004"),
            signOffRequired: true))
        XCTAssertEqual(badges(list.recent.first), [.debrief, .reportNotSent, .signOff, .parts])
        let spoken = list.recent.first?.spoken ?? ""
        XCTAssertTrue(spoken.hasPrefix("Job 1004, Resolved, "), spoken)
        XCTAssertTrue(spoken.hasSuffix("Debrief not saved, Report not sent, Sign-off owed, Parts request waiting"), spoken)
    }

    func testTheBadgesAgreeWithTheJobDayCard() {
        // The same facts, today: the card's to-do kinds for a session are the list's badge kinds.
        let facts = session("s1", ref: "1004", started: at(day: 2, hour: 6), ended: at(day: 2, hour: 7),
                            reportSent: false, parts: 1)
        let card = JobDayComposer.compose(JobDayInputs(now: now, calendar: calendar, sessions: [facts.facts],
                                                       signOffRequired: true))
        let list = JobListComposer.compose(inputs(finished: [facts], signOffRequired: true))
        XCTAssertEqual(card.todos.compactMap(\.sessionId), ["s1", "s1", "s1"])
        XCTAssertEqual(card.todos.map { JobList.Badge.Kind($0.kind) }, badges(list.recent.first))
    }

    // MARK: - Search

    func testSearchFindsJobsInEverySectionByNumberCustomerOrMachine() {
        let base = inputs(
            open: session("open", ref: "1009", started: at(day: 2, hour: 7), customer: "Smith & Co"),
            finished: [session("s1", ref: "1004", started: at(day: 1, hour: 9), ended: at(day: 1, hour: 10),
                               equipment: "SLP99"),
                       session("s0", ref: "1001", started: at(day: 1, hour: 9, month: 8),
                               ended: at(day: 1, hour: 10, month: 8), customer: "Smith & Co")],
            upcoming: [upcoming("u1", ref: "1011", customer: "Smith & Co", at: at(day: 3, hour: 9))])

        var query = base; query.query = "smith"
        XCTAssertEqual(JobListComposer.compose(query).results?.map(\.title), ["Job 1009", "Job 1011", "Job 1001"],
                       "open, scheduled, then finished — the sections' own order")
        query.query = " 1004 "
        XCTAssertEqual(JobListComposer.compose(query).results?.map(\.title), ["Job 1004"])
        query.query = "slp99"
        XCTAssertEqual(JobListComposer.compose(query).results?.map(\.title), ["Job 1004"])
        query.query = "zzq9"
        XCTAssertEqual(JobListComposer.compose(query).results, [])
        XCTAssertEqual(JobList.noResults(" zzq9 "), "No job matches \u{201C}zzq9\u{201D}.")
        query.query = "   "
        XCTAssertNil(JobListComposer.compose(query).results, "blank is no search")
    }

    // MARK: - Older, paged

    func testOlderJobsArePagedTwentyFiveAtATime() {
        let older = (0..<60).map { n in
            session("s\(n)", ref: "\(n)", started: at(day: 1, hour: 0, month: 8).addingTimeInterval(Double(-n) * 3600),
                    ended: at(day: 1, hour: 0, month: 8).addingTimeInterval(Double(-n) * 3600 + 60))
        }
        let list = JobListComposer.compose(inputs(finished: older))
        XCTAssertEqual(list.older.count, 60)
        XCTAssertEqual(list.older.first?.title, "Job 0", "newest first")
        let first = JobListComposer.page(list.older, pages: 0)
        XCTAssertEqual(first.shown.count, 25)
        XCTAssertEqual(first.remaining, 35)
        XCTAssertEqual(JobListComposer.page(list.older, pages: 1).shown.count, 50)
        let all = JobListComposer.page(list.older, pages: 2)
        XCTAssertEqual(all.shown.count, 60)
        XCTAssertEqual(all.remaining, 0)
        XCTAssertEqual(list.olderTitle, "Older jobs (60)")
    }
}
