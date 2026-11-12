import Foundation

// Plan LM P3 / Plan DZ PR6 — durable scheduler semantics.
//
// A scheduled prompt task's definition (`AgentScheduler.ScheduledTask`, the wearer's words) and its
// execution state (`ScheduledTaskState`, dates, counts and fixed reason tokens) are kept apart. The
// rules that turn a run's outcome into the next state live here, pure, so tests never sleep and
// tuning the retry delays never touches execution code.

/// Why a run did not happen yet, through no fault of the task. A deferral sets a short wait and
/// never counts as a failure.
enum ScheduleDeferralReason: String, Codable, Equatable, Sendable {
    /// The on-device model is not in memory; a scheduled run never loads it.
    case modelNotLoaded
    /// The on-device model cannot run while the app is in the background.
    case localModelInBackground
}

/// Why a run could not even be tried. Counts as a failure: something the task needs is missing.
enum ScheduleCheckFailure: String, Codable, Equatable, Sendable {
    /// The app's state was not there to run against (a launch that never built it).
    case noAppState
    /// The task is pinned to a model that is no longer saved. It never runs on another one.
    case pinnedModelMissing
    /// The task is pinned to a persona that is gone or switched off.
    case pinnedPersonaMissing
}

/// A failed run, reduced to the closed vocabulary of `SafeErrorSummary`. Never response text.
struct SanitizedTaskFailure: Codable, Equatable, Sendable {
    /// A `SafeErrorSummary.Category` raw value.
    let category: String

    init(category: String) { self.category = category }

    init(_ error: Error) {
        category = SafeErrorSummary(error).category.rawValue
    }
}

/// What one run of a scheduled prompt task came to.
enum ScheduledTaskRunStatus: Codable, Equatable, Sendable {
    /// It ran. `reported` is false for `[NOTHING]` — nothing worth saying is still a success.
    case succeeded(reported: Bool)
    case deferred(reason: ScheduleDeferralReason)
    case couldNotCheck(reason: ScheduleCheckFailure)
    case failed(SanitizedTaskFailure)
    /// Stopped before it finished — the wearer's own turn started, or the background wake ended.
    case cancelled

    /// A fixed token naming the outcome and its reason: what the history shows and what "the
    /// failure reason changed" compares.
    var token: String {
        switch self {
        case .succeeded(let reported): return reported ? "succeeded" : "succeeded.nothing"
        case .deferred(let reason): return "deferred.\(reason.rawValue)"
        case .couldNotCheck(let reason): return "couldNotCheck.\(reason.rawValue)"
        case .failed(let failure): return "failed.\(failure.category)"
        case .cancelled: return "cancelled"
        }
    }

    var countsAsFailure: Bool {
        switch self {
        case .couldNotCheck, .failed: return true
        case .succeeded, .deferred, .cancelled: return false
        }
    }
}

/// What started a run.
enum ScheduledRunTrigger: String, Codable, Equatable, Sendable {
    /// The foreground timer's cycle.
    case scheduled
    /// The shared background wake (Plan LM).
    case background
    /// "Run now" in Scheduled Tasks.
    case manual
}

/// One run in a task's bounded history. No response text.
struct ScheduledTaskRunRecord: Codable, Equatable, Sendable {
    let at: Date
    let trigger: ScheduledRunTrigger
    let status: ScheduledTaskRunStatus
    let seconds: Double
}

/// A task's mutable execution state, kept apart from its definition.
struct ScheduledTaskState: Codable, Equatable, Sendable {
    let taskID: String
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    /// Not before this — set by a deferral's short wait or a failure's backoff.
    var nextEligibleAt: Date?
    var consecutiveFailures: Int = 0
    var firstFailureAt: Date?
    var lastFailure: ScheduledTaskRunStatus?
    var lastWarningAt: Date?
    /// The failure token the last warning was given for: a materially different reason may warn
    /// again inside the 24-hour suppression.
    var lastWarningToken: String?
    var recentRuns: [ScheduledTaskRunRecord] = []

