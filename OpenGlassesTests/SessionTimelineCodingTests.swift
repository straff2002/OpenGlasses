import XCTest
@testable import OpenGlasses

/// `timeline.json` version 1 (Contracts/recorded-session.md §4) against the golden timeline: what
/// the phone writes, byte for byte, and what a reader makes of a file from a later version.
final class SessionTimelineCodingTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias T = SessionTimeline
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    /// The golden job, built here the way a recorder would build it.
    private func golden() -> SessionTimeline {
        SessionTimeline(
            wallStart: 1_800_000_000_000,
            tracks: [
                T.Track(track: .video, parts: [T.Part(partID: "v1", tZero: t(0.25), duration: t(119.75)),
                                               T.Part(partID: "v2", tZero: t(126.5), duration: t(173.5))]),
                T.Track(track: .audio, parts: [T.Part(partID: "a1", tZero: t(0.2), duration: t(299.8))]),
            ],
            gaps: [T.Gap(track: .video, from: t(120), to: t(126.5), reason: .stall),
                   T.Gap(track: .video, from: t(200), to: t(200.4), reason: .filter)],
            events: [
                T.Event(t: t(39.6), kind: .toolCall, ref: "procedure_runner"),
                T.Event(t: t(40), kind: .procedureStarted, ref: "no-heat-check"),
                T.Event(t: t(42), kind: .procedureStep, ref: "remove-cover"),
                T.Event(t: t(58.3), kind: .photo, ref: "photo-1"),
                T.Event(t: t(95), kind: .procedureStep, ref: "check-fuse"),
                T.Event(t: t(110), kind: .procedureCompleted, ref: "no-heat-check"),
                T.Event(t: t(129.8), kind: .turnStarted),
                T.Event(t: t(131), kind: .turnLogged, ref: "turn-2", text: "The fuse looks fine.",
                        speaker: T.Speaker.technician, precision: .aligned),
                T.Event(t: t(143.8), kind: .turnLogged, ref: "turn-3",
                        text: "Noted. Refit the cover when you are ready.",
                        speaker: T.Speaker.assistant, precision: .coarse),
                T.Event(t: t(144), kind: .assistantSpeakingBegan),
                T.Event(t: t(144), kind: .captureSilenced),
                T.Event(t: t(147.5), kind: .assistantSpeakingEnded),
                T.Event(t: t(147.5), kind: .capturePassed),
                T.Event(t: t(240), kind: .userMarker),
            ],
            candidates: [T.Candidate(from: t(12), to: t(143), certainty: .likely, reason: "step_run"),
                         T.Candidate(from: t(40), to: t(110), certainty: .certain, reason: "procedure_run"),
                         T.Candidate(from: t(210), to: t(270), certainty: .certain, reason: "user_marker")])
    }

    // MARK: - The golden timeline

    func testTheGoldenTimelineReadsAsTheJobThatWasRecorded() throws {
        XCTAssertEqual(try F.goldenTimeline(), golden())
    }

    func testThePhoneWritesTheGoldenTimelineByteForByte() throws {
        XCTAssertEqual(String(decoding: try golden().encoded(), as: UTF8.self),
                       String(decoding: try F.data("recorded-session-timeline-v1"), as: UTF8.self))
    }

    func testTheFileHasExactlyTheContractsMembers() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden().encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["clock", "tracks", "gaps", "events", "candidates"])
        let clock = try XCTUnwrap(object["clock"] as? [String: Any])
        XCTAssertEqual(Set(clock.keys), ["wallStart", "monotonicZero"])
        XCTAssertEqual(clock["monotonicZero"] as? Int, 0)
        // A member with nothing to say is left out, not written as null.
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(Set(events[0].keys), ["t", "kind", "ref"])
        XCTAssertEqual(Set(events[6].keys), ["t", "kind"])
        XCTAssertEqual(Set(events[7].keys), ["t", "kind", "ref", "text", "speaker", "precision"])
    }

    func testEveryEventKindTheContractNamesIsWrittenUnderItsName() {
        XCTAssertEqual(Set(T.EventKind.allCases.map(\.rawValue)), [
            "turn_started", "turn_logged", "assistant_speaking_began", "assistant_speaking_ended", "tool_call",
            "photo", "procedure_started", "procedure_step", "procedure_completed", "capture_silenced",
            "capture_passed", "user_marker"])
    }

    // MARK: - Written order

    func testATimelineIsWrittenInOrderWhateverOrderItWasBuiltIn() throws {
        var shuffled = golden()
        shuffled.tracks.reverse()
        shuffled.gaps.reverse()
        shuffled.candidates.reverse()
        shuffled.events = shuffled.events.filter { $0.t != t(144) && $0.t != t(147.5) }.reversed()
            + golden().events.filter { $0.t == t(144) || $0.t == t(147.5) }
        XCTAssertEqual(try shuffled.encoded(), try golden().encoded())
        XCTAssertEqual(shuffled.normalized(), golden())
    }

    func testEventsAtTheSameMomentKeepTheOrderTheyWereAddedIn() {
        let a = T.Event(t: t(5), kind: .captureSilenced)
        let b = T.Event(t: t(5), kind: .assistantSpeakingBegan)
        let early = T.Event(t: t(1), kind: .turnStarted)
        XCTAssertEqual(T(wallStart: 0, events: [a, b, early]).normalized().events, [early, a, b])
        XCTAssertEqual(T(wallStart: 0, events: [b, a, early]).normalized().events, [early, b, a])
    }

    // MARK: - A tolerant reader

    private func timeline(events: String = "[]", extra: String = "", gaps: String = "[]",
                          candidates: String = "[]", zero: String = "0") -> Data {
        Data("""
        {"clock":{"wallStart":1800000000000,"monotonicZero":\(zero)},\(extra)
         "tracks":[{"track":"video","parts":[{"partID":"v1","tZero":0,"duration":60}]}],
         "gaps":\(gaps),"events":\(events),"candidates":\(candidates)}
        """.utf8)
    }

    func testAnEventKindThisVersionDoesNotKnowIsPassedOverNeverRefused() throws {
        let read = try T.decode(timeline(events: """
        [{"t":1,"kind":"turn_started"},
         {"t":2,"kind":"thermal_warning","level":"serious"},
         {"kind":"battery_swap","at":"later","t":"not a time"},
         {"t":3,"kind":"photo","ref":"photo-1","lens":"wide"}]
        """))
        XCTAssertEqual(read.events, [T.Event(t: t(1), kind: .turnStarted),
                                     T.Event(t: t(3), kind: .photo, ref: "photo-1")])
    }

    func testMembersThisVersionDoesNotKnowArePassedOver() throws {
        let read = try T.decode(timeline(extra: #""device":{"model":"fictional"},"#))
        XCTAssertEqual(read.tracks.map(\.track), [.video])
        XCTAssertEqual(read.wallStart, 1_800_000_000_000)
    }

    func testAnUnknownTrackGoesWithItsGapsAndAnUnknownGapReasonIsStillAGap() throws {
        let read = try T.decode(Data("""
        {"clock":{"wallStart":1,"monotonicZero":0},
         "tracks":[{"track":"depth","parts":[{"partID":"d1","tZero":0,"duration":9}]},
                   {"track":"video","parts":[{"partID":"v1","tZero":0,"duration":60}]}],
         "gaps":[{"track":"depth","from":1,"to":2,"reason":"stall"},
                 {"track":"video","from":10,"to":12,"reason":"lens_covered"}],
         "events":[],"candidates":[{"from":1,"to":2,"certainty":"possible","reason":"hunch"},
                                   {"from":3,"to":4,"certainty":"likely","reason":"step_run"}]}
        """.utf8))
        XCTAssertEqual(read.tracks.map(\.track), [.video])
        XCTAssertEqual(read.gaps, [T.Gap(track: .video, from: t(10), to: t(12), reason: T.GapReason(rawValue: "lens_covered"))])
        XCTAssertEqual(read.clearSpans(.video).map(\.to), [t(10), t(60)], "a gap of any reason cuts the video")
        XCTAssertEqual(read.candidates, [T.Candidate(from: t(3), to: t(4), certainty: .likely, reason: "step_run")])
        // The reason it does not know is written back as it was read.
        XCTAssertTrue(String(decoding: try read.encoded(), as: UTF8.self).contains(#""reason":"lens_covered""#))
    }

    func testAnUnknownPrecisionIsNoPrecision() throws {
        let read = try T.decode(timeline(events: #"[{"t":1,"kind":"turn_logged","ref":"r","precision":"exact"}]"#))
        XCTAssertEqual(read.events, [T.Event(t: t(1), kind: .turnLogged, ref: "r")])
    }

    func testWhatIsNotATimelineIsRefused() {
        let refused: [(String, Data)] = [
            ("not JSON", Data("timeline".utf8)),
            ("an array", Data("[]".utf8)),
            ("no clock", Data(#"{"tracks":[],"gaps":[],"events":[],"candidates":[]}"#.utf8)),
            ("no events", Data(#"{"clock":{"wallStart":1,"monotonicZero":0},"tracks":[],"gaps":[],"candidates":[]}"#.utf8)),
            ("a zero that is not the session's", timeline(zero: "1500")),
            ("a known event with no time", timeline(events: #"[{"kind":"photo"}]"#)),
            ("an event with no kind", timeline(events: #"[{"t":1}]"#)),
            ("a time that is text", timeline(gaps: #"[{"track":"video","from":"1","to":2,"reason":"stall"}]"#)),
        ]
        for (name, data) in refused {
            XCTAssertThrowsError(try T.decode(data), name) { XCTAssertEqual($0 as? T.Refusal, .malformed, name) }
        }
    }

    // MARK: - Clear spans

    func testClearSpansAreThePartsWithEveryGapCutOut() throws {
        XCTAssertEqual(try F.goldenTimeline().clearSpans(.video), [
            T.ClearSpan(partID: "v1", from: t(0.25), to: t(120)),
            T.ClearSpan(partID: "v2", from: t(126.5), to: t(200)),
            T.ClearSpan(partID: "v2", from: t(200.4), to: t(300)),
        ])
        XCTAssertEqual(try F.goldenTimeline().clearSpans(.audio), [T.ClearSpan(partID: "a1", from: t(0.2), to: t(300))],
                       "a gap on the video does not cut the audio")
    }

    func testAGapAtAPartsEdgeOrCoveringItLeavesNoEmptySpan() {
        let part = T.Part(partID: "v1", tZero: t(10), duration: t(10))
        func spans(_ gaps: [T.Gap]) -> [T.ClearSpan] {
            T(wallStart: 0, tracks: [T.Track(track: .video, parts: [part])], gaps: gaps).clearSpans(.video)
        }
        XCTAssertEqual(spans([T.Gap(track: .video, from: t(5), to: t(12), reason: .stall)]),
                       [T.ClearSpan(partID: "v1", from: t(12), to: t(20))])
        XCTAssertEqual(spans([T.Gap(track: .video, from: t(18), to: t(25), reason: .stall)]),
                       [T.ClearSpan(partID: "v1", from: t(10), to: t(18))])
        XCTAssertEqual(spans([T.Gap(track: .video, from: t(0), to: t(30), reason: .pause)]), [])
        XCTAssertEqual(spans([T.Gap(track: .video, from: t(12), to: t(14), reason: .filter),
                              T.Gap(track: .video, from: t(13), to: t(16), reason: .filter)]),
                       [T.ClearSpan(partID: "v1", from: t(10), to: t(12)), T.ClearSpan(partID: "v1", from: t(16), to: t(20))])
        XCTAssertEqual(spans([T.Gap(track: .video, from: t(15), to: t(15), reason: .stall)]),
                       [T.ClearSpan(partID: "v1", from: t(10), to: t(20))], "a gap with no length cuts nothing")
    }
}
