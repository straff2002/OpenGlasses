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
/// if the capability falls to `stopping`/`stopped` after it was seen `starting` (or after
/// `stoppedGrace`, in case the phase still read `stopped` straight after `start()`); `.timedOut`
/// when `timeout` passes first.
enum DisplayStartWait {
    enum Outcome: String, Equatable {
        case started, stopped, timedOut
    }

    /// As long as the session itself is given to start (`MetaDisplayBackend.prepareSession`).
    static let timeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.1
    /// How long a `stopped` read straight after `start()` is taken as "not begun yet".
    static let stoppedGrace: TimeInterval = 1

    /// `elapsed` is counted from the sleeps taken, not a wall clock, so a test drives it exactly.
    @MainActor
    static func wait(
        timeout: TimeInterval = DisplayStartWait.timeout,
        pollInterval: TimeInterval = DisplayStartWait.pollInterval,
        phase: () -> DisplayCapabilityPhase,
        sleep: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) async throws -> (outcome: Outcome, waited: TimeInterval) {
        var polls = 0
        var elapsed: TimeInterval { Double(polls) * pollInterval }   // counted, so 10 × 0.1 is 1
        var sawStarting = false
        while true {
            switch phase() {
            case .started:
                return (.started, elapsed)
            case .starting:
                sawStarting = true
            case .stopping, .stopped:
                if sawStarting || elapsed >= stoppedGrace { return (.stopped, elapsed) }
            }
            if elapsed >= timeout { return (.timedOut, elapsed) }
            try await sleep(pollInterval)
            polls += 1
        }
    }
}
