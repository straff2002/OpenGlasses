import XCTest
@testable import OpenGlasses

/// Plan HP P2 item 13 — live translation speaks a translation or nothing.
///
/// Before this, `translate()` returned "[es→en] " plus the *original* words and the app spoke them
/// to the person in front of the wearer as if they were translated. These drive the service through
/// an injected translator, without a microphone or a recogniser.
@MainActor
final class LiveTranslationServiceTests: XCTestCase {

    private let spanish = "Hola, ¿cómo estás? Me alegro mucho de verte hoy en la ciudad."

    private func makeService(target: String = "en") -> (LiveTranslationService, () -> [String]) {
        let service = LiveTranslationService()
        service.targetLanguage = target
        service.isActive = true
        var spoken: [String] = []
        service.onTranslation = { spoken.append($0) }
        return (service, { spoken })
    }

    func testARealTranslationIsSpokenAndNothingElse() async {
        let (service, spoken) = makeService()
        var asked: [(String, String?, String)] = []
        service.translateText = { text, source, target in
            asked.append((text, source, target))
            return "  Hello, how are you? I'm very glad to see you in town today.  "
        }

        await service.translateAndSpeak(spanish)

        XCTAssertEqual(spoken(), ["Hello, how are you? I'm very glad to see you in town today."])
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, spanish)
        XCTAssertEqual(asked.first?.1, "es", "the detected language is handed to the translator")
        XCTAssertEqual(asked.first?.2, "en")
        XCTAssertEqual(service.translationCount, 1)
        XCTAssertFalse(spoken().joined().contains("["), "no language-tag stub")
        XCTAssertFalse(spoken().joined().contains("Hola"), "the original words are never spoken as a translation")
    }

    func testWithoutATranslatorNothingIsSpoken() async {
        let (service, spoken) = makeService()
        await service.translateAndSpeak(spanish)
        XCTAssertTrue(spoken().isEmpty)
        XCTAssertEqual(service.translationCount, 0)
    }

    func testAFailedTranslationIsNotSpoken() async {
        let (service, spoken) = makeService()
        service.translateText = { _, _, _ in throw TranslationEngineError.timeout }
        await service.translateAndSpeak(spanish)
        XCTAssertTrue(spoken().isEmpty)
        XCTAssertEqual(service.translationCount, 0)
    }

    func testSpeechAlreadyInTheTargetLanguageIsNotTranslated() async {
        let (service, spoken) = makeService(target: "es")
        var calls = 0
        service.translateText = { _, _, _ in calls += 1; return "x" }
        await service.translateAndSpeak(spanish)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(spoken().isEmpty)
    }

    func testATranslationThatLandsAfterStopIsDropped() async {
        let (service, spoken) = makeService()
        service.translateText = { [weak service] _, _, _ in
            service?.isActive = false
            return "Hello"
        }
        await service.translateAndSpeak(spanish)
        XCTAssertTrue(spoken().isEmpty)
    }

    /// The registered tool still reaches this service, so the stub is gone rather than hidden.
    func testTheToolDrivesTheRealService() async throws {
        let service = LiveTranslationService()
        var tool = LiveTranslationTool()
        tool.translationService = service
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(status.contains("not running"), status)
    }
}
