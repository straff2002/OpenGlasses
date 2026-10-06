import AVFoundation
import Foundation

/// A capture source that applies `AssistantAudioGate`, for a recorder that reads the mic some
/// other way (Plan HQ P1 item 3).
///
/// The audio-only recorder takes the always-on listener's tap directly rather than registering
/// through `CaptureAudioRouter`, so the router's fan-out never sees its buffers. It still needs the
/// router's decision — made from the one subscription to the assistant's speaking state, the
/// output route and the "Include Assistant Voice" setting — so the setting means the same thing
/// for an audio-only recording as for a video or a stream.
protocol AssistantVoiceGating: AnyObject, Sendable {
    /// Whether the assistant's voice may end up in a capture that starts now: the "Include
    /// Assistant Voice" setting, read at the start. Decides the recording's metadata, which the
    /// writer needs before its first sample.
    @MainActor var assistantVoiceMayBeIncluded: Bool { get }
    /// The gate's current decision applied to one buffer: the buffer itself, or a silent buffer of
    /// the same shape. Called from the audio thread.
    nonisolated func gatedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer
}

/// What to do with a mic buffer on its way to capture consumers.
enum CaptureAudioGateDecision: String, Equatable, Sendable {
    /// Forward the buffer untouched.
    case pass
    /// Forward a zero-filled buffer of the same shape. **Not** a drop: the broadcast's audio PTS
    /// comes from a running sample-count clock, so a missing buffer shifts every later sample and
    /// desynchronises the stream. Silence keeps the timeline honest.
    case silence
}

/// Whether the assistant's own voice should be captured into a stream or a recording.
///
/// When replies play out of the phone speaker (glasses not connected, or an explicit speaker
/// route), the mic hears them and muxes them straight back into whatever is being captured. The
/// wearer hears their assistant once; the audience hears it twice, out of sync with itself, over
/// the top of whatever the wearer was actually saying. Nothing gates this today.
///
/// The route condition is load-bearing rather than incidental: replies rendered into the glasses
/// (or any private output) never reach the mic in the first place, so gating on `isSpeaking` alone
/// would blank real audio during every reply for the common case where there is nothing to blank.
///
/// Pure and side-effect free; the router evaluates it and pushes the result to the audio thread.
enum AssistantAudioGate {
    /// - Parameters:
    ///   - ttsSpeaking: the assistant is rendering speech right now.
    ///   - ttsOnPhoneSpeaker: that speech is coming out of the phone's own speaker, where the mic
    ///     can hear it.
    ///   - includeAssistantVoice: the wearer has opted to let the capture hear the assistant (a
    ///     streamer whose audience is following the conversation wants exactly this).
    static func decide(
        ttsSpeaking: Bool,
        ttsOnPhoneSpeaker: Bool,
        includeAssistantVoice: Bool
    ) -> CaptureAudioGateDecision {
        guard ttsSpeaking, ttsOnPhoneSpeaker, !includeAssistantVoice else { return .pass }
        return .silence
    }
}
