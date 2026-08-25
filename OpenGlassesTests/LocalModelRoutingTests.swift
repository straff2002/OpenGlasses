import XCTest
@testable import OpenGlasses

/// Regression guard for on-device model routing, and for the prompt budget that keeps a turn
/// under the observed OOM point.
///
/// `visionModelIds` decides which factory `LocalLLMService.loadModel` tries first. Gemma 4 is in
/// that set because it *is* a VLM; what used to make that dangerous — a wrong token shape through
/// the VLM forward pass — is now keyed off `loadedViaVLMFactory`, the factory that actually
/// loaded, so a checkpoint that fails VLM weight mapping demotes to text without a shape mismatch.
@MainActor
final class LocalModelRoutingTests: XCTestCase {

    /// Attempt-and-demote (2026-07-16): Gemma 4 models ATTEMPT the VLM factory (they are
    /// architecturally VLMs) and demote to the text factory at runtime if the checkpoint's
    /// vision weights fail mapping. The old crash this test feared (wrong token shape through
    /// the VLM forward pass) is prevented by keying the shape off `loadedViaVLMFactory` — the
    /// factory that ACTUALLY loaded — not off nominal membership in `visionModelIds`.
    func testGemma4AttemptsVisionFactoryWithRuntimeDemotion() {
        XCTAssertTrue(LocalLLMService.visionModelIds.contains { $0.contains("gemma-4") },
                      "Gemma 4 must attempt the VLM factory so vision self-enables on a fixed runtime")
        XCTAssertTrue(LocalLLMService.visionModelIds.contains { $0.contains("SmolVLM") },
                      "the proven vision models stay on the VLM route")
    }

    /// The on-device prompt budget (BK P2) must sit below the observed OOM point (an ~8.2k-token
    /// prompt Jetsam-killed the app) yet leave headroom for a normal lean prompt + some history —
    /// for every recommended model and for an unknown/user-typed id.
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
