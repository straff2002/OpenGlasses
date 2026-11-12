import XCTest
@testable import OpenGlasses

final class TTSVoiceResolverTests: XCTestCase {
    private func voice(_ id: String, _ language: String, _ quality: Int = 1) -> TTSVoiceResolver.Voice {
        .init(identifier: id, language: language, quality: quality, name: id)
    }

    func testSavedVoiceOverridesDeviceLanguages() {
        let voices = [voice("english", "en-US", 3), voice("japanese", "ja-JP")]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "japanese", preferredLanguages: ["en-US"],
                                                voices: voices)?.identifier, "japanese")
    }

    func testMissingSavedVoiceFallsBackToStandardQualityPrimaryLanguage() {
        let voices = [voice("english", "en-US", 3), voice("french", "fr-FR")]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "removed", preferredLanguages: ["fr-FR", "en-US"],
                                                voices: voices)?.identifier, "french")
    }

    func testExactRegionWinsBeforeQuality() {
        let voices = [voice("canadian", "fr-CA"), voice("france", "fr-FR", 3)]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["FR_ca"],
                                                voices: voices)?.identifier, "canadian")
    }

    func testPrimaryLanguageRegionFallbackWinsBeforeSecondaryLanguage() {
        let voices = [voice("french", "fr-FR"), voice("english", "en-US", 3)]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["fr-CA", "en-US"],
                                                voices: voices)?.identifier, "french")
    }

    func testQualityWinsWithinMatchingLocale() {
        let voices = [voice("standard", "de-DE"), voice("enhanced", "de-DE", 2), voice("premium", "de-DE", 3)]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["de-DE"],
                                                voices: voices)?.identifier, "premium")
    }

    func testRegionalFallbackPreservesInferredScript() {
        let voices = [voice("simplified", "zh-CN", 3), voice("traditional", "zh-HK")]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["zh-TW"],
                                                voices: voices)?.identifier, "traditional")
    }

    func testExplicitScriptDoesNotFallBackToIncompatibleVoice() {
        let voices = [voice("cyrillic", "sr-RS", 3), voice("english", "en-US")]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["sr-Latn"],
                                                voices: voices)?.identifier, "english")
    }

    func testUnsupportedPrimaryLanguageTriesNextPreference() {
        let voices = [voice("german", "de-DE"), voice("english", "en-US", 3)]
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["ja-JP", "de-DE"],
                                                voices: voices)?.identifier, "german")
    }

    func testEnglishFallbackAndEmptyCatalog() {
        XCTAssertEqual(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: ["ja-JP"],
                                                voices: [voice("english", "en-GB")])?.identifier, "english")
        XCTAssertNil(TTSVoiceResolver.resolve(savedIdentifier: "", preferredLanguages: [], voices: []))
    }

    func testPickerIncludesPreferredLanguagesEnglishAndSavedVoice() {
        let voices = [voice("fr", "fr-FR"), voice("de", "de-DE", 2), voice("en", "en-US"),
                      voice("saved", "ja-JP"), voice("unrelated", "es-ES")]
        let available = TTSVoiceResolver.available(savedIdentifier: "saved", preferredLanguages: ["fr-CA", "de-DE"], voices: voices)
        XCTAssertEqual(Set(available.map(\.identifier)), Set(["fr", "de", "en", "saved"]))
        XCTAssertEqual(available.first?.identifier, "de")
    }

    // MARK: - Pointing at the better system voices

    func testNoAdviceWhenTheVoiceInUseIsAlreadyPremium() {
        let voices = [voice("yuna-premium", "ko-KR", 3), voice("yuna", "ko-KR", 1)]
        XCTAssertNil(TTSVoiceResolver.qualityAdvice(savedIdentifier: "", preferredLanguages: ["ko-KR"],
                                                    voices: voices))
    }

    func testTheCompactVoiceDrawsAdviceAboutItsOwnLanguage() {
        let voices = [voice("yuna", "ko-KR", 1), voice("samantha-premium", "en-US", 3)]
        let advice = TTSVoiceResolver.qualityAdvice(savedIdentifier: "", preferredLanguages: ["ko-KR", "en-US"],
                                                    voices: voices)
        XCTAssertEqual(advice, .init(language: "ko-KR", installedQuality: 1))
        XCTAssertEqual(advice?.isCompactOnly, true)
    }

    func testAnEnhancedVoiceStillLeavesRoomForPremium() {
        let voices = [voice("yuna-enhanced", "ko-KR", 2)]
        let advice = TTSVoiceResolver.qualityAdvice(savedIdentifier: "", preferredLanguages: ["ko-KR"],
                                                    voices: voices)
        XCTAssertEqual(advice?.installedQuality, 2)
        XCTAssertEqual(advice?.isCompactOnly, false)
    }

    /// The advice follows the voice the app would actually use: a pinned compact voice is still
    /// compact, whatever else is installed.
    func testAPinnedCompactVoiceIsAdvisedOnEvenWhenPremiumIsInstalled() {
        let voices = [voice("yuna", "ko-KR", 1), voice("yuna-premium", "ko-KR", 3)]
        XCTAssertEqual(TTSVoiceResolver.qualityAdvice(savedIdentifier: "yuna", preferredLanguages: ["ko-KR"],
                                                      voices: voices),
                       .init(language: "ko-KR", installedQuality: 1))
    }

    func testAPinnedVoiceTheSystemNoLongerListsFallsBackToTheLanguageRule() {
        let voices = [voice("yuna-premium", "ko-KR", 3)]
        XCTAssertNil(TTSVoiceResolver.qualityAdvice(savedIdentifier: "gone", preferredLanguages: ["ko-KR"],
                                                    voices: voices))
    }
}

