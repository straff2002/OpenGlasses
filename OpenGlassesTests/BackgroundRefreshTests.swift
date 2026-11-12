import UserNotifications
import XCTest
@testable import OpenGlasses

/// Plan LM P0–P2 — the shared background wake and notification buttons, headless.
@MainActor
final class BackgroundRefreshTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Policy

    func testNoParticipantWantingAWakeAsksForNothing() {
        XCTAssertNil(BackgroundRefreshPolicy.earliestBeginDate(now: t0, wanted: []))
        XCTAssertNil(BackgroundRefreshPolicy.earliestBeginDate(now: t0, wanted: [nil, nil]))
    }

    func testTheSoonestWantedWakeIsAskedForButNeverInsideTheFloor() {
        let soon = t0.addingTimeInterval(60)
        let later = t0.addingTimeInterval(3 * 3600)
        XCTAssertEqual(BackgroundRefreshPolicy.earliestBeginDate(now: t0, wanted: [later, nil, soon]),
                       t0.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval),
                       "a wake wanted in a minute is asked for at the 15-minute floor")
        XCTAssertEqual(BackgroundRefreshPolicy.earliestBeginDate(now: t0, wanted: [later]), later)
        XCTAssertEqual(BackgroundRefreshPolicy.earliestBeginDate(now: t0, wanted: [t0.addingTimeInterval(-600)]),
                       t0.addingTimeInterval(BackgroundRefreshPolicy.minimumInterval),
                       "an overdue participant is asked for at the floor, never in the past")
    }

    func testDueAndTimeLeftRules() {
        XCTAssertTrue(BackgroundRefreshPolicy.isDue(nextWake: t0, now: t0))
        XCTAssertTrue(BackgroundRefreshPolicy.isDue(nextWake: t0.addingTimeInterval(-1), now: t0))
        XCTAssertFalse(BackgroundRefreshPolicy.isDue(nextWake: t0.addingTimeInterval(1), now: t0))
        XCTAssertFalse(BackgroundRefreshPolicy.isDue(nextWake: nil, now: t0))
        XCTAssertTrue(BackgroundRefreshPolicy.mayStart(minimumSeconds: 2, remaining: 2))
        XCTAssertFalse(BackgroundRefreshPolicy.mayStart(minimumSeconds: 3, remaining: 2))
        XCTAssertFalse(BackgroundRefreshPolicy.mayStart(minimumSeconds: 0, remaining: 0),
                       "nothing starts once the budget is spent")
    }

    func testTheBudgetLeavesRoomInsideIOSsThirtySeconds() {
        XCTAssertLessThanOrEqual(BackgroundRefreshPolicy.budget, 25)
        XCTAssertGreaterThanOrEqual(BackgroundRefreshPolicy.minimumInterval, 15 * 60)
    }

    // MARK: - Record and summary

    private func record(at start: Date, trigger: BackgroundRunTrigger = .systemRefresh,
                        asked: Date? = nil, expired: Bool = false) -> BackgroundRunRecord {
        BackgroundRunRecord(startedAt: start, trigger: trigger, requestedEarliest: asked,
                            results: [BackgroundParticipantResult(id: "goal-check-ins", outcome: .didWork, seconds: 0.4)],
                            seconds: 0.5, expired: expired)
    }

    func testTheLedgerKeepsTheNewestForty() {
        var records: [BackgroundRunRecord] = []
        for i in 0..<45 {
            records = BackgroundRunRecord.appending(record(at: t0.addingTimeInterval(Double(i))), to: records)
        }
        XCTAssertEqual(records.count, BackgroundRunRecord.keep)
        XCTAssertEqual(records.first?.startedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(records.last?.startedAt, t0.addingTimeInterval(44))
    }

    func testARecordRoundTripsThroughJSON() throws {
        let original = record(at: t0, asked: t0.addingTimeInterval(-7500), expired: true)
        let decoded = try JSONDecoder().decode(BackgroundRunRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testSummaryLines() {
        let line = BackgroundRunSummary.line(record(at: t0, asked: t0.addingTimeInterval(-7500)), calendar: utc)
        XCTAssertEqual(line, "2027-01-15 08:00 · system · 2h 05m late · goal-check-ins didWork 0.4s · 0.5s")
        XCTAssertTrue(BackgroundRunSummary.line(record(at: t0, trigger: .manual), calendar: utc).contains("· manual ·"))
        XCTAssertTrue(BackgroundRunSummary.line(record(at: t0, expired: true), calendar: utc).hasSuffix("· EXPIRED"))
        let empty = BackgroundRunRecord(startedAt: t0, trigger: .systemRefresh, requestedEarliest: nil,
                                        results: [], seconds: 0, expired: false)
        XCTAssertTrue(BackgroundRunSummary.line(empty, calendar: utc).contains("no participants"))
        XCTAssertEqual(BackgroundRunSummary.lateness(20), "on time")
        XCTAssertEqual(BackgroundRunSummary.lateness(45 * 60), "45m late")
        XCTAssertEqual(BackgroundRunSummary.lateness(27 * 3600), "1d 3h late")
    }

    func testRequestLines() {
        let asked = BackgroundRequestRecord(submittedAt: t0, earliestBegin: t0.addingTimeInterval(900), failure: nil)
        XCTAssertEqual(BackgroundRunSummary.line(asked, calendar: utc), "Asked 2027-01-15 08:00 for 2027-01-15 08:15 or later")
        let nothing = BackgroundRequestRecord(submittedAt: t0, earliestBegin: nil, failure: nil)
        XCTAssertTrue(BackgroundRunSummary.line(nothing, calendar: utc).contains("for nothing"))
        let failed = BackgroundRequestRecord(submittedAt: t0, earliestBegin: t0, failure: "unavailable")
        XCTAssertTrue(BackgroundRunSummary.line(failed, calendar: utc).hasSuffix("failed: unavailable"))
    }

    func testAnUnknownSubmitErrorIsAFixedToken() {
        struct Odd: Error {}
        XCTAssertEqual(BackgroundRefreshCoordinator.failureReason(Odd()), "other")
    }

    // MARK: - Runner

    private func participant(_ id: String, minimum: TimeInterval = 1, next: Date?,
                             outcome: BackgroundWorkOutcome = .didWork,
                             onRun: (() -> Void)? = nil) -> BackgroundWorkParticipant {
        BackgroundWorkParticipant(id: id, minimumSeconds: minimum, nextWake: { _ in next }, run: { _ in
            onRun?()
            return outcome
        })
    }

    func testParticipantsRunInOrderAndTheNotDueAreNoted() async {
        var ran: [String] = []
        let progress = BackgroundRunProgress(startedAt: t0, trigger: .systemRefresh, requestedEarliest: nil)
        let participants = [
            participant("a", next: t0, onRun: { ran.append("a") }),
            participant("b", next: t0.addingTimeInterval(60), onRun: { ran.append("b") }),
            participant("c", next: nil, onRun: { ran.append("c") }),
            participant("d", next: t0, outcome: .nothingToDo, onRun: { ran.append("d") }),
        ]
        await BackgroundWorkRunner.run(participants, progress: progress, clock: { self.t0 })
        let record = progress.finish(at: t0.addingTimeInterval(1), expired: false)
        XCTAssertEqual(ran, ["a", "d"])
        XCTAssertEqual(record?.results.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(record?.results.map(\.outcome), [.didWork, .notDue, .notDue, .nothingToDo])
        XCTAssertEqual(record?.expired, false)
    }

    func testAParticipantThatCannotFinishIsNotStarted() async {
        var ran = false
        var now = t0
        let progress = BackgroundRunProgress(startedAt: t0, trigger: .systemRefresh, requestedEarliest: nil)
        let participants = [
            participant("slow", next: t0, onRun: { now = self.t0.addingTimeInterval(24) }),
            participant("needs-five", minimum: 5, next: t0, onRun: { ran = true }),
        ]
        await BackgroundWorkRunner.run(participants, progress: progress, clock: { now })
        let record = progress.finish(at: now, expired: false)
        XCTAssertFalse(ran)
        XCTAssertEqual(record?.results.map(\.outcome), [.didWork, .skippedNoTime])
        XCTAssertEqual(record?.results.first?.seconds ?? 0, 24, accuracy: 0.001)
    }

    func testAnExpiredWakeKeepsATrueRecordAndTheLateFinishChangesNothing() async {
        let progress = BackgroundRunProgress(startedAt: t0, trigger: .systemRefresh, requestedEarliest: nil)
        let participants = [
            participant("first", next: t0),
            BackgroundWorkParticipant(id: "hangs", minimumSeconds: 1, nextWake: { _ in self.t0 }, run: { _ in
                // iOS ends the wake while this one is running.
                _ = progress.finish(at: self.t0.addingTimeInterval(30), expired: true)
                return .didWork
            }),
            participant("never", next: t0),
        ]
        await BackgroundWorkRunner.run(participants, progress: progress, clock: { self.t0 })
        let record = progress.record
        XCTAssertEqual(record?.expired, true)
        XCTAssertEqual(record?.results.map(\.id), ["first", "hangs"])
        XCTAssertEqual(record?.results.last?.outcome, .cancelled, "the one running when the wake ended")
        XCTAssertNil(progress.finish(at: t0.addingTimeInterval(31), expired: false),
                     "the record is written once; the late completion does not overwrite it")
    }

    func testACancelledPassMarksTheRestCancelled() async {
        let progress = BackgroundRunProgress(startedAt: t0, trigger: .systemRefresh, requestedEarliest: nil)
        let participants = [participant("a", next: t0), participant("b", next: t0)]
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await BackgroundWorkRunner.run(participants, progress: progress, clock: { self.t0 })
        }
        await task.value
        let record = progress.finish(at: t0, expired: true)
        XCTAssertEqual(record?.results.map(\.outcome), [.cancelled, .cancelled])
    }

    // MARK: - Ledger store

    func testTheLedgerPersistsAndClears() throws {
        let suite = "BackgroundRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let ledger = BackgroundRunLedger(defaults: defaults)
        ledger.append(record(at: t0))
        ledger.setLastRequest(BackgroundRequestRecord(submittedAt: t0, earliestBegin: nil, failure: nil))

        let reloaded = BackgroundRunLedger(defaults: defaults)
        XCTAssertEqual(reloaded.records, [record(at: t0)])
        XCTAssertEqual(reloaded.lastRequest?.submittedAt, t0)

        reloaded.clear()
        let cleared = BackgroundRunLedger(defaults: defaults)
        XCTAssertTrue(cleared.records.isEmpty)
        XCTAssertNil(cleared.lastRequest)
    }

    // MARK: - Coordinator participants

    func testAddingAParticipantTwiceReplacesIt() {
        let coordinator = BackgroundRefreshCoordinator(ledger: BackgroundRunLedger(
            defaults: UserDefaults(suiteName: "BackgroundRefreshTests.coordinator")!))
        coordinator.add(participant("x", next: nil))
        coordinator.add(participant("x", next: t0))
        coordinator.add(participant("y", next: nil))
        XCTAssertEqual(coordinator.participants.map(\.id), ["x", "y"])
        coordinator.remove(id: "x")
        XCTAssertEqual(coordinator.participants.map(\.id), ["y"])
    }

    // MARK: - Goal check-ins as the first participant

    func testGoalCheckInsWantNoWakeWithAgentModeOffOrNoGoals() {
        let key = "agentScheduledTasks"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        AgentScheduler.saveTasks([])
        let scheduler = AgentScheduler()
        scheduler.goals = { [] }
        scheduler.agentModeEnabled = { true }
        XCTAssertNil(scheduler.nextGoalCheckInWake(now: t0), "no goal with check-ins: no wake")

        scheduler.agentModeEnabled = { false }
        XCTAssertNil(scheduler.nextGoalCheckInWake(now: t0))
        XCTAssertEqual(scheduler.runGoalCheckInsInBackground(now: t0), .notDue)

        scheduler.agentModeEnabled = { true }
        scheduler.goals = { nil }
        XCTAssertEqual(scheduler.runGoalCheckInsInBackground(now: t0), .deferred,
                       "an unreadable goal store is a try-again, not nothing")
        XCTAssertEqual(scheduler.goalCheckInBackgroundParticipant().id, AgentScheduler.goalCheckInsBackgroundID)
    }

    // MARK: - Notification buttons

    func testTheCatalogIdsAreUniqueAndStable() {
        let categoryIDs = NotificationActionCatalog.all.map(\.id)
        XCTAssertEqual(Set(categoryIDs).count, categoryIDs.count)
        let actionIDs = NotificationActionCatalog.all.flatMap(\.actions).map(\.id)
        XCTAssertEqual(Set(actionIDs).count, actionIDs.count)
        XCTAssertEqual(NotificationActionCatalog.askUntilDone.id, "avenkin.ask-until-done")
        XCTAssertEqual(NotificationActionCatalog.askUntilDone.actions.map(\.id), ["avenkin.done", "avenkin.stop-today"])
        XCTAssertFalse(NotificationActionCatalog.askUntilDone.actions.contains { $0.opensApp },
                       "Done and Stop for today answer without opening the app")
        XCTAssertEqual(NotificationActionCatalog.systemCategories().map(\.identifier).sorted(), categoryIDs.sorted())
    }

    func testParsingAPressATapAndADismissal() {
        let info: [AnyHashable: Any] = [NotificationActionCatalog.subjectKey: "reminder-7"]
        XCTAssertEqual(NotificationActionResponse.parse(actionIdentifier: "avenkin.done",
                                                        categoryIdentifier: "avenkin.ask-until-done", userInfo: info),
                       .press(NotificationActionPress(categoryID: "avenkin.ask-until-done", actionID: "avenkin.done",
                                                      subject: "reminder-7")))
        XCTAssertEqual(NotificationActionResponse.parse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                        categoryIdentifier: "avenkin.ask-until-done", userInfo: info), .tap)
        XCTAssertEqual(NotificationActionResponse.parse(actionIdentifier: UNNotificationDismissActionIdentifier,
                                                        categoryIdentifier: "", userInfo: [:]), .dismiss)
        XCTAssertEqual(NotificationActionResponse.parse(actionIdentifier: "x", categoryIdentifier: "elsewhere", userInfo: [:]),
                       .press(NotificationActionPress(categoryID: "elsewhere", actionID: "x", subject: nil)))
    }

    func testTheHubRoutesToItsCategoryAndDropsTheRest() {
        let hub = NotificationActionHub()
        var received: [NotificationActionPress] = []
        hub.register(categoryID: "avenkin.ask-until-done") { received.append($0) }
        let press = NotificationActionPress(categoryID: "avenkin.ask-until-done", actionID: "avenkin.done", subject: "r")
        XCTAssertTrue(hub.route(press))
        XCTAssertFalse(hub.route(NotificationActionPress(categoryID: "elsewhere", actionID: "x", subject: nil)))
        XCTAssertEqual(received, [press])
        hub.unregister(categoryID: "avenkin.ask-until-done")
        XCTAssertFalse(hub.route(press))
    }

    func testTheRouterSendsPressesToTheHubAndTapsToTheirTab() {
        var tabs: [MainTab] = []
        var presses: [NotificationActionPress] = []
        let router = JobSendNotificationRouter(openTab: { tabs.append($0) }, routeAction: { presses.append($0) })
        let tabInfo: [AnyHashable: Any] = [JobSendNotifications.openTabKey: MainTab.job.rawValue]

        router.handle(.tap, userInfo: tabInfo)
        XCTAssertEqual(tabs, [.job], "a tap keeps today's routing")

        let press = NotificationActionPress(categoryID: "avenkin.ask-until-done", actionID: "avenkin.stop-today", subject: nil)
        router.handle(.press(press), userInfo: tabInfo)
        XCTAssertEqual(presses, [press])
        XCTAssertEqual(tabs, [.job], "a button press does not also open a tab")

        router.handle(.dismiss, userInfo: tabInfo)
        XCTAssertEqual(tabs, [.job])
    }

    // MARK: - Info.plist guard

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheAuthoredPlistPermitsTheSharedIdentifierAndFetch() throws {
        let url = Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist")
        let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        let info = try XCTUnwrap(parsed as? [String: Any])
        let identifiers = try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        XCTAssertEqual(identifiers, [BackgroundRefreshPolicy.taskIdentifier],
                       "one shared identifier: a plan joins the wake with a participant, never its own task")
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("fetch"))
        XCTAssertFalse(modes.contains("processing"), "no BGProcessingTask until a feature needs one (Plan LM)")
    }

    // MARK: - The notification-button test (P4 check 5)

    func testTheButtonTestHasItsOwnCategoryWithTheSameButtons() {
        let test = NotificationButtonTest.category
        XCTAssertNotEqual(test.id, NotificationActionCatalog.askUntilDone.id,
                          "a test press must never reach LE's or LG's handler")
        XCTAssertEqual(test.actions.map(\.id), ["avenkin.developer-test.done", "avenkin.developer-test.stop-today"])
        XCTAssertEqual(test.actions.map(\.title), NotificationActionCatalog.askUntilDone.actions.map(\.title))
        XCTAssertFalse(test.actions.contains { $0.opensApp })
        XCTAssertNotNil(NotificationActionCatalog.category(id: test.id))
    }

    func testButtonTestPressesKeepTheLastTenAndReadAsOneLine() {
        var presses: [NotificationButtonTestPress] = []
        for i in 0..<12 {
            presses = NotificationButtonTestPress.appending(
                NotificationButtonTestPress(pressedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                                            actionID: "avenkin.developer-test.done", appState: "background",
                                            secondsSinceLaunch: 3.24),
                to: presses)
        }
        XCTAssertEqual(presses.count, NotificationButtonTestPress.maxKept)
        XCTAssertEqual(presses.first?.pressedAt, Date(timeIntervalSince1970: 2))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(presses.last?.line(calendar: calendar),
                       "1970-01-01 00:00:11 · avenkin.developer-test.done · background · 3.2s after launch")
    }

    @MainActor
    func testATestPressIsRecordedAndSurvivesAReload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotificationButtonTest-\(UUID().uuidString)"))
        let log = NotificationButtonTestLog(defaults: defaults)
        let hub = NotificationActionHub()
        NotificationButtonTest.registerHandler(hub: hub, recorder: log)
        XCTAssertTrue(hub.route(NotificationActionPress(categoryID: NotificationButtonTest.category.id,
                                                        actionID: "avenkin.developer-test.stop-today",
                                                        subject: "developer-test")))
        XCTAssertEqual(log.presses.map(\.actionID), ["avenkin.developer-test.stop-today"])
        XCTAssertNotNil(log.presses.first?.secondsSinceLaunch)
        XCTAssertEqual(NotificationButtonTestLog(defaults: defaults).presses, log.presses)
        XCTAssertFalse(hub.route(NotificationActionPress(categoryID: NotificationActionCatalog.askUntilDone.id,
                                                         actionID: "avenkin.done", subject: nil)),
                       "the test registers only its own category")
    }
}
