import Foundation
import CoreGraphics

/// Plan FF P1/PR4 — what was actually delivered to the model, measured at the capture boundary.
///
/// # Why this is a value and not a log line
///
/// The reading pipeline has four places where a picture can quietly stop being usable, and until
/// this type none of them produced an artefact anyone could assert against:
///
/// * the capture itself (a cached stream frame stands in for a full-resolution still),
/// * the privacy filter (a blur pass rewrites the pixels and can change their size),
/// * the JPEG encode (quality and byte size decide whether thin strokes survive),
/// * the injection (the bytes may belong to a camera or a conversation that no longer exists).
///
/// So the boundary produces a report, the report travels with the bytes, and the decision to inject
/// is made *from the report* rather than from the fact that a capture returned without throwing.
/// `sendHighResImage` neither resizes nor re-encodes — it base64s the bytes as given on both the
/// Gemini and the Realtime wire — so `deliveredPixelSize` is the encoded still's own size and
/// `jpegByteCount` is what goes on the wire.
struct CaptureQualityReport: Equatable {

    /// Pixel size of the still as the camera produced it, before the privacy filter ran. `nil`
    /// when the provider did not report one — a fake, or a path that never held source pixels.
    let sourcePixelSize: CGSize?
    /// Pixel size of the image that was actually encoded, after filtering.
    let deliveredPixelSize: CGSize
    /// Bytes on the wire.
    let jpegByteCount: Int
    /// Laplacian variance (higher = sharper), or nil when the bytes would not decode.
    let sharpness: Double?
    /// Mean luma 0–1, or nil when the bytes would not decode.
    let meanLuma: Double?
    /// The privacy scope the still was obtained under. Recorded so a reader can assert that a
    /// model-bound still was requested under a filtered scope rather than an on-device one.
    let scope: PrivacyFilterScope
    /// The camera session the pixels came from (`CameraReadiness.session`).
    let cameraSession: Int
    /// The live session the capture was started for. A still stamped with a different identity than
    /// the session that is live when injection is attempted belongs to a conversation that no
    /// longer exists.
    let liveSessionIdentity: Int
    /// When the pixels were obtained.
    let capturedAt: Date

    init(sourcePixelSize: CGSize?,
         deliveredPixelSize: CGSize,
         jpegByteCount: Int,
         sharpness: Double?,
         meanLuma: Double?,
         scope: PrivacyFilterScope,
         cameraSession: Int,
         liveSessionIdentity: Int,
         capturedAt: Date) {
        self.sourcePixelSize = sourcePixelSize
        self.deliveredPixelSize = deliveredPixelSize
        self.jpegByteCount = jpegByteCount
        self.sharpness = sharpness
        self.meanLuma = meanLuma
        self.scope = scope
        self.cameraSession = cameraSession
        self.liveSessionIdentity = liveSessionIdentity
        self.capturedAt = capturedAt
    }

    /// Measure a JPEG that is about to be injected.
    static func measure(jpeg: Data,
                        sourcePixelSize: CGSize?,
                        deliveredPixelSize: CGSize,
                        scope: PrivacyFilterScope,
                        cameraSession: Int,
                        liveSessionIdentity: Int,
                        capturedAt: Date) -> CaptureQualityReport {
        CaptureQualityReport(sourcePixelSize: sourcePixelSize,
                             deliveredPixelSize: deliveredPixelSize,
                             jpegByteCount: jpeg.count,
                             sharpness: ImageSharpness.score(jpeg),
                             meanLuma: ImageBrightness.meanLuma(jpeg),
                             scope: scope,
                             cameraSession: cameraSession,
                             liveSessionIdentity: liveSessionIdentity,
                             capturedAt: capturedAt)
    }

    // MARK: - Quality

