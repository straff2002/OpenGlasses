import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan HP P2 item 10 — the AI-translation line for the other person: which catalog language it is
/// said in, and when it is said at all.
final class TranslationDisclosureLanguageTests: XCTestCase {

    private typealias T = TranslationDisclosureLanguage
    private let shipped = ["Base", "en", "es-MX", "ru", "nl", "zh-Hans", "zh-Hant", "pt-BR", "pt-PT"]

    func testAnExactLocalizationWins() {
        XCTAssertEqual(T.localization(forTarget: "ru", available: shipped), "ru")
        XCTAssertEqual(T.localization(forTarget: "es-MX", available: shipped), "es-MX")
        XCTAssertEqual(T.localization(forTarget: "es_mx", available: shipped), "es-MX",
                       "case and separator are ignored; the bundle's spelling comes back")
        XCTAssertEqual(T.localization(forTarget: " nl ", available: shipped), "nl")
    }

    func testTheBareLanguageBeatsARegionalVariant() {
        XCTAssertEqual(T.localization(forTarget: "nl-BE", available: shipped), "nl")
        XCTAssertEqual(T.localization(forTarget: "es-ES", available: ["es", "es-MX"]), "es")
    }

    func testARegionalVariantOfTheSameLanguageIsUsedDeterministically() {
        XCTAssertEqual(T.localization(forTarget: "es", available: shipped), "es-MX")
        XCTAssertEqual(T.localization(forTarget: "es-ES", available: shipped), "es-MX")
        XCTAssertEqual(T.localization(forTarget: "pt", available: shipped), "pt-BR")
        XCTAssertEqual(T.localization(forTarget: "pt", available: ["pt-PT", "pt-BR"]), "pt-BR",
                       "sorted, so the bundle's order does not decide")
        XCTAssertEqual(T.localization(forTarget: "zh", available: shipped), "zh-Hans")
    }

    func testALanguageTheCatalogDoesNotShipFallsBackToEnglish() {
        XCTAssertEqual(T.localization(forTarget: "sw", available: shipped), "en")
        XCTAssertEqual(T.localization(forTarget: "", available: shipped), "en")
        XCTAssertEqual(T.localization(forTarget: "base", available: shipped), "en", "Base is not a language")
        XCTAssertEqual(T.localization(forTarget: "fr", available: []), "en")
    }

    /// With no catalog to read the English source is said — never nothing, never a key.
    func testTheLineIsEnglishWhenTheBundleHasNoTranslation() {
        let bare = Bundle(for: Self.self)
        XCTAssertEqual(T.listenerLine(forTarget: "sw", bundle: bare), "This is a live AI translation by Avenkin AI.")
        XCTAssertEqual(T.captionLabel(forTarget: "sw", bundle: bare), "AI translation")
        XCTAssertFalse(T.listenerLine(forTarget: "es", bundle: .main).isEmpty)
        XCTAssertTrue(T.listenerLine(forTarget: "en", bundle: .main).contains("AI"))
    }

    // MARK: - When the other person can hear it

    func testTheLoudspeakerIsWhereTheOtherPersonHearsIt() {
        XCTAssertTrue(T.playsFromPhoneSpeaker(outputs: [.builtInSpeaker], glassesOnlyAudio: false))
        XCTAssertTrue(T.playsFromPhoneSpeaker(outputs: [.builtInReceiver], glassesOnlyAudio: false),
                      "the speech service moves an earpiece-only route to the loudspeaker")
        XCTAssertTrue(T.playsFromPhoneSpeaker(outputs: [], glassesOnlyAudio: false))
    }

    func testTheGlassesHeadphonesAndGlassesOnlyAudioKeepItWithTheWearer() {
        XCTAssertFalse(T.playsFromPhoneSpeaker(outputs: [.bluetoothHFP], glassesOnlyAudio: false))
        XCTAssertFalse(T.playsFromPhoneSpeaker(outputs: [.bluetoothA2DP], glassesOnlyAudio: false))
        XCTAssertFalse(T.playsFromPhoneSpeaker(outputs: [.headphones], glassesOnlyAudio: false))
        XCTAssertFalse(T.playsFromPhoneSpeaker(outputs: [.carAudio], glassesOnlyAudio: false))
        XCTAssertFalse(T.playsFromPhoneSpeaker(outputs: [.builtInSpeaker], glassesOnlyAudio: true),
                       "with Glasses Only Audio, speech plays on the glasses or not at all")
    }
}
