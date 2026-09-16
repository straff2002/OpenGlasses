import UIKit
import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR4 — what the capture boundary measured, and what it refuses.
///
/// Two halves. The measurement half proves the report describes the bytes that are actually going
/// out: dimensions before and after the privacy pass, the encoded size, sharpness and luma. The
/// admission half proves the three ways a still can be the wrong still — older than the request,
/// a replaced live session, a replaced camera — each refuse, and refuse as `noFreshView` rather
/// than as some new story the wearer has to interpret.
@MainActor
final class CaptureQualityReportTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeProvider: FilteredStillProviding {
        var result: FilteredStillResult
        private(set) var requests: [(scope: PrivacyFilterScope, source: FilteredStillSource)] = []
        init(_ result: FilteredStillResult) { self.result = result }
        func filteredStill(for scope: PrivacyFilterScope,
                           source: FilteredStillSource) async -> FilteredStillResult {
            requests.append((scope, source))
            return result
        }
    }

    private final class FakeInjector: LiveSessionInjecting {
        var canInject = true
        var isBusyForInjection = false
        var liveSessionIdentity = 7
        private(set) var injected: [Data] = []
        func injectSharpImage(jpegData: Data) { injected.append(jpegData) }
        func injectText(_ text: String, completeTurn: Bool) {}
    }

    /// A readable render, so the measurements are of something real rather than of a flat fill
    /// (a flat fill has zero Laplacian variance and would read as "blurry" for the wrong reason).
    private func textImage(size: CGSize = CGSize(width: 640, height: 400),
                           background: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            ("Account 5820 7714" as NSString).draw(at: CGPoint(x: 24, y: 80),
                                                   withAttributes: attributes)
            ("EXP 03/2027" as NSString).draw(at: CGPoint(x: 24, y: 180), withAttributes: attributes)
        }
    }

    // MARK: - Measurement

    func testTheReportRecordsBothSizesTheByteCountAndBothScores() async throws {
        // A filter that hands back a smaller picture: the case a report exists to make visible.
        let source = textImage(size: CGSize(width: 1200, height: 800))
        let filtered = textImage(size: CGSize(width: 600, height: 400))
        let provider = FakeProvider(.still(FilteredStill(image: filtered, scope: .liveSession,
                                                         sourcePixelSize: source.pixelSize)))
        let capture = SharpStillCapture(provider: provider, cameraSession: { 3 })

        let result = await capture.capture(liveSessionIdentity: 7)
        guard case .captured(let jpeg, let report) = result else {
            return XCTFail("expected a capture, got \(result)")
        }

        XCTAssertEqual(report.sourcePixelSize, CGSize(width: 1200, height: 800))
        XCTAssertEqual(report.deliveredPixelSize, CGSize(width: 600, height: 400))
        XCTAssertEqual(report.jpegByteCount, jpeg.count)
        XCTAssertEqual(report.scope, .liveSession)
        XCTAssertEqual(report.cameraSession, 3)
        XCTAssertEqual(report.liveSessionIdentity, 7)
        XCTAssertNotNil(report.sharpness)
        XCTAssertNotNil(report.meanLuma)
        XCTAssertEqual(report.quality, .usable, report.summary)
    }

    /// The bytes on the wire are the bytes measured. `sendHighResImage` base64s them unchanged on
    /// both wires — it neither resizes nor re-encodes — so the byte count in the report is the
    /// delivered payload, not an estimate of it.
    func testTheInjectedBytesAreExactlyTheMeasuredBytes() async throws {
        let provider = FakeProvider(.still(FilteredStill(image: textImage(), scope: .liveSession,
                                                         sourcePixelSize: CGSize(width: 640,
                                                                                 height: 400))))
        let injector = FakeInjector()
        let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
        let tool = LookCloselyTool(
            captureSharpStill: { await capture.capture(liveSessionIdentity: $0) },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { .normal })

        let result = try await tool.execute(args: [:])

        XCTAssertEqual(result, LookCloselyPolicy.sharpFrameInstruction)
        XCTAssertEqual(injector.injected.count, 1, "one request, one image")
        let delivered = try XCTUnwrap(injector.injected.first)
        let decoded = try XCTUnwrap(UIImage(data: delivered))
        XCTAssertEqual(decoded.pixelSize, CGSize(width: 640, height: 400))
    }

    /// The still a live session is given travels under the filtered live-session scope, taken fresh.
    func testTheCaptureIsRequestedUnderTheFilteredLiveSessionScope() async throws {
        let provider = FakeProvider(.still(FilteredStill(image: textImage(), scope: .liveSession)))
        let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })

        _ = await capture.capture(liveSessionIdentity: 1)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.scope, .liveSession)
        XCTAssertEqual(provider.requests.first?.source, .photoOnly)
        XCTAssertTrue(SharpStillCapture.scope.isFiltered,
                      "the scope this path uses must be one the bystander blur applies to")
    }

    /// Fail closed: a chokepoint that cannot serve the scope yields nothing, and the wearer is told
    /// the picture could not be prepared rather than being read an unfiltered one.
    func testAnUnfilterableStillNeverBecomesACapture() async throws {
        let provider = FakeProvider(.unavailable(.filterUnavailable))
        let injector = FakeInjector()
        let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
        let tool = LookCloselyTool(
            captureSharpStill: { await capture.capture(liveSessionIdentity: $0) },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { .normal })

        let result = try await tool.execute(args: [:])

        XCTAssertTrue(injector.injected.isEmpty)
        XCTAssertTrue(result.contains("couldn't prepare the picture"), result)
        XCTAssertTrue(result.contains("Never guess characters, digits, names, dates or instructions"))
    }

    // MARK: - Quality verdicts

    func testDarknessIsReportedBeforeBlur() {
        // An underexposed frame also scores low on the Laplacian. Reporting it as blur would send a
        // wearer to hold still in a dark room.
        let report = report(sharpness: 5, luma: 0.02)
        XCTAssertEqual(report.quality, .tooDark)
    }

    func testABlurredButWellLitFrameIsReportedAsBlur() {
        XCTAssertEqual(report(sharpness: 10, luma: 0.55).quality, .tooBlurry)
    }

    func testASharpWellLitFrameIsUsable() {
        XCTAssertEqual(report(sharpness: 600, luma: 0.5).quality, .usable)
    }

    func testBytesThatDoNotDecodeAreNotAQualityVerdict() {
        XCTAssertEqual(report(sharpness: nil, luma: nil).quality, .undecodable)
    }

    /// The reading threshold is deliberately more forgiving than the OCR nag threshold: a false
    /// "blurry" here costs a whole extra capture and several seconds of a wearer's time.
    func testTheReadingBlurThresholdIsBelowTheOCRNagThreshold() {
        XCTAssertLessThan(CaptureQualityReport.readingBlurThreshold, ImageSharpness.blurThreshold)
    }

    // MARK: - Admission

    func testAFreshStillFromThisSessionAndCameraIsAdmitted() {
        let requestedAt = Date()
        let report = report(sharpness: 600, luma: 0.5,
                            capturedAt: requestedAt.addingTimeInterval(0.4))
        XCTAssertNil(report.refusal(requestedAt: requestedAt, liveSessionIdentity: 7,
                                    cameraSession: 3))
    }

    func testAStillOlderThanTheRequestIsRefused() {
        let requestedAt = Date()
        let report = report(sharpness: 600, luma: 0.5,
                            capturedAt: requestedAt.addingTimeInterval(-1))
        XCTAssertEqual(report.refusal(requestedAt: requestedAt, liveSessionIdentity: 7,
                                      cameraSession: 3), .olderThanRequest)
    }

    func testAStillFromAReplacedLiveSessionIsRefused() {
        let requestedAt = Date()
        let report = report(sharpness: 600, luma: 0.5, capturedAt: requestedAt)
        XCTAssertEqual(report.refusal(requestedAt: requestedAt, liveSessionIdentity: 8,
                                      cameraSession: 3), .sessionReplaced)
    }

    func testAStillFromAReplacedCameraSessionIsRefused() {
        let requestedAt = Date()
        let report = report(sharpness: 600, luma: 0.5, capturedAt: requestedAt)
        XCTAssertEqual(report.refusal(requestedAt: requestedAt, liveSessionIdentity: 7,
                                      cameraSession: 4), .cameraSessionReplaced)
    }

    /// Every refusal tells the wearer the same true thing: there is a picture and it is not a
    /// current view.
    func testEveryRefusalReportsNoFreshView() {
        for refusal: CaptureQualityReport.Refusal in [.olderThanRequest, .sessionReplaced,
                                                      .cameraSessionReplaced] {
            XCTAssertEqual(refusal.stillReason, .noFreshView)
        }
    }

    // MARK: - Session replacement, through the production adapters

    /// The failure this guard exists for: capture takes seconds, a reconnect inside that window
    /// replaces the session, and `canInject` is true again — for a different conversation.
    func testAStillCapturedForAReplacedSessionIsNeverInjected() async throws {
        let provider = FakeProvider(.still(FilteredStill(image: textImage(), scope: .liveSession)))
        let injector = FakeInjector()
        let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
        let tool = LookCloselyTool(
            captureSharpStill: { identity in
                let result = await capture.capture(liveSessionIdentity: identity)
                // The reconnect lands while the shutter is open.
                injector.liveSessionIdentity += 1
                return result
            },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { .normal })

        let result = try await tool.execute(args: ["reason": "read this label"])

        XCTAssertTrue(injector.injected.isEmpty,
                      "a still captured for the previous conversation must not be delivered into "
                      + "the one that replaced it")
        XCTAssertTrue(result.contains("out of date"), result)
    }

    /// A session that dropped entirely during the capture is the same refusal, not a crash and not
    /// a silent success.
    func testAStillCapturedForASessionThatEndedIsNeverInjected() async throws {
        let provider = FakeProvider(.still(FilteredStill(image: textImage(), scope: .liveSession)))
        let injector = FakeInjector()
        let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
        let tool = LookCloselyTool(
            captureSharpStill: { identity in
                let result = await capture.capture(liveSessionIdentity: identity)
                injector.canInject = false
                return result
            },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { .normal })

        let result = try await tool.execute(args: [:])

        XCTAssertTrue(injector.injected.isEmpty)
        XCTAssertTrue(result.contains("out of date"), result)
    }

    /// A camera replaced mid-capture is the third way the pixels stop belonging to this question.
    func testAStillFromACameraThatWasReplacedIsNeverInjected() async throws {
        let provider = FakeProvider(.still(FilteredStill(image: textImage(), scope: .liveSession)))
        let injector = FakeInjector()
        var cameraSession = 2
        let capture = SharpStillCapture(provider: provider, cameraSession: { cameraSession })
        let tool = LookCloselyTool(
            captureSharpStill: { identity in
                let result = await capture.capture(liveSessionIdentity: identity)
                cameraSession = 3
                return result
            },
            injectorProvider: { injector },
            cameraSession: { cameraSession },
            posture: { .normal })

        let result = try await tool.execute(args: [:])

        XCTAssertTrue(injector.injected.isEmpty)
        XCTAssertTrue(result.contains("out of date"), result)
    }

    /// A capture source that stamps an identity it was not given has not measured the still this
    /// request asked for, whatever else is true of it.
    func testAReportStampedWithTheWrongSessionIsNeverInjected() async throws {
        let provider = FakeProvider(.still(FilteredStill(image: textImage(), scope: .liveSession)))
        let injector = FakeInjector()
        let capture = SharpStillCapture(provider: provider, cameraSession: { 0 })
        let tool = LookCloselyTool(
            captureSharpStill: { _ in
                // Stamps a different session than the one it was handed.
                await capture.capture(liveSessionIdentity: 99)
            },
            injectorProvider: { injector },
            cameraSession: { 0 },
            posture: { .normal })

        let result = try await tool.execute(args: [:])

        XCTAssertTrue(injector.injected.isEmpty)
        XCTAssertTrue(result.contains("out of date"), result)
    }

    // MARK: - Helper

    private func report(sharpness: Double?, luma: Double?,
                        capturedAt: Date = Date()) -> CaptureQualityReport {
        CaptureQualityReport(sourcePixelSize: CGSize(width: 640, height: 400),
                             deliveredPixelSize: CGSize(width: 640, height: 400),
                             jpegByteCount: 40_000,
                             sharpness: sharpness,
                             meanLuma: luma,
                             scope: .liveSession,
                             cameraSession: 3,
                             liveSessionIdentity: 7,
                             capturedAt: capturedAt)
    }
}
