import Foundation

/// A session transition a VoiceOver user might need told (pure).
///
/// The session surface renders every one of these — a blind user only *sees* the ones that
/// reach the accessibility tree as speech. Rendering a new label is not telling anyone: VoiceOver
/// re-reads an element when focus lands on it, and hands-free is precisely the case where focus
/// is nowhere near the status card.
enum SessionTransition: Equatable {
    /// A live duplex session came up or went down (Gemini Live / OpenAI Realtime).
    case liveSession(mode: String, active: Bool)
    /// A live session dropped and is retrying.
    case reconnecting(mode: String)
    /// The wake-word / push-to-talk listener opened or closed a turn.
    case listening(Bool)
    /// A turn was dispatched to the model and is in flight.
    case thinking(Bool)
    /// The assistant's voice started or stopped.
    case speaking(Bool)
    /// Glasses camera streaming to the model.
    case cameraStreaming(Bool)
    /// The glasses link came up or went down.
    case glassesConnected(Bool)
    /// The microphone was muted or unmuted (the capsule's long-press).
    case micMuted(Bool)
    /// Something the user asked for did not happen.
    case error(String)
}

/// What the app is already making noise about, at the moment of the transition.
///
/// Both fields are the *reason an announcement is withheld*, never a reason to make one — which
/// is why the default is the quiet case, so a caller that forgets to fill one in errs toward
/// saying too little rather than talking over the assistant.
struct AnnouncementContext: Equatable {
    /// Nothing is listening otherwise, and an unconditional post is a silent no-op that hides
    /// wiring mistakes: gating here means a test can state "VoiceOver off ⇒ nothing".
    var voiceOverRunning: Bool = false
    /// The assistant's voice is on the air right now (TTS, Kokoro, or a live model's audio).
    var assistantIsSpeaking: Bool = false
    /// The processing pad is looping — the app's own "I'm working on it" sound.
    var thinkingSoundPlaying: Bool = false

    init(voiceOverRunning: Bool = false,
         assistantIsSpeaking: Bool = false,
         thinkingSoundPlaying: Bool = false) {
        self.voiceOverRunning = voiceOverRunning
        self.assistantIsSpeaking = assistantIsSpeaking
        self.thinkingSoundPlaying = thinkingSoundPlaying
    }
}

/// One spoken line, and how badly it wants the floor.
struct SessionAnnouncement: Equatable {
    let message: String
    /// `true` maps to `.announcement` posted at high priority — an interruption is warranted
    /// because the thing the user asked for failed.
    let interrupts: Bool
}

/// Which session transitions VoiceOver is told about, and which the app already says out loud.
///
/// The whole point is the *subtraction*. This app talks: it plays an ascending cue when the
/// glasses attach, a chime when a turn opens, a descending cue when the link drops, an ambient
/// pad while a turn runs, and it speaks its answers. Announcing those again puts two voices in
/// one ear a half-second apart, which is worse for the user this phase exists for than saying
/// nothing at all. So a transition earns an announcement only when the app is otherwise *silent*
/// about it.
enum SessionAnnouncementPolicy {

    /// Transitions the app already makes its own sound for. Kept as one list, next to the
    /// wording, so removing a tone and adding its announcement is a single edit rather than a
    /// regression that nobody notices until a user reports a silent app.
    static func hasOwnAudioCue(_ transition: SessionTransition, context: AnnouncementContext) -> Bool {
        switch transition {
        // `playAcknowledgmentTone()` / `playEndListeningTone()` bracket every turn.
        case .listening:
            return true
        // `playConnectTone()` / `playDisconnectTone()`.
        case .glassesConnected:
            return true
        // The assistant's own voice IS the cue; this is the one that must never double up.
        case .speaking:
            return true
        // The ambient pad, while it is actually looping. When something stopped it — a silent
        // route, a failed player — the transition is genuinely silent and does earn a line.
        case .thinking(let active):
            return active && context.thinkingSoundPlaying
        case .liveSession, .reconnecting, .cameraStreaming, .micMuted, .error:
            return false
        }
    }

    /// The line to speak, or `nil` to stay quiet.
    static func announcement(for transition: SessionTransition,
                             context: AnnouncementContext) -> SessionAnnouncement? {
        guard context.voiceOverRunning else { return nil }
        guard !hasOwnAudioCue(transition, context: context) else { return nil }
        // Never land on top of the assistant. An error that arrives mid-sentence is no exception:
        // the app is already telling the user something, and the banner keeps the detail.
        guard !context.assistantIsSpeaking else { return nil }

        switch transition {
        case .liveSession(let mode, let active):
            return SessionAnnouncement(message: active ? "\(mode) session started"
                                                       : "\(mode) session ended",
                                       interrupts: false)
        case .reconnecting(let mode):
            return SessionAnnouncement(message: "\(mode) reconnecting", interrupts: false)
        case .thinking(let active):
            return active ? SessionAnnouncement(message: "Thinking", interrupts: false) : nil
        case .cameraStreaming(let active):
            return SessionAnnouncement(message: active ? "Camera started" : "Camera stopped",
                                       interrupts: false)
        case .micMuted(let muted):
            return SessionAnnouncement(message: muted ? "Microphone muted" : "Microphone on",
                                       interrupts: false)
        case .error(let reason):
            let spoken = SpokenErrorPolicy.looksHuman(reason) ? reason : "Something went wrong"
            return SessionAnnouncement(message: spoken, interrupts: true)
        case .listening, .speaking, .glassesConnected:
            return nil   // unreachable: covered by `hasOwnAudioCue`
        }
    }
}
