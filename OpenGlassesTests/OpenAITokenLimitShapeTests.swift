import XCTest
@testable import OpenGlasses

/// OpenAI's current models reject `max_tokens` with a 400 ("Use 'max_completion_tokens'
/// instead"), which failed every turn to them. `applyOpenAITokenLimitShape` renames the field for
/// requests that reach OpenAI and must leave every other OpenAI-compatible provider alone, since
/// several of them only know `max_tokens`.
final class OpenAITokenLimitShapeTests: XCTestCase {

    private func body() -> [String: Any] {
        ["model": "m", "max_tokens": 500, "messages": [["role": "user", "content": "hi"]]]
    }

    func testOpenAIRequestsUseMaxCompletionTokens() {
        var body = body()
        LLMService.applyOpenAITokenLimitShape(to: &body, provider: .openai,
                                              baseURL: "https://api.openai.com/v1/chat/completions")
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 500)
        XCTAssertEqual(Set(body.keys), ["model", "max_completion_tokens", "messages"])
    }

    func testCustomEndpointsPointedAtOpenAIAreRenamed() {
        for url in ["https://api.openai.com/v1", "https://myco.openai.azure.com/openai/deployments/x"] {
            var body = body()
            LLMService.applyOpenAITokenLimitShape(to: &body, provider: .custom, baseURL: url)
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 500, url)
            XCTAssertNil(body["max_tokens"], url)
        }
    }

    func testOtherProvidersKeepMaxTokens() {
        let cases: [(LLMProvider, String)] = [
            (.groq, "https://api.groq.com/openai/v1"),
            (.openrouter, "https://openrouter.ai/api/v1"),
            (.mistral, "https://api.mistral.ai/v1"),
            (.deepseek, "https://api.deepseek.com/v1"),
            (.custom, "http://192.168.1.20:11434/v1"),
        ]
        for (provider, url) in cases {
            var body = body()
            LLMService.applyOpenAITokenLimitShape(to: &body, provider: provider, baseURL: url)
            XCTAssertEqual(body["max_tokens"] as? Int, 500, provider.rawValue)
            XCTAssertNil(body["max_completion_tokens"], provider.rawValue)
        }
    }

    func testABodyWithoutALimitIsUntouched() {
        var body: [String: Any] = ["model": "m", "messages": []]
        LLMService.applyOpenAITokenLimitShape(to: &body, provider: .openai, baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(Set(body.keys), ["model", "messages"])
    }

    func testMaskedKeySummaryShowsOnlyTheLastFour() {
        XCTAssertEqual(SecretInputField.maskedSummary(of: "sk-proj-abcdefghijWXYZ"), "••••••••WXYZ")
        XCTAssertEqual(SecretInputField.maskedSummary(of: " sk-proj-abcdefghijWXYZ\n"), "••••••••WXYZ")
        XCTAssertEqual(SecretInputField.maskedSummary(of: "short"), "••••••••")
    }
}
