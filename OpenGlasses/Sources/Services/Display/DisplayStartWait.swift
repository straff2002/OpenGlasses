import Foundation

/// The Meta Display capability's own lifecycle, in the app's words (`MWDATDisplay.DisplayState`
/// mapped by `MetaDisplayBackend`), so the wait below stays SDK-free and testable headless.
enum DisplayCapabilityPhase: String, Equatable {
    case starting, started, stopping, stopped
}

/// Wait for the Display capability to reach `started` before the first send.
///
/// `Display.start()` is synchronous but the capability is not ready when it returns: it is
/// `starting` until the glasses accept the request. Meta's guide says to send "once the display
/// reaches `.started`". The backend used to send at once, while it was still `starting`. A Ray-Ban
/// Display tester's report (build 705) showed what followed: the session started, every first
/// send went unanswered past `HUDSendDeadline` (4 s), now and then `deviceDisconnected`, and
/// because a failed send tears the session down, the next frame went to a fresh `starting`
/// display in the same way. Nothing ever reached the lens.
///
/// The wait polls the phase rather than following `statePublisher`: the backend reads the
/// capability's state on the main actor between sends, and polling keeps one code path for a new
/// display and a restarted one. It ends `.started` as soon as the phase is `started`; `.stopped`
/// at once if the capability falls to `stopping`/`stopped` after it was seen `starting` (the
/// glasses refused it), or when `isCurrent` says the backend has let this display go; and at
/// `timeout`, `.stopped` if the phase never left `stopped` or `.timedOut` if it was still
/// `starting`.
///
/// A display that still reads `stopped` after `start()` has not begun yet, and it gets the whole
/// `timeout` to begin, not a shorter grace. It had one second until 2026-11-19: a Ray-Ban Display
/// tester's report (build 728) showed that a Display waking from its idle sleep (Meta dims it at
/// 20 s and sleeps it at 25 s) stays `stopped` for longer than that before it moves. Every start
/// was abandoned at one second, the render-error path tore the session down and rebuilt it, the
/// next start was abandoned the same way, and the lens stayed off for the whole answer; the one
/// that got through reached `started` right at the one-second mark. No shorter bound is known to
/// be safe, since how long the wake takes is the glasses' business, so a display that has not
/// begun is held to the same allowance as one that is `starting`, which is the allowance the
/// session itself gets. Waiting costs only the render queue's turn (it is latest-wins: frames that
/// arrive meanwhile wait, and the newest of them goes next); giving up early cost a session
/// rebuild that then failed the same way.
enum DisplayStartWait {
    enum Outcome: String, Equatable {
        case started, stopped, timedOut
    }

    /// As long as the session itself is given to start (`MetaDisplayBackend.prepareSession`). It
    /// covers a display that has not begun yet (still `stopped`) as well as one that is `starting`.
    static let timeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.1

    /// `elapsed` is counted from the sleeps taken, not a wall clock, so a test drives it exactly.
    @MainActor
    static func wait(
        timeout: TimeInterval = DisplayStartWait.timeout,
        pollInterval: TimeInterval = DisplayStartWait.pollInterval,
        phase: () -> DisplayCapabilityPhase,
        isCurrent: () -> Bool = { true },
        sleep: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) async throws -> (outcome: Outcome, waited: TimeInterval) {
        var polls = 0
        var elapsed: TimeInterval { Double(polls) * pollInterval }   // counted, so 10 × 0.1 is 1
        var sawStarting = false
        while true {
            // A display the backend has let go of (the session ended, the HUD was turned off) is
            // not waited for: with the whole allowance for a display that has not begun, it could
            // otherwise hold the render queue for `timeout`.
            guard isCurrent() else { return (.stopped, elapsed) }
            let now = phase()
            switch now {
            case .started:
                return (.started, elapsed)
            case .starting:
                sawStarting = true
            case .stopping, .stopped:
                if sawStarting { return (.stopped, elapsed) }   // begun, then refused
            }
            if elapsed >= timeout { return (now == .starting ? .timedOut : .stopped, elapsed) }
            try await sleep(pollInterval)
            polls += 1
        }
    }
}

extension DisplayCapabilityPhase {
    /// Whether a Display in this phase still needs `stop()`: one already stopping or stopped
    /// doesn't.
    static func needsStop(_ phase: DisplayCapabilityPhase) -> Bool {
        phase == .starting || phase == .started
    }
}

/// Wait for a Display we let go of to reach `stopped` before another is added on the same session.
///
/// The session is shared with the camera (`DeviceSessionCoordinator`), so handing it back no
/// longer stops it, and the SDK refuses a second Display on a session while one is active
/// (`capabilityAlreadyActive`). Build 717 showed what followed when the dropped Display was left
/// running: after one failed draw, every later frame was refused until the camera let go.
///
/// A wait that runs out is reported, not thrown: the `addDisplay()` after it says for itself
/// whether the old Display is still in the way.
enum DisplayStopWait {
    enum Outcome: String, Equatable {
        case stopped, timedOut
    }

    static let timeout: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.1

    /// `elapsed` is counted from the sleeps taken, not a wall clock, so a test drives it exactly.
    @MainActor
    static func wait(
        timeout: TimeInterval = DisplayStopWait.timeout,
        pollInterval: TimeInterval = DisplayStopWait.pollInterval,
        phase: () -> DisplayCapabilityPhase,
        sleep: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) async throws -> (outcome: Outcome, waited: TimeInterval) {
        var polls = 0
        var elapsed: TimeInterval { Double(polls) * pollInterval }
        while true {
            if phase() == .stopped { return (.stopped, elapsed) }
            if elapsed >= timeout { return (.timedOut, elapsed) }
            try await sleep(pollInterval)
            polls += 1
        }
    }
}
