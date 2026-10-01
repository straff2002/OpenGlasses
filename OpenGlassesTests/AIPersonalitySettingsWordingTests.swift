import XCTest
@testable import OpenGlasses

/// How the AI & Personality screen speaks a model row and badges its auth state. (These lived with
/// the settings journey's tests until Plan HA removed the journey.)
final class AIPersonalitySettingsWordingTests: XCTestCase {

    func testModelRowSaysKeyStateInWords() {
        XCTAssertEqual(
            AIPersonalitySettingsScreen.spokenModelRow(
                name: "Claude Sonnet", provider: "Anthropic",
                badge: .init(label: "Key set", isReady: true), vision: true),
            "Claude Sonnet, Anthropic, vision enabled, Key set"
        )
        XCTAssertEqual(
            AIPersonalitySettingsScreen.spokenModelRow(
                name: "Local", provider: "On-device",
                badge: .init(label: "On-device", isReady: true), vision: false),
            "Local, On-device, On-device"
        )
        XCTAssertEqual(
            AIPersonalitySettingsScreen.spokenModelRow(
                name: "ChatGPT", provider: "ChatGPT (Subscription)",
                badge: .init(label: "Not signed in", isReady: false), vision: false),
            "ChatGPT, ChatGPT (Subscription), needs setup: Not signed in"
        )
    }

    /// Auth is key OR account OR on-device; the badge must never warn about a provider that
    /// cannot take the missing thing.
    func testModelAuthBadgeTruthTable() {
        func badge(_ p: LLMProvider, key: Bool = false, claude: Bool = false,
                   chatgpt: Bool = false, google: Bool = false)
            -> AIPersonalitySettingsScreen.ModelAuthBadge {
            AIPersonalitySettingsScreen.modelAuthBadge(
                provider: p, hasKey: key, claudeConnected: claude,
                chatgptConnected: chatgpt, googleConnected: google)
        }
        // On-device providers are always ready and never mention keys.
        XCTAssertEqual(badge(.local), .init(label: "On-device", isReady: true))
        XCTAssertEqual(badge(.appleOnDevice), .init(label: "On-device", isReady: true))
        // Subscription providers report the account, not a key.
        XCTAssertEqual(badge(.chatgpt, chatgpt: true),
                       .init(label: "ChatGPT account connected", isReady: true))
        XCTAssertEqual(badge(.chatgpt), .init(label: "Not signed in", isReady: false))
        XCTAssertEqual(badge(.geminiVertex, google: true),
                       .init(label: "Google account connected", isReady: true))
        XCTAssertEqual(badge(.geminiVertex), .init(label: "Not signed in", isReady: false))
        // Anthropic: explicit key wins, account suffices, neither warns.
        XCTAssertEqual(badge(.anthropic, key: true, claude: true),
                       .init(label: "Key set", isReady: true))
        XCTAssertEqual(badge(.anthropic, claude: true),
                       .init(label: "Claude account connected", isReady: true))
        XCTAssertEqual(badge(.anthropic), .init(label: "No account or key", isReady: false))
        // Custom servers often need no key; absence is not a warning.
        XCTAssertEqual(badge(.custom), .init(label: "Key optional", isReady: true))
        XCTAssertEqual(badge(.custom, key: true), .init(label: "Key set", isReady: true))
        // Plain key providers keep the original behaviour.
        XCTAssertEqual(badge(.openai), .init(label: "No API key", isReady: false))
        XCTAssertEqual(badge(.openai, key: true), .init(label: "Key set", isReady: true))
        // A connected account for a different provider changes nothing.
        XCTAssertEqual(badge(.openai, claude: true, chatgpt: true, google: true),
                       .init(label: "No API key", isReady: false))
    }
}
