import Foundation
import UIKit

/// The still-image half of the privacy chokepoint.
///
/// `OutboundFrameRelay` solved this for camera-rate consumers: one blur pass, one subscription,
/// and a roster test that fails when someone taps the raw publisher instead. Still-image readers
/// had no equivalent. They each wrote the same five lines — take `CameraService.latestFrame`, fall
/// back to `capturePhoto()`, JPEG-encode, hand the bytes to a model or a file — and whether the
/// blur ran depended on whether that particular author remembered to call `filtered(_:for:)`.
/// Twenty-odd of them did not.
///
/// So the five lines live here instead, behind a call that cannot be made without naming a scope.
/// A reader asks for a still *for a purpose*; the purpose decides whether the blur runs; and a
/// purpose that must be filtered but cannot be (no filter wired, filtering suspended, Vision
/// failed) yields `.unavailable` rather than the source pixels. Fail-closed is the whole point:
/// the failure mode this replaces returned raw bystanders to a cloud model.
enum FilteredStillSource {
    /// Only the frame the camera stream already delivered. Never starts a capture.
    case cachedFrameOnly
    /// The cached frame if there is one, otherwise a fresh photo capture.
    case cachedFrameThenPhoto
    /// Always take a fresh photo, ignoring any cached frame.
    case photoOnly
}

/// A still that has been through the chokepoint and is safe to hand onward for its scope.
///
/// The scope travels with the pixels so a sink can log or assert what it received, and so a still
/// obtained for one purpose is not silently reused for a stricter one.
struct FilteredStill {
    let image: UIImage
    let scope: PrivacyFilterScope

    /// The bytes the still arrived as, when it arrived as bytes *and* the filter did not rewrite
    /// them. Present only on the unfiltered paths, where re-encoding a freshly captured JPEG would
    /// cost a decode, a re-encode and a generation of quality for nothing. Absent whenever the blur
    /// actually ran — those pixels exist only as an image.
    private let sourceData: Data?

    init(image: UIImage, scope: PrivacyFilterScope, sourceData: Data? = nil) {
        self.image = image
        self.scope = scope
        self.sourceData = sourceData
    }

    /// JPEG bytes for the sink. Returns the original capture bytes when the filter was a no-op for
    /// this scope; otherwise encodes the filtered image.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        if let sourceData { return sourceData }
        return image.jpegData(compressionQuality: compressionQuality)
    }
}

/// What a still reader gets back. `.unavailable` is a first-class answer, not an error case to be
/// papered over: "we could not filter this" and "here are the raw pixels" must never be the same
/// return value.
enum FilteredStillResult {
    case still(FilteredStill)
    case unavailable(Reason)

    enum Reason: String {
        /// No cached frame, and either no capture was requested or the capture failed.
        case noStill
        /// The scope requires filtering and the filter reports it cannot run right now —
        /// backgrounded, device locked, or Vision/Core Image failed on this frame.
        case filterUnavailable
        /// The scope requires filtering and no filter is wired to the provider at all. Fails
        /// closed on purpose: a wiring omission must not read as "nothing to filter".
        case filterNotWired
    }

    var still: FilteredStill? {
        if case .still(let still) = self { return still }
        return nil
    }

    var image: UIImage? { still?.image }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        still?.jpegData(compressionQuality: compressionQuality)
    }

    /// A short, non-identifying phrase for a spoken or logged explanation. Deliberately says the
    /// picture could not be prepared rather than naming the blur — the wearer's question is
    /// whether to try again.
    var unavailableReason: Reason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The seam every still-image reader uses in place of `CameraService.latestFrame`.
///
/// `CameraService` is the production conformance. Tests fake it, which is the second reason this is
/// a protocol: a headless test cannot construct the shared camera (it reaches the Meta SDK), so
/// without a seam the rerouted paths would have no test at all.
@MainActor
protocol FilteredStillProviding: AnyObject {
    func filteredStill(for scope: PrivacyFilterScope,
                       source: FilteredStillSource) async -> FilteredStillResult
}

extension FilteredStillProviding {
    /// The common case: whatever the stream last delivered, filtered for `scope`.
    func filteredStill(for scope: PrivacyFilterScope) async -> FilteredStillResult {
        await filteredStill(for: scope, source: .cachedFrameOnly)
    }
}

/// The blur pass as a seam, for the one consumer that already holds its own pixels.
///
/// `DwellCaptureService` receives frames from the raw publisher (its saliency pass needs them) and
/// then writes a crop to the Photos library, which is an egress by any reading. It cannot ask a
/// provider for a still — it has one — so it takes the filter itself, through a protocol for the
/// same testability reason as above.
@MainActor
protocol StillImageFiltering: AnyObject {
    /// Blur for `scope`, or `nil` when the scope requires filtering and it could not be done.
    func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage?
}
