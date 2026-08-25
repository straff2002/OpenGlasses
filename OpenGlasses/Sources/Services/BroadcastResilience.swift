import Foundation

/// CY: the decision layer under a live RTMP broadcast — everything about *when to retry*,
/// *what state the session is in*, *how fast frames are actually reaching the wire*, and
/// *what bitrate the link can carry*, expressed over plain numbers.
///
/// None of this touches HaishinKit, `AVFoundation` or the network. `BroadcastService` owns the
/// sockets and the encoder; it feeds those types observations and applies what they decide. That
/// split is the point: a broadcast drop is the one failure mode we cannot reproduce at a desk, so
/// the logic that handles it has to be exercisable without a stream at all.

// MARK: - Session state

/// Where a broadcast is in its life.
///
/// `reconnecting` carries the attempt number because that is what the wearer is owed: "still
/// trying" reads very differently on attempt 1 than on attempt 7, and the number is the only
/// honest way to say which one they are looking at.
enum BroadcastSessionState: Equatable {
    case idle
    case connecting
    case live
    case reconnecting(attempt: Int)
    case failed(String)

    /// Frames are reaching the server.
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// The session is trying to get (back) onto the wire.
    var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }
}

/// Something that happened to the session. Kept separate from the state so the transition table
/// is a table — the alternative is a service method per state pair, which is where the illegal
/// transitions hide.
enum BroadcastSessionEvent: Equatable {
    /// The wearer asked to go live.
    case start
    /// The server accepted the publish.
    case connected
    /// A live stream lost its connection.
    case dropped
    /// A reconnect attempt is about to be made.
    case retry(attempt: Int)
    /// Give up — reconnection is not going to work (bad credentials, or the retry budget ran out).
    case fail(String)
    /// The wearer stopped the broadcast, or teardown finished.
    case stop
}

/// The session's legal transitions, as data.
///
/// `apply` returns whether the event was legal *and* took effect, so the caller can tell a
/// meaningful change from a duplicate. Duplicates are real here, not hypothetical: a dropped
/// connection surfaces on both the connection status stream and the stream status stream, and the
/// second one must not restart a reconnect that is already running.
struct BroadcastSessionMachine {

    private(set) var state: BroadcastSessionState = .idle

    init(state: BroadcastSessionState = .idle) {
        self.state = state
    }

    @discardableResult
    mutating func apply(_ event: BroadcastSessionEvent) -> Bool {
        guard let next = Self.transition(from: state, on: event) else { return false }
        guard next != state else { return false }
        state = next
        return true
    }

    /// The table itself. `nil` means "not a legal thing to happen from here".
    static func transition(from state: BroadcastSessionState,
                           on event: BroadcastSessionEvent) -> BroadcastSessionState? {
        switch event {
        case .start:
            // Only from a settled session. Starting on top of a live one is the caller's bug.
            switch state {
            case .idle, .failed: return .connecting
            default: return nil
            }

        case .connected:
            switch state {
            case .connecting, .reconnecting: return .live
            default: return nil
            }

        case .dropped:
            // Only a stream that got established can drop; a failure while connecting is a
            // failed connect, which the caller reports as `.fail` (or retries explicitly).
            switch state {
            case .live: return .reconnecting(attempt: 1)
            default: return nil
            }

        case .retry(let attempt):
            switch state {
            case .reconnecting, .connecting, .live: return .reconnecting(attempt: attempt)
            default: return nil
            }

        case .fail(let reason):
            switch state {
            case .connecting, .live, .reconnecting: return .failed(reason)
            default: return nil
            }

        case .stop:
            // Always legal — stop is the one thing the wearer can always do.
            return .idle
        }
    }
}

// MARK: - Reconnection

/// What to do about a connection that just died.
enum BroadcastReconnectDecision: Equatable {
    /// Wait `delay` seconds, then try again. `attempt` counts from 1.
    case retry(attempt: Int, delay: TimeInterval)
    /// Stop trying — the failure has lasted longer than the budget.
    case giveUp
}

