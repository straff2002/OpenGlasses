import Foundation

/// Typed errors for the realtime audio managers (Gemini Live, OpenAI Realtime).
///
/// These exist so that a `nil` audio format or a failed session activation surfaces as a
/// clear, user-meaningful error the caller can present or log — instead of trapping on a
/// force-unwrap or throwing an opaque low-level `AVAudioSession` error mid-conversation.
/// Mirrors the `WakeWordError` pattern already used by `WakeWordService`.
enum AudioSessionError: LocalizedError, Equatable {
    /// Microphone permission is in the `.denied` state — the session can't capture.
    case microphonePermissionDenied
    /// `AVAudioFormat` could not be constructed for the given role (e.g. "playback",
    /// "capture resampling"). `context` names the role for logging/diagnostics.
    case invalidFormat(context: String)
    /// The audio session could not be activated even after the conservative fallback.
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable microphone permission for Avenkin in Settings."
        case .invalidFormat(let context):
            return "Could not create the \(context) audio format."
        case .activationFailed(let detail):
            return "Could not start the audio session: \(detail)"
        }
    }
}
