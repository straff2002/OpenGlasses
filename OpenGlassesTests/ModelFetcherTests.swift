import XCTest
@testable import OpenGlasses

/// Pure-logic coverage for the Custom / self-hosted-local-server plumbing:
/// the models-endpoint URL derivation and the vision inference heuristic.
/// Network I/O is deliberately untested — the string logic is the bug surface.
final class ModelFetcherTests: XCTestCase {

    // MARK: - modelsEndpoint(from:)

    func testModelsEndpointFromChatCompletionsURL() {
        // …/v1/chat/completions → …/v1/models (the OpenAI-style base URL the app stores)
        XCTAssertEqual(
            ModelFetcher.modelsEndpoint(from: "https://api.openai.com/v1/chat/completions"),
            "https://api.openai.com/v1/models"
        )
    }

    func testModelsEndpointFromV1Suffix() {
        // …/v1 → …/v1/models (the typical Ollama / LM Studio base, e.g. http://host.local:11434/v1)
        XCTAssertEqual(
            ModelFetcher.modelsEndpoint(from: "http://my-mac.local:11434/v1"),
            "http://my-mac.local:11434/v1/models"
        )
    }

    func testModelsEndpointFromBareHost() {
        // Bare host → /models
        XCTAssertEqual(
            ModelFetcher.modelsEndpoint(from: "http://my-mac.local:11434"),
            "http://my-mac.local:11434/models"
        )
    }

    func testModelsEndpointTrimsTrailingSlashOnBareHost() {
        XCTAssertEqual(
            ModelFetcher.modelsEndpoint(from: "http://my-mac.local:11434/"),
            "http://my-mac.local:11434/models"
        )
    }

    func testModelsEndpointPrefersLastV1Segment() {
        // The `.backwards` search anchors on the final /v1/ occurrence.
        XCTAssertEqual(
            ModelFetcher.modelsEndpoint(from: "https://proxy.example.com/v1/openai/v1/chat/completions"),
            "https://proxy.example.com/v1/openai/v1/models"
        )
    }

    // MARK: - ChatGPT account catalog

    func testParsesDocumentedAppServerModelListShape() throws {
        let json = #"""
        {
          "data": [
            {
              "id": "gpt-5.6-sol",
              "displayName": "GPT-5.6-Sol",
              "hidden": false,
              "isDefault": true,
              "inputModalities": ["text", "image"]
            },
            { "id": "hidden-model", "displayName": "Hidden", "hidden": true }
          ]
        }
        """#
        let models = ModelFetcher.parseChatGPTModels(Data(json.utf8))

        XCTAssertEqual(models.map(\.id), ["gpt-5.6-sol"])
        XCTAssertEqual(models.first?.name, "GPT-5.6-Sol")
        XCTAssertEqual(models.first?.isDefault, true)
        XCTAssertEqual(models.first?.inputModalities, ["text", "image"])
    }

    func testParsesSnakeCaseAccountCatalogAndDeduplicates() {
        let json = #"""
        {
          "models": [
            {
              "slug": "gpt-5.6-terra",
              "display_name": "GPT-5.6-Terra",
              "is_default": true,
              "input_modalities": ["text", "image"]
            },
            { "model": "gpt-5.6-terra", "display_name": "Duplicate" },
            { "model": "gpt-5.6-luna" }
          ]
        }
        """#
        let models = ModelFetcher.parseChatGPTModels(Data(json.utf8))

        XCTAssertEqual(models.map(\.id), ["gpt-5.6-terra", "gpt-5.6-luna"])
        XCTAssertEqual(models.map(\.name), ["GPT-5.6-Terra", "gpt-5.6-luna"])
    }

    func testChatGPTDefaultIsCurrentPreDiscoveryFallback() {
        XCTAssertEqual(ChatGPTOAuth.defaultModel, "gpt-5.6-sol")
    }

    // MARK: - xAI provider defaults

    func testXAIProviderDefaults() {
        let config = ModelConfig.defaultConfig(for: .xai)
        XCTAssertEqual(config.baseURL, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(config.model, "grok-4")
        XCTAssertTrue(LLMProvider.xai.isOpenAICompatible)
        XCTAssertTrue(LLMProvider.xai.requiresAPIKey)
        XCTAssertEqual(
            ModelFetcher.modelsEndpoint(from: LLMProvider.xai.defaultBaseURL),
            "https://api.x.ai/v1/models"
        )
    }

    // MARK: - ModelConfig.inferredSupportsVision

    private func inferredVision(_ provider: LLMProvider, _ model: String, baseURL: String = "") -> Bool {
        ModelConfig.inferredSupportsVision(provider: provider, model: model, baseURL: baseURL)
    }

    func testInferredVisionCustomVisionModels() {
        // A keyless local server commonly runs a vision model — these should default Vision on.
        XCTAssertTrue(inferredVision(.custom, "llava"))
        XCTAssertTrue(inferredVision(.custom, "pixtral-12b"))
        XCTAssertTrue(inferredVision(.custom, "minicpm-v"))
        XCTAssertTrue(inferredVision(.custom, "qwen2.5-vl-7b"))
    }

    func testInferredVisionCustomTextOnlyModel() {
        // A bare text model on the Custom provider should default Vision off.
        XCTAssertFalse(inferredVision(.custom, "llama3.1:8b"))
        XCTAssertFalse(inferredVision(.custom, "mistral-7b"))
    }

    func testInferredVisionAlwaysOnProviders() {
        XCTAssertTrue(inferredVision(.anthropic, "claude-anything"))
        XCTAssertTrue(inferredVision(.gemini, "gemini-2.0-flash"))
        XCTAssertTrue(inferredVision(.openai, "gpt-4o-mini"))
    }

    func testInferredVisionAlwaysOffProviders() {
        XCTAssertFalse(inferredVision(.groq, "llama-3.1-70b"))
        XCTAssertFalse(inferredVision(.local, "gemma-2b"))
        XCTAssertFalse(inferredVision(.appleOnDevice, "apple"))
    }

    func testInferredVisionQwenHeuristic() {
        XCTAssertTrue(inferredVision(.qwen, "qwen-vl-max"))
        XCTAssertTrue(inferredVision(.qwen, "qwen-omni"))
        XCTAssertFalse(inferredVision(.qwen, "qwen-turbo"))
    }

    func testInferredVisionOpenRouterHeuristic() {
        XCTAssertTrue(inferredVision(.openrouter, "anthropic/claude-3.5-sonnet"))
        // xAI: Grok 4 family is multimodal, earlier text models are not
        XCTAssertTrue(inferredVision(.xai, "grok-4"))
        XCTAssertTrue(inferredVision(.xai, "grok-4-fast"))
        XCTAssertFalse(inferredVision(.xai, "grok-3-mini"))
        XCTAssertTrue(inferredVision(.openrouter, "meta-llama/llava-13b"))
        XCTAssertFalse(inferredVision(.openrouter, "mistralai/mistral-7b"))
    }
}