/// Plan LO — the iOS voice reads a reply in its own language: an installed voice for a reply
/// confidently in another language, the chosen voice otherwise.
final class TTSVoiceReplyLanguageTests: XCTestCase {
    private func voice(_ id: String, _ language: String, _ quality: Int = 1) -> TTSVoiceResolver.Voice {
        .init(identifier: id, language: language, quality: quality, name: id)
    }

    private let english = TTSVoiceResolver.Voice(identifier: "saved-en", language: "en-GB", quality: 2, name: "saved-en")
    private var installed: [TTSVoiceResolver.Voice] {
        [english, voice("es-compact", "es-ES", 1), voice("es-premium", "es-ES", 3), voice("es-mx", "es-MX", 1),
         voice("de", "de-DE", 2)]
    }
    private let spanish = TTSVoiceResolver.DetectedLanguage(code: "es", confidence: 0.97)

    private func pick(_ detected: TTSVoiceResolver.DetectedLanguage?, letters: Int = 40, logographic: Bool = false,
                      preferred: [String] = ["en-GB"], voices: [TTSVoiceResolver.Voice]? = nil) -> String? {
        TTSVoiceResolver.voiceForReply(chosen: english, detected: detected, letters: letters, logographic: logographic,
                                       preferredLanguages: preferred, voices: voices ?? installed)?.identifier
    }

    func testTheSameLanguageKeepsTheChosenVoice() {
        XCTAssertEqual(pick(.init(code: "en", confidence: 0.99)), "saved-en")
    }

    func testConfidentSpanishWithASpanishVoiceInstalledSwitches() {
        XCTAssertEqual(pick(spanish), "es-premium", "highest quality when no region is preferred")
        XCTAssertEqual(pick(spanish, preferred: ["en-GB", "es-MX"]), "es-mx", "a device language's region first")
    }

    func testTheChosenVoicesRegionWinsBeforeQuality() {
        let voices = [english, voice("es-us", "es-US", 3), voice("es-gb", "es-GB", 1)]
        XCTAssertEqual(pick(spanish, voices: voices), "es-gb")
    }

    func testLowConfidenceKeepsTheChosenVoice() {
        XCTAssertEqual(pick(.init(code: "es", confidence: TTSVoiceResolver.switchConfidence - 0.01)), "saved-en")
        XCTAssertEqual(pick(nil), "saved-en", "nothing detected")
    }

    func testNoVoiceForTheLanguageKeepsTheChosenVoice() {
        XCTAssertEqual(pick(.init(code: "ja", confidence: 0.99)), "saved-en")
    }

    func testShortTextKeepsTheChosenVoice() {
        XCTAssertEqual(pick(spanish, letters: TTSVoiceResolver.minimumSwitchLetters - 1), "saved-en")
        XCTAssertEqual(TTSVoiceResolver.letterCount(of: "Sí, 42.").letters, 2)
    }

    func testLogographicTextNeedsFewerCharacters() {
        let zh = [english, voice("zh", "zh-CN", 2)]
        let counted = TTSVoiceResolver.letterCount(of: "六点关门")
        XCTAssertEqual(counted.letters, 4)
        XCTAssertTrue(counted.logographic)
        XCTAssertEqual(pick(.init(code: "zh-Hans", confidence: 0.95), letters: counted.letters,
                            logographic: counted.logographic, voices: zh), "zh")
        XCTAssertEqual(pick(.init(code: "zh-Hans", confidence: 0.95), letters: 3, logographic: true, voices: zh), "saved-en")
        XCTAssertFalse(TTSVoiceResolver.letterCount(of: "The pharmacy closes at six tonight.").logographic)
    }

    func testTraditionalChineseIsNotReadBySimplifiedVoice() {
        let voices = [english, voice("zh-cn", "zh-CN", 3)]
        XCTAssertEqual(pick(.init(code: "zh-Hant", confidence: 0.95), letters: 8, logographic: true, voices: voices),
                       "saved-en", "no Traditional voice installed: keep the chosen one")
    }
}
