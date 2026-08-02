import Foundation

/// A temple-gesture AVRCP command as it arrives from the glasses via `MPRemoteCommandCenter`
/// (Plan CH). The glasses' temple gestures send standard media commands to whatever app owns
/// Now Playing; while we hold the claim these are the raw events.
enum MediaRemoteCommand: Equatable {
    /// Double-tap on the temple (AVRCP next-track).
    case nextTrack
    /// Single-tap on the temple (AVRCP play/pause).
    case togglePlayPause
    /// Triple-tap / back gesture (AVRCP previous-track).
    case previousTrack
}

/// What the media-trigger subsystem should do with its Now Playing claim right now.
enum MediaTriggerAction: Equatable {
    /// Nothing is playing and nothing exclusive holds the audio lease — claim Now Playing so
    /// temple gestures reach us.
    case claim
    /// Conditions no longer allow holding the claim (user audio started, a realtime session
    /// took the lease, or the feature was disabled) — release it immediately.
    case release
    /// Leave things as they are: either we can't claim yet (wait for conditions to clear) or
    /// we already hold the claim and may keep it.
    case `defer`
}

/// Everything the claim/release decision depends on, as plain values (Plan CH P1).
struct MediaTriggerConditions: Equatable {
    /// The user's "Temple Tap" setting (off by default) AND the service is running.
    var triggerEnabled: Bool
    /// External audio is audible — `isOtherAudioPlaying` / an interruption is active. The
    /// user's own music always wins; we never squat on their session.
    var userAudioPlaying: Bool
    /// A realtime voice session (Gemini Live / OpenAI Realtime) is running. These own the
    /// duplex audio pipeline end-to-end; the media trigger stays out entirely.
    var realtimeSessionActive: Bool
    /// Current exclusive holder of the shared `AVAudioSession` (Plan AS coordinator).
    var leaseOwner: AudioSessionOwner?
    /// Whether we currently hold the Now Playing claim.
    var isClaimed: Bool
}

/// The pure claim/release/defer policy for the temple-tap media trigger (Plan CH).
///
/// Claiming Now Playing is how we receive the glasses' temple gestures — but it collides with
/// the user's own audio, with `MusicControlTool` driving *their* player, and with realtime
/// sessions that hold the audio lease. This table decides who wins: the user's audio and any
/// exclusive lease holder always beat us; we claim only when the coast is clear and release
/// the moment it isn't. Pure and value-driven so the whole matrix is testable as data — no
/// audio stack needed.
enum MediaTriggerPolicy {

    /// Decide what to do with the Now Playing claim given the current conditions.
    static func decide(_ conditions: MediaTriggerConditions) -> MediaTriggerAction {
        let mayHold = conditions.triggerEnabled
            && !conditions.userAudioPlaying
            && !conditions.realtimeSessionActive
            && !ownerBlocksClaim(conditions.leaseOwner)
        switch (mayHold, conditions.isClaimed) {
        case (true, false): return .claim
        case (false, true): return .release
        default: return .defer
        }
    }

    /// Whether an exclusive audio-lease holder forbids claiming Now Playing.
    ///
    /// The ambient owners are fine to coexist with: `wakeWord` holds the lease whenever the
    /// always-on listener runs (its `mixWithOthers` session is exactly what our silent player
    /// rides on), `textToSpeech` is a coexisting rider, and `mediaTrigger` is ourselves. Every
    /// mode that captures or duplexes audio for a conversation blocks the claim.
    static func ownerBlocksClaim(_ owner: AudioSessionOwner?) -> Bool {
        switch owner {
        case nil, .wakeWord, .textToSpeech, .mediaTrigger:
            return false
        case .transcription, .liveTranslation, .geminiLive, .openAIRealtime, .expertCall:
            return true
        }
    }

    /// Gesture grammar v1 (Plan CH): **only next-track (temple double-tap) starts listening.**
    /// Play/pause and previous-track are accepted while we hold the claim (so the OS has a
    /// live handler) but deliberately do nothing — one gesture until device testing (P3) says
    /// more is reliable.
    static func firesTrigger(_ command: MediaRemoteCommand) -> Bool {
        command == .nextTrack
    }
}
