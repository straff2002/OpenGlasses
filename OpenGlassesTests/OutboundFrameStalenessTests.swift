import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// W04.1 — faces that arrive between detection intervals, and detectors that cannot keep up.
///
/// Detection is expensive, so the relay runs it on an interval and reuses the rectangles in
/// between. That trade-off was documented, but the code enforced only half of it: an over-age cache
/// answered with an empty rectangle list, and an empty list was indistinguishable from Vision
/// verifying that nobody is in shot. So the one situation the interval exists to bound — "I do not
/// currently know who is in this frame" — published the frame untouched.
///
/// `FaceRectCache.masking(now:frameSize:)` now returns a three-way verdict and `maxDetectionAge` is
/// the ceiling on the age of a detection that may back a published frame. The relay re-tests that
/// age at the publication boundary as well as when it chooses the mask, because everything in
/// between takes wall-clock time — which is exactly what CPU pressure buys you.
final class OutboundFrameStalenessTests: XCTestCase {

    private func makeImage(color: UIColor = .red,
                           size: CGSize = CGSize(width: 16, height: 16)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A clock the test moves by hand — including from inside the detector, which is how a slow
    /// Vision pass is simulated without actually being slow.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ time: TimeInterval) { lock.lock(); value = time; lock.unlock() }
        func advance(by delta: TimeInterval) { lock.lock(); value += delta; lock.unlock() }
    }

    // MARK: - The cache's verdict

    private let frame = CGSize(width: 100, height: 100)
    private let face = CGRect(x: 20, y: 20, width: 20, height: 20)

    func testNothingDetectedYetIsStaleNotClear() {
        let cache = FaceRectCache()
        XCTAssertEqual(cache.masking(now: 0, frameSize: frame), .stale,
                       "an empty cache is ignorance, not a clean bill of health")
    }

    func testFreshEmptyDetectionIsVerifiedClear() {
        var cache = FaceRectCache(maxDetectionAge: 0.6)
        cache.record([], at: 0)
        XCTAssertEqual(cache.masking(now: 0.5, frameSize: frame), .verifiedClear)
    }

    /// The boundary that matters: one side publishes, the other must not.
    func testEmptyDetectionPastTheCeilingIsStale() {
        var cache = FaceRectCache(maxDetectionAge: 0.6)
        cache.record([], at: 0)
        XCTAssertEqual(cache.masking(now: 0.6, frameSize: frame), .verifiedClear, "at the limit, still usable")
        XCTAssertEqual(cache.masking(now: 0.61, frameSize: frame), .stale, "past the limit, unknown")
    }

    func testDetectedFacesWithinTheCeilingProduceAMask() {
        var cache = FaceRectCache(maxDetectionAge: 0.6, motionMargin: 0)
        cache.record([face], at: 0)
        XCTAssertEqual(cache.masking(now: 0.5, frameSize: frame), .rects([face]))
    }

    func testDetectedFacesPastTheCeilingAreStaleNotUnmasked() {
        var cache = FaceRectCache(maxDetectionAge: 0.6, motionMargin: 0)
        cache.record([face], at: 0)
        XCTAssertEqual(cache.masking(now: 0.7, frameSize: frame), .stale)
    }

    /// The pre-existing `grace` window and the new ceiling are separate knobs; a cache whose grace
    /// has lapsed has no mask for a frame that had faces in it, and that is not publishable either.
    func testGraceLapsedWithFacesKnownIsStale() {
        var cache = FaceRectCache(grace: 0.2, maxDetectionAge: 5, motionMargin: 0)
        cache.record([face], at: 0)
        XCTAssertEqual(cache.masking(now: 0.3, frameSize: frame), .stale)
    }

    /// A clock that jumps backwards must not read as "detected in the future, therefore fresh".
    func testNegativeAgeIsStale() {
        var cache = FaceRectCache(maxDetectionAge: 0.6)
        cache.record([], at: 10)
        XCTAssertEqual(cache.masking(now: 9, frameSize: frame), .stale)
    }

