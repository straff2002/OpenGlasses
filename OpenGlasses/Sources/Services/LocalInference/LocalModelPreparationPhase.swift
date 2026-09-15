import Foundation

/// Where a local model actually is on its way to being usable, in one vocabulary shared by both
/// acquisition paths (docs/plans/FC-local-model-remediation.md, "Honest download and
/// model-preparation feedback").
///
/// ### Why a phase rather than three booleans
///
/// The MLX service used to describe a preparation with `isDownloading`, `downloadProgress` and
/// `isLoadingModel` — three independent values that could disagree, and did. The byte poller
/// capped its estimate at 0.99 so a *finished* download could read "Downloading 99%" for as long
/// as the transfer took to settle, and the load that followed wrote the model factory's fraction
/// back into the **download's** progress variable, so a load was drawn as a download. Neither
/// number was wrong on its own; the screen had no way to say which one it was looking at.
///
/// A phase can only be in one state, and every state here corresponds to a boundary something
/// actually crosses:
///
/// - `.downloading` — bytes are moving. The fraction is `nil` unless the total is *known*: for a
///   catalog model that is the measured snapshot size (Plan FC P0); for an uncatalogued id there
///   is no denominator, and a per-file fraction across an unknown number of files is not progress.
/// - `.verifying` / `.installing` — the acquisition pipeline's digest check and file move. Only
///   that pipeline produces them, because only that pipeline does them. The MLX hub path has no
///   verification step and must never claim one.
/// - `.loading` — weights are being materialized. Its fraction is the model factory's own, which
///   is preparation progress and is labelled as such; it is never shown as downloaded bytes.
/// - `.cancelling` — a stop was asked for and the step in flight cannot honour it promptly. The
///   result is already invalidated; this says so instead of pretending the work stopped.
///
/// Pure and `Equatable`, so the whole progression is a test rather than a screenshot.
enum LocalModelPreparationPhase: Equatable, Sendable {

    /// Nothing in flight.
    case idle
    /// A plan exists and is waiting for a person to confirm it — not for the network.
    case waitingForConsent
    /// Accepted, not yet transferring.
    case queued
    /// Bytes are moving. `fraction` is `nil` when the total size is unknown, which is the only
    /// honest reading when there is no denominator.
    case downloading(fraction: Double?)
    /// Downloaded bytes are being checked against their recorded digest. Produced only where a
    /// verification genuinely runs.
    case verifying
    /// Verified files are being moved into place.
    case installing
    /// Weights are being materialized into memory. `fraction` is the factory's own preparation
    /// fraction where it reports one, and `nil` (indeterminate) otherwise.
    case loading(fraction: Double?)
    /// Finished — the files are in place, or the model is resident, depending on what was asked.
    case ready
    /// A stop was requested and the step in flight cannot be interrupted promptly. Its result is
    /// already invalidated: whatever it returns will be discarded rather than activated.
    case cancelling
    /// Stopped at the user's request.
    case cancelled
    /// Stopped by a failure. The reason is an already-user-ready sentence.
    case failed(reason: String)

    // MARK: - Progress

    /// The fraction to draw on a determinate progress control, or `nil` for an indeterminate one.
    ///
    /// Only the two measurable phases have one, and `.ready` is a full bar so a finished
    /// preparation does not snap back to empty. Everything else — verifying, installing, a load
    /// with no reported fraction — is indeterminate, because inventing a number for a step with no
    /// denominator is exactly the behaviour this type exists to stop.
    var determinateFraction: Double? {
        switch self {
        case .downloading(let fraction), .loading(let fraction):
            return fraction.map { min(1, max(0, $0)) }
        case .ready:
            return 1
        case .idle, .waitingForConsent, .queued, .verifying, .installing,
             .cancelling, .cancelled, .failed:
            return nil
        }
    }

