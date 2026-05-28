import XCTest
@testable import OpenGlasses

/// Tests for Live Coach (Plan C) pure logic: domain parsing, per-domain prompts, and dedup
/// similarity. The frame loop itself (camera + live LLM) isn't unit-tested.
@MainActor
final class LiveCoachTests: XCTestCase {

    func testDomainParsingAliases() {
        XCTAssertEqual(LiveCoachDomain(rawValue: "posture"), .posture)
        XCTAssertEqual(LiveCoachDomain(rawValue: "sports"), .sportsTactics)
        XCTAssertEqual(LiveCoachDomain(rawValue: "COOKING"), .cookingForm)
        XCTAssertNil(LiveCoachDomain(rawValue: "underwater_basket_weaving"))
    }

    func testDomainPromptRespectsMaxWords() {
        let prompt = LiveCoachDomain.posture.systemPrompt(maxWords: 12, customPrompt: nil)
        XCTAssertTrue(prompt.contains("12 words"))
        XCTAssertTrue(prompt.lowercased().contains("spine"))
    }

    func testCustomDomainUsesCustomPrompt() {
        let prompt = LiveCoachDomain.custom.systemPrompt(maxWords: 20, customPrompt: "Watch my pottery wheel centering.")
        XCTAssertTrue(prompt.contains("pottery wheel centering"))
    }

    func testDedupTreatsNearIdenticalAsSimilar() {
        XCTAssertTrue(LiveCoachService.isSimilar("Straighten your back and relax shoulders",
                                                 "Straighten your back, relax your shoulders"))
    }

    func testDedupTreatsDifferentAdviceAsDistinct() {
        XCTAssertFalse(LiveCoachService.isSimilar("Straighten your back",
                                                  "Move your left foot to the higher hold"))
    }

    func testNotConfiguredByDefaultDoesNotCrashStatus() {
        XCTAssertEqual(LiveCoachService.shared.statusSummary(), "Live Coach is not running.")
    }
}
