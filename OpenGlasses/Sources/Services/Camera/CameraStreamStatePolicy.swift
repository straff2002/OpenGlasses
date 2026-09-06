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
        /// Stopped with streaming still intended: the stream died under us. Same shape as
        /// `pausedWhileWanted` — report it, stop claiming to stream — but a stop does *not* come
        /// back from a `start()` nudge, so the caller owns a bounded reconnect ladder instead.
        case stoppedWhileWanted(notice: String)
    }

    /// Shown when a wanted stream pauses. Names the likeliest cause first — since DAT 0.9 a doff
    /// pauses the camera, and "put them back on" is the whole fix in the common case.
    static let pausedNotice = "Camera paused — put the glasses on, or check they aren't folded."

    /// Shown when a wanted stream stops. Says a retry is already under way, because it is: the
    /// wearer's job here is to make the retry able to succeed, not to press anything.
    static let stoppedNotice = "Camera dropped — reconnecting. Check the glasses are on and unfolded."

    /// Secondary line for a preview that is still waiting on its first frame. A *healthy* cold
    /// start takes up to `StreamRecoveryPolicy.observedColdStart`, so a spinner alone is honest
    /// but useless: field reports of "black screen" are overwhelmingly folded hinges or glasses
    /// off the face, both of which turn the camera off, and neither of which the old copy named.
    static let coldStartHint = "Put the glasses on and open the hinges — the first frame can take up to 20 seconds."

    /// How long to let the plain spinner stand before adding the hint. Short enough to help a
    /// stuck start, long enough that a quick connect never flashes advice the wearer didn't need.
    static let coldStartHintDelay: TimeInterval = 5

    /// - Parameters:
    ///   - streamingIntended: whether continuous streaming is still wanted.
    ///   - transitionIsOurs: whether a start or rebuild **we own** is in flight — warmup, or the
    ///     tiered stall recovery. Both drive the stream through `.stopped` on purpose and both
    ///     report their own outcome, so their churn must not be read as the stream dropping out
    ///     from under us. This is not a nicety: a healthy cold start bounces through `.stopped`
    ///     for 15-18 s with the intent already set, and `teardownStreamOnly()` stops the stream
    ///     with the listeners still attached — without this, every ordinary start and every
    ///     1.5 s frame stall would announce "Camera dropped" and then re-announce the recovery
    ///     the caller is about to announce itself.
    static func decide(state: StreamState,
                       streamingIntended: Bool,
                       transitionIsOurs: Bool = false) -> Decision {
        switch state {
        case .streaming:
            return .streaming
        case .paused:
            // Only a *wanted* stream deserves a notice: a pause after a one-off capture is the
            // app's own doing (the stream is deliberately parked) and must stay silent.
            //
            // Deliberately NOT gated on `transitionIsOurs`: a doff during warmup is still the
            // wearer's doing and still the thing they can fix in one move, and the nudge this
            // row triggers is what warmup wanted anyway.
            return streamingIntended ? .pausedWhileWanted(notice: pausedNotice) : .waiting
        case .stopped:
            // Intent is checked FIRST, and the order is load-bearing. Ownership may only soften a
            // stop for a stream somebody still wants: the windows where a transition is ours but
            // the intent has already been cleared are a warmup that just threw and a stop pressed
            // mid-recovery, and both of those are endings. Softening them to `.waiting` parks the
            // UI on "Connecting…" for a camera that has finished trying.
            guard streamingIntended else { return .stopped }
            // A stop that is ours is one step of a ladder already climbing, so it reads as
            // transient and the owner reports the ending if there is one.
            if transitionIsOurs { return .waiting }
            // Device-traced: a mid-stream Bluetooth hiccup or a brief fold drops the stream to
            // `.stopped` while continuous streaming is still intended. This row used to return a
            // flat `.stopped`, which cleared `isStreaming` — and clearing `isStreaming` disarms
            // the stall detector, the one thing that would otherwise have rebuilt the stream. So
            // the preview went black and stayed black until the wearer stopped and started by
            // hand. A stop we did not ask for is a reconnect, not an ending.
            return .stoppedWhileWanted(notice: stoppedNotice)
        case .starting, .stopping, .waitingForDevice:
            return .waiting
        }
    }

    /// Whether this state should leave `isStreaming` true. The regression in one line: a paused
    /// stream is not streaming, whatever the label said.
    static func isStreaming(_ state: StreamState) -> Bool { state == .streaming }
}
