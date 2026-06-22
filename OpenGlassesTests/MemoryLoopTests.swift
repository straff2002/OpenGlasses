import XCTest
@testable import OpenGlasses

/// Headless tests for the Memory & Recall Phase 3 self-improving loop. `decide(...)` takes the
/// flags as parameters (no Config / no singletons / no TTS), so the nudge-vs-auto-save vs
/// presence vs cooldown logic is fully deterministic and unit-tested.
@MainActor
final class MemoryLoopTests: XCTestCase {

    private func service() -> MemoryLoopService {
        MemoryLoopService(skillDetector: SkillPatternDetector(threshold: 3), nudgeCooldownTurns: 4)
    }

    private let fact = CompletedTurn(userText: "My daughter's name is Mia")
    private let neutral = CompletedTurn(userText: "thanks, that's all")

    // MARK: - Facts

    func testFactAutoSavedInAgentMode() {
        let actions = service().decide(turn: fact, nudgesEnabled: false, agentMode: true, present: false)
        XCTAssertEqual(actions, [.saveFact("My daughter's name is Mia")])
    }

    func testFactNudgedWhenEnabledAndPresent() {
        let actions = service().decide(turn: fact, nudgesEnabled: true, agentMode: false, present: true)
        guard case .nudgeFact = actions.first else { return XCTFail("expected a fact nudge") }
    }

    func testFactNotNudgedWhenAway() {
        let actions = service().decide(turn: fact, nudgesEnabled: true, agentMode: false, present: false)
        XCTAssertTrue(actions.isEmpty)
    }

    func testNothingWhenAllOff() {
        XCTAssertTrue(service().decide(turn: fact, nudgesEnabled: false, agentMode: false, present: true).isEmpty)
    }

    func testNeutralTurnProducesNothing() {
        XCTAssertTrue(service().decide(turn: neutral, nudgesEnabled: true, agentMode: true, present: true).isEmpty)
    }

    // MARK: - Cooldown

    func testNudgeCooldownSuppressesConsecutive() {
        let s = service()
        let first = s.decide(turn: fact, nudgesEnabled: true, agentMode: false, present: true)
        guard case .nudgeFact = first.first else { return XCTFail("first should nudge") }
        // Immediately again — within the 4-turn cooldown → suppressed.
        XCTAssertTrue(s.decide(turn: fact, nudgesEnabled: true, agentMode: false, present: true).isEmpty)
    }

    // MARK: - Skills

    func testSkillNudgedAfterThreshold() {
        let s = service()
        let tools = ["get_weather", "get_news"]
        let t = CompletedTurn(userText: "give me my morning brief", toolNames: tools)
        XCTAssertTrue(s.decide(turn: t, nudgesEnabled: true, agentMode: false, present: true).isEmpty)
        XCTAssertTrue(s.decide(turn: t, nudgesEnabled: true, agentMode: false, present: true).isEmpty)
        let third = s.decide(turn: t, nudgesEnabled: true, agentMode: false, present: true)
        guard case .nudgeSkill = third.first else { return XCTFail("expected a skill nudge on the 3rd repeat") }
    }

    func testSkillAutoSavedInAgentMode() {
        let s = service()
        let tools = ["calendar", "reminder"]
        let t = CompletedTurn(userText: "set up my day", toolNames: tools)
        _ = s.decide(turn: t, nudgesEnabled: false, agentMode: true, present: false)
        _ = s.decide(turn: t, nudgesEnabled: false, agentMode: true, present: false)
        let third = s.decide(turn: t, nudgesEnabled: false, agentMode: true, present: false)
        guard case let .saveSkill(trigger, instruction) = third.first else {
            return XCTFail("expected a skill save on the 3rd repeat")
        }
        XCTAssertEqual(trigger, "set up my day")
        XCTAssertTrue(instruction.contains("calendar"))
    }

    func testSingleToolNeverSuggestsSkill() {
        let s = service()
        let t = CompletedTurn(userText: "set a timer", toolNames: ["set_timer"])
        for _ in 0..<5 {
            XCTAssertTrue(s.decide(turn: t, nudgesEnabled: true, agentMode: true, present: true).isEmpty)
        }
    }

    func testTriggerPhraseClipsToSixWords() {
        XCTAssertEqual(MemoryLoopService.triggerPhrase(from: "Give Me My Morning Brief Please Now Quickly"),
                       "give me my morning brief please")
    }
}
