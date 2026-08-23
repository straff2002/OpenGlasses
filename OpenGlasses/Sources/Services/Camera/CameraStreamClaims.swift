import Foundation

/// Who is holding the glasses video stream open, so that a feature which *started* the stream can
/// stop it again without stopping one somebody else still wants.
///
/// The rule this encodes is not new — `ReadingCompanionService` already spelled it out in prose
/// ("stop only a stream this session started, and only when nothing else is consuming it") and
/// `FingerspellingSessionService` re-derived it as an `ownsCameraStream` boolean. Two ad-hoc copies
/// of a rule is how the third one gets it wrong, and Plan CV adds a third owner: continuous scene
/// narration now starts the camera itself, and it runs for as long as the wearer is walking — the
/// longest-lived claim in the app and therefore the one most likely to be underneath somebody
/// else's `stopStreaming()`.
///
/// Two facts do all the work, and both are about the *first* claim:
///
/// 1. **Was the stream already running when we arrived?** If it was, nobody here started it and
///    nobody here may stop it. This is the case that protects a manual stream from the bottom
///    control bar, or a live session's, from a narration session ending on top of it.
/// 2. **Is anything left holding it?** A stop is owed only when the last claim goes.
///
/// Pure value type — no camera, no clock, no I/O. The service applies the outcome.
struct CameraStreamClaims: Equatable {

    /// A named holder of the stream. A struct rather than an enum so a new consumer can claim
    /// without this file becoming a registry of every feature that touches the camera.
    struct Owner: Hashable, CustomStringConvertible {
        let id: String
        init(_ id: String) { self.id = id }
        var description: String { id }

        /// Plan CV — continuous scene narration.
        static let sceneNarration = Owner("sceneNarration")
        /// Plan CK — fingerspelling recognition.
        static let fingerspelling = Owner("fingerspelling")
    }

    /// What the service should do about a `claim`.
    enum ClaimOutcome: Equatable {
        /// Nothing is streaming and this is the first claim: start it.
        case startStream
        /// Frames are already flowing — either somebody else's stream or an earlier claim's.
        case alreadyRunning
        /// This owner already holds a claim; claiming twice is a no-op, not an error.
        case alreadyClaimed
    }

    /// What the service should do about a `release`.
    enum ReleaseOutcome: Equatable {
        /// Last claim gone, we are the ones who started it, and nothing else is consuming it.
        case stopStream
        /// Leave it running — somebody still wants it, or it was never ours to stop.
        case keepRunning
        /// This owner held nothing. Reported rather than ignored so a double-release is visible.
        case notHeld
    }

    private(set) var owners: Set<Owner> = []
    /// Whether the *first* claim was the thing that started the stream. Reset whenever the set
    /// empties, so a later claim re-answers question 1 against the world as it is then.
    private(set) var startedStream = false

    init() {}

    var isEmpty: Bool { owners.isEmpty }

    func holds(_ owner: Owner) -> Bool { owners.contains(owner) }

    /// Record a claim. `streamRunning` is read at the moment of the claim and only matters for the
    /// first one — after that the answer is already recorded.
    mutating func claim(_ owner: Owner, streamRunning: Bool) -> ClaimOutcome {
        guard !owners.contains(owner) else { return .alreadyClaimed }
        let isFirst = owners.isEmpty
        owners.insert(owner)
        guard isFirst else { return .alreadyRunning }
        startedStream = !streamRunning
        return startedStream ? .startStream : .alreadyRunning
    }

    /// Give a claim back.
    ///
    /// `otherConsumersActive` covers the consumers that never claim — recording, broadcast, WebRTC,
    /// a live realtime session. They are the reason a claim-count of zero is not sufficient on its
    /// own: a narration session that started the stream and then handed it, in effect, to a live
    /// session must not pull it out from under one.
    mutating func release(_ owner: Owner,
                          streamRunning: Bool,
                          otherConsumersActive: Bool) -> ReleaseOutcome {
        guard owners.remove(owner) != nil else { return .notHeld }
        guard owners.isEmpty else { return .keepRunning }
        let weStartedIt = startedStream
        startedStream = false
        guard weStartedIt, streamRunning, !otherConsumersActive else { return .keepRunning }
        return .stopStream
    }

    /// Drop a claim whose stream never came up, without proposing a stop for a stream that was
    /// never started. Distinct from `release` because "the start failed" and "we are finished with
    /// it" are different facts, and collapsing them asks the service to stop a stopped camera.
    mutating func abandon(_ owner: Owner) {
        owners.remove(owner)
        if owners.isEmpty { startedStream = false }
    }

    /// Forget everything — the camera has been torn down under us, so no claim describes reality.
    mutating func reset() {
        owners.removeAll()
        startedStream = false
    }
}
