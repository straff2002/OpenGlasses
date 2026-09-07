import XCTest
@testable import OpenGlasses

/// Which providers get an OpenAI-style `tools` array attached to their request.
///
/// Issue 427: `.xai` and `.minimax` were added to the `sendOpenAICompatible` route but never to
/// the hand-written `||` chain that decided whether to attach tools, so a grok-4.6 turn logged
/// `turnStarted detail=nativeTools` while the request carried no tool definitions at all —
/// "take a photo" simply came back as prose. The predicate is now an exhaustive switch, and
/// these tests pin it to the routing table so the two can't drift again.
final class ProviderToolSupportTests: XCTestCase {

    /// Every provider whose `completeStateless` / `sendMessage` route is `sendOpenAICompatible`.
    /// Keep this list in step with those two switch statements in `LLMService`.
    private static let openAICompatibleRoute: [LLMProvider] = [
        .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom,
    ]

    /// Providers with their own request builder — they never reach this predicate.
    private static let ownRequestBuilder: [LLMProvider] = [
        .anthropic, .chatgpt, .gemini, .geminiVertex, .local, .appleOnDevice,
    ]

    func testEveryOpenAICompatibleProviderGetsTools() {
        for provider in Self.openAICompatibleRoute {
            XCTAssertTrue(
                LLMService.providerSupportsTools(provider, customEndpointRejectsTools: false),
                "\(provider.rawValue) routes to sendOpenAICompatible and must be handed tools"
            )
        }
    }

    /// The regression guard proper: the two providers issue 427 was actually about.
    func testXAIAndMiniMaxGetTools() {
        XCTAssertTrue(LLMService.providerSupportsTools(.xai, customEndpointRejectsTools: false))
        XCTAssertTrue(LLMService.providerSupportsTools(.minimax, customEndpointRejectsTools: false))
        // The remembered-rejection flag is about `.custom` alone and must not silence them.
        XCTAssertTrue(LLMService.providerSupportsTools(.xai, customEndpointRejectsTools: true))
        XCTAssertTrue(LLMService.providerSupportsTools(.minimax, customEndpointRejectsTools: true))
    }

    func testCustomEndpointLosesToolsOnceItHasRejectedThem() {
        XCTAssertTrue(LLMService.providerSupportsTools(.custom, customEndpointRejectsTools: false))
        XCTAssertFalse(LLMService.providerSupportsTools(.custom, customEndpointRejectsTools: true))
    }

    func testProvidersWithTheirOwnRequestBuilderAreNotHandedAnOpenAIToolsArray() {
        for provider in Self.ownRequestBuilder {
            XCTAssertFalse(
                LLMService.providerSupportsTools(provider, customEndpointRejectsTools: false),
                "\(provider.rawValue) builds its own request and never reaches this predicate"
            )
        }
    }

    /// Nothing may fall through the two lists — a newly added provider has to be classified.
    func testEveryProviderIsAccountedFor() {
        let classified = Set(Self.openAICompatibleRoute + Self.ownRequestBuilder)
        for provider in LLMProvider.allCases {
            XCTAssertTrue(classified.contains(provider),
                          "\(provider.rawValue) is unclassified — decide whether it takes tools")
        }
    }
}
