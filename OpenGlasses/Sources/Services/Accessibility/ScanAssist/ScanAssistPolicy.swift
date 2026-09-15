import Foundation

/// Where a Scan Assist session is in its life.
enum ScanAssistState: Equatable, Sendable {
    case idle
    case running
    case paused
    case ended(ScanAssistEndReason)

    var isRunning: Bool { self == .running }
    var isPaused: Bool { self == .paused }
    /// Running or paused — a session exists and owns scheduled work.
    var isLive: Bool { isRunning || isPaused }
}

/// Why a session finished. Both are ordinary endings; neither is an error.
enum ScanAssistEndReason: String, Equatable, Sendable {
    /// The wearer stopped it.
    case stopped
    /// The chosen session length ran out.
    case expired
}

/// Everything that can move a session.
///
/// `tick` is the only time-driven event: the owner wakes at `nextWakeDeadline` and calls it. The
/// policy reads its injected clock rather than trusting the caller's idea of "now", so a late
/// wake-up produces the same decision a punctual one would.
enum ScanAssistEvent: Equatable, Sendable {
    case start
    case pause
    case resume
    case stop
    case tick
    case sideChanged(ScanAssistSide?)
    case timingChanged(interval: ScanAssistInterval, duration: ScanAssistSessionDuration)
    case expired
}

/// What the owner must do about an event. An empty result means "nothing".
enum ScanAssistOutput: Equatable, Sendable {
    /// Deliver one reminder for `side` now. `generation` is the session generation at the moment
    /// the cue was produced, so a cue that loses a race with a stop or a side change is
    /// recognisable as stale by the thing about to speak it.
    case emitCue(side: ScanAssistSide, generation: Int)
    /// Drop any reminder already scheduled. It belongs to a side, a rhythm or a session that no
    /// longer exists.
    case cancelQueuedCue
    /// The session is over: cancel everything it owned, queued speech included.
    case sessionEnded(reason: ScanAssistEndReason)
}

/// The deterministic core of Scan Assist (docs/plans/FB-scan-assist.md P1).
///
/// No hardware, no speech, no `Task`, no wall clock — a monotonic clock closure is the only thing
/// it reads from the outside world, so every schedule, cancellation and expiry in this feature is
/// decided somewhere a test can step through second by second.
///
/// ## Events → outputs
///
/// | State | Event | Next state | Outputs |
/// |---|---|---|---|
/// | idle/ended | `start` (side chosen) | running | — (owner schedules `nextWakeDeadline`) |
/// | idle/ended | `start` (no side) | unchanged | — |
/// | running/paused | `start` | unchanged | — (a repeat start is harmless) |
/// | running | `pause` | paused | `cancelQueuedCue` |
/// | paused | `resume` | running | `cancelQueuedCue` (fresh interval, no backlog) |
/// | running/paused | `stop` | ended(.stopped) | `cancelQueuedCue`, `sessionEnded(.stopped)` |
/// | idle/ended | `stop` | unchanged | — |
/// | running | `tick` at/after expiry | ended(.expired) | `cancelQueuedCue`, `sessionEnded(.expired)` |
/// | running | `tick` at/after cue deadline | running | `emitCue(side, generation)` |
/// | running | `tick` before either deadline | running | — |
/// | running | `sideChanged(new)` | running | `cancelQueuedCue` (same deadline, new side) |
/// | running | `sideChanged(nil)` | ended(.stopped) | `cancelQueuedCue`, `sessionEnded(.stopped)` |
/// | running | `timingChanged` | running | `cancelQueuedCue` (rescheduled from now) |
/// | running/paused | `expired` | ended(.expired) | `cancelQueuedCue`, `sessionEnded(.expired)` |
/// | any | (config event while not running) | unchanged | — (config is stored, nothing scheduled) |
///
/// `generation` increments on every transition that invalidates scheduled work, which is how a
/// callback that arrives after a stop, a pause or a side change is recognised and dropped.
struct ScanAssistPolicy {

    /// Monotonic seconds. `ProcessInfo.systemUptime` by default: it never jumps backwards when the
    /// wearer's clock changes, which a reminder rhythm must not do either.
    private let now: () -> TimeInterval

    private(set) var state: ScanAssistState = .idle
    private(set) var side: ScanAssistSide?
    private(set) var interval: ScanAssistInterval
    private(set) var sessionDuration: ScanAssistSessionDuration

    /// Bumped by every invalidating transition. Scheduled work carries the generation it was
    /// scheduled under and is ignored once this moves past it.
    private(set) var generation: Int = 0

    /// When the next reminder is due, in the clock's units. `nil` whenever nothing is scheduled.
    private(set) var nextCueDeadline: TimeInterval?
    /// When the session ends itself. `nil` when no session is running.
    private(set) var sessionExpiry: TimeInterval?
    /// Session time left at the moment of a pause, so a resume continues rather than restarts.
    private var remainingAtPause: TimeInterval?

    init(side: ScanAssistSide? = nil,
         interval: ScanAssistInterval = .thirtySeconds,
         sessionDuration: ScanAssistSessionDuration = .fiveMinutes,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.side = side
        self.interval = interval
        self.sessionDuration = sessionDuration
        self.now = now
    }

