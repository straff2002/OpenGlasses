import XCTest
@testable import OpenGlasses

/// Agreement between what was seen and what was said (Contracts/recorded-session.md §7.3) against
/// `agreement-v1.json`.
final class SpeechAgreementTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias U = TimedTranscript.Utterance
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private struct Expected: Decodable {
        struct Seen: Decodable, Equatable {
            let event: String
            let label: String
            let low_confidence: Bool
            let utterances: [String]
        }
        struct Unseen: Decodable, Equatable {
            let segment: String
            let label: String
            let from: SessionTime
            let to: SessionTime
            let utterances: [String]
        }
        let seen: [Seen]
        let unseen: [Unseen]
    }

    private func event(_ id: String, _ start: Double, _ end: Double, _ action: String, object: String? = nil,
                       tool: String? = nil, claimed: [String] = [], low: Bool = false) -> ActionEvent {
        ActionEvent(id: id, start: t(start), end: t(end), action: action, object: object, tool: tool,
                    evidence: [ActionEvent.Moment(t: t(start))], utterances: claimed, confidence: low ? 0.1 : 0.9,
                    lowConfidence: low)
    }

    // MARK: - The fixture

    func testEveryFixtureCaseGivesItsLabels() throws {
        let cases = try F.cases(F.object("agreement-v1"))
        XCTAssertEqual(cases.count, 10)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let events: [ActionEvent] = try F.decoded(item["events"])
            let expected: Expected = try F.decoded(item["expected"])
            let result = SpeechAgreement.assess(events: events, transcript: try F.transcript(item["transcript"]))
            XCTAssertEqual(result.seen.map {
                Expected.Seen(event: $0.eventID, label: $0.label.rawValue, low_confidence: $0.lowConfidence,
                              utterances: $0.utterances)
            }, expected.seen, name)
            XCTAssertEqual(result.unseen.map {
                Expected.Unseen(segment: $0.segmentID, label: SpeechAgreement.Label.saidNotSeen.rawValue, from: $0.from,
                                to: $0.to, utterances: $0.utterances)
            }, expected.unseen, name)
        }
    }

    func testTheFixtureCoversWhatTheContractAsksOfIt() throws {
        let cases = try F.cases(F.object("agreement-v1"))
        let expected: [Expected] = try cases.map { try F.decoded($0["expected"]) }
        let labels = Set(expected.flatMap { $0.seen.map(\.label) + $0.unseen.map(\.label) })
        XCTAssertEqual(labels, ["confirmed_by_speech", "seen_not_said", "said_not_seen"], "the three labels")
        XCTAssertTrue(expected.contains { $0.seen.contains(where: \.low_confidence) }, "a low-confidence event")
        let names = try cases.map { try XCTUnwrap($0["name"] as? String) }
        XCTAssertTrue(names.contains { $0.contains("negat") }, "the negation case")
        XCTAssertTrue(names.contains { $0.contains("window edge") }, "the window edges")
    }

    func testTheWindowIsFiveSeconds() throws {
        let rules = try XCTUnwrap(F.object("agreement-v1")["rules"] as? [String: Any])
        XCTAssertEqual(rules["windowSeconds"] as? Double, SpeechAgreement.window.seconds)
        XCTAssertEqual(SpeechAgreement.window, t(5))
    }

    // MARK: - The rule, piece by piece

    func testNearIsSymmetricAndClosedAtTheWindow() {
        XCTAssertTrue(SpeechAgreement.near(t(10), t(12), t(17), t(19)))
        XCTAssertTrue(SpeechAgreement.near(t(17), t(19), t(10), t(12)))
        XCTAssertFalse(SpeechAgreement.near(t(10), t(12), t(17.001), t(19)))
        XCTAssertFalse(SpeechAgreement.near(t(17.001), t(19), t(10), t(12)))
        XCTAssertTrue(SpeechAgreement.near(t(10), t(30), t(15), t(16)), "one inside the other")
    }

    func testEveryNearUtteranceThatSaysItConfirmsInTranscriptOrder() {
        let transcript = TimedTranscript.numbered([
            U(start: t(10), end: t(12), text: "Remove the cover."),
            U(start: t(13), end: t(15), text: "It's stiff."),
            U(start: t(16), end: t(18), text: "The cover is off now."),
            U(start: t(60), end: t(62), text: "Remove the cover."),
        ])
        let result = SpeechAgreement.assess(events: [event("e1", 11, 17, "remove cover")], transcript: transcript)
        XCTAssertEqual(result.seen, [SpeechAgreement.Seen(eventID: "e1", label: .confirmedBySpeech, lowConfidence: false,
                                                          utterances: ["u1", "u3"])])
    }

    func testOnlyStopWordsInCommonConfirmNothing() {
        let transcript = TimedTranscript.numbered([U(start: t(10), end: t(12), text: "Put it back on the other one.")])
        let result = SpeechAgreement.assess(events: [event("e1", 11, 12, "put the lid back on")], transcript: transcript)
        // "put" is shared and is a content word; the rest of what they share is not.
        XCTAssertEqual(result.seen.first?.label, .confirmedBySpeech)
        let none = SpeechAgreement.assess(events: [event("e2", 11, 12, "take it off the other one")], transcript: transcript)
        XCTAssertEqual(none.seen.first?.label, .seenNotSaid)
    }

    func testTheModelsClaimedUtterancesMakeNoDifference() {
        let transcript = TimedTranscript.numbered([U(start: t(10), end: t(12), text: "Remove the cover.")])
        let claimed = SpeechAgreement.assess(events: [event("e1", 11, 12, "remove cover", claimed: ["u9"])], transcript: transcript)
        let unclaimed = SpeechAgreement.assess(events: [event("e1", 11, 12, "remove cover")], transcript: transcript)
        XCTAssertEqual(claimed, unclaimed)
        XCTAssertEqual(claimed.seen.first?.utterances, ["u1"])
    }

    func testAStepIsSeenWhenAnyEventIsNearItWhateverTheEventShows() {
        let transcript = TimedTranscript.numbered([U(start: t(10), end: t(12), text: "Next, bleed the radiator."),
                                                   U(start: t(40), end: t(42), text: "Then refill the system.")])
        let result = SpeechAgreement.assess(events: [event("e1", 11, 12, "open window", low: true)], transcript: transcript)
        XCTAssertEqual(result.unseen, [SpeechAgreement.Unseen(segmentID: "s2", from: t(40), to: t(42), utterances: ["u2"])])
        XCTAssertEqual(result.seen.first?.label, .seenNotSaid)
        XCTAssertEqual(result.seen.first?.lowConfidence, true)
    }

    func testWithNoEventsEveryStepIsSaidAndNotSeenAndOtherTalkIsNot() throws {
        let result = SpeechAgreement.assess(events: [], transcript: try F.goldenTranscript())
        XCTAssertEqual(result.seen, [])
        XCTAssertEqual(result.unseen.map(\.segmentID), ["s1", "s2", "s3", "s4", "s5", "s7", "s8"])
    }

    func testWithNoTranscriptEveryEventIsSeenAndNotSaid() {
        let result = SpeechAgreement.assess(events: [event("e1", 11, 12, "remove cover")],
                                            transcript: TimedTranscript(utterances: []))
        XCTAssertEqual(result.seen.map(\.label), [.seenNotSaid])
        XCTAssertEqual(result.unseen, [])
    }
}
