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
    /// The glasses are connected and not known to be off the wearer's face. Taps can only come
    /// from glasses being worn, so with none there the lock-screen widget the claim brings is
    /// pure clutter.
    var glassesPresent: Bool = true
    /// External audio is audible — `isOtherAudioPlaying` / an interruption is active. The
    /// user's own music always wins; with it playing, their taps control their music.
    var userAudioPlaying: Bool
    /// Another app's media has played since the glasses last arrived. Its player keeps Now
    /// Playing — paused or not — until the glasses are next put on or reconnect, so a paused
    /// podcast is never pushed off the lock screen by our silent claim.
    var yieldedToMedia: Bool = false
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
    /// Whether a `.standby` claim is still holding on as far as the app can tell — its silent player
    /// is playing, or about to. iOS stops that player under us (another owner reshaping the shared
    /// session, an interruption) without telling the claim, and a dead standby claim receives no
    /// taps, so the policy treats it as no claim at all. Ignored for `.sessionControl`, which has
    /// no player.
    var standbyClaimLive: Bool = true

    var isClaimed: Bool { claimedMode != nil }

    /// The claim as it really stands: a standby claim whose player has stopped counts as none.
    var effectiveClaimedMode: NowPlayingClaimMode? {
        claimedMode == .standby && !standbyClaimLive ? nil : claimedMode
    }
}

/// Why the temple taps hold no claim — the condition that won, as written to the support log.
enum MediaTriggerReleaseReason: String, Equatable {
    /// The setting is off, or the service is not running.
    case disabled
    /// The glasses are not connected, or are off the wearer's face.
    case glassesAbsent
    /// The user's own audio is playing; their taps control it.
    case userAudio
    /// The user's own audio has played since the glasses arrived; their player keeps Now Playing.
    case yieldedToMedia
    /// Another person is on the line (live translation, an expert call).
    case otherParty
    /// The app's own conversation holds the session and the calibration says taps don't reach it.
    case sessionControlUnavailable
}

/// The pure claim/release/defer policy for the temple taps (Plan CH, extended by GJ).
///
/// Claiming Now Playing is how we receive the glasses' temple gestures — but it collides with the
/// user's own audio, with `MusicControlTool` driving *their* player, and with anything that puts
/// another person on the line, and iOS shows whoever holds it on the lock screen. This table
/// decides who wins: no claim without worn glasses, and the user's media (playing, or played and
/// paused) and other-party audio always beat us. Pure and value-driven so the whole matrix is
/// testable as data.
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

    /// Whether the app's own conversation is under way, by lease or by state.
    static func ownConversation(_ conditions: MediaTriggerConditions) -> Bool {
        classify(conditions.leaseOwner) == .ownConversation
            || conditions.realtimeSessionActive
            || conditions.conversationActive
    }

    /// The condition that rules a claim out, or nil when one should be held. Checked in this
    /// order, so the log names the first condition that won.
    static func releaseReason(_ conditions: MediaTriggerConditions) -> MediaTriggerReleaseReason? {
        guard conditions.triggerEnabled else { return .disabled }
        guard conditions.glassesPresent else { return .glassesAbsent }
        if conditions.userAudioPlaying { return .userAudio }
        if conditions.yieldedToMedia { return .yieldedToMedia }
        if classify(conditions.leaseOwner) == .otherParty { return .otherParty }
        if ownConversation(conditions), !conditions.sessionControlEnabled {
            return .sessionControlUnavailable
        }
        return nil
    }

    /// The mode the claim should be in, or nil for no claim.
    static func desiredMode(_ conditions: MediaTriggerConditions) -> NowPlayingClaimMode? {
        guard releaseReason(conditions) == nil else { return nil }
        return ownConversation(conditions) ? .sessionControl : .standby
    }

    /// Decide what to do with the Now Playing claim given the current conditions. A standby claim
    /// whose player has stopped is compared as no claim, so it is taken afresh when one is wanted
    /// and dropped cleanly when not.
    static func decide(_ conditions: MediaTriggerConditions) -> MediaTriggerAction {
        let desired = desiredMode(conditions)
        let held = conditions.effectiveClaimedMode
        if desired == held {
            // A lapsed claim with nothing wanted still has handlers to drop.
            return held == nil && conditions.isClaimed ? .release : .defer
        }
        guard let desired else { return .release }
        return .claim(desired)
    }
}