    func testResetReturnsToStale() {
        var cache = FaceRectCache()
        cache.record([], at: 0)
        cache.reset()
        XCTAssertEqual(cache.masking(now: 0, frameSize: frame), .stale)
    }

    // MARK: - The relay

    /// Build a relay whose clock and detection cadence the test owns. The detection interval is
    /// long so detections happen only when the relay is *forced* to run one, which is what makes
    /// "published on a cached mask" and "re-detected" distinguishable.
    @MainActor
    private func makeRelay(clock: FakeClock,
                           maxDetectionAge: TimeInterval,
                           detectionInterval: TimeInterval = 100,
                           masked: UIImage,
                           detector: @escaping @Sendable () -> PrivacyFaceDetectionResult)
    -> (PrivacyFilterService, PassthroughSubject<UIImage, Never>, OutboundFrameRelay) {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let relay = OutboundFrameRelay(
            filter: filter,
            detector: { _ in detector() },
            compositor: { _, _, _ in masked },
            rectCache: FaceRectCache(detectionInterval: detectionInterval,
                                     grace: 1000,
                                     maxDetectionAge: maxDetectionAge,
                                     motionMargin: 0),
            now: { clock.now })
        let source = PassthroughSubject<UIImage, Never>()
        relay.attach(to: source)
        return (filter, source, relay)
    }

