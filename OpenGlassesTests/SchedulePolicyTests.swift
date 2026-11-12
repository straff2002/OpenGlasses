import XCTest
@testable import OpenGlasses

/// Plan LM P3 / Plan DZ PR6 — durable scheduler semantics. The exit criteria, one test each where
/// they are pure, plus the store's relaunch and the scheduler's write of a run.
@MainActor
final class SchedulePolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return calendar
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let offline = ScheduledTaskRunStatus.failed(SanitizedTaskFailure(category: "offline"))

    private func task(interval: Int = 30, lastRun: Date? = nil, enabled: Bool = true,
                      id: String = "t") -> AgentScheduler.ScheduledTask {
        .init(id: id, name: "Check the shed", prompt: "Check", intervalMinutes: interval,
              enabled: enabled, lastRun: lastRun, speakResult: false)
    }

    private func applying(_ statuses: [ScheduledTaskRunStatus], from start: ScheduledTaskState = .init(taskID: "t"),
                          at times: [Date]) -> ScheduledTaskState {
        zip(statuses, times).reduce(start) { state, pair in
            SchedulePolicy.apply(pair.0, to: state, trigger: .scheduled, seconds: 1, at: pair.1, jitter: 0)
        }
    }

    // MARK: - Exit criteria

    func testAFailureNeverRecordsASuccess() {
        let succeeded = applying([.succeeded(reported: true)], at: [t0])
        let failed = applying([offline, .couldNotCheck(reason: .noAppState)], from: succeeded,
                              at: [t0 + 3600, t0 + 7200])
        XCTAssertEqual(failed.lastSuccessAt, t0, "thrown errors never update lastSuccessAt")
        XCTAssertEqual(failed.lastAttemptAt, t0 + 7200)
        XCTAssertEqual(failed.consecutiveFailures, 2)
        XCTAssertEqual(failed.firstFailureAt, t0 + 3600)
        XCTAssertEqual(failed.lastFailure, .couldNotCheck(reason: .noAppState))
    }

    func testADeferralWaitsBrieflyAndIsNotAFailure() {
        let deferred = applying([.deferred(reason: .modelNotLoaded)], at: [t0])
        XCTAssertEqual(deferred.consecutiveFailures, 0)
        XCTAssertNil(deferred.lastFailure)
        XCTAssertEqual(deferred.nextEligibleAt, t0 + SchedulePolicy.deferralDelay)
        let due = task(lastRun: nil)
        XCTAssertFalse(SchedulePolicy.isDue(task: due, state: deferred, now: t0 + 60, calendar: calendar),
                       "deferred work retries only when eligible")
        XCTAssertTrue(SchedulePolicy.isDue(task: due, state: deferred, now: t0 + SchedulePolicy.deferralDelay,
                                           calendar: calendar))
    }

    func testAWeekOfMissedIntervalsIsOneCatchUpRun() {
        let weekAgo = t0 - 7 * 24 * 3600
        let hourly = task(interval: 60, lastRun: weekAgo)
        XCTAssertTrue(SchedulePolicy.isDue(task: hourly, state: nil, now: t0, calendar: calendar))
        // The run succeeds: the recurrence restarts from now, so nothing else is due this hour.
        let ran = task(interval: 60, lastRun: t0)
        let state = applying([.succeeded(reported: false)], at: [t0])
        XCTAssertFalse(SchedulePolicy.isDue(task: ran, state: state, now: t0 + 60, calendar: calendar))
        XCTAssertFalse(SchedulePolicy.isDue(task: ran, state: state, now: t0 + 3599, calendar: calendar))
        XCTAssertTrue(SchedulePolicy.isDue(task: ran, state: state, now: t0 + 3600, calendar: calendar))
    }

    func testRecoveryEndsTheEpisodeAndLeavesNoStaleWarning() {
        let times = [t0, t0 + 3 * 3600, t0 + 7 * 3600]
        var state = applying([offline, offline, offline], at: times)
        XCTAssertTrue(SchedulePolicy.shouldWarn(state, now: t0 + 7 * 3600))
        state = SchedulePolicy.markWarned(state, at: t0 + 7 * 3600)
        state = SchedulePolicy.apply(.succeeded(reported: true), to: state, trigger: .scheduled, seconds: 1,
                                     at: t0 + 8 * 3600, jitter: 0)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertNil(state.firstFailureAt)
        XCTAssertNil(state.lastFailure)
        XCTAssertNil(state.nextEligibleAt)
        XCTAssertNil(state.lastWarningAt)
        XCTAssertFalse(SchedulePolicy.shouldWarn(state, now: t0 + 30 * 3600))
    }

    func testRelaunchKeepsAttemptsBackoffAndWarningSuppression() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentScheduleStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = applying([offline, offline, offline], at: [t0, t0 + 3 * 3600, t0 + 7 * 3600])
        state = SchedulePolicy.markWarned(state, at: t0 + 7 * 3600)

        let store = AgentScheduleStateStore(directory: directory)
        store.update(state)
        let reloaded = AgentScheduleStateStore(directory: directory)
        let read = try XCTUnwrap(reloaded.state(for: "t"))
        XCTAssertEqual(read, state)
        XCTAssertEqual(read.nextEligibleAt, state.nextEligibleAt)
        XCTAssertFalse(SchedulePolicy.shouldWarn(read, now: t0 + 8 * 3600), "suppression survives a relaunch")

        reloaded.prune(keeping: [])
        XCTAssertNil(AgentScheduleStateStore(directory: directory).state(for: "t"),
                     "a deleted task leaves no state behind")
    }

    // MARK: - Backoff and warnings

    func testRetryDelaysClimbAndAreCapped() {
        XCTAssertEqual((1...7).map { SchedulePolicy.retryDelay(afterFailures: $0, jitter: 0) / 60 },
                       [5, 15, 30, 60, 120, 120, 120])
        XCTAssertEqual(SchedulePolicy.retryDelay(afterFailures: 1, jitter: 1), 5.5 * 60)
        XCTAssertEqual(SchedulePolicy.retryDelay(afterFailures: 5, jitter: 1), SchedulePolicy.maximumRetryDelay,
                       "jitter never takes a wait past two hours")
        let state = applying([offline, offline], at: [t0, t0 + 600])
        XCTAssertEqual(state.nextEligibleAt, t0 + 600 + 15 * 60)
    }

    func testAWarningNeedsThreeFailuresAndSixHours() {
        let quick = applying([offline, offline, offline], at: [t0, t0 + 600, t0 + 1200])
        XCTAssertFalse(SchedulePolicy.shouldWarn(quick, now: t0 + 1200), "three failures inside six hours")
        XCTAssertTrue(SchedulePolicy.shouldWarn(quick, now: t0 + 6 * 3600))
        let two = applying([offline, offline], at: [t0, t0 + 600])
        XCTAssertFalse(SchedulePolicy.shouldWarn(two, now: t0 + 24 * 3600), "six hours but two failures")
        let afterSuccess = applying([.succeeded(reported: true), offline, offline, offline],
                                    at: [t0, t0 + 5 * 3600, t0 + 5 * 3600 + 600, t0 + 5 * 3600 + 1200])
        XCTAssertFalse(SchedulePolicy.shouldWarn(afterSuccess, now: t0 + 5 * 3600 + 1200),
                       "six hours since the last success, not since the first failure ever")
        XCTAssertTrue(SchedulePolicy.shouldWarn(afterSuccess, now: t0 + 6 * 3600))
    }

    func testAWarningIsNotRepeatedForADayUnlessTheReasonChanges() {
        var state = applying([offline, offline, offline], at: [t0, t0 + 600, t0 + 1200])
        state = SchedulePolicy.markWarned(state, at: t0 + 6 * 3600)
        XCTAssertFalse(SchedulePolicy.shouldWarn(state, now: t0 + 12 * 3600))
        XCTAssertTrue(SchedulePolicy.shouldWarn(state, now: t0 + 30 * 3600 + 1))
        let changed = SchedulePolicy.apply(.couldNotCheck(reason: .pinnedModelMissing), to: state,
                                           trigger: .scheduled, seconds: 0, at: t0 + 7 * 3600, jitter: 0)
        XCTAssertTrue(SchedulePolicy.shouldWarn(changed, now: t0 + 7 * 3600), "a different reason warns again")
    }

    func testACancelledRunIsAnAttemptButNeitherSuccessNorFailure() {
        let state = applying([offline, .cancelled], at: [t0, t0 + 600])
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertEqual(state.lastAttemptAt, t0 + 600)
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertEqual(state.recentRuns.map(\.status), [offline, .cancelled])
    }

    func testHistoryIsBounded() {
        let times = (0..<25).map { t0 + Double($0) * 60 }
        let state = applying(Array(repeating: .succeeded(reported: false), count: 25), at: times)
        XCTAssertEqual(state.recentRuns.count, SchedulePolicy.maxRecentRuns)
        XCTAssertEqual(state.recentRuns.first?.at, times[5])
    }

    // MARK: - Execution policy

    func testOnlyALoadedLocalModelInTheForegroundOrACloudModelRuns() {
        XCTAssertNil(SchedulePolicy.readinessDecision(.localLoaded, inForeground: true))
        XCTAssertEqual(SchedulePolicy.readinessDecision(.localLoaded, inForeground: false), .localModelInBackground)
        XCTAssertEqual(SchedulePolicy.readinessDecision(.localNotLoaded, inForeground: true), .modelNotLoaded)
        XCTAssertEqual(SchedulePolicy.readinessDecision(.localNotLoaded, inForeground: false), .modelNotLoaded)
        XCTAssertNil(SchedulePolicy.readinessDecision(.cloud, inForeground: false))
    }

    func testNextWakeIsTheLaterOfRecurrenceAndWait() {
        let hourly = task(interval: 60, lastRun: t0)
        XCTAssertEqual(SchedulePolicy.nextRun(task: hourly, state: nil, now: t0, calendar: calendar), t0 + 3600)
        var waiting = ScheduledTaskState(taskID: "t")
        waiting.nextEligibleAt = t0 + 2 * 3600
        XCTAssertEqual(SchedulePolicy.nextRun(task: hourly, state: waiting, now: t0, calendar: calendar), t0 + 2 * 3600)
        XCTAssertNil(SchedulePolicy.nextRun(task: task(enabled: false), state: nil, now: t0, calendar: calendar))
        XCTAssertEqual(SchedulePolicy.nextWake(tasks: [hourly, task(interval: 30, lastRun: t0, id: "u")],
                                               states: ["t": waiting], now: t0, calendar: calendar), t0 + 1800)
    }

    func testBackgroundOutcomes() {
        XCTAssertEqual(AgentScheduler.backgroundOutcome(nil), .nothingToDo)
        XCTAssertEqual(AgentScheduler.backgroundOutcome(.succeeded(reported: false)), .didWork)
        XCTAssertEqual(AgentScheduler.backgroundOutcome(.deferred(reason: .localModelInBackground)), .deferred)
        XCTAssertEqual(AgentScheduler.backgroundOutcome(.cancelled), .cancelled)
        XCTAssertEqual(AgentScheduler.backgroundOutcome(offline), .failed)
        XCTAssertEqual(AgentScheduler.backgroundOutcome(.couldNotCheck(reason: .noAppState)), .failed)
    }

    func testStatusesRoundTripAndHaveFixedTokens() throws {
        let all: [ScheduledTaskRunStatus] = [.succeeded(reported: true), .succeeded(reported: false),
                                             .deferred(reason: .modelNotLoaded), .couldNotCheck(reason: .noAppState),
                                             offline, .cancelled]
        let data = try JSONEncoder().encode(all)
        XCTAssertEqual(try JSONDecoder().decode([ScheduledTaskRunStatus].self, from: data), all)
        XCTAssertEqual(all.map(\.token), ["succeeded", "succeeded.nothing", "deferred.modelNotLoaded",
                                          "couldNotCheck.noAppState", "failed.offline", "cancelled"])
        for status in all { XCTAssertFalse(ScheduledRunWording.outcome(status).isEmpty) }
    }

    // MARK: - The scheduler's write

    func testOnlyASuccessAdvancesTheTasksRecurrence() throws {
        let key = "agentScheduledTasks"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentScheduleStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = task(interval: 30, lastRun: t0 - 7200)
        AgentScheduler.saveTasks([original])
        let scheduler = AgentScheduler()
        scheduler.stateStore = AgentScheduleStateStore(directory: directory)
        scheduler.jitter = { 0 }

        scheduler.record(offline, for: original, trigger: .scheduled, seconds: 1, at: t0)
        XCTAssertEqual(AgentScheduler.savedTasks().first?.lastRun, t0 - 7200, "a failure leaves the recurrence alone")
        XCTAssertEqual(scheduler.state(for: "t")?.consecutiveFailures, 1)

        scheduler.record(.succeeded(reported: true), for: original, trigger: .manual, seconds: 1, at: t0 + 600)
        XCTAssertEqual(AgentScheduler.savedTasks().first?.lastRun, t0 + 600)
        XCTAssertEqual(scheduler.state(for: "t")?.consecutiveFailures, 0)
        XCTAssertEqual(scheduler.state(for: "t")?.recentRuns.map(\.trigger), [.scheduled, .manual])
    }
}
