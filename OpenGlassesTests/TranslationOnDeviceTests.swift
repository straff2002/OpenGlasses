import XCTest
@testable import OpenGlasses

/// Plan BY P3 — the deterministic core of the on-device tier and two-way mode: energy-based
/// utterance segmentation (SenseVoice is an offline recognizer, so boundaries come from us, not
/// server VAD) and direction/leg routing shared by both tiers and both surfaces.
final class TranslationOnDeviceTests: XCTestCase {

    /// 100 ms of speech-loud samples (well above the RMS gate).
    private func speech(_ count: Int = 1600) -> [Float] {
        (0..<count).map { i in 0.2 * sinf(Float(i) * 0.1) }
    }

    private func silence(_ count: Int = 1600) -> [Float] {
        [Float](repeating: 0.0001, count: count)
    }

    // MARK: - UtteranceSegmenter

    func testSilenceAloneNeverEmits() {
        var seg = UtteranceSegmenter()
        for _ in 0..<50 {
            XCTAssertEqual(seg.accept(silence(), duration: 0.1), .none)
        }
        XCTAssertNil(seg.flush())
    }

    func testSpeechThenHeldSilenceEmitsTheUtterance() {
        var seg = UtteranceSegmenter(silenceHold: 0.3)
        XCTAssertEqual(seg.accept(speech(), duration: 0.1), .none)
        XCTAssertEqual(seg.accept(speech(), duration: 0.1), .none)
        XCTAssertEqual(seg.accept(silence(), duration: 0.2), .none)   // hold not reached
        guard case .ended(let samples) = seg.accept(silence(), duration: 0.2) else {
            return XCTFail("expected utterance end after silence hold")
        }
        // The buffered utterance includes the speech and the trailing silence chunks.
        XCTAssertEqual(samples.count, 4 * 1600)
    }

    func testShortSilenceGapDoesNotSplit() {
        var seg = UtteranceSegmenter(silenceHold: 0.5)
        _ = seg.accept(speech(), duration: 0.1)
        XCTAssertEqual(seg.accept(silence(), duration: 0.2), .none)   // gap < hold
        XCTAssertEqual(seg.accept(speech(), duration: 0.1), .none)    // speech resumes — no split
        XCTAssertEqual(seg.accept(silence(), duration: 0.2), .none)   // silence counter was reset
        guard case .ended = seg.accept(silence(), duration: 0.3) else {
            return XCTFail("expected end once the hold finally elapses")
        }
    }

    func testMaxUtteranceForceEmitsAndKeepsListening() {
        var seg = UtteranceSegmenter(silenceHold: 10, maxUtterance: 0.3)
        _ = seg.accept(speech(), duration: 0.1)
        _ = seg.accept(speech(), duration: 0.1)
        guard case .ended(let first) = seg.accept(speech(), duration: 0.1) else {
            return XCTFail("expected force-emit at the ceiling")
        }
        XCTAssertEqual(first.count, 3 * 1600)
        // Still speaking: the continuation accumulates without needing a fresh speech onset.
        XCTAssertEqual(seg.accept(silence(), duration: 0.1), .none)
        XCTAssertNotNil(seg.flush(), "continuation samples were buffered")
    }

    func testFlushReturnsPendingSpeechOnce() {
        var seg = UtteranceSegmenter()
        _ = seg.accept(speech(), duration: 0.1)
        XCTAssertNotNil(seg.flush())
        XCTAssertNil(seg.flush(), "flush resets the segmenter")
    }

    // MARK: - TranslationRouting

    func testActiveDirectionFromSettings() {
        XCTAssertEqual(
            TranslationRouting.activeDirection(twoWayEnabled: false, languageA: "en", languageB: "es",
                                               oneWayTarget: "de"),
            .oneWay(target: "de"))
        XCTAssertEqual(
            TranslationRouting.activeDirection(twoWayEnabled: true, languageA: "en", languageB: "es",
                                               oneWayTarget: "de"),
            .twoWay("en", "es"))
    }

    func testOneWayIsAlwaysWearerLeg() {
        let direction = TranslationDirectionPolicy.oneWay(target: "en")
        XCTAssertTrue(TranslationRouting.isWearerLeg(detected: "es", direction: direction, wearerLanguage: "en"))
        XCTAssertTrue(TranslationRouting.isWearerLeg(detected: nil, direction: direction, wearerLanguage: "en"))
    }

    func testTwoWayLegsRouteByDetectedLanguage() {
        let direction = TranslationDirectionPolicy.twoWay("en", "es")
        // Spanish speech renders in English → the wearer's leg.
        XCTAssertTrue(TranslationRouting.isWearerLeg(detected: "es", direction: direction, wearerLanguage: "en"))
        // The wearer's own English renders in Spanish → the other leg.
        XCTAssertFalse(TranslationRouting.isWearerLeg(detected: "en", direction: direction, wearerLanguage: "en"))
        // Undetectable defaults to the wearer leg — show too much rather than hide.
        XCTAssertTrue(TranslationRouting.isWearerLeg(detected: nil, direction: direction, wearerLanguage: "en"))
        // French in an en/es conversation has no leg → wearer leg by the same default.
        XCTAssertTrue(TranslationRouting.isWearerLeg(detected: "fr", direction: direction, wearerLanguage: "en"))
    }

    func testWearerLegPrefixMatchesRegionalVariants() {
        let direction = TranslationDirectionPolicy.twoWay("pt-BR", "en")
        // English speech renders in pt-BR; wearer language "pt-BR" matches the render language.
        XCTAssertTrue(TranslationRouting.isWearerLeg(detected: "en", direction: direction, wearerLanguage: "pt-BR"))
    }

    // MARK: - Segment fallbacks (provider contract)

    func testSegmentWithoutTranslationCarriesNoOriginal() {
        // The fail-open shape the on-device provider emits when translation fails or is
        // unnecessary: transcript as text, no original ribbon.
        let segment = TranslationSegment(text: "hola", isFinal: true, language: "es")
        XCTAssertNil(segment.original)
        XCTAssertEqual(segment.language, "es")
    }
}
