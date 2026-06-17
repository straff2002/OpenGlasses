import XCTest
@testable import OpenGlasses

/// Tests for the pure TTS engine-selection policy (Additional Capabilities #1 — the Kokoro tier):
/// given availability (ElevenLabs key + online, Kokoro model present), the user's preference, and
/// urgency, `TTSEngineSelector` produces the `ElevenLabs → Kokoro → AVSpeech` fallback chain.
final class TTSEngineSelectorTests: XCTestCase {

    private typealias Availability = TTSEngineSelector.Availability

    private func chain(_ preference: TTSEnginePreference,
                       _ availability: Availability,
                       _ urgency: TextToSpeechService.SpeechUrgency = .low) -> [TTSEngine] {
        TTSEngineSelector.chain(preference: preference, availability: availability, urgency: urgency)
    }

    // MARK: - Terminal fallback

    func testChainAlwaysTerminatesInSystem() {
        // Every preference × availability combination must end in the always-available system voice.
        for preference in TTSEnginePreference.allCases {
            for eleven in [false, true] {
                for kokoro in [false, true] {
                    let result = chain(preference, Availability(elevenLabsReady: eleven, kokoroReady: kokoro))
                    XCTAssertEqual(result.last, .system, "\(preference) eleven=\(eleven) kokoro=\(kokoro)")
                    XCTAssertEqual(result.filter { $0 == .system }.count, 1, "system appears exactly once")
                    XCTAssertFalse(result.isEmpty)
                }
            }
        }
    }

    func testNothingAvailableFallsToSystemOnly() {
        let result = chain(.auto, Availability(elevenLabsReady: false, kokoroReady: false))
        XCTAssertEqual(result, [.system])
    }

    // MARK: - Auto cascade

    func testAutoWithElevenLabsOnly() {
        let result = chain(.auto, Availability(elevenLabsReady: true, kokoroReady: false))
        XCTAssertEqual(result, [.elevenLabs, .system])  // today's behaviour, unchanged
        XCTAssertEqual(TTSEngineSelector.select(preference: .auto,
                                                availability: Availability(elevenLabsReady: true, kokoroReady: false)),
                       .elevenLabs)
    }

    func testAutoWithKokoroOnly() {
        let result = chain(.auto, Availability(elevenLabsReady: false, kokoroReady: true))
        XCTAssertEqual(result, [.kokoro, .system])
    }

    func testAutoWithBothReadyPrefersElevenLabsAtLowUrgency() {
        let result = chain(.auto, Availability(elevenLabsReady: true, kokoroReady: true))
        XCTAssertEqual(result, [.elevenLabs, .kokoro, .system])
    }

    // MARK: - Urgency adjustment

    func testHighUrgencyPromotesReadyKokoroAheadOfNetworkElevenLabs() {
        // A hazard-level alert shouldn't wait on a network round-trip when an on-device neural
        // voice is ready — Kokoro leads, ElevenLabs is kept as the next fallback.
        let result = chain(.auto, Availability(elevenLabsReady: true, kokoroReady: true), .high)
        XCTAssertEqual(result, [.kokoro, .elevenLabs, .system])
        XCTAssertEqual(TTSEngineSelector.select(preference: .auto,
                                                availability: Availability(elevenLabsReady: true, kokoroReady: true),
                                                urgency: .high),
                       .kokoro)
    }

    func testHighUrgencyDoesNotDowngradeToSystemWhenKokoroUnavailable() {
        // No on-device neural option → keep ElevenLabs first; never drop to the robotic voice
        // purely for speed.
        let result = chain(.auto, Availability(elevenLabsReady: true, kokoroReady: false), .high)
        XCTAssertEqual(result, [.elevenLabs, .system])
    }

    func testMediumUrgencyDoesNotReorder() {
        let result = chain(.auto, Availability(elevenLabsReady: true, kokoroReady: true), .medium)
        XCTAssertEqual(result, [.elevenLabs, .kokoro, .system])
    }

    // MARK: - Explicit preferences

    func testElevenLabsPreferenceFallsThroughToKokoroThenSystem() {
        let result = chain(.elevenLabs, Availability(elevenLabsReady: false, kokoroReady: true))
        XCTAssertEqual(result, [.kokoro, .system])  // graceful fallback when the cloud is unavailable
    }

    func testKokoroPreferenceNeverFallsBackToPaidCloud() {
        // User explicitly chose on-device → ElevenLabs is excluded even when it's available.
        let result = chain(.kokoro, Availability(elevenLabsReady: true, kokoroReady: true))
        XCTAssertEqual(result, [.kokoro, .system])
    }

    func testKokoroPreferenceWithoutModelIsSystemOnly() {
        let result = chain(.kokoro, Availability(elevenLabsReady: true, kokoroReady: false))
        XCTAssertEqual(result, [.system])  // still no paid cloud
    }

    func testKokoroPreferenceHighUrgencyStaysOnDevice() {
        let result = chain(.kokoro, Availability(elevenLabsReady: true, kokoroReady: true), .high)
        XCTAssertEqual(result, [.kokoro, .system])
    }

    func testSystemPreferenceForcesSystemEvenWhenEverythingReady() {
        let result = chain(.system, Availability(elevenLabsReady: true, kokoroReady: true), .high)
        XCTAssertEqual(result, [.system])
    }

    // MARK: - select == chain.first

    func testSelectMatchesChainHead() {
        let combos: [(TTSEnginePreference, Availability, TextToSpeechService.SpeechUrgency)] = [
            (.auto, Availability(elevenLabsReady: true, kokoroReady: true), .low),
            (.auto, Availability(elevenLabsReady: false, kokoroReady: true), .high),
            (.kokoro, Availability(elevenLabsReady: true, kokoroReady: false), .low),
            (.system, Availability(elevenLabsReady: true, kokoroReady: true), .medium),
        ]
        for (preference, availability, urgency) in combos {
            let head = TTSEngineSelector.chain(preference: preference, availability: availability, urgency: urgency).first
            let selected = TTSEngineSelector.select(preference: preference, availability: availability, urgency: urgency)
            XCTAssertEqual(selected, head)
        }
    }
}
