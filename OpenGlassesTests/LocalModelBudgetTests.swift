import XCTest
@testable import OpenGlasses

/// BK P2 — the on-device prompt budget is now derived per model (window − generation reserve −
/// margin) and the caller truncates oldest-history-first to fit, only hard-failing when the
/// minimal prompt (system + current turn) can't fit any window. All pure/headless.
final class LocalModelBudgetTests: XCTestCase {

    // MARK: - Budget calculation

    func testBudgetSubtractsGenerationReserveAndMargin() {
        // The concrete review example: a 4096 window must NOT admit a 4096-token prompt, or
        // prompt + 512 generated tokens overflows mid-stream.
        let budget = LocalModelBudget.promptBudget(contextWindow: 4096)
        XCTAssertEqual(budget, 4096 - LocalModelBudget.generationReserve - LocalModelBudget.safetyMargin)
        XCTAssertLessThan(budget, 4096, "must leave room for the model's own 512-token output")
    }

    func testUnknownModelFallsBackToConservativeDefault() {
        XCTAssertEqual(LocalModelBudget.contextWindow(for: "some/model-nobody-knows"),
                       LocalModelBudget.defaultContextWindow)
        XCTAssertEqual(LocalModelBudget.contextWindow(for: nil),
                       LocalModelBudget.defaultContextWindow)
    }

    func testKnownModelUsesItsTableWindow() {
        // A tiny model gets a larger memory-safe window than the conservative default.
        XCTAssertGreaterThan(
            LocalModelBudget.contextWindow(for: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
            LocalModelBudget.defaultContextWindow)
    }

    func testBudgetNeverGoesBelowFloor() {
        // A mis-entered tiny window can't produce a zero/negative budget that rejects everything.
        XCTAssertEqual(LocalModelBudget.promptBudget(contextWindow: 10),
                       LocalModelBudget.minimumBudget)
    }

    // MARK: - Reasoning-model reserve (LFM2.5)

    func testReasoningModelGetsLargerGenerationReserve() {
        // The think block spends from the same cap as the answer — 512 exhausts mid-think.
        let lfm = "LiquidAI/LFM2.5-2.6B-MLX-4bit"
        XCTAssertTrue(LocalModelBudget.reasoningModelIds.contains(lfm))
        XCTAssertEqual(LocalModelBudget.generationReserve(for: lfm),
                       LocalModelBudget.reasoningGenerationReserve)
        XCTAssertGreaterThan(LocalModelBudget.reasoningGenerationReserve,
                             LocalModelBudget.generationReserve)
    }

    func testNonReasoningModelKeepsDefaultReserve() {
        XCTAssertEqual(LocalModelBudget.generationReserve(for: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
                       LocalModelBudget.generationReserve)
        XCTAssertEqual(LocalModelBudget.generationReserve(for: nil),
                       LocalModelBudget.generationReserve)
    }

    func testReasoningModelPromptBudgetSubtractsItsOwnReserve() {
        // Budget must shrink by the REASONING reserve, or prompt + think + answer overflows
        // the window mid-stream (the uncatchable per-token OOM the budget exists to prevent).
        let lfm = "LiquidAI/LFM2.5-2.6B-MLX-4bit"
        XCTAssertEqual(LocalModelBudget.promptBudget(for: lfm),
                       LocalModelBudget.contextWindow(for: lfm)
                           - LocalModelBudget.reasoningGenerationReserve
                           - LocalModelBudget.safetyMargin)
    }

    // MARK: - Truncation: drop oldest history first

    /// Each history turn counts as 10 tokens; system + user baseline is 20. Lets us drive the
    /// pure truncation loop deterministically without a real tokenizer.
    private func fakeCount(_ hist: [(role: String, content: String)]) -> Int {
        20 + hist.count * 10
    }

    func testUnderBudgetKeepsAllHistory() throws {
        let history = [("user", "a"), ("assistant", "b")].map { (role: $0.0, content: $0.1) }
        let kept = try LocalModelBudget.historyFittingBudget(history: history, budget: 100) {
            fakeCount($0)
        }
        XCTAssertEqual(kept.count, 2)
    }

    func testOverBudgetDropsOldestFirstUntilFits() throws {
        // 5 turns → 20 + 50 = 70 tokens. Budget 40 admits (40-20)/10 = 2 turns.
        let history = (0..<5).map { (role: "user", content: "turn\($0)") }
        let kept = try LocalModelBudget.historyFittingBudget(history: history, budget: 40) {
            fakeCount($0)
        }
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.map(\.content), ["turn3", "turn4"],
                       "oldest dropped, the most recent turns are preserved")
        XCTAssertLessThanOrEqual(fakeCount(kept), 40)
    }

    func testMinimalPromptStillTooBigThrowsPromptTooLong() {
        // Baseline (system + current turn) alone is 20 tokens; a budget of 15 can never fit.
        let history = [(role: "user", content: "x")]
        XCTAssertThrowsError(
            try LocalModelBudget.historyFittingBudget(history: history, budget: 15) { fakeCount($0) }
        ) { error in
            guard case LocalLLMError.promptTooLong = error else {
                return XCTFail("expected .promptTooLong, got \(error)")
            }
        }
    }

    // MARK: - Download size parsing (drives the byte-based progress bar)

    @MainActor
    func testExpectedDownloadBytesParsesCatalogSizes() {
        // Every catalog entry must parse — a nil here silently reverts that model's download
        // bar to the useless per-file hub fraction.
        for model in LocalLLMService.recommendedModels {
            let bytes = LocalLLMService.expectedDownloadBytes(for: model.id)
            XCTAssertNotNil(bytes, "catalog size failed to parse: \(model.id) (\(model.estimatedSize))")
            XCTAssertGreaterThan(bytes ?? 0, 100_000_000, "implausibly small for \(model.id)")
        }
        // Spot-check the arithmetic: "5.1 GB" → 5.1 × 2^30.
        XCTAssertEqual(LocalLLMService.expectedDownloadBytes(for: "mlx-community/gemma-4-e4b-it-4bit"),
                       Int64(5.1 * 1_073_741_824))
    }

    @MainActor
    func testExpectedDownloadBytesNilForUnknownModel() {
        XCTAssertNil(LocalLLMService.expectedDownloadBytes(for: "someone/custom-model-4bit"),
                     "custom ids have no expected size — hub fraction is the fallback")
    }
}
