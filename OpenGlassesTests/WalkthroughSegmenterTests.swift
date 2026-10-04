import XCTest
@testable import OpenGlasses

/// The segmenter against `walkthrough-segments-v1.json`, and the rules one at a time.
final class WalkthroughSegmenterTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias U = TimedTranscript.Utterance
    private typealias S = WalkthroughSegmenter
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private struct Expected: Decodable, Equatable {
        let id: String
        let start: SessionTime
        let end: SessionTime
        let text: String
        let utterances: [String]
        let opening: String
        let stepLike: Bool

        init(_ segment: WalkthroughSegmenter.Segment) {
            id = segment.id
            start = segment.start
            end = segment.end
            text = segment.text
            utterances = segment.utteranceIDs
            opening = segment.opening.rawValue
            stepLike = segment.isStepLike
        }
    }

    private func segments(_ utterances: U...) -> [S.Segment] {
        S.segments(TimedTranscript.numbered(utterances))
    }

    // MARK: - The fixture

    func testEveryFixtureCaseGivesItsSegments() throws {
        let cases = try F.cases(F.object("walkthrough-segments-v1"))
        XCTAssertEqual(cases.count, 6)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected: [Expected] = try F.decoded(item["expected"])
            XCTAssertEqual(S.segments(try F.transcript(item["transcript"])).map(Expected.init), expected, name)
        }
    }

    func testTheFixturesRulesAreTheRulesInTheCode() throws {
        let rules = try XCTUnwrap(F.object("walkthrough-segments-v1")["rules"] as? [String: Any])
        XCTAssertEqual(rules["silenceSeconds"] as? Double, S.Configuration.standard.silence.seconds)
        XCTAssertEqual(rules["minimumWords"] as? Int, S.Configuration.standard.minimumWords)
        XCTAssertEqual(Set(try XCTUnwrap(rules["fillers"] as? [String])), S.fillers)
        XCTAssertEqual(try XCTUnwrap(rules["markers"] as? [[String]]), S.markers)
        XCTAssertEqual(try XCTUnwrap(rules["explicitMarker"] as? [String]), S.explicitMarker)
        XCTAssertEqual(Set(try XCTUnwrap(rules["stepNumbers"] as? [String])), S.stepNumbers)
    }

    func testTheWalkthroughInTheFixtureIsTheGoldenTranscript() throws {
        let first = try XCTUnwrap(F.cases(F.object("walkthrough-segments-v1")).first)
        XCTAssertEqual(try F.transcript(first["transcript"]), try F.goldenTranscript())
    }

    // MARK: - Markers

    func testEachSpokenMarkerOpensAStep() {
        for opener in ["First", "Next", "Then", "Step three", "Step 12", "Now I'm going to", "Now I am going to",
                       "Once that's done", "Once that is done", "Okay, next", "And then", "So, first", "Um, right, next"] {
            let made = segments(U(start: t(0), end: t(3), text: "The cover is off."),
                                U(start: t(3.5), end: t(7), text: "\(opener) loosen the two clamps."))
            XCTAssertEqual(made.map(\.opening), [.start, .marker], opener)
            XCTAssertEqual(made.map(\.isStepLike), [false, true], opener)
        }
    }

    func testAMarkerWordThatIsNotAtTheStartOfASentenceOpensNothing() {
        for text in ["Loosen the first clamp.", "The next clamp is seized.", "Turn it and then pull.",
                     "Step carefully round it.", "Stepping back now.", "Firstly it looks fine."] {
            XCTAssertEqual(segments(U(start: t(0), end: t(3), text: "The cover is off."),
                                    U(start: t(3.5), end: t(7), text: text)).count, 1, text)
        }
    }

    func testNewStepOpensAStepEvenMidSentence() {
        let made = segments(U(start: t(0), end: t(3), text: "Loosen the clamp and"),
                            U(start: t(3.2), end: t(6), text: "new step pull the hose off."))
        XCTAssertEqual(made.map(\.opening), [.start, .newStep])
        XCTAssertEqual(made.map(\.text), ["Loosen the clamp and", "new step pull the hose off."])
    }

    func testASentenceIsNeverSplit() {
        // "then" begins the second utterance, but the first did not finish its sentence.
        let made = segments(U(start: t(0), end: t(3), text: "Loosen the clamp and"),
                            U(start: t(3.2), end: t(6), text: "then pull the hose off."))
        XCTAssertEqual(made.map(\.text), ["Loosen the clamp and then pull the hose off."])
        XCTAssertEqual(made.first?.utteranceIDs, ["u1", "u2"])
    }

    // MARK: - Silence

    func testASilenceLongerThanTheThresholdOpensASegmentAndOneExactlyAtItDoesNot() {
        let exactly = segments(U(start: t(0), end: t(3), text: "The cover is off."),
                               U(start: t(7), end: t(9), text: "It is quite corroded."))
        XCTAssertEqual(exactly.count, 1)
        let over = segments(U(start: t(0), end: t(3), text: "The cover is off."),
                            U(start: t(7.001), end: t(9), text: "It is quite corroded."))
        XCTAssertEqual(over.map(\.opening), [.start, .silence])
        XCTAssertEqual(over.map(\.isStepLike), [false, false], "a pause alone does not make a step")
    }

    func testALongSilenceSplitsEvenAnUnfinishedSentence() {
        let made = segments(U(start: t(0), end: t(3), text: "Loosen the clamp and"),
                            U(start: t(20), end: t(23), text: "then pull the hose off."))
        XCTAssertEqual(made.map(\.opening), [.start, .marker])
    }

    func testTheThresholdsCanBeChangedButTheContractUsesTheStandardOnes() {
        var loose = S.Configuration()
        loose.silence = t(1)
        let transcript = TimedTranscript.numbered([U(start: t(0), end: t(3), text: "The cover is off."),
                                                   U(start: t(5), end: t(8), text: "It is quite corroded.")])
        XCTAssertEqual(S.segments(transcript, configuration: loose).count, 2)
        XCTAssertEqual(S.segments(transcript).count, 1)
        XCTAssertEqual(S.Configuration.standard, S.Configuration())
    }

    // MARK: - Sentences and their times

    func testASentenceInsideAnUtteranceIsPlacedByHowFarAlongTheTextItBegins() {
        let utterance = U(id: "u1", start: t(136), end: t(143),
                          text: "Once that's done, refit the cover. New step. Restore the power.")
        let sentences = S.sentences(of: utterance)
        XCTAssertEqual(sentences.map(\.text), ["Once that's done, refit the cover.", "New step.", "Restore the power."])
        // 63 characters over 7 seconds; the second sentence begins at character 35, the third at 45.
        XCTAssertEqual(sentences.map(\.start), [t(136), t(139.888), t(141)])
        XCTAssertEqual(sentences.map(\.end), [t(139.888), t(141), t(143)])
    }

    func testSentencesEndOnlyAtAStopFollowedBySpaceOrTheEnd() {
        func texts(_ text: String) -> [String] {
            S.sentences(of: U(id: "u1", start: t(0), end: t(10), text: text)).map(\.text)
        }
        XCTAssertEqual(texts("It reads 3.5 volts. Good."), ["It reads 3.5 volts.", "Good."])
        XCTAssertEqual(texts("Is it off? Yes! Carry on..."), ["Is it off?", "Yes!", "Carry on..."])
        XCTAssertEqual(texts("  no stop at all  "), ["no stop at all"])
        XCTAssertEqual(texts("... "), [], "punctuation alone is not a sentence")
        XCTAssertEqual(texts(""), [])
    }

    func testAnUtteranceWithNoWordsIsPassedOver() {
        let made = segments(U(start: t(0), end: t(3), text: "The cover is off."),
                            U(start: t(3.5), end: t(4), text: "..."),
                            U(start: t(4.5), end: t(7), text: "Next, loosen the clamps."))
        XCTAssertEqual(made.map(\.utteranceIDs), [["u1"], ["u3"]])
        XCTAssertEqual(S.segments(TimedTranscript(utterances: [])), [])
    }

    // MARK: - Fragments

    func testATrailingFragmentStandsAlone() {
        let made = segments(U(start: t(0), end: t(3), text: "First, isolate the supply."),
                            U(start: t(3.5), end: t(4), text: "Next."))
        XCTAssertEqual(made.map(\.text), ["First, isolate the supply.", "Next."])
        XCTAssertEqual(made.map(\.opening), [.marker, .marker])
    }

    func testFragmentsInARowAllJoinTheStepTheyLeadTo() {
        let made = segments(U(start: t(0), end: t(1), text: "Next."),
                            U(start: t(9), end: t(10), text: "Okay."),
                            U(start: t(20), end: t(23), text: "Remove the cover."))
        XCTAssertEqual(made.map(\.text), ["Next. Okay. Remove the cover."])
        XCTAssertEqual(made.first?.opening, .marker)
        XCTAssertEqual(made.first?.start, t(0))
        XCTAssertEqual(made.first?.utteranceIDs, ["u1", "u2", "u3"])
    }

    func testSegmentsAreNumberedInOrderAfterJoining() {
        let made = segments(U(start: t(0), end: t(1), text: "Right."),
                            U(start: t(1.5), end: t(4), text: "First, isolate the supply."),
                            U(start: t(4.5), end: t(8), text: "Next, remove the cover."))
        XCTAssertEqual(made.map(\.id), ["s1", "s2"])
    }
}
