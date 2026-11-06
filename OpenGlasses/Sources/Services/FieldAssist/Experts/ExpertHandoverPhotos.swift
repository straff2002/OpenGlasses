import Foundation
import UIKit

/// The photos in a handover: chosen, blurred, downscaled and fitted to the channel (Plan KM P1,
/// decision 4). The `expertHandoverPhotos` row on the `OutboundFrameConsumer` roster.
///
/// **Every picture goes through the blur, whatever the app-wide switch says.** The stored copy in
/// the job's `photos/` folder was blurred at capture only if the switch was on then
/// (`JobMediaItem.filterWasOn`), so each one is put through `filteredOrUnavailable(_:for:)` under
/// the mandatory `expertHandover` scope here, at the one chokepoint the package is built from. A
/// picture the blur cannot process — the phone locked, Vision failed — is **dropped and counted**,
/// never sent as it was. Recorded clips are not handover material and are never read.
///
/// Then the budget: the channel's `AttachmentBudget`, with the oldest photos dropped first until
/// what is left fits, and the count said on the sheet.
@MainActor
enum ExpertHandoverPhotos {

    /// The downscale every handover photo gets: big enough to read a gauge or a wiring label,
    /// small enough that four go by Messages.
    static let plan = EvidenceImageBudget.Plan(photoCount: 1, longEdge: 1_280, quality: 0.7,
                                               estimatedBytesPerPhoto: 250_000, atFloor: false)

    /// How many the sheet ticks to begin with: the most recent four (decision 4).
    static let preselectedCount = 4

    /// Room kept for `handover.json`, the text and the PDF's own words, on top of the pictures.
    static let reservedBytes = 300_000
    /// Each picture travels twice: inside the `.ogcase` and drawn into the PDF.
    static let copiesPerPhoto = 2

    struct Prepared {
        /// In the order they go: oldest first, as the job happened.
        let photos: [ExpertHandoverBuilder.PreparedPhoto]
        /// The JPEG for each photo, by item id. Only blurred pixels are ever in here.
        let jpegs: [String: Data]
        let leftOut: ExpertHandover.PhotosLeftOut
    }

    /// The photos the sheet ticks first: the most recent four of the job's photos.
    static func preselection(_ media: [JobMediaItem]) -> [String] {
        media.filter { $0.kind == .photo }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(preselectedCount).map(\.id)
    }

    /// Blur, downscale and fit the chosen photos.
    ///
    /// - Parameters:
    ///   - chosen: the job photos the technician ticked. Clips among them are ignored.
    ///   - load: the stored file for an item, or nil when it is missing.
    ///   - filter: the blur. `nil` back means it could not run on this picture.
    ///   - budget: the channel's limits.
    static func prepare(chosen: [JobMediaItem], load: (JobMediaItem) -> UIImage?,
                        filter: StillImageFiltering, budget: AttachmentBudget) -> Prepared {
        let photos = chosen.filter { $0.kind == .photo }.sorted { $0.capturedAt < $1.capturedAt }
        var unfilterable = 0
        var ready: [(item: JobMediaItem, jpeg: Data)] = []
        for item in photos {
            guard let stored = load(item) else { unfilterable += 1; continue }
            // The chokepoint: the mandatory scope, so the switch being off is no passthrough.
            guard let blurred = filter.filteredOrUnavailable(stored, for: .expertHandover) else {
                unfilterable += 1
                continue
            }
            let small = EvidenceImageRenderer.downscaled(blurred, plan: plan)
            guard let jpeg = small.jpegData(compressionQuality: plan.quality) else {
                unfilterable += 1
                continue
            }
            ready.append((item, jpeg))
        }
        let fit = budget.photosFittingNewestFirst(
            ready.map { .init(id: $0.item.id, capturedAt: $0.item.capturedAt, bytes: $0.jpeg.count) },
            reservedBytes: reservedBytes, copiesPerPhoto: copiesPerPhoto)
        let kept = Set(fit.kept)
        let going = ready.filter { kept.contains($0.item.id) }
        return Prepared(
            photos: going.map { .init(itemId: $0.item.id, capturedAt: $0.item.capturedAt, caption: $0.item.caption) },
            jpegs: Dictionary(going.map { ($0.item.id, $0.jpeg) }, uniquingKeysWith: { first, _ in first }),
            leftOut: .init(couldNotBeBlurred: unfilterable, overSizeLimit: fit.dropped.count))
    }
}

// MARK: - The budget for pictures

extension AttachmentBudget {

    /// A picture's measured size, for `photosFittingNewestFirst`.
    struct SizedPhoto: Equatable, Sendable {
        let id: String
        let capturedAt: Date
        let bytes: Int
    }

    /// Which pictures fit, dropping the **oldest first** until the rest do (Plan KM P1). The
    /// newest pictures are the job as it stands, which is what the expert is being asked about.
    ///
    /// - Parameters:
    ///   - reservedBytes: what the documents themselves take before any picture.
    ///   - copiesPerPhoto: how many times each picture travels (in the package and in the PDF).
    /// - Returns: the ids kept, in the order given, and the ids dropped, oldest first.
    func photosFittingNewestFirst(_ photos: [SizedPhoto], reservedBytes: Int,
                                  copiesPerPhoto: Int = 1) -> (kept: [String], dropped: [String]) {
        guard carriesFiles else { return ([], photos.sorted { $0.capturedAt < $1.capturedAt }.map(\.id)) }
        let ceiling = [perFileBytes, totalBytes].compactMap { $0 }.min()
        guard let ceiling else { return (photos.map(\.id), []) }
        let copies = max(1, copiesPerPhoto)
        var remaining = photos.sorted { $0.capturedAt < $1.capturedAt }
        var dropped: [String] = []
        func total() -> Int { reservedBytes + remaining.reduce(0) { $0 + $1.bytes * copies } }
        while !remaining.isEmpty, total() > ceiling {
            dropped.append(remaining.removeFirst().id)
        }
        let kept = Set(remaining.map(\.id))
        return (photos.map(\.id).filter(kept.contains), dropped)
    }
}