    /// Whether the delivered picture is worth reading fine detail from, and if not, which thing the
    /// wearer can change.
    ///
    /// Two failures, not one, because they have opposite remedies and a blind wearer cannot tell
    /// them apart by looking. Order is deliberate: darkness is checked first, because an
    /// underexposed frame also scores low on the Laplacian and would otherwise be reported as blur,
    /// sending someone to hold still in a dark room.
    enum Quality: String, Equatable {
        case usable
        case tooDark
        case tooBlurry
        /// The bytes did not decode at all. Not a quality verdict — a delivery failure.
        case undecodable
    }

    /// Blur threshold for a *reading* capture.
    ///
    /// `ImageSharpness.blurThreshold` (90) is tuned for the question "should I suggest holding
    /// steady when OCR found nothing", where a false "blurry" is only a nagging message. Here a
    /// false "blurry" costs a whole extra capture and several seconds of a wearer's time, so this
    /// sits below it: a frame has to be clearly worse than the existing nag threshold before a
    /// reading capture is thrown away and retaken. Same scale, same measurement, more conservative
    /// use.
    static let readingBlurThreshold: Double = 55

    /// Darkness threshold, taken unchanged from `ImageBrightness`. Unlike blur, the remedy here is
    /// the same whichever consumer asks, so there is no reason for a second number.
    static let readingDarkThreshold: Double = ImageBrightness.darkThreshold

    var quality: Quality {
        guard let sharpness, let meanLuma else { return .undecodable }
        if meanLuma < Self.readingDarkThreshold { return .tooDark }
        if sharpness < Self.readingBlurThreshold { return .tooBlurry }
        return .usable
    }

    // MARK: - Admission

    /// Why a measured still may not be put in front of the model.
    ///
    /// Both cases map onto `FilteredStillResult.Reason.noFreshView`, which is the existing name for
    /// "there is a picture and it is not a current view". Keeping the same reason is the point: a
    /// wearer hears the same honest thing whether the picture aged out or its session was replaced.
    enum Refusal: String, Equatable {
        /// The pixels predate the request that asked for them.
        case olderThanRequest
        /// The live session that asked for them has been replaced.
        case sessionReplaced
        /// The camera session that produced them has been replaced.
        case cameraSessionReplaced

        var stillReason: FilteredStillResult.Reason { .noFreshView }
    }

    /// May these bytes be injected for this request, in this session?
    ///
    /// Assertive in code, not only in tests: every exit from a reading capture goes through this,
    /// so a still that fails any of the three checks cannot be injected by forgetting to check.
    ///
    /// - Parameters:
    ///   - requestedAt: when the reading request started. Pixels older than this are somebody
    ///     else's answer, whatever their age in seconds.
    ///   - liveSessionIdentity: the identity of the session that is live *now*.
    ///   - cameraSession: the camera session that is current *now*.
    func refusal(requestedAt: Date, liveSessionIdentity: Int, cameraSession: Int) -> Refusal? {
        if capturedAt < requestedAt { return .olderThanRequest }
        if self.liveSessionIdentity != liveSessionIdentity { return .sessionReplaced }
        if self.cameraSession != cameraSession { return .cameraSessionReplaced }
        return nil
    }

    // MARK: - Diagnostics

    /// A one-line, content-free summary for a log or a test failure. Sizes, bytes and scores only —
    /// nothing about what the picture is of.
    var summary: String {
        let source = sourcePixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown"
        let delivered = "\(Int(deliveredPixelSize.width))x\(Int(deliveredPixelSize.height))"
        let sharp = sharpness.map { String(format: "%.1f", $0) } ?? "n/a"
        let luma = meanLuma.map { String(format: "%.3f", $0) } ?? "n/a"
        return "source=\(source) delivered=\(delivered) bytes=\(jpegByteCount) "
            + "sharpness=\(sharp) luma=\(luma) scope=\(scope.rawValue) "
            + "camera=\(cameraSession) live=\(liveSessionIdentity) quality=\(quality.rawValue)"
    }
}
