import XCTest
@testable import OpenGlasses

/// Plan BY P2 — the deterministic core of the cloud translation tier: stream folding
/// (deltas + turn completion + input transcription → `TranslationSegment`s), the source-language
/// tag contract shared with the prompt builder, tier selection, and the 16 kHz resample the
/// Gemini wire requires.
final class TranslationCloudTierTests: XCTestCase {

    // MARK: - TranslationStreamAccumulator: tag parsing

    func testLeadingLanguageTagIsParsedAndStripped() {
        var acc = TranslationStreamAccumulator()
        let interim = acc.acceptDelta("[es] Hello there")
        XCTAssertEqual(interim?.text, "Hello there")
        XCTAssertEqual(interim?.language, "es")
    }

    func testTagSplitAcrossDeltasResolvesOnceClosed() {
        var acc = TranslationStreamAccumulator()
        // The head is ambiguous until `]` arrives — no interim yet, but nothing is lost.
        XCTAssertNil(acc.acceptDelta("[e"))
        let interim = acc.acceptDelta("s] Hello")
        XCTAssertEqual(interim?.text, "Hello")
        XCTAssertEqual(interim?.language, "es")
    }

    func testSubtagLanguageCodeParses() {
        var acc = TranslationStreamAccumulator()
        let interim = acc.acceptDelta("[pt-BR] Oi")
        XCTAssertEqual(interim?.language, "pt-br")
        XCTAssertEqual(interim?.text, "Oi")
    }

    func testMissingTagDegradesToPlainText() {
        var acc = TranslationStreamAccumulator()
        let interim = acc.acceptDelta("Hello there")
        XCTAssertEqual(interim?.text, "Hello there")
        XCTAssertNil(interim?.language)
    }

    func testMalformedBracketIsKeptVerbatim() {
        var acc = TranslationStreamAccumulator()
        // Brackets that aren't a language code are content, not a tag.
        let interim = acc.acceptDelta("[shouting] stop the car")
        XCTAssertEqual(interim?.text, "[shouting] stop the car")
        XCTAssertNil(interim?.language)
    }

    func testUnclosedBracketEventuallyGivesUp() {
        var acc = TranslationStreamAccumulator()
        XCTAssertNil(acc.acceptDelta("[this bracket"))
        let interim = acc.acceptDelta(" never closes and keeps going")
        XCTAssertNotNil(interim)
        XCTAssertTrue(interim!.text.hasPrefix("[this bracket"))
        XCTAssertNil(interim?.language)
    }

    func testIsLanguageCodeAcceptsAndRejects() {
        XCTAssertTrue(TranslationStreamAccumulator.isLanguageCode("es"))
        XCTAssertTrue(TranslationStreamAccumulator.isLanguageCode("yue"))
        XCTAssertTrue(TranslationStreamAccumulator.isLanguageCode("pt-BR"))
        XCTAssertTrue(TranslationStreamAccumulator.isLanguageCode("zh-Hans"))
        XCTAssertFalse(TranslationStreamAccumulator.isLanguageCode(""))
        XCTAssertFalse(TranslationStreamAccumulator.isLanguageCode("e"))
        XCTAssertFalse(TranslationStreamAccumulator.isLanguageCode("shouting"))
        XCTAssertFalse(TranslationStreamAccumulator.isLanguageCode("a-b-c"))
        XCTAssertFalse(TranslationStreamAccumulator.isLanguageCode("12"))
    }

    // MARK: - TranslationStreamAccumulator: turn lifecycle

    func testFinalEqualsLastInterim() {
        var acc = TranslationStreamAccumulator()
        _ = acc.acceptDelta("[es] The car")
        let interim = acc.acceptDelta(" is red")
        let final = acc.turnCompleted()
        XCTAssertEqual(final?.text, interim?.text)
        XCTAssertEqual(final?.language, interim?.language)
        XCTAssertEqual(final?.isFinal, true)
        XCTAssertEqual(interim?.isFinal, false)
    }

    func testTurnResetsForNextUtterance() {
        var acc = TranslationStreamAccumulator()
        _ = acc.acceptDelta("[es] First utterance")
        _ = acc.turnCompleted()
        let next = acc.acceptDelta("[fr] Second")
        XCTAssertEqual(next?.text, "Second")
        XCTAssertEqual(next?.language, "fr")
        XCTAssertNil(next?.original)
    }

    func testEmptyTurnYieldsNoFinal() {
        var acc = TranslationStreamAccumulator()
        XCTAssertNil(acc.turnCompleted())
        _ = acc.acceptDelta("   ")
        XCTAssertNil(acc.turnCompleted())
    }

    func testShortTaglessTurnFlushesBufferedHeadOnCompletion() {
        var acc = TranslationStreamAccumulator()
        // "[OK" style heads stay buffered waiting on a close — a turn end must flush, not drop.
        XCTAssertNil(acc.acceptDelta("[OK"))
        let final = acc.turnCompleted()
        XCTAssertEqual(final?.text, "[OK")
    }

