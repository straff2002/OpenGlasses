import XCTest
import CoreGraphics
import CoreImage
import Combine
import UIKit
@testable import OpenGlasses

/// Plan CP — the two cores that make a blur affordable at camera rate.
final class OutboundFramePrivacyTests: XCTestCase {

    private func makeImage(color: UIColor = .red, size: CGSize = CGSize(width: 16, height: 16)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - FrameCoalescer

    func testIdleSubmitProcessesImmediately() {
        var coalescer = FrameCoalescer<Int>()
        guard case .process(let frame) = coalescer.submit(1) else { return XCTFail("expected .process") }
        XCTAssertEqual(frame, 1)
        XCTAssertTrue(coalescer.isProcessing)
    }

    func testSubmitWhileBusyGoesPendingWithoutDropping() {
        var coalescer = FrameCoalescer<Int>()
        _ = coalescer.submit(1)
        guard case .madePending(let dropped) = coalescer.submit(2) else { return XCTFail("expected .madePending") }
        XCTAssertEqual(dropped, 0, "the first frame to wait displaces nothing")
    }

    /// The point of the whole type: a backlog is never allowed to form. A third arrival replaces
    /// the second, which is then never processed.
    func testThirdSubmitReplacesPendingAndReportsTheDrop() {
        var coalescer = FrameCoalescer<Int>()
        _ = coalescer.submit(1)
        _ = coalescer.submit(2)
        guard case .madePending(let dropped) = coalescer.submit(3) else { return XCTFail("expected .madePending") }
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(coalescer.totalDropped, 1)
        XCTAssertEqual(coalescer.finishedProcessing(), 3, "the newest frame wins, not the oldest")
    }

    /// Ordering guarantee: a stale frame must never be published after a fresher one.
    func testNeverProcessesAnOlderFrameAfterANewerOne() {
        var coalescer = FrameCoalescer<Int>()
        var processed: [Int] = []

        if case .process(let f) = coalescer.submit(1) { processed.append(f) }
        for frame in 2...9 { _ = coalescer.submit(frame) }
        while let next = coalescer.finishedProcessing() { processed.append(next) }

        XCTAssertEqual(processed, [1, 9])
        XCTAssertEqual(processed, processed.sorted(), "output order must be monotonic in frame age")
        XCTAssertEqual(coalescer.totalDropped, 7)
    }

    func testFinishingWithNothingPendingGoesIdle() {
        var coalescer = FrameCoalescer<Int>()
        _ = coalescer.submit(1)
        XCTAssertNil(coalescer.finishedProcessing())
        XCTAssertFalse(coalescer.isProcessing)
    }

    func testResetClearsInFlightAndPending() {
        var coalescer = FrameCoalescer<Int>()
        _ = coalescer.submit(1)
        _ = coalescer.submit(2)
        coalescer.reset()
        XCTAssertFalse(coalescer.isProcessing)
        XCTAssertNil(coalescer.finishedProcessing())
    }

    // MARK: - FaceRectCache

    private let frame = CGSize(width: 1000, height: 1000)
    private let face = CGRect(x: 400, y: 400, width: 100, height: 100)

    func testDetectsOnTheFirstFrameThenSuppressesWithinTheInterval() {
        let cache = FaceRectCache(detectionInterval: 0.2)
        XCTAssertTrue(cache.shouldDetect(now: 100), "nothing known yet — must detect")

        var recorded = cache
        recorded.record([face], at: 100)
        XCTAssertFalse(recorded.shouldDetect(now: 100.1))
        XCTAssertTrue(recorded.shouldDetect(now: 100.2), "interval elapsed")
    }

    /// The cheap half: rectangles are reused between detections, expanded so a head that moves
    /// stays covered.
    func testRectsAreExpandedForMotion() {
        var cache = FaceRectCache(detectionInterval: 0.2, grace: 0.6, motionMargin: 0.25)
        cache.record([face], at: 100)

        let rects = cache.blurRects(now: 100.1, frameSize: frame)
        XCTAssertEqual(rects.count, 1)
        XCTAssertGreaterThan(rects[0].width, face.width, "expanded to tolerate motion")
        XCTAssertTrue(rects[0].contains(face), "the expansion must never shrink coverage")
    }

    /// A single missed detection must not flash a face unblurred.
    func testRectsSurviveAMissedDetectionWithinGrace() {
        var cache = FaceRectCache(detectionInterval: 0.2, grace: 0.6)
        cache.record([face], at: 100)
        XCTAssertFalse(cache.blurRects(now: 100.5, frameSize: frame).isEmpty, "still inside grace")
    }

    /// …but stale rectangles must not blur forever, or the picture is wrong in the other direction.
    func testRectsExpireAfterGrace() {
        var cache = FaceRectCache(detectionInterval: 0.2, grace: 0.6)
        cache.record([face], at: 100)
        XCTAssertTrue(cache.blurRects(now: 100.7, frameSize: frame).isEmpty)
    }

    /// An empty detection is information — once grace elapses it must clear, not freeze the
    /// previous result.
    func testEmptyDetectionClearsOnceGraceElapses() {
        var cache = FaceRectCache(detectionInterval: 0.2, grace: 0.6)
        cache.record([face], at: 100)
        cache.record([], at: 100.2)
        XCTAssertTrue(cache.blurRects(now: 100.3, frameSize: frame).isEmpty)
    }

    /// Expansion must not push a rectangle off the image.
    func testExpandedRectsAreClampedToTheFrame() {
        var cache = FaceRectCache(motionMargin: 0.5)
        cache.record([CGRect(x: 0, y: 0, width: 100, height: 100)], at: 100)

        let rects = cache.blurRects(now: 100.01, frameSize: frame)
        XCTAssertEqual(rects.count, 1)
        XCTAssertGreaterThanOrEqual(rects[0].minX, 0)
        XCTAssertGreaterThanOrEqual(rects[0].minY, 0)
        XCTAssertLessThanOrEqual(rects[0].maxX, frame.width)
        XCTAssertLessThanOrEqual(rects[0].maxY, frame.height)
    }

    func testResetForgetsEverything() {
        var cache = FaceRectCache()
        cache.record([face], at: 100)
        cache.reset()
        XCTAssertTrue(cache.blurRects(now: 100.01, frameSize: frame).isEmpty)
        XCTAssertTrue(cache.shouldDetect(now: 100.01))
    }

    /// Rects come from Vision in pixel coordinates and the composite flips them against the
    /// CIImage extent, also pixels. Clamping against a *point* size would truncate every rect on a
    /// 2x/3x frame — a silent under-blur on exactly the high-resolution captures that carry the
    /// most recognisable detail.
    func testClampingUsesPixelExtentNotPointSize() {
        var cache = FaceRectCache(motionMargin: 0)
        let pixelRect = CGRect(x: 1500, y: 1500, width: 200, height: 200)   // beyond a 1000pt frame
        cache.record([pixelRect], at: 100)

        let pixels = CGSize(width: 2000, height: 2000)
        XCTAssertEqual(cache.blurRects(now: 100.01, frameSize: pixels).first, pixelRect,
                       "against the true pixel extent the rect survives intact")

        let points = CGSize(width: 1000, height: 1000)
        XCTAssertTrue(cache.blurRects(now: 100.01, frameSize: points).isEmpty,
                      "against a point size the same rect vanishes — the bug this guards")
    }

    // MARK: - Scope

    /// CO Item 0 shipped with recording and broadcast asserted *not* covered, precisely so that
    /// building this pipeline would fail that test and force the copy to be corrected. This is the
    /// other side of that assertion.
    func testOutboundConsumersAreNowCovered() {
        XCTAssertTrue(PrivacyFilterScope.recording.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.broadcast.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.expertStream.isFiltered)
    }

    /// The exemptions are exactly two, and both are exempt for the same reason: the blur is
    /// indiscriminate and would break the feature it was applied to. Face recognition would lose
    /// the enrolled faces; on-device scene narration (Plan CV) would lose the people a blind
    /// wearer is being told about — and it is not an egress in the first place, since those frames
    /// never leave the device. Pinning the whole set means a third exemption has to be argued for
    /// here rather than added quietly.
    func testExemptionsAreExactlyTheTwoNonEgressConsumers() {
        let exempt = PrivacyFilterScope.allCases.filter { !$0.isFiltered }
        XCTAssertEqual(exempt, [.faceRecognition, .sceneNarration])
    }

    /// Camera-rate consumers share one pass; the ~1 fps model paths filter at their own chokepoint.
    func testOnlyCameraRateConsumersUseTheSharedRelay() {
        XCTAssertTrue(PrivacyFilterScope.recording.usesOutboundRelay)
        XCTAssertTrue(PrivacyFilterScope.broadcast.usesOutboundRelay)
        XCTAssertTrue(PrivacyFilterScope.expertStream.usesOutboundRelay)
        XCTAssertFalse(PrivacyFilterScope.liveSession.usesOutboundRelay)
        XCTAssertFalse(PrivacyFilterScope.pinnedFrame.usesOutboundRelay)
        XCTAssertFalse(PrivacyFilterScope.faceRecognition.usesOutboundRelay)
    }

    /// Every relay-fed consumer must also be a filtered one — a scope that routes through the blur
    /// pipeline but claims to be unfiltered would be incoherent.
    func testRelayFedConsumersAreAlwaysFiltered() {
        for scope in PrivacyFilterScope.allCases where scope.usesOutboundRelay {
            XCTAssertTrue(scope.isFiltered, "\(scope.rawValue) routes through the relay but claims to be unfiltered")
        }
    }

    // MARK: - Relay fail-closed behavior

    /// Background optimization deliberately suspends expensive filtering. With privacy enabled,
    /// that must pause the camera-rate pixels rather than turn the relay into a raw passthrough.
    @MainActor
    func testEnabledSuspendedRelayDropsInsteadOfPublishingRawFrame() {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        filter.suspend()
        let relay = OutboundFrameRelay(filter: filter)
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        var received: [UIImage] = []
        let token = relay.publisher.sink { received.append($0) }
        source.send(makeImage())

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(relay.privacyDroppedFrameCount, 1)
        XCTAssertEqual(relay.droppedFrameCount, 1)
        withExtendedLifetime(token) {}
    }

    /// Backgrounding can race a Vision pass already in flight. The relay must enforce suspension
    /// again at publication rather than relying only on the state observed when the frame arrived.
    @MainActor
    func testSuspensionDuringDetectionDropsVerifiedNoFaceFrameBeforePublish() async {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let detectorStarted = expectation(description: "detector started")
        let releaseDetector = DispatchSemaphore(value: 0)
        let relay = OutboundFrameRelay(
            filter: filter,
            detector: { _ in
                detectorStarted.fulfill()
                releaseDetector.wait()
                return .success([])
            },
            compositor: { image, _, _ in image })
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        let dropped = expectation(description: "in-flight source frame was dropped")
        var received = 0
        var tokens: Set<AnyCancellable> = []
        relay.publisher.sink { _ in received += 1 }.store(in: &tokens)
        relay.$privacyDroppedFrameCount.dropFirst().sink { count in
            if count == 1 { dropped.fulfill() }
        }.store(in: &tokens)

        source.send(makeImage())
        await fulfillment(of: [detectorStarted], timeout: 2)
        filter.suspend()
        releaseDetector.signal()
        await fulfillment(of: [dropped], timeout: 2)

        XCTAssertEqual(received, 0)
        XCTAssertEqual(relay.droppedFrameCount, 1)
    }

    /// Invalid/non-CG-backed input cannot be inspected, so it cannot be declared face-free.
    @MainActor
    func testEnabledRelayDropsWhenImageCannotBeConverted() {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let relay = OutboundFrameRelay(filter: filter)
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        var received = 0
        let token = relay.publisher.sink { _ in received += 1 }
        let ciBacked = UIImage(ciImage: CIImage(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 16, height: 16)))
        XCTAssertNil(ciBacked.cgImage, "fixture must traverse the conversion-failure branch")
        source.send(ciBacked)

        XCTAssertEqual(received, 0)
        XCTAssertEqual(relay.privacyDroppedFrameCount, 1)
        withExtendedLifetime(token) {}
    }

