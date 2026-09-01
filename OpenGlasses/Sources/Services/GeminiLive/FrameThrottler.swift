import Foundation
import UIKit

/// Throttles camera frames to a configurable interval before forwarding.
/// Used in Gemini Live mode to rate-limit video frames sent over the WebSocket (default: 1fps).
///
/// When `Config.frameDedupEnabled` is on, a perceptual-hash `FrameGate` runs
/// *after* the time check (Plan AT): time-throttled frames that are visually
/// indistinguishable from the last one sent are dropped before reaching
/// `onThrottledFrame`. With the flag off the gate is never constructed and the
/// behaviour is byte-for-byte the time-only throttle.
class FrameThrottler {
    var onThrottledFrame: ((UIImage) -> Void)?

    /// Fires when a forwarded frame represents a *genuine scene change* (the gate's
    /// first-frame or distinct send, never a heartbeat re-send) — i.e. a keyframe
    /// worth describing. Only ever called when the content gate is active
    /// (`Config.frameDedupEnabled`); with the gate off there is no distinct signal.
    /// Feeds Visual State Memory (Plan AV).
    var onKeyframe: ((UIImage) -> Void)?

    private var lastFrameTime: Date = .distantPast
    private let interval: TimeInterval
    private var isPaused: Bool = false

    /// Power-posture stretch on the interval (Plan BV P2): `1.0` = full rate, higher = fewer frames
    /// under `conserve`/`reserve`. Defaults to `1.0` so the throttle is byte-for-byte unchanged; the
    /// session manager updates it from `PowerPolicyService`'s posture on the main actor (the same
    /// actor `submit` runs on), so no cross-thread read is needed.
    var powerIntervalMultiplier: Double = 1.0

    /// Content gate; non-nil only when `Config.frameDedupEnabled` was set at init.
    private var frameGate: FrameGate?

    /// Set when something needs the model to have a *current* view — the wearer has started
    /// speaking, and whatever they are about to ask is about what is in front of them now.
    ///
    /// Device-traced 2026-08-23: with the content gate on, a still scene forwards nothing between
    /// heartbeats, so a question could be answered against a frame up to `heartbeat` seconds old
    /// (12 by default). That number is right for its own job — keeping a background view from going
    /// stale — and wrong as the wait behind a question. Rather than shorten it for everyone, a turn
    /// asks for one frame that skips both gates.
    private var freshFrameWanted = false

    /// Injected clock, so the interval/power-multiplier gate is deterministic under test. The live
    /// app leaves the default `Date()`.
    private let now: () -> Date

    /// - Parameter interval: Minimum seconds between forwarded frames (default: from Config).
    init(interval: TimeInterval = Config.geminiLiveVideoFrameInterval, now: @escaping () -> Date = { Date() }) {
        self.interval = interval
        self.now = now
        if Config.frameDedupEnabled {
            frameGate = FrameGate(
                hammingThreshold: Config.frameDedupHammingThreshold,
                heartbeat: Config.frameDedupHeartbeatSeconds
            )
        }
    }

    /// Total frames received and forwarded (for diagnostics).
    private(set) var receivedCount: Int = 0
    private(set) var forwardedCount: Int = 0

    /// Fraction of time-throttled frames dropped by the content gate (0 when disabled).
    var dedupRatio: Double { frameGate?.dedupRatio ?? 0 }

    /// Temporarily pause frame forwarding (e.g. during tool execution).
    func pause() {
        isPaused = true
    }

    /// Resume frame forwarding after a pause.
    func resume() {
        isPaused = false
    }

    /// Call with every camera frame. Only forwards if enough time has passed,
    /// not paused, and the content gate (if enabled) considers it distinct.
    func submit(_ image: UIImage) {
        receivedCount += 1
        guard !isPaused else { return }
        let now = self.now()

        // A turn is starting: send this one whatever the gates say, then resume normal throttling.
        let forced = freshFrameWanted
        freshFrameWanted = false

        let effectiveInterval = interval * max(1.0, powerIntervalMultiplier)
        if !forced {
            guard now.timeIntervalSince(lastFrameTime) >= effectiveInterval else { return }
        }

        // Content gate runs after the time gate. dhash failure → fail open (send).
        var isKeyframe = false
        if !forced, frameGate != nil, let hash = PerceptualHash.dhash(image) {
            let decision = frameGate!.evaluate(hash: hash, now: now.timeIntervalSinceReferenceDate)
            guard decision == .send else { return }
            // A heartbeat re-send is not evidence of a new scene, and neither is a forced one —
            // keyframe consumers describe what changed, and nothing did.
            isKeyframe = frameGate!.lastSendReason != .heartbeat
        }

        lastFrameTime = now
        forwardedCount += 1
        if forwardedCount <= 3 || forwardedCount % 10 == 0 {
            PrivacyLog.realtimeSession(.gemini, .frameForwarded, count: forwardedCount,
                                       total: receivedCount)
        }
        onThrottledFrame?(image)
        if isKeyframe { onKeyframe?(image) }
    }

    /// The wearer has started speaking: make sure the next frame reaches the model, bypassing both
    /// the rate limit and the content gate. Idempotent — several partial transcripts in one turn
    /// still force exactly one frame.
    func requestFreshFrame() {
        freshFrameWanted = true
    }

    /// Reset the throttle timer (e.g. on session restart).
    func reset() {
        lastFrameTime = .distantPast
        receivedCount = 0
        forwardedCount = 0
        freshFrameWanted = false
        frameGate?.reset()
    }
}