    init(taskID: String) { self.taskID = taskID }
}

/// How the task's model would run right now.
enum ScheduleModelReadiness: Equatable, Sendable {
    case localLoaded
    case localNotLoaded
    case cloud
}

enum SchedulePolicy {

    /// Retry waits after the 1st, 2nd, … consecutive failure, in minutes; the last repeats.
    static let retryDelayMinutes: [Int] = [5, 15, 30, 60, 120]
    /// No retry wait is ever longer than this, jitter included.
    static let maximumRetryDelay: TimeInterval = 2 * 60 * 60
    /// The wait after a deferral. Short: the cause is usually gone in minutes.
    static let deferralDelay: TimeInterval = 5 * 60
    /// History kept per task.
    static let maxRecentRuns = 20
    /// A warning needs this many consecutive failures…
    static let warningFailureCount = 3
    /// …and this long without a success, whichever is later.
    static let warningQuietPeriod: TimeInterval = 6 * 60 * 60
    /// The same warning is not repeated inside this.
    static let warningSuppression: TimeInterval = 24 * 60 * 60

    /// The wait after `failures` consecutive failures (≥ 1). `jitter` in 0…1 adds up to a tenth,
    /// so many tasks failing together do not retry together; tests pass a fixed value.
    static func retryDelay(afterFailures failures: Int, jitter: Double) -> TimeInterval {
        let index = min(max(failures, 1), retryDelayMinutes.count) - 1
        let base = TimeInterval(retryDelayMinutes[index]) * 60
        let spread = base * 0.1 * min(max(jitter, 0), 1)
        return min(base + spread, maximumRetryDelay)
    }

    /// Whether the task may run at all yet: no deferral wait or backoff still pending.
    static func isEligible(_ state: ScheduledTaskState?, now: Date) -> Bool {
        guard let next = state?.nextEligibleAt else { return true }
        return next <= now
    }

    /// Whether a prompt task is due: its recurrence says so (`ScheduleDuePolicy`, read from the
    /// last *successful* run) and nothing makes it wait. A week of missed intervals is one due run,
    /// not seven: the recurrence restarts from that run.
    static func isDue(task: AgentScheduler.ScheduledTask, state: ScheduledTaskState?,
                      now: Date, calendar: Calendar) -> Bool {
        ScheduleDuePolicy.isDue(task: task, now: now, calendar: calendar) && isEligible(state, now: now)
    }

    /// When the task can next run: the later of its recurrence and its wait. Nil when switched off.
    static func nextRun(task: AgentScheduler.ScheduledTask, state: ScheduledTaskState?,
                        now: Date, calendar: Calendar) -> Date? {
        guard let due = ScheduleDuePolicy.nextDue(task: task, now: now, calendar: calendar) else { return nil }
        guard let eligible = state?.nextEligibleAt else { return due }
        return max(due, eligible)
    }

    /// The soonest any of `tasks` can run, for a background wake request. Nil when none can.
    static func nextWake(tasks: [AgentScheduler.ScheduledTask], states: [String: ScheduledTaskState],
                         now: Date, calendar: Calendar) -> Date? {
        tasks.compactMap { nextRun(task: $0, state: states[$0.id], now: now, calendar: calendar) }.min()
    }

    /// Whether the task's model may run now. A local model runs only loaded and in the foreground,
    /// and is never loaded for a scheduled run; a cloud model is eligible here, and its own
    /// credentials, privacy mode and network policy still decide at the request.
    static func readinessDecision(_ readiness: ScheduleModelReadiness,
                                  inForeground: Bool) -> ScheduleDeferralReason? {
        switch readiness {
        case .localNotLoaded: return .modelNotLoaded
        case .localLoaded: return inForeground ? nil : .localModelInBackground
        case .cloud: return nil
        }
    }