    /// The percentage VoiceOver reads as the control's *value*, or `nil` when there is none to
    /// read. Deliberately restricted to a download with a known total: a percentage is only a
    /// meaningful value when it counts something, and repeating one for an indeterminate step is
    /// how a screen reader ends up announcing a number that means nothing.
    var accessibilityPercent: Int? {
        guard case .downloading(let fraction) = self, let fraction else { return nil }
        return Int((min(1, max(0, fraction)) * 100).rounded())
    }

    // MARK: - Predicates

    /// Bytes are being fetched right now (queued counts: the transfer owns the slot).
    var isDownloadActive: Bool {
        switch self {
        case .queued, .downloading: return true
        default: return false
        }
    }

    /// Weights are being materialized, including a load whose stop is still pending.
    var isLoadActive: Bool {
        switch self {
        case .loading, .cancelling: return true
        default: return false
        }
    }

    /// Any step is in flight. `.cancelling` counts — the work has not stopped yet.
    var isActive: Bool {
        switch self {
        case .idle, .ready, .cancelled, .failed: return false
        case .waitingForConsent, .queued, .downloading, .verifying, .installing,
             .loading, .cancelling:
            return true
        }
    }

    /// Whether offering Cancel makes sense. A phase that has already stopped has nothing to stop,
    /// and `.cancelling` has already been asked once.
    var isCancellable: Bool {
        switch self {
        case .waitingForConsent, .queued, .downloading, .verifying, .installing, .loading:
            return true
        case .idle, .ready, .cancelling, .cancelled, .failed:
            return false
        }
    }

    // MARK: - Copy

    /// The short caption drawn beside the control.
    var displayLabel: String {
        switch self {
        case .idle: return ""
        case .waitingForConsent: return "Waiting for you"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .verifying: return "Checking"
        case .installing: return "Installing"
        case .loading: return "Preparing"
        case .ready: return "Ready"
        case .cancelling: return "Stopping"
        case .cancelled: return "Cancelled"
        case .failed: return "Stopped"
        }
    }

    /// The phase as a sentence, for `accessibilityLabel`. No percentage: the number belongs in
    /// `accessibilityValue`, where a screen reader reads it on demand instead of announcing every
    /// tick of a multi-gigabyte transfer.
    var spokenLabel: String {
        switch self {
        case .idle:
            return "Not started"
        case .waitingForConsent:
            return "Waiting for you to confirm the download"
        case .queued:
            return "Download queued"
        case .downloading(let fraction):
            return fraction == nil
                ? "Downloading. The total size isn't known, so there's no percentage."
                : "Downloading"
        case .verifying:
            return "Checking the downloaded files"
        case .installing:
            return "Installing the downloaded files"
        case .loading:
            // No percentage even when the factory reports one: it measures materializing weights,
            // not a transfer, and reading it as a download percentage is the confusion this
            // whole type removes.
            return "Preparing the model. This can take a moment and has no percentage."
        case .ready:
            return "Ready"
        case .cancelling:
            return "Stopping after the current step. The model won't be activated."
        case .cancelled:
            return "Cancelled"
        case .failed(let reason):
            return "Stopped. \(reason)"
        }
    }
}

// MARK: - Bridge from the acquisition pipeline

extension LocalModelPreparationPhase {

    /// The acquisition pipeline's staging summary said in this vocabulary, so both paths describe
    /// themselves with the same words.
    ///
    /// The pipeline keeps its own richer summary (file counts, byte totals, a typed retry reason)
    /// — this is the phase alone, which is what decides whether a percentage may be shown at all.
    init(staging: LocalModelStagingSummary) {
        switch staging.phase {
        case .awaitingConsent:
            self = .waitingForConsent
        case .queued:
            self = .queued
        case .downloading:
            // The pipeline always knows its total: the plan records every file's size up front.
            self = .downloading(fraction: staging.totalBytes > 0 ? staging.fractionCompleted : nil)
        case .validating:
            self = .verifying
        case .installing:
            self = .installing
        case .retryable(let reason):
            self = .failed(reason: LocalModelRowState.retryExplanation(reason))
        }
    }
}
