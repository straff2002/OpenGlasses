import XCTest
@testable import OpenGlasses

/// A recording's timeline and transcript put together when it stops: the media, what was noted as
/// it happened, and what the job log wrote down, all on the one clock.
final class RecordedJobAssemblyTests: XCTestCase {
    private typealias A = RecordedJobAssembly
    private typealias U = TimedTranscript.Utterance
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private let wallStart = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock: SessionClock { SessionClock(wallStart: wallStart, monotonicStart: 5_000) }
    private func wall(_ seconds: Double) -> Date { wallStart.addingTimeInterval(seconds) }

    private func part(_ id: String, from: Double, for length: Double, audioLate: Double = 0.2,
                      endedBy: SessionTimeline.GapReason? = nil) -> RecordingTimebase.PlacedPart {
        RecordingTimebase(video: .init(firstSample: 5_000 + from, duration: length),
                          audio: .init(firstSample: 5_000 + from + audioLate, duration: length - audioLate))
            .placed(partID: id, on: clock, endedBy: endedBy)
    }

    // MARK: - The transcript

    func testEachPartsWordsAreMovedToWhereItsSoundBegins() {
        let parts = [part("part-1", from: 0, for: 60, endedBy: .stall), part("part-2", from: 70, for: 60)]
        let transcript = A.transcript([
            .init(partID: "part-2", utterances: [U(start: t(5), end: t(8), text: "Next, refit the cover.")]),
            .init(partID: "part-1", utterances: [U(start: t(10), end: t(12), text: " First, isolate the supply. "),
                                                 U(start: t(20), end: t(21), text: "   ")]),
        ], parts: parts)

        XCTAssertEqual(transcript.utterances.map(\.id), ["u1", "u2"], "numbered in time order, blanks left out")
        XCTAssertEqual(transcript.utterances[0], U(id: "u1", start: t(10.2), end: t(12.2), text: "First, isolate the supply."))
        XCTAssertEqual(transcript.utterances[1], U(id: "u2", start: t(75.2), end: t(78.2), text: "Next, refit the cover."))
    }

    func testWordsForAPartWithNoSoundOnTheTimelineAreLeftOut() {
        let silent = RecordingTimebase(video: .init(firstSample: 5_000, duration: 30)).placed(partID: "part-1", on: clock)
        let transcript = A.transcript([.init(partID: "part-1", utterances: [U(start: t(1), end: t(2), text: "Hello.")]),
                                       .init(partID: "no-such-part", utterances: [U(start: t(1), end: t(2), text: "Hi.")])],
                                      parts: [silent])
        XCTAssertEqual(transcript.utterances, [])
    }

    func testWordsDoNotRunPastTheSoundTheyWereHeardIn() {
        let transcript = A.transcript([.init(partID: "part-1", utterances: [U(start: t(55), end: t(70), text: "Done.")])],
                                      parts: [part("part-1", from: 0, for: 60)])
        XCTAssertEqual(transcript.utterances.first?.end, t(60))
    }

    // MARK: - The timeline

