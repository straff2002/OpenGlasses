import Foundation

/// Whether the end of a turn may re-open the microphone, and — when it may not — whether that
/// answer can change on its own.
///
/// `WakeAutoRestartPolicy` answers the same question for the *automatic* restarts (foreground,
/// route change, interruption ended) and returns a bare `Bool`, which is all those callers need:
/// something else will try again later. `returnToWakeWord()` is the opposite case. It is the last
/// thing that runs in a turn, so whatever it decides is the state the app is left in until the
/// wearer does something — and a bare `return` there is how a field build (407) ended up with a
/// wake word that worked once per launch: the cached `isConnected` had latched `false`, the
/// disconnected guard fired at the end of the first turn, and nothing re-armed afterwards because
/// nothing was watching.
///
/// So this returns the *reason*, and the reason says whether it is recoverable:
///
/// - **Not recoverable** — the wearer turned listening off, chose push-to-talk, or muted the mic.
///   The mic stays shut until they change their mind. Retrying would be overriding them.
/// - **Recoverable** — the glasses link is the app's observation of the world, not an instruction
///   from the wearer, and it can come back without them touching anything. A skip on this reason
///   schedules a bounded re-arm rather than ending the session silently.
///
/// The connection input must be **re-derived at the call site**, not read from a cached flag —
/// see `AppState.glassesConnectionIsLive()`. A policy cannot tell a stale `false` from a true one.
enum WakeRearmPolicy {

    /// Everything the decision reads.
    struct Inputs: Equatable {
        /// The master listening toggle.
        var listeningEnabled: Bool
        /// Push-to-talk: no always-on listener.
        var silentMode: Bool
        /// Whether the turn that just ended was an active conversation. Silent mode suppresses the
        /// *initial* auto-start only — a wearer who was just talking expects the mic back.
        var wasInConversation: Bool
        /// Glasses link, freshly observed.
        var isConnected: Bool
        /// Explicit mute.
        var micMuted: Bool
    }

    enum SkipReason: String, Equatable {
        case masterOff
        case silentMode
        case disconnected
        case micMuted

        /// Whether this condition can clear without the wearer changing a setting.
        ///
        /// Only the glasses link can. The other three are decisions the wearer made, and a policy
        /// that retried its way around them would be a mic that turns itself back on.
        var isRecoverable: Bool {
            switch self {
            case .disconnected: return true
            case .masterOff, .silentMode, .micMuted: return false
            }
        }
    }

    enum Decision: Equatable {
        /// Re-arm the wake-word listener now.
        case restart
        /// Leave the mic shut, for this reason.
        case skip(SkipReason)
    }

    /// How long to wait between bounded re-arm attempts after a recoverable skip, in seconds.
    ///
    /// Three attempts over ~12 seconds: long enough for a Bluetooth route to settle after the
    /// flip that caused the skip, short enough that the wearer's next wake word lands on a live
    /// listener rather than on nothing. It gives up rather than polling forever — the route-change
    /// and reconnect events re-arm on their own, and this is only the gap before one arrives.
    static let retryDelays: [TimeInterval] = [1, 3, 8]

    static func decide(_ inputs: Inputs) -> Decision {
        // The master toggle wins over every rule below.
        guard inputs.listeningEnabled else { return .skip(.masterOff) }
        // Silent mode suppresses the always-on listener, but not the mic coming back after the
        // wearer has just been talking.
        if inputs.silentMode && !inputs.wasInConversation { return .skip(.silentMode) }
        guard inputs.isConnected else { return .skip(.disconnected) }
        guard !inputs.micMuted else { return .skip(.micMuted) }
        return .restart
    }
}
