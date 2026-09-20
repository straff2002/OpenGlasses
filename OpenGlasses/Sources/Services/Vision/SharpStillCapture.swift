import Foundation
import UIKit

/// The result of asking for one sharp still for a reading request.
///
/// `unavailable` carries the chokepoint's own reason rather than a new vocabulary, so a caller can
/// say the true thing — "the camera isn't giving me a picture" versus "the only picture I have is
/// old" versus "I couldn't prepare the picture" — without inventing a fourth story.
enum ReadingCaptureResult {
    case captured(jpeg: Data, report: CaptureQualityReport)
    case unavailable(FilteredStillResult.Reason)

    var report: CaptureQualityReport? {
        if case .captured(_, let report) = self { return report }
        return nil
    }
}

/// Plan FF P1/PR4 — the production path from "the model asked to look closely" to measured bytes.
///
/// # The privacy correction this carries
///
/// `look_closely` used to be wired straight to `CameraService.capturePhoto()`. That accessor is the
/// wearer's own framed shot and is deliberately unfiltered (the product decision recorded in the
/// repository guide), but this tool does not take the wearer's shot — it pushes pixels into a cloud
/// realtime session, which is an egress like every other, and `PrivacyFilterScope.liveSession` is
/// exactly the scope the streamed frames beside it already travel under. So the capture now goes
/// through `filteredStill(for:source:)` like every other still reader, under `.liveSession`, and a
/// scope that cannot be filtered yields `.unavailable` rather than the source pixels.
///
/// The roster scraper did not catch this: `NativeToolRegistry` contains `capturePhoto()`, but the
/// sink it fed — `injectSharpImage` — was not one of the patterns the sink test knows about. That
/// pattern is added alongside this change, so the next tool that injects unfiltered pixels fails a
/// test rather than shipping.
@MainActor
struct SharpStillCapture {

    /// The scope a still injected into a live realtime session travels under.
    nonisolated static let scope: PrivacyFilterScope = .liveSession

    /// Encode quality. High on purpose: the whole reason this path exists is that the streamed
    /// frames' quality-0.5 encode discards the thin strokes that make small print legible.
    nonisolated static let jpegQuality: CGFloat = 0.9

    private let provider: any FilteredStillProviding
    private let cameraSession: @MainActor () -> Int
    private let now: () -> Date

    init(provider: any FilteredStillProviding,
         cameraSession: @escaping @MainActor () -> Int,
         now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.cameraSession = cameraSession
        self.now = now
    }

    /// Take one fresh full-resolution still and measure it.
    ///
    /// `.photoOnly` rather than `.cachedFrameThenPhoto`: the cached frame is the throttled stream
    /// frame, which is the picture that already failed to resolve the detail. Accepting it here
    /// would make the tool a no-op that reports success.
    func capture(liveSessionIdentity: Int) async -> ReadingCaptureResult {
        let result = await provider.filteredStill(for: Self.scope, source: .photoOnly)
        switch result {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .still(let still):
            guard let jpeg = still.jpegData(compressionQuality: Self.jpegQuality) else {
                // A still that will not encode is not a still we can send. Fail closed and say the
                // picture could not be prepared, rather than reaching for the source pixels.
                return .unavailable(.noStill)
            }
            let report = CaptureQualityReport.measure(
                jpeg: jpeg,
                sourcePixelSize: still.sourcePixelSize,
                deliveredPixelSize: still.image.pixelSize,
                scope: still.scope,
                cameraSession: cameraSession(),
                liveSessionIdentity: liveSessionIdentity,
                capturedAt: now())
            return .captured(jpeg: jpeg, report: report)
        }
    }
}
