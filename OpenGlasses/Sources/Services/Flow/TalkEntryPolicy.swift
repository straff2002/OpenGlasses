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

// MARK: - Session card: wake word off

/// The line the session card adds when the master "Listen for Wake Phrase" switch is off.
///
/// That switch can be turned off from places that are nowhere near the card — the Lock Screen Live
/// Activity's button, Control Center, the widget, the Action Button, Siri — and the card went on
/// saying "Ready" over a wake phrase that would never be heard. So the card says it, and tapping
/// the line turns listening back on.
///
/// Only when the wake phrase is *expected*: push-to-talk (`Config.silentMode`, the "Push-Talk"
/// tile) is the wearer's own choice to talk by tapping, and the card says nothing extra then.
enum SessionCardWakeWordNotice {
    static let text = "Wake word off \u{2014} tap to turn on"
    static let accessibilityLabel = "Wake word off"
    static let accessibilityHint = "Turns listening for the wake phrase back on."

    static func shows(listeningEnabled: Bool, pushToTalk: Bool) -> Bool {
        !listeningEnabled && !pushToTalk
    }
}

// MARK: - Session card: mode dot

/// The reduced shape of `GeminiConnectionState` / `OpenAIRealtimeConnectionState` the mode dot
/// needs. Both realtime services declare the same five cases; this drops the server-supplied
/// `.error` payload (user-content class, and the dot only needs to know a failure happened), so
/// `SessionCardModeDot` stays free of either module and is testable on its own.
enum SessionCardRealtimePhase: Equatable {
    case disconnected, connecting, settingUp, ready, error
}

/// A semantic colour tier for a session-card indicator — pure so the mapping is testable without
/// touching `OGTheme`. The view is the only place a tier becomes a `Color`.
enum SessionCardTint: Equatable {
    /// Green — the thing described is fine, live, or simply available.
    case ok
    /// Amber — in progress (a link coming up), or a quiet condition worth a glance.
    case warn
    /// Red — failed.
    case error
    /// Grey — not right now, and nothing is wrong.
    case quiet
}

/// The colour tier for the dot beside "Mode: <persona>", and (so the row stays internally
/// consistent — its own existing comment calls the dot and the name "the same state, two roles")
/// the "Mode:"/"Active mode:" prefix and the name's colour beside it.
///
/// Before this type the row read `AppState.isConnected` — whether the *glasses* are linked — so it
/// went grey and said "Mode: Avenkin" the instant the wearer took the glasses off mid-conversation,
/// and green and "Active mode:" the instant they put them back on: a sentence that never mentions
/// glasses, driven entirely by them.
///
/// The fixed mapping, independent of hardware:
/// - **`.active`** (green, "Active mode:") — Avenkin is available to talk to or is in the middle of
///   it: ready for the next turn, listening, thinking (processing a turn, or a realtime link
///   connecting/setting up), or speaking. This is the common case the row exists to report — "can I
///   talk to Avenkin right now", not "is a call in progress".
/// - **`.muted`** — the wearer muted the mic. The session is fine; the input is deliberately off.
/// - **`.error`** — a realtime session reported an error.
/// - **`.offline`** — a realtime session the wearer started has dropped the link and is not
///   retrying. Direct (on-device) voice has no such state: there is no persistent link to lose.
enum SessionCardModeDot: Equatable {
    case active, muted, error, offline

    var tint: SessionCardTint {
        switch self {
        case .active: return .ok
        case .muted: return .warn
        case .error: return .error
        case .offline: return .quiet
        }
    }

    /// Whether the row's prefix reads "Active mode:" rather than "Mode:".
    var readsAsActiveMode: Bool { self == .active }

