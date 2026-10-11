import XCTest
@testable import OpenGlasses

final class PhotoPrefillAdmissionTests: XCTestCase {
    func testTheCapturedCrashPromptCannotEnterGemmaPrefill() {
        // Actual phone report: 7,305 processed tokens, 3,093 MiB available, 12 GB device.
        let plan = LocalModelBudget.multimodalTurnPlan(
            for: "mlx-community/gemma-4-e2b-it-4bit", marketingRAMGB: 12,
            availableBytes: 3_093 * 1_048_576)
        let budget = LocalModelBudget.gemmaPhotoPrefillBudget(
            promptBudget: plan.promptBudget, availableBytes: 3_093 * 1_048_576)
        XCTAssertEqual(budget, 1_034)
        XCTAssertEqual(LocalModelBudget.photoPromptAction(
            tokens: 7_305, budget: budget, historyCount: 0, usesCompactSystem: false), .compactSystem)
        XCTAssertEqual(LocalModelBudget.photoPromptAction(
            tokens: 7_305, budget: budget, historyCount: 0, usesCompactSystem: true), .refuse)
    }

    func testHistoryIsRemovedBeforeTheSystemPromptIsCompacted() {
        XCTAssertEqual(LocalModelBudget.photoPromptAction(
            tokens: 1_500, budget: 1_024, historyCount: 2, usesCompactSystem: false), .dropOldestHistory)
        XCTAssertEqual(LocalModelBudget.photoPromptAction(
            tokens: 900, budget: 1_024, historyCount: 0, usesCompactSystem: true), .generate)
        XCTAssertEqual(LocalModelBudget.photoPromptAction(
            tokens: 1_024, budget: 1_024, historyCount: 0, usesCompactSystem: false), .generate)
    }

    func testMemoryPressureAndUnknownBudgetsAreHandled() {
        XCTAssertEqual(LocalModelBudget.gemmaPhotoPrefillBudget(promptBudget: 3_456, availableBytes: 0), 3_456)
        XCTAssertEqual(LocalModelBudget.gemmaPhotoPrefillBudget(
            promptBudget: 3_456, availableBytes: 512 * 1_048_576), 0)
        XCTAssertEqual(LocalModelBudget.gemmaPhotoPrefillBudget(
            promptBudget: 3_456, availableBytes: 16_384 * 1_048_576), 3_456)
        XCTAssertEqual(LocalModelBudget.photoPromptAction(
            tokens: 256, budget: 0, historyCount: 0, usesCompactSystem: true), .refuse)
    }
}
