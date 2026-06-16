import XCTest
import CoreMotion
@testable import OpenGlasses

/// Tests for Plan W v2: the CoreMotion engagement signal fused into `PresenceEvaluator`, the
/// `MotionActivityProvider` classifier, and the continuous-caption `CaptionPresenceGate`.
final class PresenceMotionCaptionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func signals(ageSeconds: TimeInterval, voice: Bool = false, connected: Bool = true,
                         foreground: Bool = true, motion: Bool = false) -> PresenceSignals {
        PresenceSignals(lastInteraction: at(-ageSeconds), voiceActive: voice,
                        connected: connected, foreground: foreground, motionActive: motion)
    }

    // MARK: - Motion fusion

    func testMotionKeepsQuietUserPresentNotIdle() {
        // 10 min since interaction, silent — would be idle, but active motion ⇒ present (engaged).
        let stationary = PresenceEvaluator.mode(for: signals(ageSeconds: 600), now: t0, thresholds: .default)
        XCTAssertEqual(stationary, .idle)
        let moving = PresenceEvaluator.mode(for: signals(ageSeconds: 600, motion: true), now: t0, thresholds: .default)
        XCTAssertEqual(moving, .present)
    }

    func testMotionDoesNotOverrideAway() {
        // Disconnected (or backgrounded) ⇒ away regardless of motion — nothing can run.
        XCTAssertEqual(PresenceEvaluator.mode(for: signals(ageSeconds: 1, connected: false, motion: true), now: t0, thresholds: .default), .away)
        XCTAssertEqual(PresenceEvaluator.mode(for: signals(ageSeconds: 1, foreground: false, motion: true), now: t0, thresholds: .default), .away)
    }

    func testMotionDoesNotDowngradeActive() {
        // A recent interaction is still fully active; motion doesn't change that.
        XCTAssertEqual(PresenceEvaluator.mode(for: signals(ageSeconds: 5, motion: true), now: t0, thresholds: .default), .active)
        XCTAssertEqual(PresenceEvaluator.mode(for: signals(ageSeconds: 600, voice: true, motion: true), now: t0, thresholds: .default), .active)
    }

    func testNoMotionPreservesIdleBands() {
        // Backward-compatible default: without a motion signal, the bands are unchanged.
        XCTAssertEqual(PresenceEvaluator.mode(for: signals(ageSeconds: 60), now: t0, thresholds: .default), .present)
        XCTAssertEqual(PresenceEvaluator.mode(for: signals(ageSeconds: 600), now: t0, thresholds: .default), .idle)
    }

    func testDefaultSignalsHaveNoMotion() {
        // The added field defaults off, so existing call sites are unaffected.
        let s = PresenceSignals(lastInteraction: t0, voiceActive: false, connected: true, foreground: true)
        XCTAssertFalse(s.motionActive)
    }

    // MARK: - MotionActivityProvider classifier

    func testIsMovingNilIsFalse() {
        // The only CMMotionActivity we can construct in a unit test is "none"; the walking/running/
        // cycling/automotive paths are device-validated.
        XCTAssertFalse(MotionActivityProvider.isMoving(nil))
    }

    // MARK: - CaptionPresenceGate

    func testCaptionsSuspendOnlyWhenAway() {
        XCTAssertTrue(CaptionPresenceGate.shouldSuspend(mode: .away))
        XCTAssertFalse(CaptionPresenceGate.shouldSuspend(mode: .idle))     // reading silently is engaged
        XCTAssertFalse(CaptionPresenceGate.shouldSuspend(mode: .present))
        XCTAssertFalse(CaptionPresenceGate.shouldSuspend(mode: .active))
    }
}
