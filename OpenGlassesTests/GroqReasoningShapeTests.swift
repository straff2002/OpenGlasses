import XCTest
@testable import OpenGlasses

/// What a Chat Completions body carries to a Groq `gpt-oss` model, whose reasoning is drawn from
/// the same output cap as its answer. From Groq's reasoning guide as read 2026-10-10; not run
/// against a live key.
final class GroqReasoningShapeTests: XCTestCase {

    private func config(_ provider: LLMProvider, _ model: String, effort: ReasoningEffort? = nil) -> ModelConfig {
        var config = ModelConfig.defaultConfig(for: provider)
        config.model = model
        config.reasoningEffort = effort?.rawValue
        return config
    }

    func testReasoningTextIsNotRequestedFromGPTOSS() {
        typealias Row = (provider: LLMProvider, model: String, hidden: Bool)
        let rows: [Row] = [
            (.groq, "openai/gpt-oss-120b", true),
            (.groq, "openai/gpt-oss-20b", true),
            (.groq, "openai/gpt-oss-safeguard-20b", false),
            (.groq, "llama-3.3-70b-versatile", false),
            // `include_reasoning` is Groq's parameter: it is not sent to another host.
            (.openrouter, "openai/gpt-oss-120b", false),
            (.custom, "openai/gpt-oss-120b", false),
        ]
        for row in rows {
            var body: [String: Any] = ["model": row.model]
            LLMService.applyGroqReasoningVisibility(to: &body, provider: row.provider, model: row.model)
            XCTAssertEqual(body["include_reasoning"] as? Bool, row.hidden ? false : nil, "\(row.provider) \(row.model)")
            // Groq refuses `include_reasoning` together with `reasoning_format`.
            XCTAssertNil(body["reasoning_format"])
        }
    }

    /// The intent classifier asks for five tokens and the summariser for 512. On a model that
    /// reasons first, inside the same cap, neither would reach its answer.
    func testOneShotRequestsGetTheEffortAndARaisedCap() {
        for cap in [5, 512, 1024] {
            var body: [String: Any] = ["model": "openai/gpt-oss-120b", "max_tokens": cap]
            LLMService.applyGroqOneShotReasoning(to: &body, config: config(.groq, "openai/gpt-oss-120b"))
            XCTAssertEqual(body["max_tokens"] as? Int, ReasoningPolicy.groqLowEffortOutputFloor, "cap \(cap)")
            XCTAssertEqual(body["reasoning_effort"] as? String, "low")
            XCTAssertEqual(body["include_reasoning"] as? Bool, false)
        }
        // A cap already above the floor is left alone. A level saved for conversation is not
        // carried into a one-shot: the classifier has five seconds.
        var body: [String: Any] = ["model": "openai/gpt-oss-120b", "max_tokens": 6000,
                                   "tools": [["type": "function"]]]
        LLMService.applyGroqOneShotReasoning(to: &body, config: config(.groq, "openai/gpt-oss-120b", effort: .high))
        XCTAssertEqual(body["max_tokens"] as? Int, 6000)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    }

    /// The one retry at `none` exists for models that refuse reasoning with tools. These models
    /// refuse `none` itself, so the retry would only bury the provider's real error.
    func testARefusalIsNotRetriedAtAValueTheModelRejects() {
        let refusal = "reasoning_effort is not supported with tools for this model"
        XCTAssertFalse(ReasoningPolicy.chatModelAcceptsNone(provider: .groq, model: "openai/gpt-oss-120b"))
        XCTAssertFalse(ReasoningRejectionClassifier.shouldRetry(
            status: 400, message: refusal, sentEffort: "low",
            acceptsNone: ReasoningPolicy.chatModelAcceptsNone(provider: .groq, model: "openai/gpt-oss-120b")))
        // Everything else keeps its retry.
        for (provider, model) in [(LLMProvider.groq, "llama-3.3-70b-versatile"), (.openai, "gpt-6-sol"),
                                  (.openrouter, "openai/gpt-oss-120b"), (.custom, "anything")] {
            XCTAssertTrue(ReasoningPolicy.chatModelAcceptsNone(provider: provider, model: model), model)
            XCTAssertTrue(ReasoningRejectionClassifier.shouldRetry(
                status: 400, message: refusal, sentEffort: "low",
                acceptsNone: ReasoningPolicy.chatModelAcceptsNone(provider: provider, model: model)), model)
        }
    }

    func testOneShotRequestsToEveryOtherModelAreUnchanged() {
        let others: [ModelConfig] = [
            config(.groq, "llama-3.3-70b-versatile"),
            config(.groq, "qwen/qwen3.8-27b"),
            config(.openai, "gpt-5.5"),
            config(.openai, "gpt-4o"),
            config(.openrouter, "openai/gpt-oss-120b"),
            config(.custom, "openai/gpt-oss-120b", effort: .high),
        ]
        for config in others {
            var body: [String: Any] = ["model": config.model, "max_tokens": 5, "temperature": 0]
            LLMService.applyGroqOneShotReasoning(to: &body, config: config)
            XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "temperature"], "\(config.provider) \(config.model)")
            XCTAssertEqual(body["max_tokens"] as? Int, 5, "\(config.provider) \(config.model)")
        }
    }
}
