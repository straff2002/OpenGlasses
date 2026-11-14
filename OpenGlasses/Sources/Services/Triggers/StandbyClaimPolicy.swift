import Foundation

/// What the standby claim's silent player does when a temple tap arrives as `pause` or
/// `togglePlayPause` (Plan LT §4). Pure: the clock is passed in, and the service applies the
/// action to the claimer.
///
/// A Gen 2 was seen to hear only the first tap after launch. One explanation, measured on another
/// platform and not yet on iOS, is that a player which keeps playing after a pause command reads to
/// the glasses as an app that ignored the command, so they stop sending. `.pauseThenResume` tests
/// that: the silent player pauses and the Now Playing rate goes to 0, as a real player would, and
/// both come back after `resumeDelay` or on the next command, whichever comes first. A command
/// that arrives during the pause is still a tap; only a `play` within `pairWindow` of the pause is
/// read as the same tap (some stacks send a press as pause-then-play).
///
/// Which mode is the default is settled by the device check (P1). Until then it is `.keepPlaying`,
/// today's behaviour, and a Developer switch chooses (`Config.standbyClaimMode`).
struct StandbyClaimPolicy: Equatable {

    enum Mode: String, CaseIterable, Equatable {
        /// The silent player keeps playing whatever command arrives (the behaviour before LT).
        case keepPlaying
        /// Pause on a pause or toggle, resume after `resumeDelay` or on the next command.
        case pauseThenResume
    }

    /// What the claimer should do with its silent player.
    enum Action: Equatable {
        case none
        /// Pause the player, set the Now Playing rate to 0, and resume after the delay unless a
        /// command resumes it first.
        case pause(resumeAfter: TimeInterval)
        /// Restart the player and set the rate back to 1.
        case resume
    }

    struct Decision: Equatable {
        var action: Action
        /// Whether the command goes on to the tap decoder. False only for the `play` half of a
        /// pause-then-play pair.
        var countsAsTap: Bool
    }

    static let resumeDelay: TimeInterval = 3
    static let pairWindow: TimeInterval = 0.6

    let mode: Mode
    /// When the silent player was paused by this policy, while it is paused.
    private(set) var pausedAt: TimeInterval?

    init(mode: Mode) {
        self.mode = mode
    }

    var isPaused: Bool { pausedAt != nil }

    /// A command arrived while the standby claim holds Now Playing.
    mutating func handle(_ command: MediaRemoteCommand, at now: TimeInterval) -> Decision {
        guard mode == .pauseThenResume else { return Decision(action: .none, countsAsTap: true) }
        if let paused = pausedAt {
            pausedAt = nil
            let elapsed = now - paused
            let pairedPlay = command == .play && elapsed >= 0 && elapsed < Self.pairWindow
            return Decision(action: .resume, countsAsTap: !pairedPlay)
        }
        switch command {
        case .pause, .togglePlayPause:
            pausedAt = now
            return Decision(action: .pause(resumeAfter: Self.resumeDelay), countsAsTap: true)
        case .play, .nextTrack, .previousTrack:
            return Decision(action: .none, countsAsTap: true)
        }
    }

    /// The resume delay ran out. `.resume` if the player is still paused by this policy.
    mutating func resumeDelayElapsed() -> Action {
        guard pausedAt != nil else { return .none }
        pausedAt = nil
        return .resume
    }

    /// The claim was released or retaken: nothing is paused any more.
    mutating func reset() {
        pausedAt = nil
    }
}
