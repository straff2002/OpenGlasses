import XCTest
@testable import OpenGlasses

/// Tests for the presence-aware throttle (Plan W): the pure `ThrottlePolicy` table + `minMode`
/// floor, the `PresenceEvaluator` signal fusion, the `ModeDebouncer` anti-flap filter, and the
/// `PresenceMonitor` publishing. All headless — pure functions plus an injectable monitor.
@MainActor
final class PresenceThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - ThrottlePolicy table

    func testActiveIsFullCadenceAutoAct() {
        let d = ThrottlePolicy.decide(mode: .active)
        XCTAssertEqual(d.intervalMultiplier, 1.0)
        XCTAssertEqual(d.autonomy, .autoAct)
        XCTAssertFalse(d.isPaused)
    }

    func testPresentIsHalfCadenceAutoAct() {
        let d = ThrottlePolicy.decide(mode: .present)
        XCTAssertEqual(d.intervalMultiplier, 2.0)
        XCTAssertEqual(d.autonomy, .autoAct)
    }

    func testIdleIsQuarterCadenceRecommend() {
        let d = ThrottlePolicy.decide(mode: .idle)
        XCTAssertEqual(d.intervalMultiplier, 4.0)
        XCTAssertEqual(d.autonomy, .recommend)   // the autonomy downgrade — surface, don't act
        XCTAssertLessThan(d.autonomy, Autonomy.autoAct)
    }

    func testAwayIsPaused() {
        let d = ThrottlePolicy.decide(mode: .away)
        XCTAssertTrue(d.isPaused)
        XCTAssertEqual(d.autonomy, .paused)
        XCTAssertTrue(d.intervalMultiplier.isInfinite)
    }

    func testIntervalAppliesMultiplierAndPause() {
        XCTAssertEqual(ThrottlePolicy.decide(mode: .active).interval(base: 2), 2)
        XCTAssertEqual(ThrottlePolicy.decide(mode: .idle).interval(base: 2), 8)   // 4× base
        XCTAssertTrue(ThrottlePolicy.decide(mode: .away).interval(base: 2).isInfinite)
    }

    func testMinModeFloorRaisesIdleToPresent() {
        // A safety-critical loop declares a `.present` floor; even when the user looks idle it keeps
        // running at present cadence and never downgrades autonomy.
        let d = ThrottlePolicy.decide(mode: .idle, minMode: .present)
        XCTAssertEqual(d.intervalMultiplier, 2.0)
        XCTAssertEqual(d.autonomy, .autoAct)
    }

    func testMinModeFloorKeepsAwayLoopAlive() {
        // Hazard navigation with an `.active` floor must never pause, even when disconnected logic
        // would say away.
        let d = ThrottlePolicy.decide(mode: .away, minMode: .active)
        XCTAssertFalse(d.isPaused)
        XCTAssertEqual(d.intervalMultiplier, 1.0)
    }

    func testMinModeDoesNotLowerAHigherMode() {
        // Floor is a minimum, not a clamp downward: an active user with an idle floor stays active.
        let d = ThrottlePolicy.decide(mode: .active, minMode: .idle)
        XCTAssertEqual(d.intervalMultiplier, 1.0)
        XCTAssertEqual(d.autonomy, .autoAct)
    }

    // MARK: - PresenceEvaluator fusion

    private func signals(ageSeconds: TimeInterval, voice: Bool = false,
                         connected: Bool = true, foreground: Bool = true) -> PresenceSignals {
        PresenceSignals(lastInteraction: at(-ageSeconds), voiceActive: voice,
                        connected: connected, foreground: foreground)
    }

    func testRecentInteractionIsActive() {
        let m = PresenceEvaluator.mode(for: signals(ageSeconds: 5), now: t0, thresholds: .default)
        XCTAssertEqual(m, .active)
    }

    func testLiveVoiceIsActiveEvenWhenInteractionIsOld() {
        let m = PresenceEvaluator.mode(for: signals(ageSeconds: 600, voice: true), now: t0, thresholds: .default)
        XCTAssertEqual(m, .active)
    }

    func testMidAgeIsPresent() {
        // 60s: past the 30s active window, well short of the 5-min idle threshold.
        let m = PresenceEvaluator.mode(for: signals(ageSeconds: 60), now: t0, thresholds: .default)
        XCTAssertEqual(m, .present)
    }

    func testOldAgeIsIdle() {
        let m = PresenceEvaluator.mode(for: signals(ageSeconds: 400), now: t0, thresholds: .default)
        XCTAssertEqual(m, .idle)
    }

    func testDisconnectedIsAwayDespiteRecentVoice() {
        let m = PresenceEvaluator.mode(for: signals(ageSeconds: 1, voice: true, connected: false),
                                       now: t0, thresholds: .default)
        XCTAssertEqual(m, .away)
    }

    func testBackgroundedIsAway() {
        let m = PresenceEvaluator.mode(for: signals(ageSeconds: 1, foreground: false),
                                       now: t0, thresholds: .default)
        XCTAssertEqual(m, .away)
    }

    func testEvaluateEngagementMatchesMode() {
        XCTAssertEqual(PresenceEvaluator.evaluate(signals(ageSeconds: 5), now: t0, thresholds: .default).engagement, 1.0)
        XCTAssertEqual(PresenceEvaluator.evaluate(signals(ageSeconds: 400), now: t0, thresholds: .default).engagement, 0.2)
        XCTAssertEqual(PresenceEvaluator.evaluate(signals(ageSeconds: 1, connected: false), now: t0, thresholds: .default).engagement, 0.0)
    }

    // MARK: - ModeDebouncer anti-flap

    func testStableModeIsUnchanged() {
        var d = ModeDebouncer(dwell: 12, initial: .present)
        XCTAssertEqual(d.step(raw: .present, now: t0), .present)
        XCTAssertEqual(d.step(raw: .present, now: at(100)), .present)
    }

    func testRisingEngagementCommitsImmediately() {
        var d = ModeDebouncer(dwell: 12, initial: .idle)
        XCTAssertEqual(d.step(raw: .active, now: t0), .active)   // no dwell on the way up
    }

    func testFallingEngagementHoldsUntilDwellElapses() {
        var d = ModeDebouncer(dwell: 12, initial: .active)
        XCTAssertEqual(d.step(raw: .idle, now: at(0)), .active)   // drop proposed, not yet committed
        XCTAssertEqual(d.step(raw: .idle, now: at(6)), .active)   // still within dwell
        XCTAssertEqual(d.step(raw: .idle, now: at(12)), .idle)    // dwell elapsed → commit
    }

    func testFallingBlipThatRevertsNeverCommits() {
        var d = ModeDebouncer(dwell: 12, initial: .active)
        XCTAssertEqual(d.step(raw: .idle, now: at(0)), .active)   // blip down
        XCTAssertEqual(d.step(raw: .active, now: at(5)), .active) // recovers before dwell
        XCTAssertEqual(d.committed, .active)                      // never flapped to idle
    }

    // MARK: - PresenceMonitor publishing

    func testMonitorPublishesDecisionFromSignals() {
        let monitor = PresenceMonitor(
            thresholds: PresenceThresholds(activeWindow: 30, idleThreshold: 300, debounceDwell: 10),
            lastInteraction: { self.at(-5) },   // 5s ago → active
            voiceActive: { false }, connected: { true }, foreground: { true })
        monitor.update(now: t0)
        XCTAssertEqual(monitor.mode, .active)
        XCTAssertEqual(monitor.engagement, 1.0)
        XCTAssertEqual(monitor.decision.intervalMultiplier, 1.0)
    }

    func testMonitorSettlesToIdleThenResumesOnReEngagement() {
        var age: TimeInterval = 600      // start long-idle
        var voice = false
        let monitor = PresenceMonitor(
            thresholds: PresenceThresholds(activeWindow: 30, idleThreshold: 300, debounceDwell: 10),
            lastInteraction: { self.at(-age) }, voiceActive: { voice },
            connected: { true }, foreground: { true })

        // Monitor starts committed .active; a drop must dwell. Settle to idle across the dwell.
        monitor.update(now: at(0))
        XCTAssertEqual(monitor.mode, .active)            // not yet — debounced
        monitor.update(now: at(10))
        XCTAssertEqual(monitor.mode, .idle)              // dwell elapsed
        XCTAssertEqual(monitor.decision.autonomy, .recommend)   // autonomy downgraded while idle
        XCTAssertEqual(monitor.decision.intervalMultiplier, 4.0)

        // User speaks → rises to active immediately, full cadence + auto-act restored.
        voice = true; age = 0
        monitor.update(now: at(11))
        XCTAssertEqual(monitor.mode, .active)
        XCTAssertEqual(monitor.decision.intervalMultiplier, 1.0)
        XCTAssertEqual(monitor.decision.autonomy, .autoAct)
    }
}