/// Capped exponential backoff with a stability reset.
///
/// Two properties matter and neither is obvious from the backoff alone:
///
/// - **The delay is capped.** An uncapped doubling reaches half an hour by attempt 12, which for a
///   broadcast means the stream is gone even though the network came back. A minute is the longest
///   wait that is still a reconnect rather than an abandonment.
/// - **The attempt counter resets only after the stream has been *stable*.** Resetting it the
///   instant a connect succeeds turns a flapping link into a tight retry loop hammering the ingest
///   every second; requiring a stable window means a stream that reconnects and immediately drops
///   keeps backing off, while a stream that ran fine for a minute gets a fresh budget.
///
/// `now` is injected on every call rather than read from `Date()` inside, so the whole thing is a
/// pure function of the observations it was given.
struct BroadcastReconnectPolicy {

    /// Delay before the first retry; each subsequent attempt doubles it.
    let baseDelay: TimeInterval
    /// Ceiling on the backoff.
    let maxDelay: TimeInterval
    /// How long a stream must stay live before its attempt counter is forgiven.
    let stableResetInterval: TimeInterval
    /// How long we keep retrying from the first failure before declaring the broadcast dead.
    let giveUpAfter: TimeInterval

    private(set) var attempt = 0
    /// When the current run of failures started — cleared by a stable stretch, not by a connect.
    private(set) var firstFailureAt: Date?
    private var liveSince: Date?

    init(baseDelay: TimeInterval = 1,
         maxDelay: TimeInterval = 60,
         stableResetInterval: TimeInterval = 60,
         giveUpAfter: TimeInterval = 300) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.stableResetInterval = stableResetInterval
        self.giveUpAfter = giveUpAfter
    }

    /// The stream is publishing as of `now`.
    mutating func recordLive(at now: Date) {
        liveSince = now
    }

    /// The connection died (or a reconnect attempt failed) at `now`.
    mutating func connectionLost(now: Date) -> BroadcastReconnectDecision {
        // A stream that held for the stable window earns a clean slate: this is a new problem,
        // not a continuation of the last one.
        if let liveSince, now.timeIntervalSince(liveSince) >= stableResetInterval {
            attempt = 0
            firstFailureAt = nil
        }
        liveSince = nil

        let start = firstFailureAt ?? now
        firstFailureAt = start

        // Budget is measured from the first failure, so a long tail of doubling delays cannot
        // silently keep a dead broadcast "reconnecting" for an hour.
        if now.timeIntervalSince(start) >= giveUpAfter {
            return .giveUp
        }

        attempt += 1
        return .retry(attempt: attempt, delay: delay(forAttempt: attempt))
    }

    /// Back to a clean slate (a new broadcast).
    mutating func reset() {
        attempt = 0
        firstFailureAt = nil
        liveSince = nil
    }

    /// 1, 2, 4, 8 … capped at `maxDelay`.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // `pow` on a large exponent is `.infinity`, and `min` with infinity is the cap — correct,
        // but only by luck. Cap the exponent so the arithmetic stays finite.
        let exponent = Double(min(attempt - 1, 32))
        return min(baseDelay * pow(2, exponent), maxDelay)
    }
}

// MARK: - Adaptive bitrate

/// One observation of how the encoder and the uplink are getting along.
///
/// Deliberately all numbers: the service converts whatever its transport reports into this, and
/// the policy never learns what a socket is.
struct BroadcastPressureSample: Equatable {
    /// What the encoder is currently asked to produce, bits/sec.
    let targetBitrate: Int
    /// What actually left the device over the sample window, bits/sec.
    let measuredBitrate: Int
    /// Bytes still sitting in the outbound queue at sample time.
    let queuedBytes: Int
    /// The transport's own verdict that the uplink cannot keep up. Strongest signal available —
    /// it comes from watching the queue grow monotonically, which a single sample cannot see.
    let insufficientBandwidth: Bool

    init(targetBitrate: Int, measuredBitrate: Int, queuedBytes: Int,
         insufficientBandwidth: Bool = false) {
        self.targetBitrate = targetBitrate
        self.measuredBitrate = measuredBitrate
        self.queuedBytes = queuedBytes
        self.insufficientBandwidth = insufficientBandwidth
    }
}

