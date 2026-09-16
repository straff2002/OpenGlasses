import Foundation

/// Why a session is paused by something other than the wearer.
///
/// A pause with no reason is the wearer's own — the Pause button — and nothing in this file ever
/// touches one of those. An automatic pause always has a reason, because a session that goes quiet
/// without saying why reads as a feature that has broken.
enum ScanAssistPauseReason: String, Equatable, Sendable, CaseIterable {
    /// A phone or FaceTime call is connected.
    case call
    /// The output the wearer was listening on went away, or changed underneath the session.
    case outputChanged
    /// Another app took the audio session.
    case audioInterrupted
    /// The app was backgrounded or the device was locked. The first release does not cue from the
    /// background: no silent keep-alive audio, so the honest thing is to stop and say so.
    case background
}

/// An audio or lifecycle event that a running session has to answer for.
///
/// Deliberately app-shaped rather than AVFoundation-shaped: the notification decoding stays where
/// the rest of the app already does it, and this type carries only the two facts the decision
/// turns on — whether the OS said we may resume, and whether we came back to the same output.
enum ScanAssistAudioEvent: Equatable, Sendable {
    /// A call connected.
    case callBegan
    /// `AVAudioSession.interruptionNotification` with `.began`.
    case interruptionBegan
    /// `AVAudioSession.interruptionNotification` with `.ended`.
    /// - Parameters:
    ///   - shouldResume: the `.shouldResume` option was present.
    ///   - routeUnchanged: the output route is the one the session was paused on.
    case interruptionEnded(shouldResume: Bool, routeUnchanged: Bool)
    /// The output went away — `oldDeviceUnavailable`, or a route with no output at all.
    case outputLost
    /// The app went to the background, or the device locked.
    case enteredBackground
    /// The app came back to the foreground.
    case becameActive
}

/// What the owner should do about an event.
enum ScanAssistRecovery: Equatable, Sendable {
    /// Nothing. Either no session is live, or the event has nothing to say about this one.
    case none
    case pause(ScanAssistPauseReason)
    /// Recovery was certain: carry on, with a fresh interval and no backlog.
    case resume
    /// Recovery was uncertain. Stay paused and tell the wearer a tap is needed — the session does
    /// not restart itself on a guess.
    case requireExplicitResume(ScanAssistPauseReason)
}

/// Maps audio and lifecycle events onto pause and resume decisions
/// (docs/plans/FB-scan-assist.md P2). Pure, so every branch below is reachable in a test rather
/// than only on a device with a phone ringing.
///
/// The asymmetry is the point. **Pausing is cheap and always allowed**: a reminder that stops for
/// a phone call costs the wearer one missed prompt. **Resuming is expensive and only allowed when
/// recovery is certain** — an automatic resume onto a route the wearer cannot hear produces a
/// session that appears to be running and is not, which is exactly the false claim this feature
/// must not make.
///
/// Certain means all three: the pause was ours, the OS asked us to resume, and we came back to the
/// same output. Everything else — an interruption that ended without `.shouldResume`, a route that
/// came back different, a return from the background — stays paused and waits for a tap.
///
/// | State | Event | Result |
/// |---|---|---|
/// | running | `callBegan` | `pause(.call)` |
/// | running | `interruptionBegan` | `pause(.audioInterrupted)` |
/// | running | `outputLost` | `pause(.outputChanged)` |
/// | running | `enteredBackground` | `pause(.background)` |
/// | paused (ours) | `interruptionEnded(true, routeUnchanged: true)` | `resume` |
/// | paused (ours) | `interruptionEnded(false, _)` | `requireExplicitResume` |
/// | paused (ours) | `interruptionEnded(_, routeUnchanged: false)` | `requireExplicitResume` |
/// | paused (`.background`) | `becameActive` | `requireExplicitResume(.background)` |
/// | paused (`.outputChanged`) | any ending | `requireExplicitResume(.outputChanged)` |
/// | paused by the wearer | anything | `none` |
/// | idle / ended | anything | `none` |
enum ScanAssistInterruptionPolicy {

    static func recovery(for event: ScanAssistAudioEvent,
                         state: ScanAssistState,
                         pauseReason: ScanAssistPauseReason?) -> ScanAssistRecovery {
        switch state {
        case .running:
            switch event {
            case .callBegan: return .pause(.call)
            case .interruptionBegan: return .pause(.audioInterrupted)
            case .outputLost: return .pause(.outputChanged)
            case .enteredBackground: return .pause(.background)
            // A running session has nothing to recover from.
            case .interruptionEnded, .becameActive: return .none
            }

        case .paused:
            // A pause the wearer asked for is theirs. No audio event may undo it — resuming
            // someone's session because a call ended would be the app deciding they are ready.
            guard let pauseReason else { return .none }
            switch event {
            case .interruptionEnded(let shouldResume, let routeUnchanged):
                // The output-loss pause is never certain: the route came back, but nothing tells
                // us it came back to the thing the wearer was listening with.
                guard pauseReason != .outputChanged else {
                    return .requireExplicitResume(.outputChanged)
                }
                // Nor is a background pause: the first release does not cue from the background,
                // so the session that ends one is over until a person says otherwise.
                guard pauseReason != .background else {
                    return .requireExplicitResume(.background)
                }
                guard shouldResume, routeUnchanged else {
                    return .requireExplicitResume(pauseReason)
                }
                return .resume

            case .becameActive:
                guard pauseReason == .background else { return .none }
                return .requireExplicitResume(.background)

            // Already paused; a second cause does not change the first one's wording. The reason
            // the wearer sees stays the one that actually stopped the session.
            case .callBegan, .interruptionBegan, .outputLost, .enteredBackground:
                return .none
            }

        case .idle, .ended:
            return .none
        }
    }
}
