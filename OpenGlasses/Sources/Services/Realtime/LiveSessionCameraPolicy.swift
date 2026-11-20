import Foundation

/// When a Gemini Live or OpenAI Realtime conversation turns the glasses camera on.
///
/// Two rules, both about the capture LED a wearer sees:
///
/// 1. **Only a session turns the camera on, never the mode.** Choosing a live mode, or launching
///    into one, used to start the stream with a bare `startStreaming()` before any session began.
///    That stream had no owner, so the session's `.liveSession` claim found it already running,
///    took it for somebody else's, and on the way out left it alone: the LED stayed on, and the
///    battery drained, for as long as the mode stayed selected. The session's claim now starts the
///    stream itself and gives it back when the session ends.
/// 2. **Audio-Only Mode keeps it off.** The setting promises to disable camera streaming from the
///    glasses; it used to stop only the frames sent to the model, with the camera still running.
///
/// Pure, so it can be tested without a session.
enum LiveSessionCameraPolicy {

    /// Whether a live session should claim the glasses camera.
    static func startsCamera(modelSupportsVision: Bool, audioOnly: Bool) -> Bool {
        modelSupportsVision && !audioOnly
    }
}