/// What to do with the encoder's bitrate.
enum AdaptiveBitrateDecision: Equatable {
    case hold
    case stepDown(to: Int)
    case stepUp(to: Int)
}

/// Bitrate control for a live uplink (pure).
///
/// A fixed bitrate chosen at start is right exactly once — at start, on the network the wearer was
/// standing on. Walking out of Wi-Fi onto a congested cell does not change the encoder's mind, so
/// the encoder keeps producing more than the link can carry, the send queue grows, and the ingest
/// eventually drops the stream. The recovery has to be asymmetric:
///
/// - **Down fast.** One decision cuts a quarter off. Backpressure is already a backlog; halving the
///   rate at which the backlog grows is not enough, and being slow about it spends the buffer we
///   are trying to save.
/// - **Up slowly.** Recovery only after a sustained healthy stretch, in small increments. A link
///   that just recovered is the least trustworthy moment to push it, and an eager climb produces a
///   sawtooth the viewer sees as repeated rebuffering.
///
/// The floor is the profile's own minimum — below that the picture is not worth sending — and the
/// ceiling is whatever the broadcast was configured to want, so recovery never overshoots the
/// setting the wearer chose.
struct AdaptiveBitratePolicy {

    /// Never climb above this (the configured/derived target).
    let ceiling: Int
    /// Never drop below this.
    let floor: Int
    /// Fraction removed per step-down decision.
    let stepDownFraction: Double
    /// Fraction of the *ceiling* added per step-up decision.
    let stepUpFraction: Double
    /// Consecutive healthy samples required before a step up.
    let healthyWindow: Int
    /// Delivering less than this share of the target counts as the link failing to keep up.
    let starvedRatio: Double
    /// Consecutive samples of a growing queue that count as backpressure.
    let queueGrowthSamples: Int

    private var healthyCount = 0
    private var queueHistory: [Int] = []

    init(ceiling: Int,
         floor: Int,
         stepDownFraction: Double = 0.25,
         stepUpFraction: Double = 0.10,
         healthyWindow: Int = 5,
         starvedRatio: Double = 0.8,
         queueGrowthSamples: Int = 3) {
        self.ceiling = max(ceiling, floor)
        self.floor = floor
        self.stepDownFraction = stepDownFraction
        self.stepUpFraction = stepUpFraction
        self.healthyWindow = healthyWindow
        self.starvedRatio = starvedRatio
        self.queueGrowthSamples = queueGrowthSamples
    }

    /// Fold one sample in and say what should happen to the bitrate.
    mutating func evaluate(_ sample: BroadcastPressureSample) -> AdaptiveBitrateDecision {
        recordQueue(sample.queuedBytes)

        if isUnderPressure(sample) {
            healthyCount = 0
            let reduced = Self.roundedToHundredKilobits(
                Double(sample.targetBitrate) * (1 - stepDownFraction))
            let next = max(floor, min(reduced, sample.targetBitrate))
            return next < sample.targetBitrate ? .stepDown(to: next) : .hold
        }

        healthyCount += 1
        guard healthyCount >= healthyWindow, sample.targetBitrate < ceiling else { return .hold }
        healthyCount = 0
        let increment = Self.roundedToHundredKilobits(Double(ceiling) * stepUpFraction)
        let next = min(ceiling, sample.targetBitrate + max(increment, 100_000))
        return next > sample.targetBitrate ? .stepUp(to: next) : .hold
    }

    /// Back to a clean slate (a reconnect re-primes the encoder, so its history means nothing).
    mutating func reset() {
        healthyCount = 0
        queueHistory.removeAll()
    }

    // MARK: - Private

    private func isUnderPressure(_ sample: BroadcastPressureSample) -> Bool {
        if sample.insufficientBandwidth { return true }
        if isQueueGrowing { return true }
        // A zero measurement is a missing observation, not evidence of a starved link: the first
        // sample of a session and any stats hiccup both read as zero, and stepping down on those
        // would walk the bitrate to the floor on a perfectly healthy stream.
        guard sample.measuredBitrate > 0, sample.targetBitrate > 0 else { return false }
        return Double(sample.measuredBitrate) < Double(sample.targetBitrate) * starvedRatio
    }

