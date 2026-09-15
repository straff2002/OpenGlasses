import Foundation

/// Plan FD P0 — one answer to "is the camera ready?", for everybody who used to have their own.
///
/// # The failure this exists to stop
///
/// Before this type, "ready" was spelled at least four different ways across the app, and the
/// spellings disagreed:
///
/// * `isStreaming` — the SDK said a stream exists. It says nothing about pictures. A stream that
///   is up and delivering nothing decodable satisfies it, which is how a control bar came to say
///   **Streaming** while the wearer looked at a frozen preview.
/// * a non-nil cached still — a *frame once arrived*. It has no age, so a picture from before the
///   wearer walked into the next room satisfies it just as well as one from this second.
/// * `isStartingStream` — a start is in flight. Useful for a button, useless as evidence.
/// * user intent — somebody wants the camera on. The only correct input for "should I press Start",
///   and the wrong one for "may I answer a question about what is in front of you".
///
/// Collapsing those into one boolean is what made the two opposite bugs possible at once: an action
/// that needed a fresh picture accepted a stale one, and a Start button that needed nothing at all
/// was disabled for want of frames.
///
/// # The shape
///
/// A snapshot separates the three questions and refuses to answer any of them with another's
/// evidence:
///
/// * `phase` — what is observably happening, in words a wearer can be shown.
/// * `frameAge` — how old the newest *successfully decoded* picture is, on a monotonic clock.
///   `nil` means this session has never produced one.
/// * `session` — which camera session this describes, so a snapshot captured across a replacement
///   can be recognised as describing a camera that no longer exists.
/// * `userWantsStream` — whether continuous streaming is still wanted. Start/Connect decisions read
///   this and nothing else, which is what keeps them reachable when there are no frames.
///
/// Pure, so the whole table is exercised headlessly. Derived from the backend's own observations —
/// this deliberately re-implements no stall detection: `StreamLiveness` and the backend's recovery
/// ladder stay authoritative, and the snapshot only reports what they found.
struct CameraReadiness: Equatable {

    /// What is observably happening to the camera. Every case is a state the wearer can be shown
    /// as-is; none of them is inferred from another component's silence.
    enum Phase: String, Equatable, CaseIterable {
        /// No stream, and none wanted.
        case stopped
        /// A start, a warm-up, or a reconnect is under way. A healthy cold start lives here for
        /// up to about twenty seconds.
        case connecting
        /// The stream is up and no picture has been produced from it yet.
        case awaitingFirstFrame
        /// Pictures are being produced. The only phase that can carry fresh visual evidence.
        case ready
        /// The SDK paused the stream. Since DAT 0.9 a doff lands here, and so do closed hinges.
        case paused
        /// Nothing is arriving from the glasses. Reported only where the backend's liveness
        /// detection observed it, never inferred from a quiet moment.
        case framesUnavailable
        /// Samples are arriving and none of them is becoming a picture. Same rule: observed by the
        /// decoder's own liveness clocks, not guessed at here.
        case decodingStalled
        /// A stop is in flight.
        case stopping
    }

    let phase: Phase

    /// Seconds since the newest successfully decoded picture, on a monotonic clock. `nil` when this
    /// session has not produced one — which is a different statement from "a long time ago" and has
    /// to stay one.
    ///
    /// A picture the decoder handed over again while waiting for a keyframe does **not** move this:
    /// the app keeps seeing it, but it is not a new view of the world.
    let frameAge: TimeInterval?

    /// The camera session this snapshot describes. Bumped whenever the stream is stopped or
    /// replaced, so a snapshot held across a replacement is recognisably about a different camera.
    let session: Int

    /// Whether continuous streaming is still wanted. The only input a "should I start the camera"
    /// decision may use.
    let userWantsStream: Bool

    init(phase: Phase, frameAge: TimeInterval?, session: Int, userWantsStream: Bool) {
        self.phase = phase
        self.frameAge = frameAge
        self.session = session
        self.userWantsStream = userWantsStream
    }

