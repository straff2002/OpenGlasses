import Foundation

/// The expert's own clock in Assisting mode (Plan KM §6, P2): their time on someone else's job.
///
/// - **Take this job** starts it, and is the receipt that they took it.
/// - **Pause** and **Resume** stop and restart it; **Done** stops it for good.
/// - **It survives the app dying.** While it runs, the app writes a checkpoint — everything up to
///   it is already counted — every minute and whenever it leaves the foreground. A relaunch that
///   finds the clock still running recovers it the way a job's billable time is recovered
///   (`BillableClock.recover`, Plan GB P3): the time up to the last checkpoint is kept, the clock
///   is paused there, and the time between that and the relaunch is not counted, and is said so on
///   the reply.
///
/// Pure: every instant is an argument, so every rule is a test.
struct AssistingClock: Codable, Equatable, Sendable {
    /// When the expert tapped Take this job.
    private(set) var acceptedAt: Date
    /// Seconds already counted: up to `checkpointAt`, or up to the last pause.
    private(set) var countedSeconds: TimeInterval
    /// The last Resume. Nil for a clock never paused.
    private(set) var resumedAt: Date?
    /// Set while paused.
    private(set) var pausedAt: Date?
    /// Everything before it is already in `countedSeconds`.
    private(set) var checkpointAt: Date?
    private(set) var doneAt: Date?
    /// Time lost after the app was killed: from the last checkpoint to the relaunch.
    private(set) var uncountedSeconds: TimeInterval
    /// Set when a relaunch paused the clock because the app had closed under it; cleared on Resume.
    private(set) var pausedWhenAppClosed: Bool

    /// The clock started by Take this job.
    static func take(at now: Date) -> AssistingClock {
        AssistingClock(acceptedAt: now, countedSeconds: 0, resumedAt: nil, pausedAt: nil, checkpointAt: nil,
                       doneAt: nil, uncountedSeconds: 0, pausedWhenAppClosed: false)
    }

    var isDone: Bool { doneAt != nil }
    var isPaused: Bool { !isDone && pausedAt != nil }
    var isRunning: Bool { !isDone && pausedAt == nil }

    /// Where counting runs from while the clock runs: the later of the last resume (or the start)
    /// and the last checkpoint.
    private var anchor: Date {
        let resumed = resumedAt ?? acceptedAt
        return max(resumed, checkpointAt ?? resumed)
    }

    /// Seconds on the clock at `now`.
    func seconds(at now: Date) -> TimeInterval {
        guard isRunning else { return countedSeconds }
        return countedSeconds + max(0, now.timeIntervalSince(anchor))
    }

    /// Whole minutes on the clock at `now`, rounded to the nearest.
    func minutes(at now: Date) -> Int { Self.wholeMinutes(seconds(at: now)) }

    var uncountedMinutes: Int { Self.wholeMinutes(uncountedSeconds) }

    static func wholeMinutes(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) / 60).rounded()) }

    /// The newest instant anything happened to the clock.
    var lastActivity: Date {
        [acceptedAt, resumedAt, pausedAt, checkpointAt, doneAt].compactMap { $0 }.max() ?? acceptedAt
    }

    // MARK: - The controls

    mutating func pause(at now: Date) {
        guard isRunning else { return }
        countedSeconds = seconds(at: now)
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard isPaused else { return }
        pausedAt = nil
        resumedAt = now
        checkpointAt = nil
        pausedWhenAppClosed = false
    }

    mutating func done(at now: Date) {
        guard !isDone else { return }
        countedSeconds = seconds(at: now)
        if pausedAt == nil { pausedAt = now }
        doneAt = now
        pausedWhenAppClosed = false
    }

    /// A sign of life while it runs: fold the time so far into the total.
    mutating func checkpoint(at now: Date) {
        guard isRunning, now > anchor else { return }
        countedSeconds = seconds(at: now)
        checkpointAt = now
    }

    // MARK: - After the app died

    /// The app relaunched and found this clock running: it did not stop on its own, so the app was
    /// killed under it. Recovered with `BillableClock`'s rule — counted to the last checkpoint,
    /// paused there, the rest not counted — and returns what was recovered, or nil when the clock
    /// was not running and there was nothing to recover.
    @discardableResult
    mutating func recoverAfterRelaunch(now: Date) -> BillableClock.Recovery? {
        guard isRunning else { return nil }
        let recovery = BillableClock.recover(startedAt: acceptedAt, resumedAt: resumedAt, pausedAt: nil,
                                             checkpointAt: checkpointAt, lastEvidenceOfLife: checkpointAt,
                                             now: now)
        countedSeconds += recovery.creditedSeconds
        checkpointAt = recovery.pausedAt
        pausedAt = recovery.pausedAt
        uncountedSeconds += recovery.uncountedSeconds
        pausedWhenAppClosed = true
        return recovery
    }
}
