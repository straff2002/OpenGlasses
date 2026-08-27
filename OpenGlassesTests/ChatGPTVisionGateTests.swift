import XCTest
@testable import OpenGlasses

/// The ChatGPT (Codex/Responses) subscription provider's image-input acceptance was never
/// actually confirmed on device (docs/plans/BW P4's image-turn checklist item is still
/// unchecked), so `ChatGPTVisionGate` refuses a photo turn instead of sending it behind a
/// system prompt that insists the model can see. Pure decision logic — no network, no
/// `.shared` services, no `LLMService` instance required.
final class ChatGPTVisionGateTests: XCTestCase {

    func testChatGPTWithImageDeclinesVision() {
        let decision = ChatGPTVisionGate.decide(provider: .chatgpt, hasImage: true)
        guard case .declineVision(let message) = decision else {
            return XCTFail("expected .declineVision, got \(decision)")
        }
        XCTAssertEqual(message, ChatGPTVisionGate.declineMessage)
    }

    func testChatGPTWithoutImageIsUnaffected() {
        XCTAssertEqual(ChatGPTVisionGate.decide(provider: .chatgpt, hasImage: false), .sendWithImage)
    }

    func testNonChatGPTProvidersWithImageAreUnaffected() {
        // Representative of the other paths this fix must not touch: API-key OpenAI, an
        // on-device local model, and Gemini all still get their image sent normally.
        for provider: LLMProvider in [.openai, .gemini, .geminiVertex, .anthropic, .local, .appleOnDevice] {
            XCTAssertEqual(ChatGPTVisionGate.decide(provider: provider, hasImage: true), .sendWithImage,
                           "\(provider) must not be affected by the ChatGPT-only vision gate")
        }
    }

    func testDeclineMessageIsHonestAndPointsAtAlternativesWithoutJargon() {
        let message = ChatGPTVisionGate.declineMessage
        XCTAssertTrue(message.contains("can't see photos"), "must be honest about the limitation")
        XCTAssertTrue(message.contains("OpenAI API key"), "must name the API-key alternative")
        XCTAssertTrue(message.contains("Gemini"), "must name the Gemini alternative")
        XCTAssertTrue(message.contains("on-device"), "must name the on-device alternative")
        // No internal plan letters or codenames leaking into user-visible copy.
        XCTAssertFalse(message.lowercased().contains("plan "), "must not reference internal plan docs")
        XCTAssertFalse(message.lowercased().contains("codex"), "must not use internal/jargon model-family names")
    }
}
