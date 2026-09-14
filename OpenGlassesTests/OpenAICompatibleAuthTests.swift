import XCTest
@testable import OpenGlasses

/// Keyless `.custom` endpoints (self-hosted Ollama/LM Studio/bridges) must be sendable, not just
/// savable/listable — the send path previously hard-rejected every empty key.
final class OpenAICompatibleAuthTests: XCTestCase {

    func testKeylessCustomProducesNoAuthorizationHeader() throws {
        let auth = try LLMService.openAICompatibleAuthorization(provider: .custom, apiKey: "")
        XCTAssertNil(auth, "A keyless .custom request must build without an Authorization header")
    }

    func testKeyedCustomProducesBearerHeader() throws {
        let auth = try LLMService.openAICompatibleAuthorization(provider: .custom, apiKey: "sk-local")
        XCTAssertEqual(auth, "Bearer sk-local")
    }

    func testKeylessNonCustomProvidersStillThrowMissingAPIKey() {
        let providers: [LLMProvider] = [.openai, .groq, .deepseek, .xai, .openrouter, .zai, .qwen, .minimax]
        for provider in providers {
            XCTAssertThrowsError(
                try LLMService.openAICompatibleAuthorization(provider: provider, apiKey: ""),
                "\(provider) with an empty key must still throw"
            ) { error in
                guard case LLMError.missingAPIKey = error else {
                    return XCTFail("\(provider) threw \(error), expected missingAPIKey")
                }
            }
        }
    }

    func testKeyedProvidersProduceBearerHeader() throws {
        let auth = try LLMService.openAICompatibleAuthorization(provider: .groq, apiKey: "gsk_123")
        XCTAssertEqual(auth, "Bearer gsk_123")
    }
}
