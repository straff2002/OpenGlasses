import XCTest
@testable import OpenGlasses

/// Plan GB P0 — usage and safety: cached input billed once, the GPT-5.x / GPT-6 price rows, the
/// Responses path's cached tokens, and HIPAA-disabled tools kept out of the declarations.
final class UsageCachedTokenTests: XCTestCase {

    func testOpenAIPromptWithCachedShareIsBilledOnce() throws {
        // 1,000-token prompt, 400 cached: 600 × rate + 400 × rate × 0.1 (+ output).
        let json: [String: Any] = ["usage": ["prompt_tokens": 1_000, "completion_tokens": 0,
                                             "prompt_tokens_details": ["cached_tokens": 400]]]
        let u = try XCTUnwrap(UsageTracker.parseUsage(provider: .openai, json: json))
        XCTAssertEqual(u.tokensIn, 600)
        XCTAssertEqual(u.cacheReadTokens, 400)
        let cost = try XCTUnwrap(ModelPricing.estimate(model: "gpt-5.5", tokensIn: u.tokensIn, tokensOut: 0,
                                                       cacheReadTokens: u.cacheReadTokens))
        let rate = 5.0 / 1_000_000
        XCTAssertEqual(cost, 600 * rate + 400 * rate * 0.1, accuracy: 1e-12)
    }

    func testGeminiPromptCountExcludesCachedShare() throws {
        let json: [String: Any] = ["usageMetadata": ["promptTokenCount": 900, "candidatesTokenCount": 10,
                                                     "cachedContentTokenCount": 300]]
        let u = try XCTUnwrap(UsageTracker.parseUsage(provider: .gemini, json: json))
        XCTAssertEqual(u.tokensIn, 600)
        XCTAssertEqual(u.cacheReadTokens, 300)
    }

    func testResponsesPathParsesCachedTokens() throws {
        let json: [String: Any] = ["usage": ["input_tokens": 30_700, "output_tokens": 120,
                                             "input_tokens_details": ["cached_tokens": 10_100]]]
        let u = try XCTUnwrap(UsageTracker.parseUsage(provider: .chatgpt, json: json))
        XCTAssertEqual(u.tokensIn, 20_600)
        XCTAssertEqual(u.cacheReadTokens, 10_100)
        XCTAssertTrue(u.recognized)
    }

    func testAnthropicInputIsUnchanged() throws {
        let json: [String: Any] = ["usage": ["input_tokens": 10, "output_tokens": 2,
                                             "cache_read_input_tokens": 500]]
        let u = try XCTUnwrap(UsageTracker.parseUsage(provider: .anthropic, json: json))
        XCTAssertEqual(u.tokensIn, 10)
        XCTAssertEqual(u.cacheReadTokens, 500)
    }

    func testStreamedOpenAIUsageSubtractsCachedShare() {
        var acc = StreamingUsageAccumulator()
        acc.consumeOpenAI(["choices": [], "usage": ["prompt_tokens": 1_000, "completion_tokens": 8,
                                                    "prompt_tokens_details": ["cached_tokens": 400]]])
        XCTAssertEqual(acc.tokensIn, 600)
        XCTAssertEqual(acc.cacheReadTokens, 400)
    }

    func testFieldTesterBillReproduces() throws {
        // One average request from the bill: ~30.7k input, 33% cached, a short answer.
        let cost = try XCTUnwrap(ModelPricing.estimate(model: "gpt-5.5", tokensIn: 20_570, tokensOut: 100,
                                                       cacheReadTokens: 10_130))
        XCTAssertEqual(cost, 20_570 * 5e-6 + 10_130 * 0.5e-6 + 100 * 30e-6, accuracy: 1e-9)
    }

    func testNewPriceRows() {
        XCTAssertEqual(ModelPricing.rate(for: "gpt-5.5"), ModelPricing.Rate(5, 30, cached: 0.50))
        XCTAssertEqual(ModelPricing.rate(for: "gpt-6-sol"), ModelPricing.Rate(2, 10, cached: 0.20))
        XCTAssertEqual(ModelPricing.rate(for: "gpt-5.6-sol"), ModelPricing.Rate(4, 20, cached: 0.40))
        XCTAssertNotNil(ModelPricing.rate(for: "gpt-5-2025-08-07"))
        // A variant that isn't listed stays unpriced rather than borrowing a sibling's rate.
        XCTAssertNil(ModelPricing.rate(for: "gpt-5.5-pro"))
        XCTAssertNil(ModelPricing.rate(for: "gpt-6-nova"))
    }

    func testPublishedCachedRateBeatsGenericMultiplier() throws {
        // gpt-6.1-sol caches at $0.10 on a $2 input rate — 0.05×, not 0.1×.
        let cost = try XCTUnwrap(ModelPricing.estimate(model: "gpt-6.1-sol", tokensIn: 0, tokensOut: 0,
                                                       cacheReadTokens: 1_000_000))
        XCTAssertEqual(cost, 0.10, accuracy: 1e-12)
    }

    func testLegacyPricingOverrideDecodes() throws {
        let legacy = #"{"my-model":{"inputPer1M":1,"outputPer1M":2}}"#
        let decoded = try JSONDecoder().decode([String: ModelPricing.Rate].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded["my-model"], ModelPricing.Rate(1, 2))
    }

    @MainActor
    func testSubscriptionUsageRecordsTokensWithoutCost() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).sqlite")
        let tracker = UsageTracker(store: UsageStore(path: url))
        tracker.record(provider: .chatgpt, model: "gpt-5.5", tokensIn: 100, tokensOut: 10)
        let row = try XCTUnwrap(tracker.store.records(since: .distantPast).first)
        XCTAssertNil(row.costUSD)
        XCTAssertEqual(row.tokensIn, 100)
    }

    // MARK: - HIPAA declarations

    func testHIPAADisabledToolsAreNotDeclared() {
        let names = ["web_search", "send_message", "get_weather", "phone_call"]
        let hipaa: Set<String> = ["send_message", "phone_call"]
        XCTAssertEqual(ToolDeclarations.declarableNames(names, isEnabled: { _ in true },
                                                        hipaaMode: true, hipaaDisabled: hipaa),
                       ["get_weather", "web_search"])
        XCTAssertEqual(ToolDeclarations.declarableNames(names, isEnabled: { $0 != "get_weather" },
                                                        hipaaMode: false, hipaaDisabled: hipaa),
                       ["phone_call", "send_message", "web_search"])
    }
}
