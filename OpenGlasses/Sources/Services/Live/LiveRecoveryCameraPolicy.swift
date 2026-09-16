import Foundation

/// Plan FF P1/PR5, over Plan FD P1 — whether a session whose socket just came back may ask the
/// camera to start.
///
/// # The rule being enforced
///
/// `StreamPausePolicy` settled it for the camera backend: **a pause is waited out, never started
/// out of.** The pinned DAT SDK exposes no resume, `Stream.start()` on a paused stream is a second
/// start issued into a hold the system already owns, and every observed cause of a pause — a temple
/// hold, a doff, folded hinges — is cleared physically by the wearer and not by the app.
///
/// A reconnect is a new way to break that rule. The socket coming back is a moment where it is very
/// tempting to "restore everything", and a camera the outage left paused would get a competing
/// start issued into it by a session that never asked the camera what state it was in.
///
/// So the decision is a value, not a line of code inside a callback: a reconnect may start the
/// camera only from a genuinely stopped one, and a paused camera is reported to the wearer — PR2's
/// `cameraUnavailable` cue — while the SDK is left to move the stream itself.
enum LiveRecoveryCameraPolicy {

    /// What a reconnect may do about the camera.
    enum Action: Equatable {
        /// Pictures are arriving (or a start is already in flight). Nothing to do.
        case none
        /// The stream is stopped and this session needs to see. A start is legitimate here — this
        /// is the cold-start case, the same one `StreamPausePolicy.warmupAction` allows a nudge in.
        case startCamera
        /// The SDK is holding the stream. Report it and wait; issuing a start here is the competing
        /// restart the pause rule exists to remove.
        case awaitSDKResume
    }

    /// - Parameters:
    ///   - readiness: the camera's own snapshot, or `nil` when no camera is wired to this session.
    ///   - sessionNeedsVision: whether this session answers questions about what the wearer sees.
    static func action(readiness: CameraReadiness?, sessionNeedsVision: Bool) -> Action {
        guard sessionNeedsVision, let readiness else { return .none }
        switch readiness.phase {
        case .paused:
            return .awaitSDKResume
        case .stopped:
            // Only where continuous streaming is still wanted. A camera the wearer turned off is
            // not something a reconnect gets to turn back on.
            return readiness.userWantsStream ? .startCamera : .none
        case .connecting, .awaitingFirstFrame, .ready, .framesUnavailable, .decodingStalled,
             .stopping:
            // A start is already in flight, pictures are flowing, or the backend's own recovery
            // ladder owns the fault. None of them is repaired by a second start from here.
            return .none
        }
    }

    /// The single question the reconnect path asks. Written as its own property so a caller cannot
    /// accidentally express "start anyway" for a paused camera.
    static func mayStartCamera(readiness: CameraReadiness?, sessionNeedsVision: Bool) -> Bool {
        action(readiness: readiness, sessionNeedsVision: sessionNeedsVision) == .startCamera
    }
}
