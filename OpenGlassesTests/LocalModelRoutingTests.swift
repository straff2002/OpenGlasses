import XCTest
@testable import OpenGlasses

/// Regression guard for on-device model routing. Gemma 4 loads through the VLM factory
/// (vision + tools) and generates via `Gemma4Processor.prepare` — not hand-built tokens.
@MainActor
final class LocalModelRoutingTests: XCTestCase {

    func testGemma4AttemptsVisionFactoryWithRuntimeDemotion() {
        XCTAssertTrue(LocalLLMService.visionModelIds.contains { $0.contains("gemma-4") },
                      "Gemma 4 must load through the VLM factory for vision")
        XCTAssertTrue(LocalLLMService.visionModelIds.contains { $0.contains("SmolVLM") })
    }

    func testOnDevicePromptBudgetIsBelowTheObservedOOMPoint() {
        let ids = LocalLLMService.recommendedModels.map(\.id) + [nil, "some/unknown-model"]
        for id in ids {
            let budget = LocalModelBudget.promptBudget(for: id)
            XCTAssertLessThan(budget, 8241,
                              "budget for \(id ?? "nil") must sit below the OOM point")
            XCTAssertGreaterThanOrEqual(budget, 2048,
                              "budget for \(id ?? "nil") must leave headroom for a lean prompt + history")
        }
    }

    func testPromptTooLongErrorIsDescriptive() {
        let msg = LocalLLMError.promptTooLong(tokens: 9000, limit: 4096).errorDescription ?? ""
        XCTAssertTrue(msg.contains("9000") && msg.contains("4096"))
        XCTAssertTrue(msg.lowercased().contains("cloud"), "tell the user the actionable fallback")
    }
}
