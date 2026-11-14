import XCTest
@testable import OpenGlasses

/// Plan LT §5 — a wake-phrase alternative made of ordinary words wakes the assistant only at the
/// start of an utterance. The corpus is 36 ordinary sentences with an alternative inside them;
/// none may wake. The same alternatives at the start wake every time.
final class WakeAlternativePositionTests: XCTestCase {

    /// A fixed lexicon, so the rule is tested apart from the system dictionary.
    private static let ordinary: Set<String> = ["summary", "small", "tree", "even", "kin", "hey", "cloud"]
    private static func isOrdinary(_ word: String) -> Bool { ordinary.contains(word) }

    private static let primary = "avenkin"
    private static let alternatives = ["summary", "small tree", "even kin"]

    private var candidates: [WakePhraseMatcher.Candidate] {
        WakeAlternativePosition.marked(
            [WakePhraseMatcher.Candidate(phrase: Self.primary)]
            + Self.alternatives.map { WakePhraseMatcher.Candidate(phrase: $0, primary: Self.primary) },
            isOrdinaryWord: Self.isOrdinary)
    }

    private func wakes(_ transcript: String,
                       segments: [WakeAlternativePosition.Segment] = []) -> Bool {
        WakePhraseMatcher.match(transcript: transcript, candidates: candidates, segments: segments) != nil
    }

    static let corpus = [
        // "summary"
        "can you give me a summary of the meeting",
        "the summary says the unit was serviced in march",
        "i need a quick summary before i call the customer",
        "send the summary to the office",
        "that summary doesn't match the invoice",
        "write a short summary of the fault",
        "is there a summary at the end of the manual",
        "the executive summary is on page two",
        "read me the summary again",
        "we'll add a summary to the job notes",
        "his summary was wrong about the pressure",
        "put a summary in the handover",
        // "small tree"
        "there's a small tree growing against the condenser",
        "park next to the small tree by the gate",
        "we planted a small tree in the back garden",
        "the small tree is blocking the vent",
        "cut back that small tree before the install",
        "is that a small tree or a big shrub",
        "she hung lights on the small tree",
        "the unit sits behind a small tree",
        "watch out for the small tree on the left",
        "a small tree fell on the fence last night",
        "the dog sleeps under the small tree",
        "move the ladder away from the small tree",
        // "even kin"
        "we're not even kin, just neighbours",
        "they aren't even kin to the owner",
        "he said we were never even kin",
        "some of them are not even kin at all",
        "are they even kin or just friends",
        "the tenants aren't even kin of the landlord",
        "i don't think they're even kin",
        "nobody here is even kin to him",
        "you're not even kin and you still helped",
        "they called each other cousins but weren't even kin",
        "maybe they're distant cousins or not even kin",
        "the will left it to people who weren't even kin",
    ]

    func testTheCorpusIsThirtySixSentencesThatEachHoldAnAlternative() {
        XCTAssertEqual(Self.corpus.count, 36)
        for sentence in Self.corpus {
            let tokens = PhraseMatcher.tokenize(sentence)
            XCTAssertTrue(Self.alternatives.contains { PhraseMatcher.contains($0, in: tokens) }, sentence)
        }
    }

    func testOrdinarySentencesWakeOnNone() {
        for sentence in Self.corpus {
            XCTAssertFalse(wakes(sentence), sentence)
        }
    }

    /// Before LT every one of them woke: the alternatives matched anywhere.
    func testTheSameSentencesWokeWithoutTheRule() {
        let anywhere = ([Self.primary] + Self.alternatives).map {
            WakePhraseMatcher.Candidate(phrase: $0, primary: Self.primary)
        }
        for sentence in Self.corpus {
            XCTAssertNotNil(WakePhraseMatcher.match(transcript: sentence, candidates: anywhere), sentence)
        }
    }

    func testTheSameAlternativesAtTheStartWakeOnAll() {
        for alternative in Self.alternatives {
            for transcript in ["\(alternative)",
                               "\(alternative), what's on today",
                               "\(alternative) turn the lights on",
                               "hey \(alternative) what's the time",
                               "ok \(alternative), read me the next step",
                               "okay \(alternative) are you there",
                               "hi \(alternative)"] {
                XCTAssertTrue(wakes(transcript), transcript)
            }
        }
    }

    func testOnlyOneOpenerAndOnlyAtTheStart() {
        XCTAssertFalse(wakes("hey ok summary what's next"), "one opener, not two")
        XCTAssertFalse(wakes("well hey summary what's next"), "an opener mid-sentence is not a start")
    }

