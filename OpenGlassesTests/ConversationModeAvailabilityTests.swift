import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23: there was no in-app way to reach `.geminiLive` — the only
/// `switchMode(to:)` call sites for it were App Intents, so the mode (and with it the whole
/// live-vision path, since the Camera button only exists in a realtime mode) was reachable through
/// Siri and nowhere else.
final class ConversationModeAvailabilityTests: XCTestCase {

    private func options(gemini: Bool, realtime: Bool) -> [ConversationModeAvailability.Option] {
        ConversationModeAvailability.options(
            for: .init(hasGeminiKey: gemini, hasOpenAIRealtimeModel: realtime))
    }

    private func option(_ mode: AppMode, gemini: Bool, realtime: Bool)
    -> ConversationModeAvailability.Option {
        options(gemini: gemini, realtime: realtime).first { $0.mode == mode }!
    }

    /// Every mode is offered, always — a mode missing from the list is the bug this replaces.
    func testAllModesAreListedWhateverTheConfiguration() {
        XCTAssertEqual(options(gemini: false, realtime: false).map(\.mode), AppMode.allCases)
        XCTAssertEqual(options(gemini: true, realtime: true).map(\.mode), AppMode.allCases)
    }

    /// Direct is the fallback every other mode degrades to, so it can never be unavailable —
    /// otherwise a misconfigured app has nowhere to land.
    func testDirectIsAlwaysAvailable() {
        XCTAssertTrue(option(.direct, gemini: false, realtime: false).isAvailable)
    }

    func testGeminiLiveNeedsAKeyAndSaysSoWhenItIsMissing() {
        let without = option(.geminiLive, gemini: false, realtime: false)
        XCTAssertFalse(without.isAvailable)
        XCTAssertEqual(without.unavailableReason?.contains("Gemini"), true)
        XCTAssertEqual(without.unavailableReason?.contains("Settings"), true,
                       "the reason must name where to fix it, not just what is wrong")

        let with = option(.geminiLive, gemini: true, realtime: false)
        XCTAssertTrue(with.isAvailable)
        XCTAssertNil(with.unavailableReason)
    }

    func testOpenAIRealtimeNeedsARealtimeModel() {
        XCTAssertFalse(option(.openaiRealtime, gemini: true, realtime: false).isAvailable)
        XCTAssertTrue(option(.openaiRealtime, gemini: false, realtime: true).isAvailable)
    }

    /// The two live modes are gated independently: a Gemini key must not unlock OpenAI Realtime,
    /// and vice versa. They are different providers with different credentials.
    func testTheTwoLiveModesAreGatedIndependently() {
        XCTAssertTrue(option(.geminiLive, gemini: true, realtime: false).isAvailable)
        XCTAssertFalse(option(.openaiRealtime, gemini: true, realtime: false).isAvailable)
        XCTAssertFalse(option(.geminiLive, gemini: false, realtime: true).isAvailable)
    }

    /// Device-traced 2026-08-27: signing in with ChatGPT and then finding live voice mode
    /// unavailable reads as a bug, because the plan the user just signed into *does* advertise a
    /// voice mode. It is a different OpenAI product on a different credential — one no account
    /// sign-in reaches — so the refusal has to say that rather than repeating "add a model".
    func testASignedInChatGPTUserIsToldWhyTheirPlanDoesNotCoverLiveVoice() {
        let generic = ConversationModeAvailability.realtimeUnavailableReason(hasChatGPTAccount: false)
        let signedIn = ConversationModeAvailability.realtimeUnavailableReason(hasChatGPTAccount: true)

        XCTAssertNotEqual(generic, signedIn)
        XCTAssertTrue(signedIn.contains("ChatGPT"),
                      "The reason must name the plan the user thinks covers this: \(signedIn)")
        XCTAssertTrue(signedIn.lowercased().contains("api key"),
                      "It must name the credential that does work: \(signedIn)")
        XCTAssertTrue(signedIn.contains("Settings"),
                      "It must say where to add it: \(signedIn)")
    }

    /// A ChatGPT account changes only the wording — never whether the mode can start. It is not a
    /// credential for this mode and must not be mistaken for one.
    func testAChatGPTAccountNeverUnlocksLiveVoice() {
        let option = ConversationModeAvailability.options(
            for: .init(hasGeminiKey: false, hasOpenAIRealtimeModel: false, hasChatGPTAccount: true)
        ).first { $0.mode == .openaiRealtime }!

        XCTAssertFalse(option.isAvailable)
        XCTAssertEqual(option.unavailableReason,
                       ConversationModeAvailability.realtimeUnavailableReason(hasChatGPTAccount: true))
    }

    /// And once a realtime model exists the explanation goes away entirely, signed in or not.
    func testTheChatGPTExplanationDisappearsOnceARealtimeModelExists() {
        let option = ConversationModeAvailability.options(
            for: .init(hasGeminiKey: false, hasOpenAIRealtimeModel: true, hasChatGPTAccount: true)
        ).first { $0.mode == .openaiRealtime }!

        XCTAssertTrue(option.isAvailable)
        XCTAssertNil(option.unavailableReason)
    }

    /// An available mode never carries a reason — a stale explanation beside an enabled control
    /// reads as a warning about the thing you just chose.
    func testAvailableModesCarryNoReason() {
        for option in options(gemini: true, realtime: true) {
            XCTAssertTrue(option.isAvailable)
            XCTAssertNil(option.unavailableReason)
        }
    }
}