    private var isQueueGrowing: Bool {
        guard queueHistory.count >= queueGrowthSamples else { return false }
        let recent = queueHistory.suffix(queueGrowthSamples)
        return zip(recent, recent.dropFirst()).allSatisfy { $0 < $1 }
    }

    private mutating func recordQueue(_ bytes: Int) {
        queueHistory.append(bytes)
        if queueHistory.count > queueGrowthSamples {
            queueHistory.removeFirst(queueHistory.count - queueGrowthSamples)
        }
    }

    private static func roundedToHundredKilobits(_ bits: Double) -> Int {
        guard bits.isFinite, bits > 0 else { return 0 }
        let step = 100_000.0
        return Int((bits / step).rounded()) * Int(step)
    }
}

// MARK: - Achieved frame rate

/// Rolling measurement of how many frames actually reached the encoder (pure).
///
/// The configured frame rate is an intention; this is the outcome. They diverge for reasons worth
/// seeing — the privacy blur coalescing frames, the glasses link stalling, the phone throttling
/// under thermal pressure — and "30 fps configured, 6 fps achieved" is a diagnosis the wearer can
/// act on where a spinning LIVE badge is not.
///
/// Samples are `(timestamp, frames since the previous sample)`, so the frames in the oldest
/// retained sample accrued *before* the window and are excluded from the numerator.
struct BroadcastFrameRateMeter {

    /// How far back the average reaches.
    let window: TimeInterval

    private var samples: [(at: Date, frames: Int)] = []

    init(window: TimeInterval = 5) {
        self.window = window
    }

    mutating func record(frames: Int, at now: Date) {
        samples.append((at: now, frames: max(frames, 0)))
        let cutoff = now.addingTimeInterval(-window)
        // Keep one sample older than the cutoff: it is the left edge the span is measured from.
        if let firstInside = samples.firstIndex(where: { $0.at >= cutoff }), firstInside > 1 {
            samples.removeFirst(firstInside - 1)
        }
    }

    /// Frames per second over the retained span, or 0 while there is nothing to divide by.
    func rate() -> Double {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            return 0
        }
        let span = last.at.timeIntervalSince(first.at)
        guard span > 0 else { return 0 }
        let frames = samples.dropFirst().reduce(0) { $0 + $1.frames }
        return Double(frames) / span
    }

    mutating func reset() {
        samples.removeAll()
    }
}

// MARK: - Health readout

/// Everything the live broadcast UI needs in one value.
///
/// A single `@Published` struct rather than six published properties: the readout is refreshed on
/// one timer tick and every field changes together, so six notifications per second would be five
/// redundant view invalidations.
struct BroadcastHealth: Equatable {

    var state: BroadcastSessionState = .idle
    /// Frame rate the encoder was configured for.
    var configuredFrameRate: Int = 0
    /// Frame rate actually being pushed (rolling average).
    var achievedFrameRate: Double = 0
    /// Bitrate currently asked of the encoder, bits/sec — moves when adaptation steps it.
    var targetBitrate: Int = 0
    /// Bitrate actually leaving the device, bits/sec, or 0 while the transport has not reported.
    var measuredBitrate: Int = 0
    /// Frames that never reached the wire since this broadcast started.
    var droppedFrameCount: Int = 0
    var duration: TimeInterval = 0

    /// "2.4 Mbps" / "820 kbps" — measured if the transport has told us, target otherwise.
    var bitrateLabel: String {
        let bits = measuredBitrate > 0 ? measuredBitrate : targetBitrate
        guard bits > 0 else { return "—" }
        if bits >= 1_000_000 {
            return VideoBitratePolicy.megabitLabel(bits)
        }
        return "\(Int((Double(bits) / 1_000).rounded())) kbps"
    }

    /// "24 fps" — the achieved rate, which is the one worth showing.
    var frameRateLabel: String {
        "\(Int(achievedFrameRate.rounded())) fps"
    }

    /// Short status word for the badge. Never names an attempt count it does not have.
    var stateLabel: String {
        switch state {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .reconnecting(let attempt): return "Reconnecting \(attempt)"
        case .failed: return "Failed"
        }
    }
}
