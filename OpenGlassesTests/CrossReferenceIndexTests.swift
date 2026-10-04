import XCTest
@testable import OpenGlasses

/// The cross-reference index (Contracts/recorded-session.md §7.4) against `cross-reference-v1.json`.
final class CrossReferenceIndexTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias T = SessionTimeline
    private typealias U = TimedTranscript.Utterance
    private typealias Row = CrossReferenceIndex.Row
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private struct Expected: Decodable {
        let rows: [CrossReferenceIndex.Row]
    }

    private func event(_ id: String, _ start: Double, _ end: Double, _ action: String, evidence: [Double]? = nil) -> ActionEvent {
        ActionEvent(id: id, start: t(start), end: t(end), action: action, object: nil, tool: nil,
                    evidence: (evidence ?? [start]).map { ActionEvent.Moment(t: t($0)) }, utterances: [],
                    confidence: 0.9, lowConfidence: false)
    }

    private func video(_ seconds: Double, gaps: [(Double, Double)] = [], events: [T.Event] = []) -> T {
        T(wallStart: 0, tracks: [T.Track(track: .video, parts: [T.Part(partID: "v1", tZero: .zero, duration: t(seconds))])],
          gaps: gaps.map { T.Gap(track: .video, from: t($0.0), to: t($0.1), reason: .stall) }, events: events)
    }

    // MARK: - The fixture

    func testTheFixtureGivesItsRowsInOrder() throws {
        let fixture = try F.object("cross-reference-v1")
        let events: [ActionEvent] = try F.decoded(fixture["events"])
        let expected: Expected = try F.decoded(fixture["expected"])
        let rows = CrossReferenceIndex.build(timeline: try F.timeline(fixture["timeline"]),
                                             transcript: try F.transcript(fixture["transcript"]), events: events)
        XCTAssertEqual(rows.map(\.rowID), expected.rows.map(\.rowID))
        for (row, wanted) in zip(rows, expected.rows) {
            XCTAssertEqual(row, wanted, wanted.rowID)
        }
        XCTAssertEqual(rows.count, 8)
    }

    func testTheFixtureIsBuiltFromTheGoldenJobAndEventsThatPassValidation() throws {
        let fixture = try F.object("cross-reference-v1")
        XCTAssertEqual(try F.timeline(fixture["timeline"]), try F.goldenTimeline())
        XCTAssertEqual(try F.transcript(fixture["transcript"]), try F.goldenTranscript())
        // The events are in validated form: putting them through validation changes nothing.
        let events: [ActionEvent] = try F.decoded(fixture["events"])
        let output = try JSONSerialization.data(withJSONObject: ["action_events": try XCTUnwrap(fixture["events"])])
        let context = ActionEventValidator.Context(spanFrom: t(0), spanTo: t(300), timeline: try F.goldenTimeline(),
                                                   transcript: try F.goldenTranscript())
        let result = try ActionEventValidator.validate(output, context: context)
        XCTAssertEqual(result.events, events)
        XCTAssertEqual(result.rejected, [])
    }

    // MARK: - Same inputs, same rows

    func testTheSameInputsGiveTheSameRows() throws {
        let fixture = try F.object("cross-reference-v1")
        let events: [ActionEvent] = try F.decoded(fixture["events"])
        let timeline = try F.goldenTimeline()
        let transcript = try F.goldenTranscript()
        let first = CrossReferenceIndex.build(timeline: timeline, transcript: transcript, events: events)
        XCTAssertEqual(CrossReferenceIndex.build(timeline: timeline, transcript: transcript, events: events), first)
        // The order the events arrive in does not change the order of the rows.
        XCTAssertEqual(CrossReferenceIndex.build(timeline: timeline, transcript: transcript, events: events.reversed()), first)
    }

    func testRowsAtTheSameMomentAreOrderedByRowIDBytes() {
        // Four events that all begin at 100, and a step said long before them that none of them shows.
        let events = [event("b", 100, 101, "open window"), event("B", 100, 103, "close window"),
                      event("a10", 100, 104, "wipe sill"), event("a2", 100, 105, "lift latch")]
        let early = TimedTranscript.numbered([U(start: t(10), end: t(12), text: "Next, bleed the radiator.")])
        XCTAssertEqual(CrossReferenceIndex.build(timeline: video(300), transcript: early, events: events).map(\.rowID),
                       ["s-s1-1", "e-B", "e-a10", "e-a2", "e-b"], "by time, then by the bytes of the row id")
        // Said at 100 instead, the step has events near it, so it was seen and has no row of its own.
        let near = TimedTranscript.numbered([U(start: t(100), end: t(102), text: "Next, bleed the radiator.")])
        XCTAssertEqual(CrossReferenceIndex.build(timeline: video(300), transcript: near, events: events).map(\.rowID),
                       ["e-B", "e-a10", "e-a2", "e-b"])
    }

    // MARK: - Never across a gap

    func testARowNeverSpansAGap() throws {
        let fixture = try F.object("cross-reference-v1")
        let events: [ActionEvent] = try F.decoded(fixture["events"])
        let timeline = try F.goldenTimeline()
        let clear = timeline.clearSpans(.video)
        for row in CrossReferenceIndex.build(timeline: timeline, transcript: try F.goldenTranscript(), events: events) {
            XCTAssertTrue(clear.contains { $0.partID == row.video.partID && $0.from <= row.video.from && row.video.to <= $0.to },
                          row.rowID)
            XCTAssertLessThan(row.video.from, row.video.to, row.rowID)
        }
    }

    func testAStepSaidAcrossAGapIsOneRowForEachStretchOfVideo() {
        let transcript = TimedTranscript.numbered([U(start: t(16), end: t(27), text: "Next, vacuum the burner tray.")])
        let rows = CrossReferenceIndex.build(timeline: video(60, gaps: [(20, 25)]), transcript: transcript, events: [])
        XCTAssertEqual(rows.map(\.rowID), ["s-s1-1", "s-s1-2"])
        XCTAssertEqual(rows.map(\.video), [CrossReferenceIndex.Video(partID: "v1", from: t(16), to: t(20)),
                                           CrossReferenceIndex.Video(partID: "v1", from: t(25), to: t(27))])
        XCTAssertEqual(rows.map(\.utterances), [["u1"], ["u1"]])
        XCTAssertEqual(rows.map(\.agreement), [.saidNotSeen, .saidNotSeen])
    }

    func testWordsSaidWhileNothingWasRecordedHaveNoRow() {
        let transcript = TimedTranscript.numbered([U(start: t(21), end: t(24), text: "Next, vacuum the burner tray.")])
        XCTAssertEqual(CrossReferenceIndex.build(timeline: video(60, gaps: [(20, 25)]), transcript: transcript, events: []), [])
    }

    func testAnEventThatIsNotOnOneClearStretchGetsNoRow() {
        let rows = CrossReferenceIndex.build(timeline: video(60, gaps: [(20, 25)]), transcript: TimedTranscript(utterances: []),
                                             events: [event("across", 18, 27, "lift panel"), event("clear", 30, 35, "lift panel")])
        XCTAssertEqual(rows.map(\.rowID), ["e-clear"])
    }

    // MARK: - The step a row belongs to

    func testARowTakesTheStepTheRunnerWasOnWhenItBegins() {
        let timeline = video(300, events: [
            T.Event(t: t(40), kind: .procedureStarted, ref: "service"),
            T.Event(t: t(50), kind: .procedureStep, ref: "one"),
            T.Event(t: t(90), kind: .procedureStep, ref: "two"),
            T.Event(t: t(120), kind: .procedureCompleted, ref: "service"),
            T.Event(t: t(200), kind: .procedureStep, ref: "stray"),
        ])
        let events = [event("before", 10, 12, "x"), event("started", 41, 45, "x"), event("atOne", 50, 55, "x"),
                      event("inOne", 89, 95, "x"), event("inTwo", 90, 95, "x"), event("after", 120, 125, "x"),
                      event("stray", 201, 205, "x")]
        let steps = CrossReferenceIndex.build(timeline: timeline, transcript: TimedTranscript(utterances: []), events: events)
            .reduce(into: [String: String]()) { $0[$1.rowID] = $1.step.map { "\($0.procedureID)/\($0.stepID)" } ?? "none" }
        XCTAssertEqual(steps, ["e-before": "none", "e-started": "none", "e-atOne": "service/one", "e-inOne": "service/one",
                               "e-inTwo": "service/two", "e-after": "none", "e-stray": "none"])
    }

    // MARK: - Written form

    func testARowIsWrittenInTheContractsShapeAndPointsAtMediaByPartAndTime() throws {
        let transcript = TimedTranscript.numbered([U(start: t(10), end: t(12), text: "Remove the cover.")])
        let rows = CrossReferenceIndex.build(timeline: video(60), transcript: transcript,
                                             events: [event("a1", 11, 14, "remove cover", evidence: [12, 13.5])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(rows), as: UTF8.self),
                       #"[{"agreement":"confirmed_by_speech","events":["a1"],"keyframes":[{"t":12},{"t":13.5}],"rowID":"e-a1","utterances":["u1"],"video":{"from":11,"partID":"v1","to":14}}]"#)
    }
}
