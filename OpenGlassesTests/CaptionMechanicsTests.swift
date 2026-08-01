import XCTest
@testable import OpenGlasses

/// Plan BY P1 — the pure caption mechanics: script-aware joining (the CJK fix), endpoint
/// debouncing, rolling compaction, the direction policy, and formatting.
final class CaptionMechanicsTests: XCTestCase {

    // MARK: - ScriptAwareJoiner: the reported defect

    func testCJKWordGapSpacesCollapse() {
        // The exact reported shape: ASR word-segmented Chinese with separator spaces.
        XCTAssertEqual(ScriptAwareJoiner.collapse("你手里 拿的 是"), "你手里拿的是")
    }

    func testMixedSentenceKeepsExactlyTheSpacesThatBelong() {
        // Latin islands keep their spacing; CJK-CJK gaps collapse.
        XCTAssertEqual(
            ScriptAwareJoiner.collapse("你手里 拿的 是 Hyperice 的 Hypervolt Go 3 按摩枪"),
            "你手里拿的是 Hyperice 的 Hypervolt Go 3 按摩枪")
    }

    func testLatinSpacingIsProvablyUntouched() {
        for text in ["hello world", "the quick brown fox", "set a timer for 5 minutes",
                     "a  double  space survives", " leading and trailing "] {
            XCTAssertEqual(ScriptAwareJoiner.collapse(text), text, text)
        }
    }

    func testCJKPunctuationCountsAsCJKNeighbour() {
        XCTAssertEqual(ScriptAwareJoiner.collapse("好的 。 谢谢"), "好的。谢谢")
        XCTAssertEqual(ScriptAwareJoiner.collapse("「 你好 」"), "「你好」")
    }

    func testKanaAndHangulCollapse() {
        XCTAssertEqual(ScriptAwareJoiner.collapse("こん にちは"), "こんにちは")
        XCTAssertEqual(ScriptAwareJoiner.collapse("안녕 하세요"), "안녕하세요")
    }

    func testLatinCJKBoundaryKeepsTheSpace() {
        // A space with only ONE CJK neighbour is legitimate separation.
        XCTAssertEqual(ScriptAwareJoiner.collapse("iPhone 是 好"), "iPhone 是好")
        XCTAssertEqual(ScriptAwareJoiner.collapse("是 iPhone"), "是 iPhone")
    }

    func testJoinCollapsesOnlyTheSeam() {
        XCTAssertEqual(ScriptAwareJoiner.join("你手里", " 拿的"), "你手里拿的")
        XCTAssertEqual(ScriptAwareJoiner.join("hello", " world"), "hello world")
        XCTAssertEqual(ScriptAwareJoiner.join("", "start"), "start")
        XCTAssertEqual(ScriptAwareJoiner.join("end", ""), "end")
        // Incremental joins equal whole-string collapse.
        var acc = ""
        for chunk in ["你手里", " 拿的", " 是", " Hypervolt", " Go"] {
            acc = ScriptAwareJoiner.join(acc, chunk)
        }
        XCTAssertEqual(acc, ScriptAwareJoiner.collapse("你手里 拿的 是 Hypervolt Go"))
    }

    /// TranscriptGuard now reads the same ranges — the refactor must not change its verdicts.
    func testTranscriptGuardStillDetectsCJKFraction() {
        XCTAssertEqual(TranscriptGuard.cjkFraction(of: "你好世界"), 1.0)
        XCTAssertEqual(TranscriptGuard.cjkFraction(of: "hello"), 0.0)
        // 4 CJK of 6 letters — the mixed case must clear the guard's majority threshold.
        XCTAssertGreaterThan(TranscriptGuard.cjkFraction(of: "你好 hi 世界"), 0.5)
        // 4 CJK of 9 letters — majority-Latin mixed text must NOT read as CJK-dominant.
        XCTAssertLessThan(TranscriptGuard.cjkFraction(of: "你好 hello 世界"), 0.5)
    }

    // MARK: - EndpointDebouncer