    /// Nothing is known about this session's pictures: a fresh session, or one whose frames have
    /// been invalidated by a disconnect or a teardown.
    static func cleared(session: Int) -> CameraReadiness {
        CameraReadiness(phase: .stopped, frameAge: nil, session: session, userWantsStream: false)
    }

    // MARK: - Evidence

    /// How old a picture may be and still answer a question about what is in front of the wearer.
    ///
    /// Deliberately a little *above* `StreamLiveness.stallThreshold`, so the backend's stall
    /// detector is always the first thing to notice a stopped picture flow and this stays a
    /// backstop rather than a second, competing detector. Two seconds is also comfortably longer
    /// than the interval of the slowest live-session poll, so a healthy stream never trips it.
    static let evidenceMaxAge: TimeInterval = 2

    /// Whether an action that needs to *see* something may proceed.
    ///
    /// Both halves are load-bearing. `.ready` alone would accept a stream whose pictures stopped a
    /// minute ago; an age alone would accept the last picture of a session that has since been
    /// replaced, because `frameAge` cannot tell which camera it came from.
    var hasFreshVisualEvidence: Bool {
        phase == .ready && (frameAge ?? .infinity) <= Self.evidenceMaxAge
    }

    /// Whether a held picture is being shown that must not be mistaken for a current one.
    var isShowingHeldPicture: Bool { frameAge != nil && !hasFreshVisualEvidence }

    /// Whether this snapshot still describes `session`. A snapshot that does not is about a camera
    /// that no longer exists, whatever its phase says.
    func describes(session: Int) -> Bool { self.session == session }

    // MARK: - Copy
    //
    // Every string below states an observation and, where there is one, the move the wearer can
    // make. None of them guesses at a cause the app cannot see — no other app owning the camera,
    // no conclusion about whether the glasses are being worn, no advice to power-cycle anything.

    /// Short label for a control that toggles the camera.
    var controlLabel: String {
        switch phase {
        case .stopped: return "Camera"
        case .connecting: return "Starting…"
        case .awaitingFirstFrame: return "Waiting…"
        case .ready: return "Streaming"
        case .paused: return "Paused"
        case .framesUnavailable: return "No frames"
        case .decodingStalled: return "No picture"
        case .stopping: return "Stopping…"
        }
    }

    /// One sentence for a status line, and for VoiceOver to read.
    var statusPhrase: String {
        switch phase {
        case .stopped: return "Camera off"
        case .connecting: return "Camera connecting"
        case .awaitingFirstFrame: return "Camera waiting for the first frame"
        case .ready: return "Camera streaming"
        case .paused: return "Camera paused"
        case .framesUnavailable: return "Camera sending no frames"
        case .decodingStalled: return "Camera picture stalled"
        case .stopping: return "Camera stopping"
        }
    }

    /// The hint a camera control offers, or `nil` when the control's own label already says it.
    var controlHint: String? {
        switch phase {
        case .stopped: return "Double-tap to stream the glasses camera to the model."
        case .connecting: return "Starting the camera. This takes a moment."
        case .awaitingFirstFrame: return "The camera is on and the first picture has not arrived yet."
        case .ready: return "The camera is streaming."
        case .paused: return "The camera is paused. Put the glasses on, or check they aren't folded."
        case .framesUnavailable: return "The camera is on and no pictures are arriving."
        case .decodingStalled: return "Pictures are arriving but none can be shown yet."
        case .stopping: return "Stopping the camera."
        }
    }

