import XCTest
import UIKit
import QuartzCore
@testable import OpenGlasses

/// Tests for Plan J pure logic: frame-quality pre-check, dedup, the hazard prompt contract, and the
/// stale-advice expiry (a slow model fake against an injected clock). The timer-driven loop itself
/// is not unit-tested.
@MainActor
final class NavigationAssistTests: XCTestCase {

    private func solidImage(_ color: UIColor, size: Int = 64) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.cgImage!
    }

    private func variedImage(size: Int = 64) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
            UIColor.gray.setFill(); ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size / 2))
        }.cgImage!
    }

    func testDarkFrameIsUnusable() {
        XCTAssertFalse(NavigationAssistService.isFrameUsable(solidImage(.black)))
    }

    func testUniformFrameIsUnusable() {
        // A flat mid-gray frame: bright enough but no variance (blurred/featureless).
        XCTAssertFalse(NavigationAssistService.isFrameUsable(solidImage(.gray)))
    }

    func testVariedFrameIsUsable() {
        XCTAssertTrue(NavigationAssistService.isFrameUsable(variedImage()))
    }

    func testDedupSuppressesRepeatCallout() {
        XCTAssertTrue(NavigationAssistService.isSimilar("Step down, two o'clock, one meter",
                                                        "Step down at two o'clock about one meter"))
        XCTAssertFalse(NavigationAssistService.isSimilar("Step down, two o'clock",
                                                         "Open doorway ahead, twelve o'clock"))
    }

    func testPromptDemandsJSONAndClockPositions() {
        let p = NavigationAssistService.systemPrompt
        XCTAssertTrue(p.contains("valid JSON"))
        XCTAssertTrue(p.lowercased().contains("clock position"))
        XCTAssertTrue(p.lowercased().contains("hazard"))
    }

    func testNavAdviceHighUrgencyMapsToHighSpeech() {
        let advice = AssistiveAdvice.parse(#"{"advice":"Vehicle approaching, ten o'clock","urgency":"high"}"#)
        XCTAssertEqual(advice?.urgency.speechUrgency, .high)
    }

    // MARK: - Stale advice expiry (pure policy)

    func testMaxAgeIsFiveSeconds() {
        XCTAssertEqual(Config.navigationAdviceMaxAge, 5.0)
    }

    func testFreshFrameIsFresh() {
        XCTAssertTrue(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: 102))
        XCTAssertTrue(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: 100))
    }

    func testStaleFrameIsNotFresh() {
        XCTAssertFalse(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: 106))
    }

    func testBoundaryAtMaxAgeIsFreshAndJustPastIsStale() {
        XCTAssertTrue(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: 105))
        XCTAssertFalse(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: 105.001))
        XCTAssertTrue(NavigationAdviceFreshness.isFresh(capturedAt: 0, now: 1, maxAge: 1))
        XCTAssertFalse(NavigationAdviceFreshness.isFresh(capturedAt: 0, now: 1.01, maxAge: 1))
    }

    func testImpossibleAgesFailClosed() {
        XCTAssertFalse(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: 99), "negative age")
        XCTAssertFalse(NavigationAdviceFreshness.isFresh(capturedAt: .nan, now: 100))
        XCTAssertFalse(NavigationAdviceFreshness.isFresh(capturedAt: 100, now: .infinity))
    }

    // MARK: - Stale advice expiry (service, slow model fake + injected clock)

    private final class FakeClock {
        var now: TimeInterval = 1_000
    }

    private let hazardReply = #"{"advice":"Step down, two o'clock, about one meter","urgency":"medium"}"#
    private let vehicleReply = #"{"advice":"Vehicle approaching, ten o'clock","urgency":"high"}"#

    /// A fresh service whose clock is the fake, and a model fake that takes `latency` seconds of
    /// that clock to answer.
    private func makeService(_ clock: FakeClock) -> NavigationAssistService {
        let service = NavigationAssistService()
        service.clock = { clock.now }
        return service
    }

    private func ask(_ service: NavigationAssistService, _ clock: FakeClock,
                     latency: TimeInterval, reply: String?) async -> AssistiveAdvice? {
        let capturedAt = service.clock()
        return await service.freshAdvice(capturedAt: capturedAt, analyze: {
            clock.now += latency
            return reply
        })
    }

    func testFastReplyIsSpoken() async {
        let clock = FakeClock()
        let service = makeService(clock)
        let advice = await ask(service, clock, latency: 2, reply: hazardReply)
        XCTAssertEqual(advice?.advice, "Step down, two o'clock, about one meter")
        XCTAssertEqual(service.staleAdviceDrops, 0)
    }

    func testSlowReplyIsDroppedAndCounted() async {
        let clock = FakeClock()
        let service = makeService(clock)
        let advice = await ask(service, clock, latency: 6, reply: hazardReply)
        XCTAssertNil(advice, "advice about where the wearer was must not be spoken")
        XCTAssertEqual(service.staleAdviceDrops, 1)

        // The next tick takes a new frame and is judged on its own age.
        let next = await ask(service, clock, latency: 1, reply: hazardReply)
        XCTAssertNotNil(next)
        XCTAssertEqual(service.staleAdviceDrops, 1)
    }

    func testHighUrgencyGetsNoExemption() async {
        let clock = FakeClock()
        let service = makeService(clock)
        let advice = await ask(service, clock, latency: 6, reply: vehicleReply)
        XCTAssertNil(advice)
        XCTAssertEqual(service.staleAdviceDrops, 1)
    }

    func testReplyExactlyAtMaxAgeIsSpoken() async {
        let clock = FakeClock()
        let service = makeService(clock)
        let atLimit = await ask(service, clock, latency: Config.navigationAdviceMaxAge, reply: hazardReply)
        XCTAssertNotNil(atLimit)
        let pastLimit = await ask(service, clock, latency: Config.navigationAdviceMaxAge + 0.01,
                                  reply: hazardReply)
        XCTAssertNil(pastLimit)
        XCTAssertEqual(service.staleAdviceDrops, 1)
    }

    func testUnparseableReplyIsNotCountedAsStale() async {
        let clock = FakeClock()
        let service = makeService(clock)
        let none = await ask(service, clock, latency: 6, reply: nil)
        XCTAssertNil(none)
        let junk = await ask(service, clock, latency: 6, reply: "not json")
        XCTAssertNil(junk)
        XCTAssertEqual(service.staleAdviceDrops, 0)
    }

    func testAgeIsMeasuredOnTheInjectedClock() async {
        // No real time passes in this test; only the injected clock moves. A drop proves the
        // service reads the injected clock rather than the wall or media clock.
        let clock = FakeClock()
        let service = makeService(clock)
        clock.now = 50
        XCTAssertEqual(service.clock(), 50)
        let advice = await service.freshAdvice(capturedAt: 40, analyze: { self.hazardReply })
        XCTAssertNil(advice, "a frame stamped 10 s earlier on the injected clock is stale")
        XCTAssertEqual(service.staleAdviceDrops, 1)
    }

    func testDefaultClockIsTheMonotonicMediaClock() {
        let service = NavigationAssistService()
        let before = CACurrentMediaTime()
        let reading = service.clock()
        let after = CACurrentMediaTime()
        XCTAssertGreaterThanOrEqual(reading, before)
        XCTAssertLessThanOrEqual(reading, after)
    }
}