    /// The primary phrase and an alternative with an invented word keep matching anywhere.
    func testThePrimaryAndInventedAlternativesStillMatchAnywhere() {
        XCTAssertTrue(wakes("what's on my list, avenkin"))
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "what's on my list, avenkin", candidates: candidates),
                       Self.primary)
        let invented = WakeAlternativePosition.marked(
            [WakePhraseMatcher.Candidate(phrase: Self.primary),
             WakePhraseMatcher.Candidate(phrase: "aven kin", primary: Self.primary)],
            isOrdinaryWord: Self.isOrdinary)
        XCTAssertFalse(invented[1].startOnly)
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "what's on my list aven kin", candidates: invented),
                       Self.primary)
    }

    func testWhoIsStartBound() {
        XCTAssertTrue(WakeAlternativePosition.isStartBound(phrase: "summary", primary: "avenkin",
                                                           isOrdinaryWord: Self.isOrdinary))
        XCTAssertTrue(WakeAlternativePosition.isStartBound(phrase: "small tree", primary: "avenkin",
                                                           isOrdinaryWord: Self.isOrdinary))
        XCTAssertFalse(WakeAlternativePosition.isStartBound(phrase: "aven kin", primary: "avenkin",
                                                            isOrdinaryWord: Self.isOrdinary),
                       "one invented word keeps it anywhere")
        XCTAssertFalse(WakeAlternativePosition.isStartBound(phrase: "hey cloud", primary: "hey cloud",
                                                            isOrdinaryWord: Self.isOrdinary),
                       "a primary is never bound")
        XCTAssertFalse(WakeAlternativePosition.isStartBound(phrase: "", primary: "avenkin",
                                                            isOrdinaryWord: Self.isOrdinary))
    }

    // MARK: - Pauses

    private func segments(_ parts: [(String, TimeInterval, TimeInterval)]) -> [WakeAlternativePosition.Segment] {
        parts.map { WakeAlternativePosition.Segment(text: $0.0, timestamp: $0.1, duration: $0.2) }
    }

    func testAPauseOfAtLeastSevenTenthsStartsAnUtterance() {
        let transcript = "thanks summary what's next"
        let long = segments([("thanks", 0, 0.4), ("summary", 1.2, 0.5), ("what's", 1.8, 0.2), ("next", 2.0, 0.2)])
        XCTAssertTrue(wakes(transcript, segments: long), "0.8 s gap")
        let edge = segments([("thanks", 0, 0.4), ("summary", 1.1, 0.5), ("what's", 1.7, 0.2), ("next", 1.9, 0.2)])
        XCTAssertTrue(wakes(transcript, segments: edge), "0.7 s gap")
        let short = segments([("thanks", 0, 0.4), ("summary", 0.7, 0.5), ("what's", 1.3, 0.2), ("next", 1.5, 0.2)])
        XCTAssertFalse(wakes(transcript, segments: short), "0.3 s is one utterance")
        XCTAssertFalse(wakes(transcript), "no timestamps: only the first token starts")
    }

    func testAnOpenerAfterAPauseCounts() {
        let transcript = "cheers hey small tree lights on"
        let parts = segments([("cheers", 0, 0.3), ("hey", 1.5, 0.2), ("small", 1.8, 0.2),
                              ("tree", 2.0, 0.2), ("lights", 2.3, 0.2), ("on", 2.5, 0.1)])
        XCTAssertTrue(wakes(transcript, segments: parts))
    }

    func testUtteranceStarts() {
        XCTAssertEqual(WakeAlternativePosition.utteranceStarts(tokenCount: 0, segments: []), [])
        XCTAssertEqual(WakeAlternativePosition.utteranceStarts(tokenCount: 3, segments: []), [0])
        // Partial results carry zero timestamps: no gaps.
        let zeros = segments([("a", 0, 0), ("b", 0, 0), ("c", 0, 0)])
        XCTAssertEqual(WakeAlternativePosition.utteranceStarts(tokenCount: 3, segments: zeros), [0])
        // A multi-token segment advances the index by its tokens.
        let multi = segments([("well then", 0, 0.5), ("summary", 2, 0.4)])
        XCTAssertEqual(WakeAlternativePosition.utteranceStarts(tokenCount: 3, segments: multi), [0, 2])
        // Segments that do not line up with the transcript are not trusted.
        XCTAssertEqual(WakeAlternativePosition.utteranceStarts(tokenCount: 5, segments: multi), [0])
    }

    func testOpenersByLanguage() {
        let english = WakeAlternativePosition.openers(forLanguage: "en-US")
        XCTAssertEqual(english, ["hey", "ok", "okay", "hi"])
        XCTAssertTrue(WakeAlternativePosition.openers(forLanguage: "de_DE").contains("hallo"))
        XCTAssertTrue(WakeAlternativePosition.openers(forLanguage: "es").isSuperset(of: english))
        XCTAssertEqual(WakeAlternativePosition.openers(forLanguage: nil), english)
    }

    // MARK: - Fuzzy and unspaced matching keep the rule

    func testTheFuzzyPassHoldsAStartBoundAlternativeToTheStart() {
        // "small three" is one edit from "small tree", inside the fuzzy allowance.
        XCTAssertTrue(wakes("small three what's next"))
        XCTAssertFalse(wakes("there's a small three by the gate"))
    }

    func testAStartBoundUnspacedAlternativeOnlyAtTheTokensStart() {
        let bound = [WakePhraseMatcher.Candidate(phrase: "阿文金", primary: Self.primary, startOnly: true)]
        XCTAssertNotNil(WakePhraseMatcher.match(transcript: "阿文金今天天气怎么样", candidates: bound))
        XCTAssertNil(WakePhraseMatcher.match(transcript: "今天阿文金天气怎么样", candidates: bound))
    }

    // MARK: - The system lexicon on this device

    @MainActor
    func testTheSystemLexiconKnowsOrdinaryWordsFromInventedOnes() throws {
        guard WakeLexicon.checkerLanguage(forLocaleIdentifier: "en-US") != nil else {
            throw XCTSkip("no English dictionary on this runtime")
        }
        XCTAssertTrue(WakeLexicon.isOrdinaryWord("summary", localeIdentifier: "en-US"))
        XCTAssertTrue(WakeLexicon.isOrdinaryWord("tree", localeIdentifier: "en-US"))
        XCTAssertFalse(WakeLexicon.isOrdinaryWord("avenkin", localeIdentifier: "en-US"))
        XCTAssertFalse(WakeLexicon.isOrdinaryWord("summary", localeIdentifier: "xx-XX"),
                       "a language with no dictionary makes nothing ordinary")
    }
}
