import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// W04.1 — the lifecycle half of "the privacy filter fails closed".
///
/// The relay's fail-closed behaviour was already proven against an explicit `suspend()`. That call
/// happened in exactly one place, and only when a broadcast or WebRTC stream was already running,
/// so the app had no answer at all for the other ways the blur pass stops being trustworthy:
/// backgrounded while recording, the lock-screen transition window, protected data going away. None
/// of those could be tested either, because the only source of truth was `UIApplication`.
///
/// `PrivacyFilterAvailability` makes the policy a value and the signals injectable, so these drive
/// real foreground → background → foreground and unlocked → locked → unlocked transitions and check
/// what the outbound relay does in each.
final class PrivacyFilterAvailabilityTests: XCTestCase {

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

    // MARK: - The policy

    func testFreshAvailabilityIsAvailable() {
        XCTAssertTrue(PrivacyFilterAvailability().isAvailable)
        XCTAssertNil(PrivacyFilterAvailability().unavailableReason)
    }

    func testBackgroundMakesFilteringUnavailable() {
        var availability = PrivacyFilterAvailability()
        availability.note(phase: .background)
        XCTAssertEqual(availability.unavailableReason, .backgrounded)
    }

    /// The transition window. `.inactive` is the lock-screen slide and the app switcher — the exact
    /// moments a frame can be in flight while the system decides whether to keep giving us GPU
    /// time. Treating it as "still fine" is the fail-open reading.
    func testTransitionWindowIsUnavailableNotAvailable() {
        var availability = PrivacyFilterAvailability()
        availability.note(phase: .inactive)
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.unavailableReason, .transitioning)
    }

    func testDeviceLockMakesFilteringUnavailable() {
        var availability = PrivacyFilterAvailability()
        availability.noteProtectedData(available: false)
        XCTAssertEqual(availability.unavailableReason, .locked)
    }

    /// Several causes can be live at once; the reported one must be stable so a device log reads
    /// consistently rather than flapping between equally true answers.
    func testReasonPriorityIsSuspendThenLockThenPhase() {
        var availability = PrivacyFilterAvailability()
        availability.note(phase: .background)
        availability.noteProtectedData(available: false)
        availability.suspend()
        XCTAssertEqual(availability.unavailableReason, .explicitlySuspended)
        availability.resume()
        XCTAssertEqual(availability.unavailableReason, .locked)
        availability.noteProtectedData(available: true)
        XCTAssertEqual(availability.unavailableReason, .backgrounded)
        availability.note(phase: .active)
        XCTAssertTrue(availability.isAvailable)
    }

    /// The generation is what tells cached detections to expire. It must move on the *return*, and
    /// only then — a bump on the way out would invalidate a cache that is still perfectly good.
    func testResumeGenerationMovesOnlyWhenAvailabilityReturns() {
        var availability = PrivacyFilterAvailability()
        XCTAssertEqual(availability.resumeGeneration, 0)
        availability.note(phase: .inactive)
        availability.note(phase: .background)
        XCTAssertEqual(availability.resumeGeneration, 0, "going away is not a resume")
        availability.note(phase: .inactive)
        XCTAssertEqual(availability.resumeGeneration, 0, "still in the transition window")
        availability.note(phase: .active)
        XCTAssertEqual(availability.resumeGeneration, 1)
    }

    /// Two overlapping causes clear one at a time; only the last one to clear is a resume.
    func testOverlappingCausesProduceOneResume() {
        var availability = PrivacyFilterAvailability()
        availability.note(phase: .background)
        availability.noteProtectedData(available: false)
        availability.note(phase: .active)
        XCTAssertEqual(availability.resumeGeneration, 0, "still locked")
        availability.noteProtectedData(available: true)
        XCTAssertEqual(availability.resumeGeneration, 1)
    }

    // MARK: - The service

    @MainActor
    func testServiceReportsLifecycleUnavailability() {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        XCTAssertFalse(filter.isSuspendedForBackground)

        filter.noteScenePhase(.background)
        XCTAssertTrue(filter.isSuspendedForBackground)
        XCTAssertEqual(filter.unavailableReason, .backgrounded)

        filter.noteScenePhase(.active)
        filter.noteProtectedDataAvailable(false)
        XCTAssertEqual(filter.unavailableReason, .locked)
        filter.noteProtectedDataAvailable(true)
        XCTAssertNil(filter.unavailableReason)
        XCTAssertEqual(filter.resumeGeneration, 2)
    }

    /// The still-image path is nonoptional, so "unavailable" has to mean an opaque replacement
    /// rather than the source pixels — for lock and transition, not only for explicit suspension.
    @MainActor
    func testProtectedStillIsOpaqueWhileLockedOrTransitioning() {
        let filter = PrivacyFilterService()
        filter.isEnabled = true
        let source = makeImage()

        filter.noteProtectedDataAvailable(false)
        XCTAssertNotIdentical(filter.filtered(source, for: .directModelTurn), source)
        filter.noteProtectedDataAvailable(true)

        filter.noteScenePhase(.inactive)
        XCTAssertNotIdentical(filter.filtered(source, for: .directModelTurn), source)

        // An exempt scope is exempt in every state — it was never filtered to begin with.
        XCTAssertIdentical(filter.filtered(source, for: .faceRecognition), source)
    }

    // MARK: - The relay, through real transitions

    /// Drive a relay and report what it published and dropped.
    @MainActor
    private final class Harness {
        let filter = PrivacyFilterService()
        let source = PassthroughSubject<UIImage, Never>()
        let relay: OutboundFrameRelay
        private(set) var published: [UIImage] = []
        private var tokens: Set<AnyCancellable> = []
        /// How many times the injected detector actually ran.
        let detections = Counter()

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }

        init(detectionInterval: TimeInterval = 100,
             detector: @escaping @Sendable (Counter) -> PrivacyFaceDetectionResult = { _ in .success([]) }) {
            let counter = detections
            filter.isEnabled = true
            relay = OutboundFrameRelay(
                filter: filter,
                detector: { _ in counter.increment(); return detector(counter) },
                compositor: { image, _, _ in image },
                // A long detection interval means any second detection can only have been forced,
                // never merely due — which is what "resumes on a *fresh* detection" has to prove.
                rectCache: FaceRectCache(detectionInterval: detectionInterval, grace: 1000,
                                         maxDetectionAge: 1000))
            relay.attach(to: source)
            relay.publisher.sink { [weak self] in self?.published.append($0) }.store(in: &tokens)
        }

        /// Send a frame and wait until the relay has published or dropped it. The detector and
        /// compositor hop through a background queue, so a fixed sleep races them on a loaded
        /// runner; a frame that never finishes fails here on the deadline instead.
        func send(_ image: UIImage, file: StaticString = #filePath, line: UInt = #line) async {
            source.send(image)
            let deadline = Date().addingTimeInterval(5)
            while !relay.isIdle {
                guard Date() < deadline else {
                    XCTFail("relay still busy after 5s — a frame never finished", file: file, line: line)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    /// Foreground → background → foreground. Nothing raw escapes while away, and coming back does
    /// not reuse the mask from before: the first frame back forces a fresh detection.
    @MainActor
    func testBackgroundDropsFramesAndReturnForcesFreshDetection() async {
        let harness = Harness()

        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 1, "foreground frame publishes")
        XCTAssertEqual(harness.detections.count, 1)

        harness.filter.noteScenePhase(.inactive)
        await harness.send(makeImage())
        harness.filter.noteScenePhase(.background)
        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 1, "nothing publishes through the transition or background")
        XCTAssertEqual(harness.relay.privacyDroppedFrameCount, 2)

        harness.filter.noteScenePhase(.active)
        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 2)
        XCTAssertEqual(harness.detections.count, 2, """
            The detection interval is 100 s, so a second detection can only have happened because \
            returning to the foreground invalidated the pre-background result.
            """)
    }

    /// Locked → unlocked, same claim. The lock screen is the case a device capture would have to
    /// cover and this stands in for until one exists.
    @MainActor
    func testDeviceLockDropsFramesAndUnlockForcesFreshDetection() async {
        let harness = Harness()
        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 1)

        harness.filter.noteProtectedDataAvailable(false)
        await harness.send(makeImage())
        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 1, "no frame publishes while the device is locked")
        XCTAssertEqual(harness.relay.privacyDroppedFrameCount, 2)

        harness.filter.noteProtectedDataAvailable(true)
        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 2)
        XCTAssertEqual(harness.detections.count, 2)
    }

    /// Turning the filter on mid-stream must take effect on the very next frame: before it, frames
    /// pass through untouched by design; after it, every frame is detected on.
    @MainActor
    func testFilterToggledOnMidStreamStartsFilteringImmediately() async {
        let harness = Harness()
        harness.filter.isEnabled = false

        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 1)
        XCTAssertEqual(harness.detections.count, 0, "filter off is a true passthrough")

        harness.filter.isEnabled = true
        await harness.send(makeImage())
        XCTAssertEqual(harness.published.count, 2)
        XCTAssertEqual(harness.detections.count, 1, "the next frame after the toggle is detected on")
    }

    /// A detector that works and then stops. The good frames publish; the moment detection fails,
    /// frames stop — the failure is not allowed to read as "nobody in shot".
    @MainActor
    func testDetectorFailingAfterGoodFramesStopsPublication() async {
        let harness = Harness(detectionInterval: 0, detector: { counter in
            counter.count > 3 ? .failure : .success([])
        })

        for _ in 0..<3 { await harness.send(makeImage()) }
        XCTAssertEqual(harness.published.count, 3)

        for _ in 0..<3 { await harness.send(makeImage()) }
        XCTAssertEqual(harness.published.count, 3, "no frame publishes once detection is failing")
        XCTAssertEqual(harness.relay.privacyDroppedFrameCount, 3)
    }
}