    /// The persistent marker over a preview that is showing a picture which is no longer current.
    /// `nil` when the picture on screen *is* current, or when there is none to mark.
    var heldPictureMarker: String? {
        guard isShowingHeldPicture else { return nil }
        switch phase {
        case .paused:
            return "Paused — this is the last picture received, not a live view."
        case .framesUnavailable:
            return "No new pictures — this is the last one received, not a live view."
        case .decodingStalled:
            return "Picture stalled — this is the last one received, not a live view."
        case .connecting, .awaitingFirstFrame:
            return "Reconnecting — this is the last picture received, not a live view."
        case .stopped, .stopping:
            return "Camera stopped — this is the last picture received, not a live view."
        case .ready:
            return "This is the last picture received, not a live view."
        }
    }

    /// What VoiceOver reads for the preview image itself. The held case has to say so in the label,
    /// not only in a marker beside it: a held picture read out as "live camera feed" is the same
    /// untruth the marker exists to prevent, delivered to the user least able to check it.
    var previewAccessibilityLabel: String {
        if let marker = heldPictureMarker { return marker }
        return "Live camera feed from glasses"
    }

    /// The camera chip on a live-session status card, or `nil` when there is nothing to report —
    /// no stream running, none wanted, and no picture being held.
    ///
    /// The chip used to appear on `isStreaming` alone, which is how a paused camera kept a green
    /// dot and the word CAM next to it.
    struct Chip: Equatable {
        let label: String
        let spoken: String
        /// Whether pictures are actually flowing. Drives the dot's colour; never the mere presence
        /// of a session.
        let isHealthy: Bool
    }

    var statusChip: Chip? {
        switch phase {
        case .stopped, .stopping:
            return nil
        case .ready:
            return Chip(label: "CAM", spoken: statusPhrase, isHealthy: true)
        case .connecting, .awaitingFirstFrame, .paused, .framesUnavailable, .decodingStalled:
            guard userWantsStream else { return nil }
            return Chip(label: "CAM \(shortPhaseWord)", spoken: statusPhrase, isHealthy: false)
        }
    }

    /// A word small enough to sit inside a chip.
    private var shortPhaseWord: String {
        switch phase {
        case .connecting: return "starting"
        case .awaitingFirstFrame: return "waiting"
        case .paused: return "paused"
        case .framesUnavailable: return "no frames"
        case .decodingStalled: return "stalled"
        case .ready, .stopped, .stopping: return ""
        }
    }

    // MARK: - Derivation

    /// Build a snapshot from what the coordinator and the backend between them observed.
    ///
    /// The order of the rules is the design. An observed reason for *not* delivering pictures beats
    /// every flag, because those reasons are things the backend watched happen; only once there is
    /// no such reason does the stream flag get to speak, and only then does a start in flight. The
    /// last line is the honest default: nothing is happening.
    ///
    /// - Parameters:
    ///   - waitReason: why the backend currently isn't delivering pictures, or `nil` when it has
    ///     no such observation. Never inferred here.
    ///   - streamIsUp: the backend's claim that a stream exists and should be delivering.
    ///   - startIsPending: a start is in flight — the cold-start window.
    ///   - userWantsStream: continuous streaming is still wanted.
    ///   - frameAge: seconds since the newest decoded picture of this session, or `nil` for none.
    ///   - session: the session identity this describes.
    static func derive(waitReason: CameraWaitReason?,
                       streamIsUp: Bool,
                       startIsPending: Bool,
                       userWantsStream: Bool,
                       frameAge: TimeInterval?,
                       session: Int) -> CameraReadiness {
        let phase: Phase
        switch waitReason {
        case .paused: phase = .paused
        case .decodingStalled: phase = .decodingStalled
        case .framesUnavailable: phase = .framesUnavailable
        case .stopping: phase = .stopping
        case .connecting: phase = .connecting
        case nil:
            if streamIsUp {
                phase = frameAge == nil ? .awaitingFirstFrame : .ready
            } else if startIsPending {
                phase = .connecting
            } else {
                phase = .stopped
            }
        }
        return CameraReadiness(phase: phase,
                               frameAge: frameAge,
                               session: session,
                               userWantsStream: userWantsStream)
    }
}