    /// The earlier of the next reminder and the end of the session — the one moment the owner has
    /// to wake up for. Without folding expiry in here, a session whose remaining time is shorter
    /// than one interval would keep running past its own end until the next reminder came due.
    var nextWakeDeadline: TimeInterval? {
        switch (nextCueDeadline, sessionExpiry) {
        case let (cue?, expiry?): return min(cue, expiry)
        case let (cue?, nil): return cue
        case let (nil, expiry?): return expiry
        case (nil, nil): return nil
        }
    }

    /// Session time left, for the countdown the wearer reads. `nil` when no session is live.
    var remainingSeconds: TimeInterval? {
        if state.isPaused { return remainingAtPause.map { max(0, $0) } }
        guard state.isRunning, let sessionExpiry else { return nil }
        return max(0, sessionExpiry - now())
    }

    // MARK: - Transitions

    @discardableResult
    mutating func handle(_ event: ScanAssistEvent) -> [ScanAssistOutput] {
        switch event {
        case .start: return start()
        case .pause: return pause()
        case .resume: return resume()
        case .stop: return end(reason: .stopped)
        case .tick: return tick()
        case .sideChanged(let newSide): return sideChanged(to: newSide)
        case .timingChanged(let newInterval, let newDuration):
            return timingChanged(interval: newInterval, duration: newDuration)
        case .expired: return end(reason: .expired)
        }
    }

    private mutating func start() -> [ScanAssistOutput] {
        // A second start on a live session is a no-op, not a restart: two taps on Start must not
        // give the wearer two overlapping rhythms, and must not silently reset their remaining
        // time either.
        guard !state.isLive else { return [] }
        // No side, no session. The question has to be answered by a person.
        guard side != nil else { return [] }

        generation += 1
        state = .running
        let at = now()
        // The first reminder lands one interval in, not at the tap: the wearer just looked at the
        // screen to start it.
        nextCueDeadline = at + interval.seconds
        sessionExpiry = at + sessionDuration.seconds
        remainingAtPause = nil
        return []
    }

    private mutating func pause() -> [ScanAssistOutput] {
        guard state.isRunning else { return [] }
        generation += 1
        state = .paused
        remainingAtPause = sessionExpiry.map { max(0, $0 - now()) }
        nextCueDeadline = nil
        sessionExpiry = nil
        return [.cancelQueuedCue]
    }

    private mutating func resume() -> [ScanAssistOutput] {
        guard state.isPaused else { return [] }
        generation += 1
        state = .running
        let at = now()
        // A fresh interval from the resume, and no backlog: a pause is not a queue. Whatever was
        // due while paused is gone rather than replayed as a burst.
        nextCueDeadline = at + interval.seconds
        sessionExpiry = at + (remainingAtPause ?? sessionDuration.seconds)
        remainingAtPause = nil
        return [.cancelQueuedCue]
    }

    private mutating func end(reason: ScanAssistEndReason) -> [ScanAssistOutput] {
        // Repeated stops are harmless — and an already-ended session must not report a second
        // ending, or a wearer tapping Stop twice hears the ending treatment twice.
        guard state.isLive else { return [] }
        generation += 1
        state = .ended(reason)
        nextCueDeadline = nil
        sessionExpiry = nil
        remainingAtPause = nil
        return [.cancelQueuedCue, .sessionEnded(reason: reason)]
    }

    private mutating func tick() -> [ScanAssistOutput] {
        guard state.isRunning else { return [] }
        let at = now()
        // Expiry first: when a reminder and the end of the session fall on the same instant, the
        // session is over. A last reminder for a session that has just ended would be a reminder
        // with nothing behind it.
        if let sessionExpiry, at >= sessionExpiry {
            return end(reason: .expired)
        }
        guard let deadline = nextCueDeadline, at >= deadline, let side else { return [] }
        generation += 1
        // Schedule from the moment the cue actually fires, not from the deadline it missed: a late
        // wake-up must not shorten the next gap trying to catch up.
        nextCueDeadline = at + interval.seconds
        return [.emitCue(side: side, generation: generation)]
    }

    private mutating func sideChanged(to newSide: ScanAssistSide?) -> [ScanAssistOutput] {
        guard newSide != side else { return [] }
        side = newSide
        guard state.isLive else { return [] }

        guard newSide != nil else {
            // Clearing the side mid-session leaves nothing to point at. Ending is the honest
            // outcome; carrying on with the old side would be the app choosing a side.
            return end(reason: .stopped)
        }

        generation += 1
        // The rhythm is unchanged — only which side it names. A queued cue for the old side is
        // dropped and the same deadline is kept, so switching sides does not quietly reset the
        // wearer's gap the way changing the interval does.
        return [.cancelQueuedCue]
    }

    private mutating func timingChanged(interval newInterval: ScanAssistInterval,
                                        duration newDuration: ScanAssistSessionDuration) -> [ScanAssistOutput] {
        guard newInterval != interval || newDuration != sessionDuration else { return [] }
        interval = newInterval
        sessionDuration = newDuration
        guard state.isLive else { return [] }

        generation += 1
        let at = now()
        if state.isPaused {
            remainingAtPause = newDuration.seconds
            return [.cancelQueuedCue]
        }
        // From the change, not from the old start: a wearer who lengthens the gap should not still
        // hear the cue the old gap had already queued.
        nextCueDeadline = at + newInterval.seconds
        sessionExpiry = at + newDuration.seconds
        return [.cancelQueuedCue]
    }
}