    func testTheMediaTheNotedEventsAndTheJobLogLandOnOneClock() throws {
        let parts = [part("part-1", from: 0, for: 120, endedBy: .stall), part("part-2", from: 126.5, for: 80)]
        let words = [A.PartWords(partID: "part-1", utterances: [
            U(start: t(99.8), end: t(102.8), text: "What's the torque for the flange bolts?"),
        ])]
        let noted: [SessionTimeline.Event] = [
            .init(t: t(99.5), kind: .turnStarted),
            .init(t: t(104), kind: .toolCall, ref: "manual_lookup"),
            .init(t: t(108), kind: .assistantSpeakingBegan),
            .init(t: t(108), kind: .captureSilenced),
            .init(t: t(111), kind: .assistantSpeakingEnded),
            .init(t: t(111), kind: .capturePassed),
            .init(t: t(150), kind: .userMarker),
        ]
        let log: [A.LogEntry] = [
            .init(at: wall(107), kind: .technicianTurn(ref: "turn-1", text: "what is the torque for the flange bolts")),
            .init(at: wall(108), kind: .assistantTurn(ref: "assistant:turn-1", text: "Twenty-five newton metres.")),
            .init(at: wall(140), kind: .photo(ref: "photo-1.jpg")),
            .init(at: wall(160), kind: .procedureStarted(procedureID: "no-heat-check")),
            .init(at: wall(162), kind: .procedureStep(stepID: "remove-cover")),
            .init(at: wall(190), kind: .procedureCompleted(procedureID: "no-heat-check")),
        ]
        let assembled = A.assemble(clock: clock, parts: parts, noted: noted, log: log, words: words, endedAt: t(206.5))
        let timeline = assembled.timeline

        XCTAssertEqual(timeline.wallStart, 1_800_000_000_000)
        XCTAssertEqual(timeline.tracks.map(\.track), [.video, .audio])
        XCTAssertEqual(timeline.gaps.map(\.reason), [.stall, .stall])
        XCTAssertEqual(timeline.gaps.first, .init(track: .video, from: t(120), to: t(126.5), reason: .stall))

        // The technician's turn is moved to where its words begin; the assistant's stays at its stamp.
        let turns = timeline.events.filter { $0.kind == .turnLogged }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0], .init(t: t(100), kind: .turnLogged, ref: "turn-1",
                                       text: "what is the torque for the flange bolts",
                                       speaker: SessionTimeline.Speaker.technician, precision: .aligned))
        XCTAssertEqual(turns[1].t, t(108))
        XCTAssertEqual(turns[1].speaker, SessionTimeline.Speaker.assistant)
        XCTAssertEqual(turns[1].precision, .coarse)

        XCTAssertEqual(timeline.events.first { $0.kind == .toolCall }?.ref, "manual_lookup")
        XCTAssertEqual(timeline.events.first { $0.kind == .photo }, .init(t: t(140), kind: .photo, ref: "photo-1.jpg"))
        XCTAssertEqual(timeline.events.first { $0.kind == .procedureStep }?.ref, "remove-cover")
        XCTAssertEqual(timeline.events.map(\.t), timeline.events.map(\.t).sorted(), "written in time order")

        // A run of the procedure runner and a spoken mark are certain candidates.
        XCTAssertTrue(timeline.candidates.contains(.init(from: t(160), to: t(190), certainty: .certain,
                                                         reason: ProcedureCandidateDetector.Reason.procedureRun)))
        XCTAssertTrue(timeline.candidates.contains(.init(from: t(120), to: t(180), certainty: .certain,
                                                         reason: ProcedureCandidateDetector.Reason.userMarker)))

        // Both files read back as what was written.
        XCTAssertEqual(try SessionTimeline.decode(timeline.encoded()), timeline)
        XCTAssertEqual(try TimedTranscript.decode(assembled.transcript.encoded()), assembled.transcript)
    }

    /// Where the organisation requires blur, the stretches the blur left without a picture are
    /// `filter` gaps on the video, beside the gaps between parts. With nothing blurred, the
    /// timeline is exactly what it was.
    func testWhereTheBlurLeftNoPictureThereIsAFilterGapOnTheVideo() {
        let parts = [part("part-1", from: 0, for: 60, endedBy: .pause), part("part-2", from: 70, for: 60)]
        func assembled(_ blurred: [BlurredPart]) -> SessionTimeline {
            A.assemble(clock: clock, parts: parts, noted: [], log: [], words: [], endedAt: t(130), blurred: blurred).timeline
        }
        let plain = assembled([])
        XCTAssertEqual(plain, A.assemble(clock: clock, parts: parts, noted: [], log: [], words: [], endedAt: t(130)).timeline)
        XCTAssertEqual(plain.gaps.map(\.reason), [.pause, .pause])

        let blurred = assembled([
            BlurredPart(partID: "part-1", framesWritten: 1_400, framesDropped: 40,
                        gaps: [.init(from: t(20), to: t(21.5))]),
            BlurredPart(partID: "part-2", framesWritten: 1_440, framesDropped: 0),
        ])
        XCTAssertEqual(blurred.gaps, [
            .init(track: .video, from: t(20), to: t(21.5), reason: .filter),
            .init(track: .video, from: t(60), to: t(70), reason: .pause),
            .init(track: .audio, from: t(60), to: t(70.2), reason: .pause),
        ])
        XCTAssertEqual(blurred.tracks, plain.tracks, "the parts are where they were")
        // The office's rules see the stretch as no video: nothing clear spans it.
        XCTAssertEqual(blurred.clearSpans(.video).map { [$0.from, $0.to] },
                       [[t(0), t(20)], [t(21.5), t(60)], [t(70), t(130)]])
    }

    func testATurnWhoseWordsAreNotInTheTranscriptKeepsItsLogTimeAndSaysSo() {
        let assembled = A.assemble(
            clock: clock, parts: [part("part-1", from: 0, for: 60)], noted: [],
            log: [.init(at: wall(30), kind: .technicianTurn(ref: nil, text: "Is the gasket reusable?"))],
            words: [], endedAt: t(60))
        let turn = assembled.timeline.events.first
        XCTAssertEqual(turn?.t, t(30))
        XCTAssertEqual(turn?.precision, .coarse)
        XCTAssertEqual(turn?.ref, "log-1", "a turn the log gave no id still has one a reader can point at")
        XCTAssertEqual(assembled.transcript.utterances, [])
    }

    func testOnlyWhatHappenedWhileTheRecordingRanIsOnItsTimeline() {
        let assembled = A.assemble(
            clock: clock, parts: [part("part-1", from: 0, for: 60)],
            noted: [.init(t: t(-2), kind: .turnStarted), .init(t: t(30), kind: .userMarker),
                    .init(t: t(61), kind: .turnStarted)],
            log: [.init(at: wall(-5), kind: .photo(ref: "before.jpg")),
                  .init(at: wall(20), kind: .photo(ref: "during.jpg")),
                  .init(at: wall(90), kind: .technicianTurn(ref: "after", text: "All done."))],
            words: [], endedAt: t(60))
        XCTAssertEqual(assembled.timeline.events.map(\.kind), [.photo, .userMarker])
        XCTAssertEqual(assembled.timeline.events.first?.ref, "during.jpg")
    }

    func testEventsWhileTheRecordingWasPausedAreKept() {
        // The clock runs through a pause; only the media stops.
        let parts = [part("part-1", from: 0, for: 30, endedBy: .pause), part("part-2", from: 100, for: 30)]
        let assembled = A.assemble(clock: clock, parts: parts, noted: [],
                                   log: [.init(at: wall(60), kind: .photo(ref: "while-paused.jpg"))],
                                   words: [], endedAt: t(130))
        XCTAssertEqual(assembled.timeline.events.map(\.ref), ["while-paused.jpg"])
        XCTAssertEqual(assembled.timeline.gaps.map(\.reason), [.pause, .pause])
    }

    func testARecordingWithNoWordsStillHasATranscriptFile() throws {
        let assembled = A.assemble(clock: clock, parts: [part("part-1", from: 0, for: 10)], noted: [], log: [],
                                   words: [], endedAt: t(10))
        XCTAssertEqual(try TimedTranscript.decode(assembled.transcript.encoded()).utterances, [])
        XCTAssertEqual(assembled.timeline.candidates, [])
    }

    func testThreeNarratedStepsMakeALikelyCandidate() {
        let words = [A.PartWords(partID: "part-1", utterances: [
            U(start: t(10), end: t(14), text: "First, isolate the supply at the board."),
            U(start: t(20), end: t(24), text: "Next, take the cover off the unit."),
            U(start: t(30), end: t(34), text: "Then check the fuse with the meter."),
        ])]
        let assembled = A.assemble(clock: clock, parts: [part("part-1", from: 0, for: 60, audioLate: 0)], noted: [],
                                   log: [], words: words, endedAt: t(60))
        XCTAssertEqual(assembled.timeline.candidates.map(\.certainty), [.likely])
        XCTAssertEqual(assembled.timeline.candidates.first?.reason, ProcedureCandidateDetector.Reason.stepRun)
    }
}
