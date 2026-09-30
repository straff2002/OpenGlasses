import Foundation
import UIKit

/// Plan GH — "remember this" at a pillar or bay sign: a still, on-device OCR, and a reading of the
/// level and space, with the photo kept beside the spot.
///
/// Both routes pass the privacy chokepoint before the pixels are read or stored:
/// - the glasses still comes from `filteredStill(for:source:)`, and
/// - a phone photo (the card's picker, for wearers without glasses) goes through
///   `StillImageFiltering.filteredOrUnavailable(_:for:)`.
///
/// Scope: **`.toolPhotoCapture`**, reused rather than extended — the plan asked for a new scope,
/// but the codebase's rule (see `JobPhotoEvidenceService`) is that a scope names where pixels
/// *go*, and "a still captured on the wearer's instruction and kept with a record" is exactly what
/// this is. A second scope would be a second name for the same `isFiltered`/`usesOutboundRelay`
/// answers. The roster records both routes separately (`parkingSignCapture`, `parkingPhonePhoto`).
///
/// Fails closed: when the blur must run and cannot, nothing is read and nothing is kept, and the
/// caller saves the spot without a photo.
@MainActor
final class ParkingPhotoFlow {

    enum Outcome {
        /// A still was taken, filtered and read. `jpeg` is what the store keeps.
        case read(ParkingSignParser.Reading, jpeg: Data)
        /// A picture was available but the filter could not run on it, or there was none.
        case unavailable(FilteredStillResult.Reason)
        /// The picture could not be encoded.
        case unreadable
    }

    struct Seams {
        /// The glasses camera. Nil when no camera is wired (phone-only).
        var camera: () -> (any FilteredStillProviding)? = { nil }
        /// The blur for phone photos. Nil fails closed, as elsewhere.
        var filter: () -> (any StillImageFiltering)? = { nil }
        /// On-device OCR: lines in reading order.
        var recognize: (UIImage) async -> [String] = { image in
            guard let cgImage = image.cgImage else { return [] }
            return await OCRService().recognizeText(in: cgImage).blocks.map(\.text)
        }
        var storageQuality: CGFloat = 0.8
    }

    private var seams: Seams

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    func connect(_ seams: Seams) { self.seams = seams }

    var hasCamera: Bool { seams.camera() != nil }

    /// The sign in front of the glasses. Tries the frame the stream already has; if that reads
    /// nothing, takes a fresh photo — a sign read from a sharp capture beats a blurred frame.
    func captureFromGlasses() async -> Outcome {
        guard let camera = seams.camera() else { return .unavailable(.noStill) }
        let cached = await camera.filteredStill(for: .toolPhotoCapture, source: .cachedFrameOnly)
        if case .unavailable(let reason) = cached, !reason.mayFallBackToCapture {
            return .unavailable(reason)
        }
        if let still = cached.still {
            let outcome = await read(still.image, jpeg: still.jpegData(compressionQuality: seams.storageQuality))
            if case .read(let reading, _) = outcome, !reading.isEmpty { return outcome }
        }
        let fresh = await camera.filteredStill(for: .toolPhotoCapture, source: .photoOnly)
        switch fresh {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .still(let still):
            return await read(still.image, jpeg: still.jpegData(compressionQuality: seams.storageQuality))
        }
    }

    /// A picture the phone took or picked, filtered here before it is read or kept.
    func acceptPhonePhoto(_ image: UIImage) async -> Outcome {
        guard let filter = seams.filter(),
              let safe = filter.filteredOrUnavailable(image, for: .toolPhotoCapture) else {
            return .unavailable(.filterUnavailable)
        }
        return await read(safe, jpeg: safe.jpegData(compressionQuality: seams.storageQuality))
    }

    /// File a phone-photo outcome: onto the active spot when there is one, otherwise as a new spot
    /// at `location`. Returns the line the Parking card shows.
    @discardableResult
    static func file(_ outcome: Outcome, into store: ParkingStore, location: LocationFix?,
                     now: Date) -> String {
        switch outcome {
        case .unavailable(.filterUnavailable), .unavailable(.filterNotWired):
            return "Face blur is on and couldn't be applied to that picture, so it wasn't kept. "
                + "Try again with Avenkin open and the phone unlocked."
        case .unavailable, .unreadable:
            return "That picture couldn't be read."
        case .read(let reading, let jpeg):
            let spot: ParkingSpot?
            if store.active != nil {
                spot = store.attachPhoto(jpeg, fields: reading.fields)
            } else {
                var fresh = ParkingSpot(coordinate: location?.coordinate,
                                        horizontalAccuracy: location?.horizontalAccuracy,
                                        locationAt: location?.at, savedAt: now, capture: .photo)
                fresh.merge(reading.fields)
                spot = store.saveManual(fresh, photo: jpeg, now: now)
            }
            guard let spot else { return "That picture couldn't be kept." }
            guard !reading.isEmpty, let details = ParkingRecallPhraser.detailPhrase(spot) else {
                return "Photo kept. I couldn't read a level or space from it."
            }
            let read = details.replacingOccurrences(of: "on ", with: "", options: .anchored)
            return reading.needsConfirmation
                ? "Photo kept. I read \(read) — check that's right."
                : "Photo kept — \(read)."
        }
    }

    private func read(_ image: UIImage, jpeg: Data?) async -> Outcome {
        guard let jpeg else { return .unreadable }
        let lines = await seams.recognize(image)
        return .read(ParkingSignParser.parse(lines: lines), jpeg: jpeg)
    }
}
