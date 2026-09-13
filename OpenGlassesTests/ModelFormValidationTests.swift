import XCTest
@testable import OpenGlasses

final class ModelFormValidationTests: XCTestCase {
    private func canAdd(_ provider: LLMProvider, key: String = "", model: String = "model",
                        url: String = "http://mac.local:11434/v1", claude: Bool = false,
                        chatgpt: Bool = false, google: Bool = false) -> Bool {
        ModelFormValidation.canAdd(
            provider: provider, model: model, baseURL: url, apiKey: key,
            claudeConnected: claude, chatgptConnected: chatgpt, googleConnected: google
        )
    }

    func testAccountProvidersFollowTheirOwnConnectionState() {
        XCTAssertFalse(canAdd(.chatgpt))
        XCTAssertTrue(canAdd(.chatgpt, chatgpt: true))
        XCTAssertFalse(canAdd(.chatgpt, key: "stale-key", claude: true, google: true))
        XCTAssertFalse(canAdd(.geminiVertex))
        XCTAssertTrue(canAdd(.geminiVertex, google: true))
        XCTAssertFalse(canAdd(.geminiVertex, key: "stale-key", chatgpt: true))
        // Disconnection must disable Add again, even if the form still holds a model ID.
        XCTAssertFalse(canAdd(.chatgpt, chatgpt: false))
        XCTAssertFalse(canAdd(.geminiVertex, google: false))
    }

    func testClaudeAcceptsEitherAuthenticationRoute() {
        XCTAssertFalse(canAdd(.anthropic))
        XCTAssertTrue(canAdd(.anthropic, key: "key"))
        XCTAssertTrue(canAdd(.anthropic, claude: true))
        XCTAssertFalse(canAdd(.anthropic, chatgpt: true, google: true))
    }

    func testKeylessProvidersCanBeSaved() {
        for provider: LLMProvider in [.local, .appleOnDevice, .custom] {
            XCTAssertTrue(canAdd(provider), provider.rawValue)
        }
    }

    func testAPIProvidersStillRequireAKeyEvenWithAccountsConnected() {
        for provider: LLMProvider in [.openai, .gemini, .groq, .zai, .qwen, .minimax, .xai, .openrouter] {
            XCTAssertFalse(canAdd(provider, key: " \n", claude: true, chatgpt: true, google: true), provider.rawValue)
            XCTAssertTrue(canAdd(provider, key: "key"), provider.rawValue)
        }
    }

    func testModelsAndEditableEndpointsMustBeUsable() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(canAdd(provider, key: "key", model: " \n", claude: true,
                                  chatgpt: true, google: true), provider.rawValue)
        }
        for url in ["", "mac.local:11434", "file:///tmp/model", "https://"] {
            XCTAssertFalse(canAdd(.custom, url: url), url)
        }
        XCTAssertTrue(canAdd(.custom, url: "https://inference.example/v1"))
        XCTAssertTrue(canAdd(.appleOnDevice, url: ""))
    }
}
