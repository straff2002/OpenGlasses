import XCTest
@testable import OpenGlasses

/// Locale resolution for all speech features (wake word, transcription, captions, rewind,
/// teleprompter). Language-agnostic by design — no per-language special cases.
final class SpeechLocaleResolverTests: XCTestCase {

    private let supported = ["en-US", "en-GB", "fr-FR", "de-DE", "pt-BR", "ja-JP"]

    private func resolve(_ preference: String, device: [String] = ["en-US"]) -> String {
        SpeechLocaleResolver.resolve(preference: preference, deviceLanguages: device, supported: supported)
    }

    // MARK: - Explicit preference

    func testExactMatchWins() {
        XCTAssertEqual(resolve("de-DE"), "de-DE")
        XCTAssertEqual(resolve("pt-BR", device: ["en-US"]), "pt-BR")
    }

    func testMatchingIsCaseAndSeparatorInsensitive() {
        XCTAssertEqual(resolve("DE_de"), "de-DE")
        XCTAssertEqual(resolve("pt_br"), "pt-BR")
    }

    func testSameLanguageRegionFallback() {
        // fr-CA isn't supported; any supported French beats falling back to English.
        XCTAssertEqual(resolve("fr-CA"), "fr-FR")
    }

    func testAnUnsupportedRegionFallsToTheLanguagesHomeRegionNotTheFirstInTheAlphabet() {
        // An English phone in Mexico: Apple has no en-MX recogniser, and en-AE sorts first.
        let english = ["en-AE", "en-AU", "en-CA", "en-GB", "en-IN", "en-US", "en-ZA", "es-MX", "pt-PT", "pt-BR"]
        func resolve(_ device: String) -> String {
            SpeechLocaleResolver.resolve(preference: SpeechLocaleResolver.automatic,
                                         deviceLanguages: [device], supported: english)
        }
        XCTAssertEqual(resolve("en-MX"), "en-US")
        XCTAssertEqual(resolve("pt-AO"), "pt-BR")
        XCTAssertEqual(resolve("en-GB"), "en-GB", "an exact region still wins")
        XCTAssertEqual(resolve("es-AR"), "es-MX", "no home region on offer: any Spanish beats English")
    }

    func testUnsupportedPreferenceFallsBackToDeviceThenEnglish() {
        XCTAssertEqual(resolve("xx-XX", device: ["de-DE"]), "de-DE")
        XCTAssertEqual(resolve("xx-XX", device: ["yy-YY"]), "en-US")
    }

    // MARK: - Automatic

    func testAutoFollowsFirstSupportedDeviceLanguage() {
        XCTAssertEqual(resolve(SpeechLocaleResolver.automatic, device: ["ja-JP", "en-US"]), "ja-JP")
        XCTAssertEqual(resolve(SpeechLocaleResolver.automatic, device: ["nl-NL", "de-DE"]), "de-DE",
                       "unsupported first language → next preferred one")
    }

    func testAutoRegionFallbackForDeviceLanguage() {
        XCTAssertEqual(resolve(SpeechLocaleResolver.automatic, device: ["pt-PT"]), "pt-BR",
                       "same-language region beats English")
    }

    func testAutoWithNothingSupportedIsEnglishUS() {
        XCTAssertEqual(resolve(SpeechLocaleResolver.automatic, device: ["zz-ZZ"]), "en-US",
                       "the old hardcoded behavior is the floor")
    }

    func testResolutionAlwaysReturnsASupportedIdentifierOrEnUS() {
        for pref in ["auto", "de-DE", "fr-CA", "xx"] {
            let out = resolve(pref, device: ["it-IT"])
            XCTAssertTrue(supported.contains(out) || out == "en-US", "\(pref) → \(out)")
        }
    }

    // MARK: - Config default

    func testPreferenceDefaultsToAutomatic() {
        UserDefaults.standard.removeObject(forKey: "speechRecognitionLocale")
        XCTAssertEqual(Config.speechRecognitionLocale, SpeechLocaleResolver.automatic)
    }
}
