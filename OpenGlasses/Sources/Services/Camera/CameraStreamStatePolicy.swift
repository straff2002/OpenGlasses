import Foundation

/// What a camera stream-state change means for a session we intended to keep streaming.
///
/// Device-traced 2026-08-23: the state observer treated `.paused` as merely "waiting" — it did not
/// clear `isStreaming`, did not report anything, and did not try to resume. The result was a UI
/// that said **Streaming** while the camera was off and no frames were arriving, which is the worst
/// available combination: the one state the wearer could act on, presented as the state where
/// everything is fine.
///
/// `.paused` matters more since DAT 0.9, which pauses the stream when the glasses are **doffed**.
/// Taking the glasses off to look at the phone — the single most likely thing a person does while
/// testing — now stops the camera, and the app said nothing.
///
/// Pure so the mapping is testable without a device: this is a decision table, and the bug was a
/// missing row in it.
enum CameraStreamStatePolicy {

    /// The stream states we act on. Mirrors the SDK's lifecycle without importing it, so the table
    /// can be exercised headlessly.
    enum StreamState: Equatable {
        case streaming
        case paused
        case stopped
        case starting
        case stopping
        case waitingForDevice
    }

    enum Decision: Equatable {
        /// Frames are flowing; nothing to do.
        case streaming
        /// Transient — the stream is coming up or going down under its own steam.
        case waiting
        /// The stream has stopped and is not coming back on its own.
        case stopped
        /// Paused with streaming still intended: report it, stop claiming to stream, and try to
        /// resume. Carries copy because the wearer can usually fix it in one move.
        case pausedWhileWanted(notice: String)
    }

    /// Shown when a wanted stream pauses. Names the likeliest cause first — since DAT 0.9 a doff
    /// pauses the camera, and "put them back on" is the whole fix in the common case.
    static let pausedNotice = "Camera paused — put the glasses on, or check they aren't folded."

    static func decide(state: StreamState, streamingIntended: Bool) -> Decision {
        switch state {
        case .streaming:
            return .streaming
        case .paused:
            // Only a *wanted* stream deserves a notice: a pause after a one-off capture is the
            // app's own doing (the stream is deliberately parked) and must stay silent.
            return streamingIntended ? .pausedWhileWanted(notice: pausedNotice) : .waiting
        case .stopped:
            return .stopped
        case .starting, .stopping, .waitingForDevice:
            return .waiting
        }
    }

    /// Whether this state should leave `isStreaming` true. The regression in one line: a paused
    /// stream is not streaming, whatever the label said.
    static func isStreaming(_ state: StreamState) -> Bool { state == .streaming }
}