    /// Wait until every frame sent so far has been published or dropped. The detector and
    /// compositor run on the relay's background queue, so a fixed sleep races them — on a loaded
    /// CI runner the last pending frame can still be in flight when the sleep ends. A requeueing
    /// bug never goes idle, so it fails here on the deadline rather than passing by accident.
    @MainActor
    private func waitUntilIdle(_ relay: OutboundFrameRelay,
                               timeout: TimeInterval = 5,
                               file: StaticString = #filePath,
                               line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !relay.isIdle {
            guard Date() < deadline else {
                XCTFail("relay still busy after \(timeout)s — a frame never finished", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Give anything that might still be scheduled a chance to run. Only meaningful *after*
    /// `waitUntilIdle`, as a check that the pipeline stays quiet — never as the wait itself.
    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        for _ in 0..<6 { await Task.yield() }
    }

    /// Just under the ceiling: the cached mask still describes this frame, so it publishes — and it
    /// publishes *masked*, not raw.
    @MainActor
    func testFrameJustUnderTheCeilingPublishesOnTheCachedMask() async {
        let clock = FakeClock()
        let masked = makeImage(color: .blue)
        let detections = DetectionCounter()
        let (_, source, relay) = makeRelay(clock: clock, maxDetectionAge: 0.5, masked: masked) {
            detections.increment()
            return .success([CGRect(x: 2, y: 2, width: 6, height: 6)])
        }
        var received: [UIImage] = []
        let token = relay.publisher.sink { received.append($0) }

        source.send(makeImage())
        await waitUntilIdle(relay)
        clock.set(0.4)
        source.send(makeImage())
        await waitUntilIdle(relay)

        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0 === masked }, "both frames left masked")
        XCTAssertEqual(detections.count, 1, "the second frame reused the cached rectangles")
        XCTAssertEqual(relay.privacyDroppedFrameCount, 0)
        withExtendedLifetime(token) {}
    }

    /// Just over the ceiling: the frame is dropped, and the cache is cleared so the *next* frame is
    /// re-detected rather than dropped forever against a dead result.
    @MainActor
    func testFrameJustOverTheCeilingIsDroppedThenReDetected() async {
        let clock = FakeClock()
        let masked = makeImage(color: .blue)
        let detections = DetectionCounter()
        let (_, source, relay) = makeRelay(clock: clock, maxDetectionAge: 0.5, masked: masked) {
            detections.increment()
            return .success([CGRect(x: 2, y: 2, width: 6, height: 6)])
        }
        var received: [UIImage] = []
        let token = relay.publisher.sink { received.append($0) }

        source.send(makeImage())
        await waitUntilIdle(relay)
        clock.set(0.6)                       // past the ceiling, and no detection is due
        source.send(makeImage())
        await waitUntilIdle(relay)

        XCTAssertEqual(received.count, 1, "the stale frame is dropped, not published")
        XCTAssertEqual(relay.privacyDroppedFrameCount, 1)

        source.send(makeImage())             // the cache was cleared, so this one re-detects
        await waitUntilIdle(relay)
        XCTAssertEqual(detections.count, 2)
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0 === masked })
        withExtendedLifetime(token) {}
    }

    /// The burst case. After a detection goes stale, a rush of frames must not sneak one out on the
    /// dead result — every frame that publishes has to carry a mask from a detection young enough
    /// to be about it.
    @MainActor
    func testBurstAfterAStaleDetectionNeverPublishesAnUnmaskedFrame() async {
        let clock = FakeClock()
        let masked = makeImage(color: .blue)
        let (_, source, relay) = makeRelay(clock: clock, maxDetectionAge: 0.5, masked: masked) {
            .success([CGRect(x: 2, y: 2, width: 6, height: 6)])
        }
        var received: [UIImage] = []
        let token = relay.publisher.sink { received.append($0) }

        source.send(makeImage())
        await waitUntilIdle(relay)
        clock.set(5)                          // the cached detection is now hopelessly old

        for _ in 0..<10 {
            source.send(makeImage())
            await waitUntilIdle(relay)
        }

        XCTAssertTrue(received.allSatisfy { $0 === masked }, """
            A frame reached the publisher without going through the compositor, which means it was \
            published on a stale or absent mask.
            """)
        XCTAssertGreaterThan(relay.privacyDroppedFrameCount, 0)
        withExtendedLifetime(token) {}
    }

    /// CPU-pressure stand-in. A detector slower than the frame interval is simulated by advancing
    /// the clock from inside it, so by the time each mask is ready it no longer describes the frame
    /// it was computed for. The relay must drop, not publish, and must not accumulate a backlog.
    ///
    /// Real device pressure is still owed — this proves the policy, not the throughput.
    @MainActor
    func testDetectorSlowerThanTheFrameIntervalDropsRatherThanPublishing() async {
        let clock = FakeClock()
        let masked = makeImage(color: .blue)
        let (_, source, relay) = makeRelay(clock: clock, maxDetectionAge: 0.5,
                                           detectionInterval: 0, masked: masked) {
            clock.advance(by: 1.0)            // one detection outlives its own result
            return .success([CGRect(x: 2, y: 2, width: 6, height: 6)])
        }
        var received: [UIImage] = []
        let token = relay.publisher.sink { received.append($0) }

        for _ in 0..<12 { source.send(makeImage()) }
        // The coalescer holds one in flight and one pending, so a backlog cannot form — a relay
        // that requeued would never go idle and fails here on the deadline.
        await waitUntilIdle(relay)

        XCTAssertTrue(received.isEmpty, """
            Every mask was obsolete by the time it was ready, so nothing was publishable. \
            Publishing here would mean sending pixels masked against a scene that had moved on.
            """)
        XCTAssertGreaterThan(relay.privacyDroppedFrameCount, 0)
        // Idle means every frame has been dropped; none may be counted twice (requeueing) or
        // left uncounted (still in the pipeline).
        XCTAssertEqual(relay.droppedFrameCount, 12,
                       "every frame is accounted for exactly once — more would mean requeueing")
        // And once idle it stays idle: the drop count must not climb after the source stops.
        await settle()
        XCTAssertTrue(relay.isIdle)
        XCTAssertEqual(relay.droppedFrameCount, 12, "the pipeline must go quiet, not chew a backlog")
        withExtendedLifetime(token) {}
    }

    /// Counts detector invocations across the relay's background queue.
    private final class DetectionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
