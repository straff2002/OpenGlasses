import XCTest
@testable import OpenGlasses

/// Tests for the Plan W live-integration cores: the presence autonomy ceiling in `SafetySupervisor`,
/// the `LoopThrottle` tick gate the loops use, the `HeldRecommendationStore`, and the
/// `PresenceMonitor` re-engagement hook. All headless — pure functions + injectable types.
@MainActor
final class PresenceLiveIntegrationTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: - Autonomy ceiling (SafetySupervisor)

    private func ctx(rules: Set<SafetyRuleKind> = [], autonomy: Autonomy) -> SafetyContext {
        SafetyContext(now: t0, location: nil, homeRegion: nil, enabledRules: rules,
                      quietHoursStart: 22, quietHoursEnd: 7, autonomy: autonomy)
    }

    func testAutoActLeavesActingToolUngated() {
        // No rules + full autonomy ⇒ the ceiling never fires.
        XCTAssertEqual(SafetySupervisor.evaluate(tool: "send_message", args: [:], context: ctx(autonomy: .autoAct)), .allow)
    }

    func testRecommendHoldsActingTool() {
        let verdict = SafetySupervisor.evaluate(tool: "send_message", args: [:], context: ctx(autonomy: .recommend))
        guard case .block(let reason) = verdict else { return XCTFail("expected block, got \(verdict)") }
        XCTAssertTrue(reason.lowercased().contains("idle") || reason.lowercased().contains("held"))
    }

    func testPausedBlocksActingTool() {
        let verdict = SafetySupervisor.evaluate(tool: "send_message", args: [:], context: ctx(autonomy: .paused))
        guard case .block = verdict else { return XCTFail("expected block, got \(verdict)") }
    }

    func testCeilingDoesNotGateReadOnlyTools() {
        // Reading is fine while disengaged — only acting (high-impact) tools are held.
        XCTAssertEqual(SafetySupervisor.evaluate(tool: "web_search", args: [:], context: ctx(autonomy: .recommend)), .allow)
        XCTAssertEqual(SafetySupervisor.evaluate(tool: "web_search", args: [:], context: ctx(autonomy: .paused)), .allow)
    }

    func testCeilingComposesWithRulesRaisingConfirmToBlock() {
        // The needsVoiceApproval rule alone ⇒ confirm; under a recommend ceiling it's raised to block.
        let rules: Set<SafetyRuleKind> = [.needsVoiceApproval]
        if case .confirm = SafetySupervisor.evaluate(tool: "send_message", args: [:], context: ctx(rules: rules, autonomy: .autoAct)) {} else {
            XCTFail("expected confirm under autoAct")
        }
        guard case .block = SafetySupervisor.evaluate(tool: "send_message", args: [:], context: ctx(rules: rules, autonomy: .recommend)) else {
            return XCTFail("expected block under recommend ceiling")
        }
    }

    func testDefaultContextAutonomyIsAutoAct() {
        // Backward compatibility: a context built without autonomy behaves as before (no ceiling).
        let legacy = SafetyContext(now: t0, location: nil, homeRegion: nil, enabledRules: [],
                                   quietHoursStart: 22, quietHoursEnd: 7)
        XCTAssertEqual(legacy.autonomy, .autoAct)
        XCTAssertEqual(SafetySupervisor.evaluate(tool: "send_message", args: [:], context: legacy), .allow)
    }

    // MARK: - LoopThrottle gate

    func testThrottleRunsEveryTickWhenActive() {
        var throttle = LoopThrottle()
        let active = ThrottlePolicy.decide(mode: .active)   // multiplier 1.0
        XCTAssertTrue(throttle.shouldRun(now: at(0), base: 2, decision: active))   // first tick
        XCTAssertTrue(throttle.shouldRun(now: at(2), base: 2, decision: active))   // every base interval
        XCTAssertTrue(throttle.shouldRun(now: at(4), base: 2, decision: active))
    }

    func testThrottleStretchesWhenIdle() {
        var throttle = LoopThrottle()
        let idle = ThrottlePolicy.decide(mode: .idle)       // multiplier 4.0 → target 8s on base 2
        XCTAssertTrue(throttle.shouldRun(now: at(0), base: 2, decision: idle))     // first tick runs
        XCTAssertFalse(throttle.shouldRun(now: at(2), base: 2, decision: idle))    // 2s < 8s
        XCTAssertFalse(throttle.shouldRun(now: at(6), base: 2, decision: idle))    // 6s < 8s
        XCTAssertTrue(throttle.shouldRun(now: at(8), base: 2, decision: idle))     // 8s ≥ 8s → run
    }

    func testThrottleNeverRunsWhenPaused() {
        var throttle = LoopThrottle()
        let paused = ThrottlePolicy.decide(mode: .away)
        XCTAssertFalse(throttle.shouldRun(now: at(0), base: 2, decision: paused))
        XCTAssertFalse(throttle.shouldRun(now: at(100), base: 2, decision: paused))
    }

    func testThrottleResetFiresImmediately() {
        var throttle = LoopThrottle()
        let idle = ThrottlePolicy.decide(mode: .idle)
        XCTAssertTrue(throttle.shouldRun(now: at(0), base: 2, decision: idle))
        XCTAssertFalse(throttle.shouldRun(now: at(1), base: 2, decision: idle))
        throttle.reset()
        XCTAssertTrue(throttle.shouldRun(now: at(1), base: 2, decision: idle))     // reset → next runs
    }

    // MARK: - HeldRecommendationStore

    func testHeldStoreSingleSummaryAndDrain() {
        let store = HeldRecommendationStore()
        store.record(summary: "send a message to Mom", at: t0)
        XCTAssertEqual(store.count, 1)
        let line = store.drainSummary()
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("one suggestion"))
        XCTAssertTrue(line!.contains("send a message to Mom"))
        XCTAssertTrue(store.isEmpty)                 // drained
        XCTAssertNil(store.drainSummary())           // nothing left
    }

    func testHeldStoreMultipleSummary() {
        let store = HeldRecommendationStore()
        store.record(summary: "call Bob", at: t0)
        store.record(summary: "unlock the door", at: at(1))
        let line = store.drainSummary()!
        XCTAssertTrue(line.contains("2 suggestions"))
        XCTAssertTrue(line.contains("call Bob"))
        XCTAssertTrue(line.contains("unlock the door"))
    }

    func testHeldStoreCapsToMostRecent() {
        let store = HeldRecommendationStore(cap: 2)
        store.record(summary: "first", at: t0)
        store.record(summary: "second", at: at(1))
        store.record(summary: "third", at: at(2))
        XCTAssertEqual(store.count, 2)
        let line = store.drainSummary()!
        XCTAssertFalse(line.contains("first"))       // oldest dropped
        XCTAssertTrue(line.contains("second"))
        XCTAssertTrue(line.contains("third"))
    }

    // MARK: - PresenceMonitor re-engagement hook

    func testReEngageFiresWhenRisingFromIdle() {
        var age: TimeInterval = 600
        var voice = false
        let monitor = PresenceMonitor(
            thresholds: PresenceThresholds(activeWindow: 30, idleThreshold: 300, debounceDwell: 10),
            lastInteraction: { self.at(-age) }, voiceActive: { voice },
            connected: { true }, foreground: { true })

        var fired = 0
        monitor.onReEngage = { fired += 1 }

        // Settle to idle across the dwell.
        monitor.update(now: at(0))
        monitor.update(now: at(10))
        XCTAssertEqual(monitor.mode, .idle)
        XCTAssertEqual(fired, 0)

        // Re-engage by speaking → active → hook fires exactly once.
        voice = true; age = 0
        monitor.update(now: at(11))
        XCTAssertEqual(monitor.mode, .active)
        XCTAssertEqual(fired, 1)
    }

    func testReEngageDoesNotFireFromPresent() {
        var age: TimeInterval = 60      // present band
        let monitor = PresenceMonitor(
            thresholds: PresenceThresholds(activeWindow: 30, idleThreshold: 300, debounceDwell: 10),
            lastInteraction: { self.at(-age) }, voiceActive: { false },
            connected: { true }, foreground: { true })

        var fired = 0
        monitor.onReEngage = { fired += 1 }

        monitor.update(now: at(0))
        monitor.update(now: at(10))
        XCTAssertEqual(monitor.mode, .present)

        age = 0                          // interaction → active, but from present (not idle/away)
        monitor.update(now: at(11))
        XCTAssertEqual(monitor.mode, .active)
        XCTAssertEqual(fired, 0)         // present→active is not a "came back" event
    }
}
