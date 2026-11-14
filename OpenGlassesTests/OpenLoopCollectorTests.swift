import XCTest
@testable import OpenGlasses

/// Invented ids, titles and names only.
enum OpenLoopFixture {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    /// 14 November 2026 (a Saturday), in UTC.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// The check-in's evening: 21:00.
    static let now = at(21)

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func reminder(_ id: String, _ title: String, due: Date?, since: Date = at(8)) -> OpenLoop {
        OpenLoop(id: "reminder:\(id)", source: .reminder, title: title, since: since, dueAt: due,
                 action: .complete(reminderID: id))
    }

    static func step(_ n: Int, _ title: String, goal: String, due: Date?, covers: Set<String> = []) -> OpenLoop {
        OpenLoop(id: "step:\(n)", source: .goalStep, title: title, subject: goal, since: at(7), dueAt: due,
                 action: .stepDone(goalID: uuid(1), stepID: uuid(100 + n)), covers: covers)
    }

    static func approval(_ n: Int, _ title: String, since: Date) -> OpenLoop {
        OpenLoop(id: "held:\(n)", source: .approval, title: title, since: since,
                 action: .approve(entryID: uuid(500 + n)))
    }

    static func report(_ id: String, job: OpenLoopJobName?, since: Date = at(15), failed: Bool = false) -> OpenLoop {
        OpenLoop(id: "report:\(id)", source: .jobReport, title: "Report", job: job, since: since, failed: failed,
                 action: .open(.job(.send(queuedId: id))))
    }

    static func job(_ source: OpenLoopSource, _ id: String, title: String, job: OpenLoopJobName?,
                    subject: String? = nil, since: Date = at(14)) -> OpenLoop {
        OpenLoop(id: "\(source.rawValue):\(id)", source: source, title: title, subject: subject, job: job,
                 since: since, action: .open(.job(.pastJob(sessionId: id))))
    }

    static func held(_ n: Int, at date: Date, title: String = "Your OK to use the send message tool") -> ActivityEntry {
        ActivityEntry(id: uuid(500 + n), at: date, kind: .held, title: title, tool: "send_message",
                      authorisation: .heldForYou, origin: .agent, outcome: .waitingOnYou)
    }
}