    /// Gemini Live / OpenAI Realtime.
    ///
    /// - Parameter sessionActive: `session.isActive` — before a turn starts, or after a clean stop,
    ///   this is `false` and the card's own headline already reads "Ready", so the dot matches it.
    static func realtime(sessionActive: Bool, phase: SessionCardRealtimePhase, muted: Bool,
                         reconnecting: Bool) -> SessionCardModeDot {
        if muted { return .muted }
        guard sessionActive else { return .active }
        switch phase {
        case .ready, .connecting, .settingUp: return .active
        case .error: return .error
        // Reconnecting is still trying — the row already reads "Reconnecting…"; a second
        // grey/alarm signal beside it would only repeat the sentence it sits next to.
        case .disconnected: return reconnecting ? .active : .offline
        }
    }

    /// Direct (on-device) voice: no persistent link to go offline from or error out of, so a mute is
    /// the only thing that ever leaves `.active` — listening, speaking and thinking
    /// (`AppState.isProcessing`) all read the same as idle-ready.
    static func direct(muted: Bool) -> SessionCardModeDot {
        muted ? .muted : .active
    }
}

// MARK: - Session card: glasses pill

/// What the glasses pill shows and does — link phase × stand-down × ever-added — decoupled from
/// `AppState.connectGlasses()`, which exists for a different request (see its own doc comment):
/// registering a pair that has never linked.
///
/// The accidental-tap bug this replaces: tapping the pill while the glasses were simply away ran
/// `connectGlasses()`, which waits up to 15 s and then surfaces the SDK's own text ("Glasses
/// registered but no device appeared (state 3)…") as an *error* — alarming, for a tap that only
/// ever meant "where are my glasses?". The pill now says what is actually true (attached,
/// connecting, paused, away) and, away, offers a plain hint instead of a wait and an error.
enum SessionCardGlassesPill {

    /// What the pill does on a tap.
    enum Action: Equatable {
        /// Ask to disconnect — today's confirmation dialog.
        case disconnect
        /// Lift the wearer's own stand-down. The link is already up; nothing to wait for.
        case resume
        /// Away, not connecting: show a plain hint, never `connectGlasses()`'s 15 s wait.
        case hint
        /// Connecting: nothing to do but wait.
        case none
    }

    struct Presentation: Equatable {
        /// The visible word (and, per the accessibility rule below, the label VoiceOver reads).
        let word: String
        let tint: SessionCardTint
        /// A second, filled dot beside the symbol — only while the glasses are in active use.
        let showsLiveDot: Bool
        let action: Action
        /// VoiceOver label matches the visible word exactly; the hint names the tap action.
        var accessibilityLabel: String { word }
        let accessibilityHint: String
    }

    /// `nil` when glasses have never been added (Plan FY P2) — the pill does not appear at all. A
    /// pair nobody has ever added is not news.
    static func presentation(link: GlassesConnectionPhase, stoodDown: Bool,
                             everAdded: Bool) -> Presentation? {
        guard everAdded else { return nil }

        if link.isConnected {
            if stoodDown {
                return Presentation(word: "Glasses paused", tint: .quiet, showsLiveDot: false,
                                    action: .resume,
                                    accessibilityHint: "Double-tap to resume the glasses.")
            }
            return Presentation(word: "Glasses attached", tint: .ok, showsLiveDot: true,
                                action: .disconnect,
                                accessibilityHint: "Double-tap to disconnect the glasses.")
        }
        if link.isConnecting {
            return Presentation(word: "Connecting…", tint: .warn, showsLiveDot: false,
                                action: .none,
                                accessibilityHint: "Glasses are linking up.")
        }
        // `.addedDisconnected`, or `.noGlassesAdded` reached only through `Config.glassesAdded`
        // (glasses that connected once, now unregistered) — either way: added, just not reachable.
        return Presentation(word: "Glasses away", tint: .quiet, showsLiveDot: false,
                            action: .hint,
                            accessibilityHint: "Double-tap for help reconnecting the glasses.")
    }

    /// The hint shown on a tap while the glasses are away — a plain, immediate notice (`NoticeCenter`,
    /// `.advisory`), never the 15 s `connectGlasses()` wait or its SDK-flavoured error text.
    static let awayHint = "Glasses aren't connected — put them on, or check the Meta AI app."
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
