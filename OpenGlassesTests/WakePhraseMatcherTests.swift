import XCTest
@testable import OpenGlasses

/// Whole-word wake matching, and why a short phrase gets no fuzzy allowance.
///
/// A field tester wants the single word "zulu". Under the old matcher — substring containment plus
/// two edits for any phrase of ten characters or fewer — that phrase wakes the assistant inside
/// half the sentences anyone says near it: "zulu" is two edits from "zoo", "blue", "rule" and
/// "you'll", and containment fires inside longer words.
final class WakePhraseMatcherTests: XCTestCase {

    private func match(_ transcript: String, _ phrases: [String]) -> String? {
        WakePhraseMatcher.match(transcript: transcript,
                                candidates: phrases.map { WakePhraseMatcher.Candidate(phrase: $0) })
    }

    // MARK: - The short-phrase corpus

    private var zuluCandidates: [WakePhraseMatcher.Candidate] {
        ([ "zulu" ] + WakePhraseAlternatives.generated(for: "zulu"))
            .map { WakePhraseMatcher.Candidate(phrase: $0, primary: "zulu") }
    }

    func testZuluWakesOnItsOwnAndAtTheHeadOfARequest() {
        for transcript in ["zulu",
                           "Zulu, what's the resistance",
                           "zulu what's the resistance across the windings",
                           "hey zulu are you there"] {
            XCTAssertEqual(WakePhraseMatcher.match(transcript: transcript, candidates: zuluCandidates),
                           "zulu", transcript)
        }
    }

    /// The sentences that must go unheard. Each one is within two edits of "zulu", contains it as
    /// a near-substring, or both — every way the old matcher went off.
    func testZuluDoesNotWakeOnOrdinarySpeech() {
        for transcript in ["we took the kids to the zoo on saturday",
                           "the blue one is leaking",
                           "that's the rule for r410a",
                           "you'll need a bigger wrench",
                           "she's at school until three",
                           "what was the result of the pressure test",
                           "the zoo is closed and the school is too",
                           "it's a blue ruler"] {
            XCTAssertNil(WakePhraseMatcher.match(transcript: transcript, candidates: zuluCandidates),
                         transcript)
        }
    }

    // MARK: - Whole-word matching

    func testAPhraseInsideALongerWordIsNotAMatch() {
        XCTAssertNil(match("hand me that ruler", ["rule"]))
        XCTAssertNil(match("the classroom was open", ["openglasses"]))
    }

    func testPunctuationDoesNotBreakAMatch() {
        XCTAssertEqual(match("hey claude, what's the time", ["hey claude"]), "hey claude")
        XCTAssertEqual(match("Openglasses — battery?", ["openglasses"]), "openglasses")
    }