    /// A thrown Vision request used to collapse into an empty array and publish the original. The
    /// injected detector makes the failure deterministic without relying on Vision internals.
    @MainActor
    func testEnabledRelayDropsDetectorFailure() async {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let relay = OutboundFrameRelay(
            filter: filter,
            detector: { _ in .failure },
            compositor: { image, _, _ in image })
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        let dropped = expectation(description: "privacy failure was recorded")
        var received = 0
        var tokens: Set<AnyCancellable> = []
        relay.publisher.sink { _ in received += 1 }.store(in: &tokens)
        relay.$privacyDroppedFrameCount.dropFirst().sink { count in
            if count == 1 { dropped.fulfill() }
        }.store(in: &tokens)

        source.send(makeImage())
        await fulfillment(of: [dropped], timeout: 2)
        XCTAssertEqual(received, 0)
        XCTAssertEqual(relay.droppedFrameCount, 1)
    }

    /// A face was found, so returning the original after a Core Image failure is a direct privacy
    /// bypass. The relay must drop it and continue processing later frames.
    @MainActor
    func testEnabledRelayDropsCompositeFailure() async {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let relay = OutboundFrameRelay(
            filter: filter,
            detector: { image in
                .success([CGRect(x: 0, y: 0, width: image.width, height: image.height)])
            },
            compositor: { _, _, _ in nil })
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        let dropped = expectation(description: "composite failure was recorded")
        var received = 0
        var tokens: Set<AnyCancellable> = []
        relay.publisher.sink { _ in received += 1 }.store(in: &tokens)
        relay.$privacyDroppedFrameCount.dropFirst().sink { count in
            if count == 1 { dropped.fulfill() }
        }.store(in: &tokens)

        source.send(makeImage())
        await fulfillment(of: [dropped], timeout: 2)
        XCTAssertEqual(received, 0)
        XCTAssertEqual(relay.droppedFrameCount, 1)
    }

