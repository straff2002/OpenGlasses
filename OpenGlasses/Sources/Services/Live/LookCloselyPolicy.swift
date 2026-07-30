import Foundation

/// Plan CB P1 — when `look_closely` may fire the camera, and what it tells the model.
///
/// A stream and a reading task want opposite things: the stream is throttled to roughly a frame a
/// second and must stay small; resolving fine print needs one sharp frame and does not care about
/// frame rate. The tool bridges that — but a full-resolution still is a real cost spike, so the
/// decision is a pure function of power posture and recency rather than an unconditional capture.
enum LookCloselyPolicy {

    /// Floor between full-resolution captures. A model that learns the tool works will call it
    /// eagerly; without a floor that becomes a photo-per-turn battery drain.
    static let minimumCaptureInterval: TimeInterval = 5

    enum Decision: Equatable {
        /// Fire the camera for a fresh full-resolution still.
        case captureSharpFrame
        /// Don't capture — tell the model to answer from the stream frame it already has,
        /// with the reason, so it says so instead of stalling.
        case declineWithReason(String)
    }

    static func decide(posture: PowerPosture, secondsSinceLastCapture: TimeInterval?) -> Decision {
        // Reserve posture: camera only on explicit *user* request (the posture's contract) — a
        // model-initiated capture doesn't qualify. The stream frame is already in its view.
        if posture == .reserve {
            return .declineWithReason(
                "The battery is in power reserve, so no fresh photo was taken. Answer from the most recent camera frame you can already see, and say the view may lack fine detail.")
        }
        if let elapsed = secondsSinceLastCapture, elapsed < minimumCaptureInterval {
            return .declineWithReason(
                "A sharp photo was captured only moments ago and is already in your view — read the detail from that image rather than requesting another.")
        }
        return .captureSharpFrame
    }

    /// The function result returned after a successful capture + injection.
    ///
    /// Live function results carry text only — the tool cannot return the image. It returns an
    /// *instruction* to read the image that has just arrived separately. Ordering matters and is
    /// owned by the tool: inject first, then answer the call with this.
    static let sharpFrameInstruction = """
        A sharp, full-resolution photo of the current view has just been added to your vision. \
        Read the fine detail the streamed frames could not resolve — small print, line items, \
        serial numbers, gauge markings — directly from that new image and answer the question \
        from it.
        """
}
