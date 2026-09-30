import Foundation

/// A temple-gesture AVRCP command as it arrives from the glasses via `MPRemoteCommandCenter`
/// (Plan CH). The glasses' temple gestures send standard media commands to whatever app owns
/// Now Playing; while we hold the claim these are the raw events. Which tap count sends which
/// command is **not** assumed here — `TempleCalibration` maps them (Plan GJ), and the mapping is
/// device-unverified until the glasses run.
enum MediaRemoteCommand: String, Hashable, CaseIterable {
    case togglePlayPause
    /// A discrete play — how many Bluetooth stacks deliver a single press.
    case play
    /// A discrete pause — likewise.
    case pause
    case nextTrack
    case previousTrack
}

/// How the app holds Now Playing while the temple taps are on (Plan GJ).
enum NowPlayingClaimMode: String, Equatable {
    /// Nothing else is going on: a silent, zero-volume player keeps the app the Now Playing owner
    /// so taps reach it (Plan CH's original claim).
    case standby
    /// The app's own conversation holds the audio session. The remote-command handlers stay
    /// registered but no silent player runs — the conversation's own audio is what should make the
    /// app the Now Playing owner. Device-unverified: whether iOS routes the commands to a
    /// record-and-play session is part of the glasses run.
    case sessionControl
}

/// What the media-trigger subsystem should do with its Now Playing claim right now.
enum MediaTriggerAction: Equatable {
    /// Hold Now Playing in this mode — a fresh claim, or a switch from the other mode.
    case claim(NowPlayingClaimMode)
    /// Conditions no longer allow holding the claim (user audio started, another person is on the
    /// line, or the feature was disabled) — release it immediately.
    case release
    /// Leave things as they are.
    case `defer`
}

/// Everything the claim/release decision depends on, as plain values (Plan CH P1, GJ P0).
struct MediaTriggerConditions: Equatable {
    /// The user's temple-tap setting (off by default) AND the service is running.
    var triggerEnabled: Bool
    /// External audio is audible — `isOtherAudioPlaying` / an interruption is active. The
    /// user's own music always wins; with it playing, their taps control their music.
    var userAudioPlaying: Bool
    /// A realtime voice session (Gemini Live / OpenAI Realtime) is running.
    var realtimeSessionActive: Bool
    /// Current exclusive holder of the shared `AVAudioSession` (Plan AS coordinator).
    var leaseOwner: AudioSessionOwner?
    /// The mode we currently hold the claim in, or nil when not claimed.
    var claimedMode: NowPlayingClaimMode?
    /// A Direct-mode conversation is under way (listening, thinking or speaking).
    var conversationActive: Bool = false
    /// Whether taps may be taken during the app's own conversations (`TempleCalibration`).
    var sessionControlEnabled: Bool = true

    var isClaimed: Bool { claimedMode != nil }
}

/// The pure claim/release/defer policy for the temple taps (Plan CH, extended by GJ).
///
/// Claiming Now Playing is how we receive the glasses' temple gestures — but it collides with the
/// user's own audio, with `MusicControlTool` driving *their* player, and with anything that puts
/// another person on the line. This table decides who wins: the user's audio and other-party audio
/// always beat us. Pure and value-driven so the whole matrix is testable as data.
enum MediaTriggerPolicy {

    /// Who holds the audio lease, from the temple taps' point of view.
    enum LeaseClass: Equatable {
        /// Ambient owners the standby claim rides alongside: the wake-word listener (whose
        /// `mixWithOthers` session is what the silent player rides on), TTS, ourselves, and the
        /// standalone capture tap.
        case ambient
        /// The app's own conversation — Direct-mode transcription or a live session. Taps are
        /// how the wearer hangs up or mutes, so the handlers stay (session control), but the
        /// silent player never runs under it.
        case ownConversation
        /// Another person is on the line — live translation or an expert call. Taps stay out.
        case otherParty
    }

    static func classify(_ owner: AudioSessionOwner?) -> LeaseClass {
        switch owner {
        case nil, .wakeWord, .textToSpeech, .mediaTrigger, .captureAudio:
            return .ambient
        case .transcription, .geminiLive, .openAIRealtime:
            return .ownConversation
        case .liveTranslation, .expertCall:
            return .otherParty
        }
    }

    /// Whether a lease holder forbids the *standby* claim (the silent player). Every mode that
    /// captures or duplexes audio for a conversation does.
    static func ownerBlocksClaim(_ owner: AudioSessionOwner?) -> Bool {
        classify(owner) != .ambient
    }

    /// The mode the claim should be in, or nil for no claim.
    static func desiredMode(_ conditions: MediaTriggerConditions) -> NowPlayingClaimMode? {
        guard conditions.triggerEnabled, !conditions.userAudioPlaying else { return nil }
        let lease = classify(conditions.leaseOwner)
        if lease == .otherParty { return nil }
        let ownConversation = lease == .ownConversation
            || conditions.realtimeSessionActive
            || conditions.conversationActive
        if ownConversation {
            return conditions.sessionControlEnabled ? .sessionControl : nil
        }
        return .standby
    }

    /// Decide what to do with the Now Playing claim given the current conditions.
    static func decide(_ conditions: MediaTriggerConditions) -> MediaTriggerAction {
        let desired = desiredMode(conditions)
        if desired == conditions.claimedMode { return .defer }
        guard let desired else { return .release }
        return .claim(desired)
    }
}