/// Plan LE P0 — `OpenLoopCollector`: §2's rules, in order, and the ranking of rule 4 as amended
/// by §10 (decision 11).
final class OpenLoopCollectorTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private func collect(_ loops: [OpenLoop], dismissed: [String: String] = [:],
                         now: Date = F.now) -> [String] {
        OpenLoopCollector.collect(loops, dismissed: dismissed, now: now, calendar: F.calendar).loops.map(\.id)
    }

    // MARK: Approvals resolve (§3)

    func testAHeldEntryApprovedLaterIsNotListed() {
        let waiting = F.held(1, at: F.at(9))
        let answered = F.held(2, at: F.at(10)).resolved(.approved, at: F.at(11))
        let declined = F.held(3, at: F.at(12)).resolved(.declined, at: F.at(12, 5))
        let lapsed = F.held(4, at: F.at(13)).resolved(.expired, at: F.at(20))
        let loops = OpenLoopApprovals.loops(from: [waiting, answered, declined, lapsed], now: F.now,
                                            calendar: F.calendar)
        XCTAssertEqual(loops.map(\.id), [OpenLoopApprovals.id(for: waiting)])
        XCTAssertEqual(loops.first?.action, .approve(entryID: waiting.id))
        XCTAssertEqual(loops.first?.source, .approval)
    }

    func testAnApprovalCountsFromTodayOrYesterdayOnly() {
        let yesterday = F.held(1, at: F.at(18, day: 13))
        let older = F.held(2, at: F.at(23, day: 12))
        let notHeld = ActivityEntry(id: F.uuid(503), at: F.at(9), kind: .action, title: "Waiting thing",
                                    authorisation: .asked, origin: .wearer, outcome: .waitingOnYou)
        let loops = OpenLoopApprovals.loops(from: [yesterday, older, notHeld], now: F.now, calendar: F.calendar)
        XCTAssertEqual(loops.map(\.id), [OpenLoopApprovals.id(for: yesterday)])
    }

    // MARK: Rule 1 — dismissals

    func testADismissedReminderStaysOutTonightAndReturnsOnlyWhenItsDueDateChanges() {
        let reminder = F.reminder("r1", "Renew the registration", due: F.at(9))
        let record = OpenLoopDismissals.empty.adding(reminder, on: F.at(21, 5), calendar: F.calendar)
        let tonight = record.active(on: F.at(21, 30), calendar: F.calendar)

        XCTAssertEqual(collect([reminder], dismissed: tonight, now: F.at(21, 30)), [],
                       "cleared tonight, still cleared on the next read tonight")
        let moved = F.reminder("r1", "Renew the registration", due: F.at(18))
        XCTAssertEqual(collect([moved], dismissed: tonight, now: F.at(21, 30)), ["reminder:r1"],
                       "its due date changed: new news")

        let tomorrow = record.active(on: F.at(21, day: 15), calendar: F.calendar)
        let stillOverdue = F.reminder("r1", "Renew the registration", due: F.at(9))
        XCTAssertEqual(collect([stillOverdue], dismissed: tomorrow, now: F.at(21, day: 15)), ["reminder:r1"],
                       "a dismissal is for tonight only")
    }

    // MARK: Rule 2 — tomorrow is the morning's

    func testTomorrowDatedItemsAreLeftToTheMorning() {
        let today = F.reminder("r1", "Put the bins out", due: F.at(22))
        let tomorrow = F.reminder("r2", "Call the garage", due: F.at(9, day: 15))
        let midnight = F.reminder("r3", "Pay the rates", due: F.at(0, day: 15))
        let undated = F.reminder("r4", "Book the skip", due: nil)
        XCTAssertEqual(collect([today, tomorrow, midnight, undated]), ["reminder:r1", "reminder:r4"])
    }

    // MARK: Rule 3 — duplicates

    func testAReminderThatIsAGoalStepsActionCountsOnceAsTheStep() {
        let reminder = F.reminder("r1", "Book the skip", due: F.at(12))
        let step = F.step(1, "Book the skip", goal: "Clear the garage", due: F.at(12), covers: ["reminder:r1"])
        let collected = OpenLoopCollector.collect([reminder, step], dismissed: [:], now: F.now, calendar: F.calendar)
        XCTAssertEqual(collected.loops.map(\.id), ["step:1"])
        XCTAssertEqual(collected.loops.first?.source, .goalStep)
    }

    func testTheSameLoopReadTwiceCountsOnce() {
        let reminder = F.reminder("r1", "Book the skip", due: F.at(12))
        XCTAssertEqual(collect([reminder, reminder]), ["reminder:r1"])
    }

    func testADismissedGoalStepKeepsItsReminderOutToo() {
        // The pair is one thing: clearing the step must not bring its reminder back on its own.
        let reminder = F.reminder("r1", "Book the skip", due: F.at(12))
        let step = F.step(1, "Book the skip", goal: "Clear the garage", due: F.at(12), covers: ["reminder:r1"])
        let dismissed = OpenLoopDismissals.empty.adding(step, on: F.now, calendar: F.calendar)
            .active(on: F.now, calendar: F.calendar)
        XCTAssertEqual(collect([reminder, step], dismissed: dismissed), [])
    }

    // MARK: Rule 4 — ranking

    func testAnUnsentReportRanksAfterAnApprovalAndBeforeAnOverdueReminder() {
        let overdue = F.reminder("r1", "Renew the registration", due: F.at(8, day: 12))
        let report = F.report("q1", job: .customer("Smith"))
        let approval = F.approval(1, "Your OK to use the send message tool", since: F.at(20))
        XCTAssertEqual(collect([overdue, report, approval]), ["held:1", "report:q1", "reminder:r1"])
    }

    func testTheFullOrder() {
        let loops = [
            OpenLoop(id: "digest:d1", source: .digest, title: "Parcel delivered", since: F.at(10), action: .dismiss),
            F.reminder("today-late", "Put the bins out", due: F.at(22)),
            F.reminder("today-later", "Lock the shed", due: F.at(23)),
            F.reminder("overdue-new", "Water the plants", due: F.at(18)),
            F.reminder("overdue-old", "Renew the registration", due: F.at(8, day: 12)),
            F.reminder("undated", "Book the skip", due: nil, since: F.at(9)),
            F.job(.expertOrEscalation, "s1", title: "Hand-off", job: .customer("Smith"), subject: "Sam"),
            F.job(.deferredTask, "s1", title: "Clean the coil", job: .customer("Smith")),
            F.job(.partsRequest, "s2", title: "filter", job: .customer("Jones")),
            F.job(.jobCloseHeld, "s3", title: "The customer's sign-off", job: .reference("1005")),
            F.report("q1", job: .customer("Smith")),
            F.approval(2, "Your OK to use the reminder tool", since: F.at(19)),
            F.approval(1, "Your OK to use the send message tool", since: F.at(9)),
        ]
        XCTAssertEqual(collect(loops), [
            "held:1", "held:2",                                       // approvals, oldest first
            "report:q1", "jobCloseHeld:s3", "partsRequest:s2",        // the job's loose ends, in order
            "deferredTask:s1", "expertOrEscalation:s1",
            "reminder:overdue-old", "reminder:overdue-new",           // overdue, oldest first
            "reminder:today-late", "reminder:today-later",            // due later today, by time
            "reminder:undated", "digest:d1",                          // undated, by since
        ])
    }

    func testTiesGoBySourceOrderInTheTable() {
        let since = F.at(9)
        let digest = OpenLoop(id: "a-digest", source: .digest, title: "Parcel delivered", since: since, action: .dismiss)
        let reminder = F.reminder("z", "Book the skip", due: nil, since: since)
        let result = OpenLoop(id: "b-result", source: .agentResult, title: "Upcoming Events", since: since,
                              action: .open(.agentResult(id: "r")))
        XCTAssertEqual(collect([result, digest, reminder]), ["reminder:z", "a-digest", "b-result"])
    }

    func testAFailedSendRanksBeforeAStagedOne() {
        let staged = F.report("q1", job: .customer("Smith"), since: F.at(12))
        let failed = F.report("q2", job: .customer("Jones"), since: F.at(16), failed: true)
        XCTAssertEqual(collect([staged, failed]), ["report:q2", "report:q1"])
    }

    // MARK: Sources that cannot be read

    func testAnUnreadableSourceIsReportedNotEmptied() {
        let reminder = F.reminder("r1", "Book the skip", due: nil)
        let collected = OpenLoopCollector.collect(
            readings: [
                (sources: [.reminder], reading: .read([reminder])),
                (sources: [.jobReport, .jobCloseHeld], reading: .unavailable),
                (sources: [.approval], reading: .unavailable),
            ],
            dismissed: [:], now: F.now, calendar: F.calendar)
        XCTAssertEqual(collected.loops.map(\.id), ["reminder:r1"])
        XCTAssertEqual(collected.unavailable, [.approval, .jobReport, .jobCloseHeld])
    }

    @MainActor
    func testGatherReadsEveryReaderFresh() async {
        final class Reader: OpenLoopSourceReading {
            let sources: [OpenLoopSource]
            let reading: OpenLoopReading
            var reads = 0
            init(_ sources: [OpenLoopSource], _ reading: OpenLoopReading) {
                self.sources = sources
                self.reading = reading
            }
            func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
                reads += 1
                return reading
            }
        }
        let reminders = Reader([.reminder], .read([F.reminder("r1", "Book the skip", due: nil)]))
        let jobs = Reader([.jobReport], .unavailable)
        let first = await OpenLoopCollector.gather([reminders, jobs], dismissed: [:], now: F.now, calendar: F.calendar)
        _ = await OpenLoopCollector.gather([reminders, jobs], dismissed: [:], now: F.now, calendar: F.calendar)
        XCTAssertEqual(first.loops.map(\.id), ["reminder:r1"])
        XCTAssertEqual(first.unavailable, [.jobReport])
        XCTAssertEqual(reminders.reads, 2, "every check-in reads its sources again")
    }

    // MARK: The sources

    func testTheTableOrderAndTheJobOrderArePinned() {
        XCTAssertEqual(OpenLoopSource.allCases, [
            .approval, .reminder, .goalStep, .digest, .agentResult, .draft, .waitingOnOthers,
            .watcherFinding, .askAgain, .jobReport, .jobCloseHeld, .partsRequest, .deferredTask,
            .expertOrEscalation,
        ])
        XCTAssertEqual(OpenLoopSource.allCases.compactMap(\.jobOrder), [0, 1, 2, 3, 4])
        XCTAssertEqual(OpenLoopSource.allCases.filter { !$0.hasProducer },
                       [.draft, .waitingOnOthers, .watcherFinding, .askAgain])
    }
}
