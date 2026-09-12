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
}
