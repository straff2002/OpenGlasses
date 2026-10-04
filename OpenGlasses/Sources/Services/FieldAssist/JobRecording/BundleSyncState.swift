import Foundation

/// Where one recorded job stands on its way to the office (Plan HE §4), as a state machine with no
/// clock, no network and no storage of its own.
///
/// ```
/// recording → preparing → sealed → waiting(reason) → transferring → delivered → acknowledged → trimmed
///                                                                   failed(reason)      expired
/// ```
///
/// Two rules it exists to keep:
///
/// - **Delivered is not acknowledged.** The transport saying every chunk was served moves the
///   recording to `delivered` and no further. Only the office's own receipt for this bundle and
///   this manifest — already verified by whoever hands it in — moves it to `acknowledged`, and
///   only from `acknowledged` can media be trimmed.
/// - **A receipt seen again changes nothing**, and one for another bundle or another manifest is
///   not this recording's receipt at all.
///
/// An event that does not apply in the current phase leaves the state as it was; `applying`
/// returns nil so the caller can tell.
struct BundleSyncState: Equatable, Sendable {

    enum WaitReason: Equatable, Sendable {
        /// The recording still has to be prepared and that needs the app open: the face blur runs
        /// only in the foreground.
        case openAppToPrepare
        case notEligible(SyncEligibility.Reason)

        /// The reason as a sentence for the technician.
        var explanation: String {
            switch self {
            case .openAppToPrepare: return "Open Avenkin to prepare the recording."
            case let .notEligible(reason): return reason.explanation
            }
        }
    }

    /// Why the office refused a bundle (Contracts/recorded-session.md §6, a closed list).
    enum RefusalReason: String, CaseIterable, Sendable {
        case signature, binding, digest
        case tooLarge = "too_large"
        case policy
    }

    enum Phase: Equatable, Sendable {
        case recording
        /// Transcribing, and blurring when the organisation requires it.
        case preparing
        /// The manifest is signed and names every file; nothing in the bundle changes from here.
        case sealed
        case waiting(WaitReason)
        case transferring(sentBytes: Int64, totalBytes: Int64)
        /// Every chunk has been served. The office has not yet said it has the recording.
        case delivered
        case acknowledged
        /// Acknowledged, and the media since removed from the phone.
        case trimmed
        /// The office refused the bundle. Nothing is deleted; the technician chooses.
        case failed(RefusalReason)
        /// Too long without an acknowledgement. Nothing is deleted; the technician chooses.
        case expired
    }

    /// What a verified office receipt says. Checking its signature and binding is not this type's
    /// work; it only decides whether the receipt is about this recording.
    struct Receipt: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case received
            case refused(RefusalReason)
        }
        let bundleID: String
        let manifestSHA256: String
        let status: Status
    }

    enum Event: Equatable, Sendable {
        case recordingStopped
        /// Preparation cannot go on in the background.
        case preparationDeferred
        case preparationResumed
        case sealed(manifestSHA256: String, totalBytes: Int64)
        case notEligible(SyncEligibility.Reason)
        case transferStarted
        /// The count of bytes in chunks served so far. It never goes down.
        case progress(sentBytes: Int64)
        case allChunksServed
        case receipt(Receipt)
        case mediaTrimmed
        case expiryReached
        /// The technician's answer to an expired or refused recording: try again.
        case keepWaiting
    }

    let bundleID: String
    private(set) var phase: Phase
    /// Known once sealed. A receipt must name it.
    private(set) var manifestSHA256: String?
    private(set) var totalBytes: Int64
    /// Bytes in chunks the office has been served. Kept across interruptions: a finished chunk is
    /// never sent twice.
    private(set) var sentBytes: Int64

    init(bundleID: String) {
        self.bundleID = bundleID
        phase = .recording
        manifestSHA256 = nil
        totalBytes = 0
        sentBytes = 0
    }

    /// Whether the office has said, in a verified receipt, that it holds this recording.
    var isAcknowledged: Bool { phase == .acknowledged || phase == .trimmed }

    /// Applies an event, or does nothing when it has no meaning in the current phase.
    /// - Returns: whether the state changed.
    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        guard let next = applying(event), next != self else { return false }
        self = next
        return true
    }

    /// The state after an event, or nil when the event does not apply here.
    func applying(_ event: Event) -> BundleSyncState? {
        var next = self
        switch (phase, event) {
        case (.recording, .recordingStopped):
            next.phase = .preparing

        case (.preparing, .preparationDeferred):
            next.phase = .waiting(.openAppToPrepare)
        case (.waiting(.openAppToPrepare), .preparationResumed):
            next.phase = .preparing
        case let (.preparing, .sealed(digest, total)) where total > 0 && !digest.isEmpty:
            next.phase = .sealed
            next.manifestSHA256 = digest
            next.totalBytes = total
            next.sentBytes = 0

        case let (.sealed, .notEligible(reason)), let (.waiting(.notEligible), .notEligible(reason)),
             let (.transferring, .notEligible(reason)):
            next.phase = .waiting(.notEligible(reason))
        case (.sealed, .transferStarted), (.waiting(.notEligible), .transferStarted):
            next.phase = .transferring(sentBytes: sentBytes, totalBytes: totalBytes)
        case let (.transferring, .progress(sent)) where sent >= sentBytes && sent <= totalBytes:
            next.sentBytes = sent
            next.phase = .transferring(sentBytes: sent, totalBytes: totalBytes)
        case (.transferring, .allChunksServed):
            next.sentBytes = totalBytes
            next.phase = .delivered

        case let (_, .receipt(receipt)):
            // Only a receipt for this bundle as sealed counts; before sealing there is nothing a
            // receipt could be about.
            guard receipt.bundleID == bundleID, let manifestSHA256,
                  receipt.manifestSHA256 == manifestSHA256 else { return nil }
            switch (phase, receipt.status) {
            case (.acknowledged, .received), (.trimmed, .received):
                // Seen before. Harmless.
                return self
            case (.sealed, .received), (.waiting(.notEligible), .received), (.transferring, .received),
                 (.delivered, .received), (.failed, .received), (.expired, .received):
                // The office says it has verified and kept everything, however the phone thought
                // the transfer was going.
                next.sentBytes = totalBytes
                next.phase = .acknowledged
            case let (.sealed, .refused(reason)), let (.waiting(.notEligible), .refused(reason)),
                 let (.transferring, .refused(reason)), let (.delivered, .refused(reason)),
                 let (.failed, .refused(reason)):
                next.phase = .failed(reason)
            default:
                // A refusal cannot take back an acknowledgement, and does not answer the question
                // an expired recording has already put to the technician.
                return nil
            }

        case (.acknowledged, .mediaTrimmed):
            next.phase = .trimmed

        case (.preparing, .expiryReached), (.sealed, .expiryReached), (.waiting, .expiryReached),
             (.transferring, .expiryReached), (.delivered, .expiryReached):
            next.phase = .expired
        case (.expired, .keepWaiting):
            next.phase = manifestSHA256 == nil ? .preparing : .sealed
        case (.failed, .keepWaiting):
            // The office refused what it was sent, so it is all sent again.
            next.sentBytes = 0
            next.phase = .sealed

        default:
            return nil
        }
        return next
    }
}