    func testAnAlternativeReportsItsPrimary() {
        let candidates = [WakePhraseMatcher.Candidate(phrase: "hey claude"),
                          WakePhraseMatcher.Candidate(phrase: "hey cloud", primary: "hey claude")]
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "hey cloud what's the weather",
                                               candidates: candidates),
                       "hey claude")
    }

    // MARK: - The fuzzy allowance, and where it stops

    /// The misrecognitions the shipped phrases have always been matched through.
    func testTheShippedPhrasesKeepTheirFuzzyAllowance() {
        XCTAssertEqual(match("hey clause what's the time", ["hey claude"]), "hey claude")
        XCTAssertEqual(match("hey cloud what's the time", ["hey claude"]), "hey claude")
    }

    func testAShortPhraseGetsNoFuzzyAllowanceAtAll() {
        XCTAssertEqual(WakePhraseMatcher.fuzzyThreshold(forPhraseLength: 4), 0)
        XCTAssertEqual(WakePhraseMatcher.fuzzyThreshold(forPhraseLength: 6), 0)
        XCTAssertNil(match("the zoo was closed", ["zulu"]))
        XCTAssertNil(match("hand me the blue one", ["zulu"]))
    }

    func testTheThresholdScalesWithThePhrase() {
        XCTAssertEqual(WakePhraseMatcher.fuzzyThreshold(
            forPhraseLength: WakePhraseMatcher.shortestFuzzyPhrase - 1), 0)
        XCTAssertEqual(WakePhraseMatcher.fuzzyThreshold(forPhraseLength: 10), 2)
        XCTAssertEqual(WakePhraseMatcher.fuzzyThreshold(forPhraseLength: 16), 3)
        XCTAssertLessThanOrEqual(WakePhraseMatcher.fuzzyThreshold(forPhraseLength: 8),
                                 WakePhraseMatcher.fuzzyThreshold(forPhraseLength: 20))
    }

    /// Fuzzy matching is still whole-window: it compares word runs, not any slice of characters.
    func testTheFuzzyPassComparesWholeWordWindows() {
        XCTAssertNil(match("theyheyclaudely", ["hey claude"]))
    }

    func testAnEmptyTranscriptOrPhraseMatchesNothing() {
        XCTAssertNil(match("", ["hey claude"]))
        XCTAssertNil(match("hey claude", [""]))
    }

    // MARK: - Hangul (Korean tester, 2026-10-09)

    /// A Hangul syllable is one character but two or three letters. Measured in characters the
    /// three-syllable name is "short" and gets no allowance; measured in letters it is on the
    /// same footing as "hey claude".
    func testHangulIsMeasuredInLettersNotSyllables() {
        XCTAssertEqual("아벤킨".count, 3)
        XCTAssertEqual(WakePhraseMatcher.fuzzyUnits("아벤킨").count, 8)
        XCTAssertEqual(WakePhraseMatcher.fuzzyUnits("hey claude").count, 10, "Latin is unchanged")
    }

    func testAOneVowelMishearingOfTheHangulNameWakes() {
        // 아 → 에: the recogniser heard the first vowel differently. One letter.
        XCTAssertEqual(WakePhraseMatcher.levenshteinDistance("에벤킨", "아벤킨"), 1)
        XCTAssertEqual(match("에벤킨 오늘 날씨 어때", ["아벤킨"]), "아벤킨")
    }

    /// Calling a name in Korean appends a vocative particle to it, as one token: "아벤킨아".
    func testTheNameWithAVocativeParticleWakes() {
        XCTAssertEqual(match("아벤킨아 지금 몇 시야", ["아벤킨"]), "아벤킨")
    }

    func testOrdinaryKoreanDoesNotWakeTheHangulName() {
        for transcript in ["아버지가 방에 들어가신다", "오늘 날씨가 참 좋네요", "안녕하세요 반갑습니다"] {
            XCTAssertNil(match(transcript, ["아벤킨"]), transcript)
        }
    }
}

/// The spellings a non-Latin recogniser gives a Latin wake phrase, and how they join the
/// candidate list.
final class WakePhraseScriptTests: XCTestCase {

    func testTheShippedNameIsSpelledInHangulForAKoreanRecognizer() {
        let spellings = WakePhraseScript.transliterations(of: "avenkin", scriptCode: "Kore")
        XCTAssertEqual(spellings, ["아벤킨"])
        XCTAssertEqual(WakePhraseScript.transliterations(of: "avenkin", scriptCode: "Hang"), ["아벤킨"])
    }

    func testALatinRecognizerGetsNoSpellings() {
        XCTAssertEqual(WakePhraseScript.transliterations(of: "avenkin", scriptCode: "Latn"), [])
        XCTAssertEqual(WakePhraseScript.transliterations(of: "avenkin", scriptCode: nil), [])
        XCTAssertNil(WakePhraseScript.transform(forScriptCode: "Hans"), "no Latin-to-Han table")
    }

    /// A recogniser writes an acronym it knows in Latin inside an otherwise-Hangul sentence
    /// ("헤이 GPT"), so every mix of the two spellings is offered, fully transliterated first.
    func testEveryMixOfLatinAndTransliteratedWordsIsOffered() {
        let spellings = WakePhraseScript.transliterations(of: "hey gpt", scriptCode: "Kore")
        XCTAssertEqual(spellings.count, 3)
        let hey = "hey".applyingTransform(.latinToHangul, reverse: false)!
        let gpt = "gpt".applyingTransform(.latinToHangul, reverse: false)!
        XCTAssertEqual(spellings.first, "\(hey) \(gpt)")
        XCTAssertTrue(spellings.contains("\(hey) gpt"))
        XCTAssertTrue(spellings.contains("hey \(gpt)"))
        XCTAssertFalse(spellings.contains("hey gpt"), "the phrase itself is already a candidate")
    }

