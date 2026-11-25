import Foundation

/// Plan NH §1 — when a turn's time stops. A turn counts from the moment it is sent until its reply
/// has finished: spoken, or, if nothing speaks it, shown. Pure state: the service feeds it the
/// turn's start and end, the speech engine's on/off and a clock tick, and adds whatever charge comes
/// back to the ledger.
///
/// "Shown" is the moment the reply came back from the model. "Spoken" is the moment the speech
/// engine went quiet after it. A reply that starts speaking within `speechSettle` of coming back is
/// waited for; one that does not is charged as shown. The ceiling bounds both, so speech that never
/// reports its end cannot drain the day.
struct TurnChargeTracker: Equatable {

    /// How long after a reply comes back its speech may start and still count as part of the turn.
    static let speechSettle: TimeInterval = 1.5

    enum Phase: Equatable {
        case idle
        /// Sent; the model is working (tool calls included).
        case running(startedAt: Date)
        /// The reply came back. `speechSeen`: its speech has started, so the turn ends when it stops.
        case replied(startedAt: Date, repliedAt: Date, speechSeen: Bool)
    }

    private(set) var phase: Phase = .idle

    var isIdle: Bool { phase == .idle }

    /// A turn was sent. A previous turn still waiting on its speech is closed now and its charge
    /// returned: a new turn is the end of the last one.
    mutating func begin(at now: Date) -> Int? {
        let previous = close(at: now)
        phase = .running(startedAt: now)
        return previous
    }

    /// The reply came back from the model.
    mutating func replyReturned(at now: Date, speaking: Bool) {
        guard case .running(let startedAt) = phase else { return }
        phase = .replied(startedAt: startedAt, repliedAt: now, speechSeen: speaking)
    }

    /// The speech engine started or stopped.
    mutating func speech(active: Bool, at now: Date) -> Int? {
        guard case .replied(let startedAt, let repliedAt, let seen) = phase else { return nil }
        if active {
            if !seen, now.timeIntervalSince(repliedAt) <= Self.speechSettle {
                phase = .replied(startedAt: startedAt, repliedAt: repliedAt, speechSeen: true)
            }
            return nil
        }
        guard seen else { return nil }
        phase = .idle
        return DailyAllowancePolicy.turnCharge(startedAt: startedAt, finishedAt: now)
    }

    /// The clock moved. Closes a shown reply once the settle has passed without speech, and any
    /// turn that reached the ceiling.
    mutating func tick(at now: Date) -> Int? {
        switch phase {
        case .idle:
            return nil
        case .running(let startedAt):
            guard now.timeIntervalSince(startedAt) >= TimeInterval(DailyAllowancePolicy.turnCeilingSeconds) else { return nil }
            phase = .idle
            return DailyAllowancePolicy.turnCeilingSeconds
        case .replied(let startedAt, let repliedAt, let seen):
            if now.timeIntervalSince(startedAt) >= TimeInterval(DailyAllowancePolicy.turnCeilingSeconds) {
                phase = .idle
                return DailyAllowancePolicy.turnCeilingSeconds
            }
            guard !seen, now.timeIntervalSince(repliedAt) > Self.speechSettle else { return nil }
            phase = .idle
            return DailyAllowancePolicy.turnCharge(startedAt: startedAt, finishedAt: repliedAt)
        }
    }

    /// Close whatever is open at `now` and return its charge.
    mutating func close(at now: Date) -> Int? {
        switch phase {
        case .idle:
            return nil
        case .running(let startedAt):
            phase = .idle
            return DailyAllowancePolicy.turnCharge(startedAt: startedAt, finishedAt: now)
        case .replied(let startedAt, let repliedAt, let seen):
            phase = .idle
            return DailyAllowancePolicy.turnCharge(startedAt: startedAt, finishedAt: seen ? now : repliedAt)
        }
    }
}

/// Plan NH §4 — a Live session against the allowance. Pure: the service ticks it once a second
/// with the seconds left and whether an answer is under way, and does what comes back.
///
/// One spoken warning at `liveWarningSeconds` left. At zero the answer in progress finishes: the
/// session closes at the first tick after zero with nothing under way, and never later than
/// `liveGraceSeconds` after zero.
struct LiveAllowanceSession: Equatable {

    enum Effect: Equatable {
        /// Say `DailyAllowancePolicy.liveWarningLine`, once.
        case warn
        /// Close the session and say `DailyAllowancePolicy.exhaustedLine`.
        case close
    }

    private(set) var warned = false
    private(set) var reachedZeroAt: Date?
    private(set) var closed = false

    mutating func tick(remainingSeconds: Int, answerInProgress: Bool, now: Date) -> [Effect] {
        guard !closed else { return [] }
        var effects: [Effect] = []
        if !warned, remainingSeconds <= DailyAllowancePolicy.liveWarningSeconds {
            warned = true
            if remainingSeconds > 0 { effects.append(.warn) }
        }
        guard remainingSeconds <= 0 else { return effects }
        let zero = reachedZeroAt ?? now
        reachedZeroAt = zero
        if !answerInProgress || now.timeIntervalSince(zero) >= DailyAllowancePolicy.liveGraceSeconds {
            closed = true
            effects.append(.close)
        }
        return effects
    }
}
