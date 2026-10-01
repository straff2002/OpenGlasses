import Foundation

/// What the big talk capsule says and does — and what `AppState.connectAndListen()` does for every
/// caller that shares it (widget, watch, Dynamic Island, `avenkin://connect`, Siri and Shortcuts).
///
/// Avenkin is phone-first: the phone's own microphone is always a good device, so wanting to talk
/// never waits on glasses and never ends in a glasses error. Glasses only shape the entry when they
/// are part of the moment:
/// - **Away or never added** — talk now, on the phone. No connect attempt, no wait, no error.
/// - **Connected** — talk now, through them.
/// - **Connecting** — a link already coming up is worth a short wait (`linkWaitSeconds`), then talk
///   on whatever is there. Never the registration error.
/// - **Stood down** (connected, but the wearer pressed Disconnect) — tapping talk is asking for the
///   assistant back, so the glasses are resumed first. Labelled so the tap says what it will do.
///
/// Connecting a pair of glasses that is not there is a different request, made from the glasses
/// controls (`AppState.connectGlasses()`), and that is the only place its failure is reported.
enum TalkEntryPolicy {

    enum Action: Equatable {
        /// Start the turn now on the current input.
        case talk
        /// Wait up to `linkWaitSeconds` for a link that is coming up, then talk regardless.
        case awaitLinkThenTalk
        /// Lift the wearer's Disconnect, then talk through the glasses.
        case resumeGlassesThenTalk
    }

    struct Decision: Equatable {
        let label: String
        let action: Action
    }

    static let tapAndTalk = "Tap & Talk"
    static let resumeAndTalk = "Resume & Talk"

    /// The same bound `captureAndAnalyzePhoto` gives a link that is coming up.
    static let linkWaitSeconds: Double = 5

    static func decide(link: GlassesConnectionPhase, stoodDown: Bool) -> Decision {
        if stoodDown && link.isConnected {
            return Decision(label: resumeAndTalk, action: .resumeGlassesThenTalk)
        }
        if link.isConnecting {
            return Decision(label: tapAndTalk, action: .awaitLinkThenTalk)
        }
        return Decision(label: tapAndTalk, action: .talk)
    }
}

/// The session card's headline when the glasses, not the session, are the news.
///
/// Phone-first: with glasses away the phone carries the session, so the card reports the session
/// ("Ready", "Listening…") exactly as it does for someone who never added glasses. The glasses'
/// own state stays on the glasses pill. The headline gives way to the glasses only while the
/// wearer has asked to connect them and the attempt is under way — that is when "Approve in Meta
/// AI…" or "Waiting for device…" is the thing to read. Before, those registration lines stayed on
/// the card after the attempt, over a phone that was ready to talk.
enum SessionCardGlassesHeadline {
    static func headline(connectAttemptInFlight: Bool,
                         link: GlassesConnectionPhase,
                         connectionStatus: String) -> String? {
        guard connectAttemptInFlight, !link.isConnected else { return nil }
        if link.isConnecting { return "Connecting…" }
        return connectionStatus == "Not connected" ? "Glasses Not Connected" : connectionStatus
    }
}

/// Whether bringing the wake word up on launch or foreground has to wait for glasses registration.
///
/// The wait exists because Bluetooth route churn while a registration is negotiating has been seen
/// to destabilise it. That only matters to someone with glasses. Before, the launch path waited
/// and then *skipped* the wake word if registration never completed, and the foreground path
/// skipped outright below registered — so a phone-only user never had a wake word at all.
enum WakeLaunchPolicy {
    /// Launch: wait (bounded) for registration to settle only when glasses are part of the setup
    /// and not yet registered. Whatever the wait ends with, the wake word then starts on whatever
    /// microphone there is — the wait protects the registration, it does not gate voice.
    static func awaitsRegistrationOnLaunch(stateRaw: Int, glassesAdded: Bool) -> Bool {
        glassesAdded && GlassesRegistration(stateRaw: stateRaw) != .registered
    }

    /// Foreground: nothing to wait for, so hold off only while a registration is visibly in flight
    /// (raw 2, `.registering`). Every other state — none, available, registered — starts.
    static func defersForegroundRestart(stateRaw: Int) -> Bool {
        GlassesRegistration(stateRaw: stateRaw) == .registering
    }
}
