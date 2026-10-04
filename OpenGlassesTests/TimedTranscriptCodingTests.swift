import XCTest
@testable import OpenGlasses

/// `transcript.json` version 1 (Contracts/recorded-session.md §5) against the golden transcript.
final class TimedTranscriptCodingTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias U = TimedTranscript.Utterance
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    func testTheGoldenTranscriptReadsAsWhatWasSaid() throws {
        let transcript = try F.goldenTranscript()
        XCTAssertEqual(transcript.utterances.map(\.id), (1...11).map { "u\($0)" })
        XCTAssertEqual(transcript.utterances[0],
                       U(id: "u1", start: t(12), end: t(16.5), text: "First, switch the boiler off at the isolator."))
        XCTAssertEqual(transcript.utterance(id: "u5")?.start, t(63.2))
        XCTAssertEqual(transcript.utterance(id: "u10")?.text,
                       "Once that's done, refit the cover. New step. Restore the power.")
        XCTAssertNil(transcript.utterance(id: "u12"))
    }

    func testThePhoneWritesTheGoldenTranscriptByteForByte() throws {
        XCTAssertEqual(String(decoding: try F.goldenTranscript().encoded(), as: UTF8.self),
                       String(decoding: try F.data("recorded-session-transcript-v1"), as: UTF8.self))
    }

    func testASpeakerIsWrittenOnlyWhenThereIsOne() throws {
        let transcript = TimedTranscript(utterances: [
            U(id: "u1", start: t(1), end: t(2), text: "Hello.", speaker: "speaker-0"),
            U(id: "u2", start: t(3), end: t(4), text: "Hi."),
        ])
        XCTAssertEqual(String(decoding: try transcript.encoded(), as: UTF8.self),
                       #"{"utterances":[{"end":2,"id":"u1","speaker":"speaker-0","start":1,"text":"Hello."},"#
                           + #"{"end":4,"id":"u2","start":3,"text":"Hi."}]}"#)
        XCTAssertEqual(try TimedTranscript.decode(transcript.encoded()), transcript)
    }

    func testUtterancesAreKeptInTimeOrderAndNumberedInIt() {
        let numbered = TimedTranscript.numbered([
            U(start: t(9), end: t(10), text: "third"),
            U(id: "x", start: t(1), end: t(4), text: "second"),
            U(start: t(1), end: t(2), text: "first"),
            U(start: t(9), end: t(10), text: "fourth"),
        ])
        XCTAssertEqual(numbered.utterances.map(\.text), ["first", "second", "third", "fourth"])
        XCTAssertEqual(numbered.utterances.map(\.id), ["u1", "u2", "u3", "u4"])
    }

    func testAPartsTranscriptIsPlacedOnTheSessionClock() {
        let part = TimedTranscript.numbered([U(start: t(0.5), end: t(2), text: "Back on.")])
        let placed = part.shifted(by: t(126.5))
        XCTAssertEqual(placed.utterances, [U(id: "u1", start: t(127), end: t(128.5), text: "Back on.")])
    }

    func testMembersThisVersionDoesNotKnowArePassedOver() throws {
        let read = try TimedTranscript.decode(Data(
            #"{"language":"en","utterances":[{"id":"u1","start":1,"end":2,"text":"Hello.","words":[]}]}"#.utf8))
        XCTAssertEqual(read.utterances, [U(id: "u1", start: t(1), end: t(2), text: "Hello.")])
    }

    func testWhatIsNotATranscriptIsRefused() {
        let refused = [
            "not JSON": "transcript",
            "no utterances": "{}",
            "no id": #"{"utterances":[{"start":1,"end":2,"text":"Hello."}]}"#,
            "an empty id": #"{"utterances":[{"id":"","start":1,"end":2,"text":"Hello."}]}"#,
            "an id used twice": #"{"utterances":[{"id":"u1","start":1,"end":2,"text":"a"},{"id":"u1","start":3,"end":4,"text":"b"}]}"#,
            "ends before it starts": #"{"utterances":[{"id":"u1","start":2,"end":1,"text":"Hello."}]}"#,
            "no text": #"{"utterances":[{"id":"u1","start":1,"end":2}]}"#,
        ]
        for (name, json) in refused {
            XCTAssertThrowsError(try TimedTranscript.decode(Data(json.utf8)), name) {
                XCTAssertEqual($0 as? TimedTranscript.Refusal, .malformed, name)
            }
        }
    }

    func testATranscriptWhoseIDsWouldNotReadBackIsNotWritten() {
        XCTAssertThrowsError(try TimedTranscript(utterances: [U(start: t(1), end: t(2), text: "no id")]).encoded())
        XCTAssertThrowsError(try TimedTranscript(utterances: [U(id: "u1", start: t(1), end: t(2), text: "a"),
                                                              U(id: "u1", start: t(3), end: t(4), text: "b")]).encoded())
    }
}
