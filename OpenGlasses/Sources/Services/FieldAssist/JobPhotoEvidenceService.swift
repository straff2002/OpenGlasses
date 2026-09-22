import Foundation
import UIKit

/// Attaching a picture the phone already holds to the open job (Plan FO P2a).
///
/// The glasses routes have a chokepoint of their own: they ask `CameraService.filteredStill(for:
/// source:)` and get back a still that has been through the blur, or an explicit refusal. A picture
/// taken with the phone's own camera, or chosen from its library, never goes near `CameraService` —
/// so it has no chokepoint at all, and before this it reached `attachPhoto` with whatever pixels the
/// picker handed over.
///
/// **Filtering is not inherited.** That is the correction Plan FO P0 made to the draft, and it is
/// the whole reason this type exists rather than the Job tab calling `attachPhoto` directly: a job
/// whose `photo_log` pictures are blurred and whose phone pictures are not is worse than one that is
/// consistently either, because the technician has no way to tell which is which.
///
/// Scope: **`.toolPhotoCapture`**, reused rather than extended. The scope classifies a consumer by
/// where its pixels *go* — "a still captured on the wearer's instruction and then attached to a
/// session log, or sent to the model, or both" — and that is exactly what a phone-sourced job photo
/// is. Which camera produced the pixels changes nothing about the egress or the policy, and a second
/// scope with identical answers to `isFiltered` and `usesOutboundRelay` would be a second name for
/// one rule. Where the source *does* belong is the roster, which records this consumer separately
/// (`OutboundFrameConsumer.jobPhoneEvidence`).
///
/// Fails closed, the same way `FilteredStillResult` does: when the filter must run and cannot, the
/// answer is `.unavailable` and **nothing is stored**. Returning the source pixels because the blur
/// was unavailable is the precise failure the still chokepoint was built to stop.
@MainActor
final class JobPhotoEvidenceService {

    /// What happened to a picture offered to the job.
    enum Outcome: Equatable {
        /// Stored. The file name is the item's id in the catalogue.
        case attached(itemId: String)
        /// No job is open, so there is nothing to attach it to. Not an error.
        case noOpenJob
        /// The picture could not be read as an image at all.
        case unreadable
        /// The blur had to run and could not. Nothing was written.
        case filterUnavailable

        var itemId: String? {
            if case .attached(let id) = self { return id }
            return nil
        }

        /// What the technician is told, in the words the Job tab shows.
        var problem: String? {
            switch self {
            case .attached: return nil
            case .noOpenJob: return "There's no job open, so there's nowhere to put that picture."
            case .unreadable: return "That file couldn't be read as a picture."
            case .filterUnavailable:
                return "Face blur is on and couldn't be applied to that picture, so it wasn't added. "
                    + "Try again with the app in the foreground and the phone unlocked."
            }
        }
    }

    /// Everything device-facing, as closures — so the whole path is exercisable headless, against a
    /// real `FieldSessionService` in a temp directory and a filter that marks what it touched.
    struct Seams {
        var sessions: () -> FieldSessionService = { FieldSessionService.shared }
        /// The blur. Nil means none is wired, which fails closed rather than reading as "nothing
        /// to filter" — the same rule `CameraService.filteredStill` follows.
        var filter: () -> (any StillImageFiltering)? = { nil }
        /// The app-wide setting as it stands, recorded against the item.
        var filterEnabled: () -> Bool = { Config.privacyFilterEnabled }
        /// Quality for the stored copy. The archive keeps a good copy; the work order downscales
        /// its own from this through `EvidenceImageBudget`.
        var storageQuality: CGFloat = 0.9
    }

    private var seams: Seams

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// Wire the app's services in after construction, the way `GuidedJobFlow` is.
    func connect(_ seams: Seams) { self.seams = seams }

    /// Put a picture on the job, filtered for `.toolPhotoCapture` first.
    @discardableResult
    func attach(imageData: Data, origin: JobMediaItem.Origin, caption: String? = nil) -> Outcome {
        let sessions = seams.sessions()
        guard sessions.isOpenForEvidence else { return .noOpenJob }
        guard let image = UIImage(data: imageData) else { return .unreadable }
        return attach(image: image, origin: origin, caption: caption, sessions: sessions)
    }

    /// The same, for a picture that arrives as an image rather than as bytes (`PhotosPicker`).
    @discardableResult
    func attach(image: UIImage, origin: JobMediaItem.Origin, caption: String? = nil) -> Outcome {
        let sessions = seams.sessions()
        guard sessions.isOpenForEvidence else { return .noOpenJob }
        return attach(image: image, origin: origin, caption: caption, sessions: sessions)
    }

    private func attach(image: UIImage, origin: JobMediaItem.Origin, caption: String?,
                        sessions: FieldSessionService) -> Outcome {
        let filterWasOn = seams.filterEnabled()
        guard let filter = seams.filter() else { return .filterUnavailable }
        guard let safe = filter.filteredOrUnavailable(image, for: .toolPhotoCapture) else {
            return .filterUnavailable
        }
        guard let data = safe.jpegData(compressionQuality: seams.storageQuality) else {
            return .unreadable
        }
        guard let url = sessions.attachPhoto(data, caption: caption, origin: origin,
                                             filterWasOn: filterWasOn) else {
            return .noOpenJob
        }
        return .attached(itemId: url.lastPathComponent)
    }
}

/// Where a tool files a still it has already had filtered (Plan FO P2a).
///
/// `photo_log` reaches `FieldSessionService.shared` directly, as it always has. `capture_photo`
/// takes this seam instead, for the reason every other capture route in this app has one: the tool
/// has no business knowing whether a job is open, and a headless test of "does a plain capture land
/// on the job?" cannot stand up the shared service.
///
/// Declared **after** the service above on purpose: the frame-tap scraper credits a chokepoint call
/// to the last type declared at column zero, and a protocol declared first would take the blame for
/// a filter call it does not make.
@MainActor
protocol JobEvidenceFiling: AnyObject {
    /// Whether a job is open enough to take evidence. Paused counts.
    var isOpenForEvidence: Bool { get }
    @discardableResult
    func attachPhoto(_ data: Data, caption: String?, origin: JobMediaItem.Origin,
                     filterWasOn: Bool) -> URL?
}

extension FieldSessionService: JobEvidenceFiling {}