    /// Empty and failed detections are intentionally different: after a successful no-face result,
    /// the source pixels may pass without paying for a no-op composite.
    @MainActor
    func testEnabledRelayPublishesAfterVerifiedNoFaceResult() async {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let relay = OutboundFrameRelay(
            filter: filter,
            detector: { _ in .success([]) },
            compositor: { image, _, _ in image })
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        let published = expectation(description: "verified no-face frame published")
        let input = makeImage()
        var output: UIImage?
        let token = relay.publisher.sink {
            output = $0
            published.fulfill()
        }

        source.send(input)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(output === input)
        XCTAssertEqual(relay.privacyDroppedFrameCount, 0)
        withExtendedLifetime(token) {}
    }

    /// Privacy-off is the one raw passthrough state. This preserves the documented user choice and
    /// avoids adding filtering cost to exempt/off operation.
    @MainActor
    func testDisabledRelayStillPassesThroughSynchronously() {
        let filter = PrivacyFilterService()
        filter.isEnabled = false
        filter.suspend()  // suspension cannot turn an explicit off state into a drop
        let relay = OutboundFrameRelay(filter: filter)
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)

        let input = makeImage()
        var output: UIImage?
        let token = relay.publisher.sink { output = $0 }
        source.send(input)

        XCTAssertTrue(output === input)
        XCTAssertEqual(relay.droppedFrameCount, 0)
        withExtendedLifetime(token) {}
    }

    // MARK: - Lower-rate protected and exempt paths

    @MainActor
    func testSuspendedProtectedStillReturnsOpaqueReplacement() {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        filter.suspend()
        let input = makeImage(color: .red)

        let output = filter.filtered(input, for: .directModelTurn)

        XCTAssertFalse(output === input)
        guard let cgImage = output.cgImage,
              let pixel = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
                CIImage(cgImage: cgImage), from: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let provider = pixel.dataProvider,
              let bytes = provider.data else {
            return XCTFail("opaque replacement should be renderable")
        }
        let pointer = CFDataGetBytePtr(bytes)
        XCTAssertNotNil(pointer)
        XCTAssertEqual(pointer?[0], 0)
        XCTAssertEqual(pointer?[1], 0)
        XCTAssertEqual(pointer?[2], 0)
    }

    /// On-device scene narration and face recognition retain their deliberately raw input even if
    /// an outbound stream has suspended its protected filter.
    @MainActor
    func testExemptOnDeviceScopesRemainRawWhileSuspended() {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        filter.suspend()
        let input = makeImage()

        XCTAssertTrue(filter.filtered(input, for: .faceRecognition) === input)
        XCTAssertTrue(filter.filtered(input, for: .sceneNarration) === input)
    }
}