    /// A phrase the wearer typed in the recogniser's own script needs nothing done to it.
    func testAPhraseAlreadyInTheScriptIsLeftAlone() {
        XCTAssertEqual(WakePhraseScript.transliterations(of: "아벤킨", scriptCode: "Kore"), [])
    }

    func testTransliterationsReportThePhraseTheyWereSpelledFrom() {
        let candidates = [WakePhraseMatcher.Candidate(phrase: "avenkin"),
                          WakePhraseMatcher.Candidate(phrase: "aven kin", primary: "avenkin")]
        let all = WakeWordService.withTransliterations(candidates, scriptCode: "Kore")
        XCTAssertEqual(Array(all.prefix(2)), candidates, "exact candidates stay first")
        let hangul = all.first { $0.phrase == "아벤킨" }
        XCTAssertEqual(hangul?.primary, "avenkin")
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "아벤킨 오늘 일정 알려줘", candidates: all), "avenkin")
        XCTAssertEqual(WakeWordService.withTransliterations(candidates, scriptCode: "Latn"), candidates)
    }

    func testOtherScriptsHaveATable() {
        XCTAssertEqual(WakePhraseScript.transliterations(of: "avenkin", scriptCode: "Cyrl"), ["авенкин"])
        XCTAssertFalse(WakePhraseScript.transliterations(of: "avenkin", scriptCode: "Jpan").isEmpty)
    }
}

/// Generated alternatives for a phrase nobody hand-tuned — structural only, never phonetic.
final class WakePhraseAlternativesTests: XCTestCase {

    func testACustomPhraseNoLongerGetsAnEmptyList() {
        XCTAssertFalse(Config.defaultAlternativesForPhrase("zulu").isEmpty,
                       "a custom phrase is the one nobody has tested the recogniser against")
    }

    func testTheCannedListsAreUntouched() {
        XCTAssertEqual(Config.defaultAlternativesForPhrase("hey claude"),
                       ["hey cloud", "hey claud", "hey clod", "hey clawed", "hey claudia"])
        XCTAssertEqual(Config.defaultAlternativesForPhrase("openglasses"),
                       ["open glasses", "openglass", "open glass"])
    }

    func testABareNameGainsTheGreetingForm() {
        XCTAssertEqual(WakePhraseAlternatives.generated(for: "zulu"), ["hey zulu"])
    }

    func testAGreetingIsOfferedAsTheWaysItIsMisheard() {
        let alternatives = WakePhraseAlternatives.generated(for: "hey zulu")
        XCTAssertTrue(alternatives.contains("hi zulu"))
        XCTAssertTrue(alternatives.contains("a zulu"))
    }

    /// The greeting is never dropped: a two-word phrase must not quietly become a one-word one,
    /// which is the shape that wakes on ordinary speech.
    func testTheBareRemainderIsNeverOffered() {
        XCTAssertFalse(WakePhraseAlternatives.generated(for: "hey zulu").contains("zulu"))
    }

    func testTwoWordsRunTogetherIsOffered() {
        XCTAssertTrue(WakePhraseAlternatives.generated(for: "field one").contains("fieldone"))
    }

    /// The line this generator will not cross: a phonetic neighbour is a guess about one person's
    /// voice, and it would hand back exactly the false-triggering the matcher was tightened to
    /// stop — in a list the wearer never typed.
    func testNoPhoneticNeighboursAreInvented() {
        let alternatives = WakePhraseAlternatives.generated(for: "zulu")
        for invented in ["zoo", "blue", "rule", "school", "zulu's"] {
            XCTAssertFalse(alternatives.contains(invented), invented)
        }
        for alternative in alternatives {
            XCTAssertTrue(alternative.contains("zulu"),
                          "every generated alternative must still contain the wearer's own word")
        }
    }

    func testTheOutputIsNormalisedAndNeverContainsThePhraseItself() {
        let alternatives = WakePhraseAlternatives.generated(for: "  Hey  Zulu!  ")
        XCTAssertFalse(alternatives.contains("hey zulu"))
        XCTAssertEqual(alternatives, alternatives.map { $0.lowercased() })
        XCTAssertEqual(Set(alternatives).count, alternatives.count)
    }

    func testAnEmptyPhraseGeneratesNothing() {
        XCTAssertTrue(WakePhraseAlternatives.generated(for: "   ").isEmpty)
    }
}