    /// The state after a run that ended `status` at `now`.
    static func apply(_ status: ScheduledTaskRunStatus, to state: ScheduledTaskState,
                      trigger: ScheduledRunTrigger, seconds: Double, at now: Date,
                      jitter: Double) -> ScheduledTaskState {
        var next = state
        next.lastAttemptAt = now
        switch status {
        case .succeeded:
            next.lastSuccessAt = now
            next.nextEligibleAt = nil
            next.consecutiveFailures = 0
            next.firstFailureAt = nil
            next.lastFailure = nil
            // Recovery ends the warning episode.
            next.lastWarningAt = nil
            next.lastWarningToken = nil
        case .deferred:
            next.nextEligibleAt = now.addingTimeInterval(deferralDelay)
        case .couldNotCheck, .failed:
            next.consecutiveFailures += 1
            if next.firstFailureAt == nil { next.firstFailureAt = now }
            next.lastFailure = status
            next.nextEligibleAt = now.addingTimeInterval(
                retryDelay(afterFailures: next.consecutiveFailures, jitter: jitter))
        case .cancelled:
            break
        }
        next.recentRuns = Array((next.recentRuns + [ScheduledTaskRunRecord(
            at: now, trigger: trigger, status: status, seconds: seconds)]).suffix(maxRecentRuns))
        return next
    }

    /// Whether to warn the wearer now: three consecutive failures and six hours without a success
    /// (since the first failure when it has never succeeded), not warned in the last 24 hours —
    /// unless the failure is now for a different reason.
    static func shouldWarn(_ state: ScheduledTaskState, now: Date) -> Bool {
        guard state.consecutiveFailures >= warningFailureCount,
              let failure = state.lastFailure,
              let since = state.lastSuccessAt ?? state.firstFailureAt,
              now.timeIntervalSince(since) >= warningQuietPeriod else { return false }
        guard let warned = state.lastWarningAt else { return true }
        if state.lastWarningToken != failure.token { return true }
        return now.timeIntervalSince(warned) >= warningSuppression
    }

    /// The state after a warning was given.
    static func markWarned(_ state: ScheduledTaskState, at now: Date) -> ScheduledTaskState {
        var next = state
        next.lastWarningAt = now
        next.lastWarningToken = state.lastFailure?.token
        return next
    }
}

/// What Scheduled Tasks says about a run: the outcome and its reason in plain words, never the
/// task's result.
enum ScheduledRunWording {
    static func outcome(_ status: ScheduledTaskRunStatus) -> String {
        switch status {
        case .succeeded(let reported):
            return reported ? String(localized: "Ran and had something to say")
                            : String(localized: "Ran, nothing to report")
        case .deferred(.modelNotLoaded):
            return String(localized: "Waiting for the on-device model to be loaded")
        case .deferred(.localModelInBackground):
            return String(localized: "Waiting for the app to be open (on-device model)")
        case .couldNotCheck(.noAppState):
            return String(localized: "Couldn't run: the app wasn't ready")
        case .couldNotCheck(.pinnedModelMissing):
            return String(localized: "Couldn't run: its model is no longer saved")
        case .couldNotCheck(.pinnedPersonaMissing):
            return String(localized: "Couldn't run: its persona is gone or switched off")
        case .failed(let failure):
            return failed(failure.category)
        case .cancelled:
            return String(localized: "Stopped before it finished")
        }
    }

    private static func failed(_ category: String) -> String {
        switch SafeErrorSummary.Category(rawValue: category) {
        case .offline?, .timedOut?, .cannotConnect?:
            return String(localized: "Failed: no connection")
        case .unauthorized?, .forbidden?:
            return String(localized: "Failed: the provider refused the key")
        case .rateLimited?, .overAllowance?:
            return String(localized: "Failed: the provider's limit was reached")
        default:
            return String(localized: "Failed: the request didn't work")
        }
    }

    static func trigger(_ trigger: ScheduledRunTrigger) -> String {
        switch trigger {
        case .scheduled: return String(localized: "On schedule")
        case .background: return String(localized: "In the background")
        case .manual: return String(localized: "Run now")
        }
    }
}