    func testOriginalTranscriptRidesTheSegments() {
        var acc = TranslationStreamAccumulator()
        acc.acceptInputTranscription("Hola")
        acc.acceptInputTranscription(" amigo")
        let interim = acc.acceptDelta("[es] Hello friend")
        XCTAssertEqual(interim?.original, "Hola amigo")
        let final = acc.turnCompleted()
        XCTAssertEqual(final?.original, "Hola amigo")
        // And it resets with the turn.
        _ = acc.acceptDelta("[es] Next")
        XCTAssertNil(acc.acceptDelta(" one")?.original)
    }

    func testCJKDeltasJoinWithoutArtificialSpaces() {
        var acc = TranslationStreamAccumulator()
        _ = acc.acceptDelta("[zh] 你手里")
        _ = acc.acceptDelta(" 拿的")
        let interim = acc.acceptDelta(" 是")
        XCTAssertEqual(interim?.text, "你手里拿的是")
    }

    // MARK: - TranslationTierPolicy

    func testHIPAAForcesOffCloudEvenWhenConfigured() {
        XCTAssertEqual(
            TranslationTierPolicy.tier(hipaa: true, offline: false, cloudConfigured: true, onDeviceAvailable: true),
            .onDevice)
        if case .unavailable = TranslationTierPolicy.tier(hipaa: true, offline: false,
                                                          cloudConfigured: true, onDeviceAvailable: false) {
        } else {
            XCTFail("HIPAA without an on-device tier must be unavailable, never cloud")
        }
    }

    func testOfflinePrefersOnDevice() {
        XCTAssertEqual(
            TranslationTierPolicy.tier(hipaa: false, offline: true, cloudConfigured: true, onDeviceAvailable: true),
            .onDevice)
    }

    func testCloudWhenConfiguredAndPermitted() {
        XCTAssertEqual(
            TranslationTierPolicy.tier(hipaa: false, offline: false, cloudConfigured: true, onDeviceAvailable: true),
            .cloud)
    }

    func testUnconfiguredIsUnavailableWithReason() {
        guard case .unavailable(let reason) = TranslationTierPolicy.tier(
            hipaa: false, offline: false, cloudConfigured: false, onDeviceAvailable: false) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - TranslationPromptBuilder

    func testOneWayInstructionNamesTargetAndTagContract() {
        let prompt = TranslationPromptBuilder.instruction(direction: .oneWay(target: "es"))
        XCTAssertTrue(prompt.contains("Spanish"))
        XCTAssertTrue(prompt.contains("[es] "), "tag example must match the accumulator's contract")
        XCTAssertTrue(prompt.contains("ONLY the translation"))
    }

    func testTwoWayInstructionNamesBothLegs() {
        let prompt = TranslationPromptBuilder.instruction(direction: .twoWay("en", "ja"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Japanese"))
    }

    func testInjectionResistanceRulePresent() {
        // The stream is bystander speech — the prompt must pin the model against treating it
        // as instructions.
        let prompt = TranslationPromptBuilder.instruction(direction: .oneWay(target: "en"))
        XCTAssertTrue(prompt.contains("not requests addressed to you"))
    }

    // MARK: - PCMConverter.resample

    func testResampleHalvesLengthAt2xDownsample() {
        let samples = [Float](repeating: 0.5, count: 480)
        let out = PCMConverter.resample(samples, from: 48_000, to: 16_000)
        XCTAssertEqual(out.count, 160)
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.5) < 0.0001 }, "constant signal survives resampling")
    }

    func testResampleEqualRatesPassesThrough() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(PCMConverter.resample(samples, from: 16_000, to: 16_000), samples)
    }

    func testResampleLinearRampStaysLinear() {
        let ramp = (0..<48).map { Float($0) / 48 }
        let out = PCMConverter.resample(ramp, from: 48_000, to: 16_000)
        XCTAssertEqual(out.count, 16)
        for i in 1..<out.count {
            XCTAssertGreaterThan(out[i], out[i - 1], "downsampled ramp must stay monotonic")
        }
    }

    func testResampleEmptyAndDegenerateInputs() {
        XCTAssertTrue(PCMConverter.resample([], from: 48_000, to: 16_000).isEmpty)
        XCTAssertTrue(PCMConverter.resample([0.5], from: 0, to: 16_000).isEmpty)
        XCTAssertTrue(PCMConverter.resample([0.5], from: 48_000, to: 0).isEmpty)
    }

    // MARK: - Curated languages

    func testCuratedLanguageCodesAreUniqueAndTaggable() {
        let codes = TranslationLanguages.curated.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        for code in codes {
            XCTAssertTrue(TranslationStreamAccumulator.isLanguageCode(code), code)
        }
    }

    func testDisplayNameFallsBackForUncuratedCode() {
        XCTAssertEqual(TranslationLanguages.displayName(for: "es"), "Spanish")
        XCTAssertEqual(TranslationLanguages.displayName(for: "nl"), "Dutch") // via Locale fallback
    }
}
