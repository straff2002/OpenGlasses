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

    /// An available mode never carries a reason — a stale explanation beside an enabled control
    /// reads as a warning about the thing you just chose.
    func testAvailableModesCarryNoReason() {
        for option in options(gemini: true, realtime: true) {
            XCTAssertTrue(option.isAvailable)
            XCTAssertNil(option.unavailableReason)
        }
    }
}
