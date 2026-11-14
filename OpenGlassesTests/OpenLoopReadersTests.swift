import XCTest
@testable import OpenGlasses

/// A reminders source the check-in's readers can be pointed at.
@MainActor
final class FakeCheckInReminders: RemindersDaySource {
    var reminders: [MyDayReminder]
    var state = MyDaySourceState.available(.reminders)
    private(set) var loads = 0
    private(set) var completed: [String] = []

    init(_ reminders: [MyDayReminder] = []) { self.reminders = reminders }

    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> {
        loads += 1
        return .init(value: reminders, state: state)
    }

    func completeReminder(id: String) async throws -> String? {
        completed.append(id)
        return reminders.first { $0.id == id }?.title
    }
}

/// A reader that returns what it is told.
@MainActor
final class FakeLoopReader: OpenLoopSourceReading {
    let sources: [OpenLoopSource]
    var reading: OpenLoopReading
    private(set) var reads = 0

    init(_ sources: [OpenLoopSource] = [.reminder], _ reading: OpenLoopReading) {
        self.sources = sources
        self.reading = reading
    }

    func readOpenLoops(now: Date, calendar: Calendar) async -> OpenLoopReading {
        reads += 1
        return reading
    }
}

/// Plan LE P1 — the everyday readers. Each one reads fresh, applies its row's "counts when", and
/// says `unavailable` rather than an empty list when its store cannot be read. Invented names only.
@MainActor
final class OpenLoopReadersTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private func loops(_ reading: OpenLoopReading) -> [OpenLoop] {
        if case .read(let loops) = reading { return loops }
        XCTFail("expected a reading, got \(reading)")
        return []
    }

    // MARK: Approvals

    func testTheApprovalReaderReadsTheTrailAndSaysWhenItCannot() async {
        let waiting = F.held(1, at: F.at(9))
        let answered = F.held(2, at: F.at(10)).resolved(.approved, at: F.at(11))
        let reader = ApprovalLoopReader(entries: { [waiting, answered] })
        let found = loops(await reader.readOpenLoops(now: F.now, calendar: F.calendar))
        XCTAssertEqual(found.map(\.id), [OpenLoopApprovals.id(for: waiting)])
        XCTAssertEqual(found.first?.action, .approve(entryID: waiting.id))

        let locked = ApprovalLoopReader(entries: { nil })
        let reading = await locked.readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(reading, .unavailable)
    }

    // MARK: Reminders

    private func reminder(_ id: String, _ title: String, due: Date?, hasTime: Bool = true) -> MyDayReminder {
        MyDayReminder(id: id, title: title, dueDate: due, hasTime: hasTime, priority: 0)
    }

    func testRemindersCountWhenDueTodayOrOverdue() async {
        let source = FakeCheckInReminders([
            reminder("r1", "Renew the registration", due: F.at(9, day: 12)),     // overdue
            reminder("r2", "Call the plumber", due: F.at(17)),                   // due today, past
            reminder("r3", "Book the dentist", due: F.at(10, day: 15)),          // tomorrow
            reminder("r4", "Water the garden", due: nil),                        // undated
            reminder("r5", "Return the library book", due: F.at(0), hasTime: false), // today, no time
        ])
        let reader = ReminderLoopReader(source: source, included: { true })
        let found = loops(await reader.readOpenLoops(now: F.now, calendar: F.calendar))
        XCTAssertEqual(Set(found.map(\.id)), ["reminder:r1", "reminder:r2", "reminder:r5"])
        XCTAssertEqual(found.first { $0.id == "reminder:r1" }?.action, .complete(reminderID: "r1"))
        let dateOnly = found.first { $0.id == "reminder:r5" }
        XCTAssertGreaterThan(dateOnly?.dueAt ?? .distantPast, F.now,
                             "a reminder with only today's date is due later today, not overdue")
        XCTAssertLessThan(dateOnly?.dueAt ?? .distantFuture, F.at(0, day: 15))
        XCTAssertEqual(source.loads, 1, "read fresh, once")
    }

    func testRemindersThatCannotBeReadAreUnavailableAndSwitchedOffAreEmpty() async {
        let source = FakeCheckInReminders([reminder("r1", "Renew", due: F.at(9))])
        source.state = .denied(.reminders)
        let denied = await ReminderLoopReader(source: source, included: { true })
            .readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(denied, .unavailable)

        let off = await ReminderLoopReader(source: source, included: { false })
            .readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(off, .read([]), "switched off in My Day is the wearer's choice, not a failure")
    }

    // MARK: Goal steps

    private func goal(_ n: Int, _ title: String, step: String, due: Date?, action: StepAction? = nil,
                      state: GoalState = .active) -> Goal {
        Goal(id: F.uuid(n), title: title, createdAt: F.at(7, day: 10), state: state,
             steps: [GoalStep(id: F.uuid(100 + n), title: step, dueAt: due, suggestedAction: action)],
             source: .wearer)
    }

    func testGoalStepsCountWhenTheNextStepIsDueTodayOrOverdue() async {
        let goals = [
            goal(1, "Clear the garage", step: "Book a skip", due: F.at(12)),
            goal(2, "Learn Spanish", step: "Lesson three", due: F.at(9, day: 16)),
            goal(3, "Paint the fence", step: "Buy paint", due: F.at(9), state: .paused),
        ]
        let reader = GoalStepLoopReader(goals: { goals }, included: { true })
        let found = loops(await reader.readOpenLoops(now: F.now, calendar: F.calendar))
        XCTAssertEqual(found.map(\.title), ["Book a skip"])
        XCTAssertEqual(found.first?.subject, "Clear the garage")
        XCTAssertEqual(found.first?.action, .stepDone(goalID: F.uuid(1), stepID: F.uuid(101)))

        let unreadable = await GoalStepLoopReader(goals: { nil }, included: { true })
            .readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(unreadable, .unavailable)
    }

    func testAStepWhoseActionIsAReminderCoversThatReminder() async {
        let reminders = FakeCheckInReminders([
            MyDayReminder(id: "r9", title: "Ring the skip company", dueDate: F.at(12), hasTime: true, priority: 0),
            MyDayReminder(id: "r8", title: "Something else", dueDate: F.at(12), hasTime: true, priority: 0),
        ])
        let goals = [goal(1, "Clear the garage", step: "Book a skip", due: F.at(12),
                          action: .reminder(text: "ring the skip company ", at: F.at(12)))]
        let stepReader = GoalStepLoopReader(goals: { goals }, reminders: reminders, included: { true })
        let step = loops(await stepReader.readOpenLoops(now: F.now, calendar: F.calendar))
        XCTAssertEqual(step.first?.covers, ["reminder:r9"])

        // Together with the reminders reader, the pair counts once — as the step.
        let reminderLoops = loops(await ReminderLoopReader(source: reminders, included: { true })
            .readOpenLoops(now: F.now, calendar: F.calendar))
        let collected = OpenLoopCollector.collect(step + reminderLoops, dismissed: [:], now: F.now,
                                                  calendar: F.calendar)
        XCTAssertEqual(Set(collected.loops.map(\.id)), [step[0].id, "reminder:r8"])
    }

    func testAStepWithNoReminderActionDoesNotReadReminders() async {
        let reminders = FakeCheckInReminders()
        let goals = [goal(1, "Clear the garage", step: "Book a skip", due: F.at(12))]
        _ = await GoalStepLoopReader(goals: { goals }, reminders: reminders, included: { true })
            .readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(reminders.loads, 0)
    }

    // MARK: Digest

    private func item(_ id: String, _ source: DigestSource, priority: NotificationPriority = .low,
                      awaitingReply: Bool = false, seen: Int = 0, thread: String? = nil) -> DigestItem {
        DigestItem(id: id, source: source, title: "Update \(id)", createdAt: F.at(20), priority: priority,
                   threadKey: thread, awaitingReply: awaitingReply, seenCount: seen)
    }

    func testDigestItemsCountWhenActionableUnseenAndNotTheirOwnRow() async {
        let items = [
            item("d1", .sync, priority: .high),                       // urgent: counts
            item("d2", .agent, priority: .medium, awaitingReply: true, thread: "a1"), // actionable: counts, covers the result
            item("d3", .proactive, priority: .medium),                // informational: no
            item("d4", .sync, priority: .high, seen: 1),              // already seen: no
            item("d5", .calendar, priority: .high),                   // its own row: no
            item("d6", .geofence, priority: .high),                   // mattered then: no
        ]
        let found = loops(await DigestLoopReader(items: { items }).readOpenLoops(now: F.now, calendar: F.calendar))
        XCTAssertEqual(Set(found.map(\.id)), ["digest:d1", "digest:d2"])
        XCTAssertEqual(found.first { $0.id == "digest:d2" }?.covers, ["agent:a1"])
        XCTAssertEqual(found.first { $0.id == "digest:d1" }?.action, .open(.digestItem(id: "d1")))
    }

    // MARK: Agent results

    func testAgentResultsCountWhileQueuedAndNotDeliveredOrStale() async {
        let fresh = AgentNotificationQueue.QueuedNotification(
            id: "a1", message: "The parcel was delivered to the side door.\nMore detail", source: "Agent Task",
            personaId: nil, personaName: nil, createdAt: F.at(20), priority: .high)
        var delivered = AgentNotificationQueue.QueuedNotification(
            id: "a2", message: "Done", source: "Agent Task", personaId: nil, personaName: nil,
            createdAt: F.at(20), priority: .high)
        delivered.delivered = true
        let stale = AgentNotificationQueue.QueuedNotification(
            id: "a3", message: "Weather", source: "Agent Task", personaId: nil, personaName: nil,
            createdAt: F.at(1, day: 10), priority: .low)
        let found = loops(await AgentResultLoopReader(pending: { [fresh, delivered, stale] })
            .readOpenLoops(now: F.now, calendar: F.calendar))
        XCTAssertEqual(found.map(\.id), ["agent:a1"])
        XCTAssertEqual(found.first?.title, "The parcel was delivered to the side door.", "the first line")
    }

    func testADigestAgentItemAndItsQueuedResultCountOnce() async {
        let digest = loops(await DigestLoopReader(items: { [self.item("d2", .agent, priority: .medium, awaitingReply: true, thread: "a1")] })
            .readOpenLoops(now: F.now, calendar: F.calendar))
        let queued = AgentNotificationQueue.QueuedNotification(
            id: "a1", message: "Update d2", source: "Agent Task", personaId: nil, personaName: nil,
            createdAt: F.at(20), priority: .high)
        let result = loops(await AgentResultLoopReader(pending: { [queued] })
            .readOpenLoops(now: F.now, calendar: F.calendar))
        let collected = OpenLoopCollector.collect(digest + result, dismissed: [:], now: F.now, calendar: F.calendar)
        XCTAssertEqual(collected.loops.map(\.id), ["digest:d2"])
    }

    // MARK: Jobs

    func testTheJobReaderIsEmptyWithFieldAssistOffAndUnavailableWhenItCannotGather() async {
        var gathered = 0
        let off = JobLoopReader(fieldAssistOn: { false }, facts: { gathered += 1; return nil })
        let offReading = await off.readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(offReading, .read([]))
        XCTAssertEqual(gathered, 0, "nothing is gathered with Field Assist off")

        let broken = JobLoopReader(fieldAssistOn: { true }, facts: { nil })
        let brokenReading = await broken.readOpenLoops(now: F.now, calendar: F.calendar)
        XCTAssertEqual(brokenReading, .unavailable)
        XCTAssertEqual(broken.sources, [.jobReport, .jobCloseHeld, .partsRequest, .deferredTask, .expertOrEscalation])
    }

    // MARK: The service reads fresh

    func testTheServiceReadsEveryReaderEachTimeAndReplacesAReaderForTheSameSources() async {
        let first = FakeLoopReader([.reminder], .read([F.reminder("r1", "Renew", due: F.at(9))]))
        let service = EveningCheckInService(readers: [first], store: OpenLoopDismissalStore(
            defaults: UserDefaults(suiteName: "OpenLoopReadersTests.\(UUID().uuidString)")!,
            calendar: { F.calendar }))
        service.calendar = { F.calendar }
        _ = await service.collect(now: F.now)
        _ = await service.collect(now: F.now)
        XCTAssertEqual(first.reads, 2, "never from a cache filled earlier")

        let second = FakeLoopReader([.reminder], .unavailable)
        service.install(second)
        let collection = await service.collect(now: F.now)
        XCTAssertEqual(first.reads, 2)
        XCTAssertEqual(collection.unavailable, [.reminder])
        XCTAssertTrue(collection.loops.isEmpty)
    }

    func testNoReaderReportsTheSourcesThatHaveNoProducer() {
        // KT drafts, KI, JO and LG stay without readers in P1 (As built): nothing the registry or
        // AppState installs answers for them, so no KT draft can double a §10 job row.
        let installed: [OpenLoopSourceReading] = [
            ApprovalLoopReader(entries: { [] }), ReminderLoopReader(source: FakeCheckInReminders()),
            GoalStepLoopReader(goals: { [] }), DigestLoopReader(items: { [] }),
            AgentResultLoopReader(pending: { [] }), JobLoopReader(facts: { nil }),
        ]
        let answered = Set(installed.flatMap(\.sources))
        XCTAssertEqual(answered, Set(OpenLoopSource.allCases.filter(\.hasProducer)))
        XCTAssertFalse(answered.contains(.draft))
    }
}