    func testPrematureEndpointIsDiscardedByArrivingTokens() {
        var debouncer = EndpointDebouncer(holdInterval: 0.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        debouncer.endpointSignaled(now: t0)
        XCTAssertFalse(debouncer.shouldCommit(now: t0.addingTimeInterval(0.3)),
                       "inside the hold window nothing commits")
        XCTAssertTrue(debouncer.tokensArrived(now: t0.addingTimeInterval(0.3)),
                      "tokens inside the window discard the endpoint — it was a premature split")
        XCTAssertFalse(debouncer.shouldCommit(now: t0.addingTimeInterval(10)),
                       "a discarded endpoint never commits")
    }

    func testSurvivingEndpointCommitsAfterHold() {
        var debouncer = EndpointDebouncer(holdInterval: 0.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        debouncer.endpointSignaled(now: t0)
        XCTAssertTrue(debouncer.shouldCommit(now: t0.addingTimeInterval(0.6)))
        debouncer.committed()
        XCTAssertFalse(debouncer.shouldCommit(now: t0.addingTimeInterval(10)))
    }

    func testTokensWithoutPendingEndpointAreNotADiscard() {
        var debouncer = EndpointDebouncer()
        XCTAssertFalse(debouncer.tokensArrived(now: Date()),
                       "ordinary mid-utterance tokens must not report a discarded endpoint")
    }

    // MARK: - CaptionCompactor

    func testFinalEqualsLastInterim() {
        var compactor = CaptionCompactor()
        compactor.acceptSegmentInterim("hello")
        compactor.acceptSegmentInterim("hello world")
        let lastInterim = compactor.rendered
        XCTAssertEqual(compactor.finalize(), lastInterim,
                       "no jarring rewrite at commit — the invariant this type exists for")
    }

    func testContinuationJoinsSegmentsIntoOneCaption() {
        var compactor = CaptionCompactor()
        compactor.acceptSegmentInterim("the meeting is")
        compactor.beginContinuation()   // premature endpoint discarded
        compactor.acceptSegmentInterim("moved to three")
        XCTAssertEqual(compactor.rendered, "the meeting is moved to three")
        XCTAssertEqual(compactor.finalize(), "the meeting is moved to three")
    }

    func testContinuationSeamIsScriptAware() {
        var compactor = CaptionCompactor()
        compactor.acceptSegmentInterim("会议改")
        compactor.beginContinuation()
        compactor.acceptSegmentInterim("到三点")
        XCTAssertEqual(compactor.rendered, "会议改到三点", "no Latin space forced between CJK segments")
    }

    func testSegmentRevisionKeepsCommittedPrefixStable() {
        var compactor = CaptionCompactor()
        compactor.acceptSegmentInterim("first part")
        compactor.beginContinuation()
        compactor.acceptSegmentInterim("second")
        compactor.acceptSegmentInterim("second thoughts")   // recognizer revised within segment
        XCTAssertEqual(compactor.rendered, "first part second thoughts")
        XCTAssertTrue(compactor.rendered.hasPrefix("first part"),
                      "committed text never rewrites, whatever the recognizer does later")
    }

    func testDeltaModePromotesLongTailsAndStaysBounded() {
        var compactor = CaptionCompactor(promoteThreshold: 50, revisableSuffixLength: 10, maxRendered: 200)
        for index in 0..<200 {
            compactor.acceptDelta("word\(index) ")
        }
        XCTAssertLessThanOrEqual(compactor.tail.count, 50, "tail stays token-granular and small")
        XCTAssertLessThanOrEqual(compactor.rendered.count, 210,
                                 "a monologue cannot grow the rendered caption without bound")
        XCTAssertTrue(compactor.rendered.hasPrefix("…"), "oldest text drops with an ellipsis")
        XCTAssertTrue(compactor.rendered.contains("word199"), "the newest text always survives")
    }

    func testShortUtteranceIsBehaviorPreserving() {
        // The flag defaults on because of this: one segment, no continuation → render and final
        // are exactly the raw recognizer text.
        var compactor = CaptionCompactor()
        compactor.acceptSegmentInterim("set a timer for five minutes")
        XCTAssertEqual(compactor.rendered, "set a timer for five minutes")
        XCTAssertEqual(compactor.finalize(), "set a timer for five minutes")
    }

    // MARK: - Direction policy

    func testDirectionPolicyRouting() {
        XCTAssertEqual(TranslationDirectionPolicy.oneWay(target: "en").renderLanguage(forDetected: "zh"), "en")
        XCTAssertEqual(TranslationDirectionPolicy.oneWay(target: "en").renderLanguage(forDetected: nil), "en")

        let twoWay = TranslationDirectionPolicy.twoWay("en", "zh")
        XCTAssertEqual(twoWay.renderLanguage(forDetected: "en-US"), "zh",
                       "each leg renders in the counterpart language")
        XCTAssertEqual(twoWay.renderLanguage(forDetected: "zh-Hans"), "en")
        XCTAssertNil(twoWay.renderLanguage(forDetected: "fr"),
                     "a third language routes nowhere rather than guessing")
        XCTAssertNil(twoWay.renderLanguage(forDetected: nil))
    }

    // MARK: - Formatter

    func testSpeakerLabelOnlyOnChange() {
        XCTAssertEqual(TranslationCaptionFormatter.line(text: "hi", speaker: 0, previousSpeaker: nil),
                       "[1]: hi")
        XCTAssertEqual(TranslationCaptionFormatter.line(text: "more", speaker: 0, previousSpeaker: 0),
                       "more", "same speaker → no label; the label never flickers")
        XCTAssertEqual(TranslationCaptionFormatter.line(text: "reply", speaker: 1, previousSpeaker: 0),
                       "[2]: reply")
        XCTAssertEqual(TranslationCaptionFormatter.line(text: "plain", speaker: nil, previousSpeaker: 0),
                       "plain", "undiarized text carries no label")
    }

    func testWindowLinesKeepTheMostRecentText() {
        let lines = TranslationCaptionFormatter.windowLines(
            "one two three four five six seven eight", maxCharsPerLine: 10, maxLines: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.last!.contains("eight"), "the tail wins — the past scrolls away")
    }

    func testWindowLinesHardWrapUnspacedRuns() {
        let lines = TranslationCaptionFormatter.windowLines(
            "会议改到三点开始请准时参加谢谢大家", maxCharsPerLine: 6, maxLines: 3)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 6 }, "unspaced CJK must still wrap")
    }
}
