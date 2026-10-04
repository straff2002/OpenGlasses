import XCTest
@testable import OpenGlasses

/// A recorder's first-sample readings placed on the job's clock: every part a `tZero` and a
/// `duration`, and what lies between parts written down as a gap.
final class RecordingTimebaseTests: XCTestCase {
    private typealias T = RecordingTimebase
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    /// The session began when the monotonic clock read 5 000 s.
    private let clock = SessionClock(wallStart: Date(timeIntervalSince1970: 1_800_000_000), monotonicStart: 5_000)

    // MARK: - One part

    func testEachTrackIsPlacedByItsOwnFirstSample() {
        // The pictures began 0.4 s into the session; the sound 0.25 s after them.
        let timebase = T(video: .init(firstSample: 5_000.4, duration: 60), audio: .init(firstSample: 5_000.65, duration: 59.5))
        let placed = timebase.placed(partID: "part-1", on: clock)

        XCTAssertEqual(placed.video, SessionTimeline.Part(partID: "part-1", tZero: t(0.4), duration: t(60)))
        XCTAssertEqual(placed.audio, SessionTimeline.Part(partID: "part-1", tZero: t(0.65), duration: t(59.5)))
        XCTAssertEqual(placed.start, t(0.4))
        XCTAssertEqual(placed.end, t(60.4), "the later of the two ends")
        XCTAssertNil(placed.endedBy)
    }

    func testATrackWithNoSamplesHasNoPart() {
        let silent = T(video: .init(firstSample: 5_010, duration: 12)).placed(partID: "p", on: clock)
        XCTAssertNotNil(silent.video)
        XCTAssertNil(silent.audio, "a part with no sound says so by having no audio entry")

        let nothing = T().placed(partID: "p", on: clock)
        XCTAssertTrue(T().isEmpty)
        XCTAssertNil(nothing.video)
        XCTAssertNil(nothing.audio)
        XCTAssertNil(nothing.end)
    }

    func testAPartOfNoLengthOrWithReadingsThatAreNotNumbersCoversNothing() {
        for track in [T.Track(firstSample: 5_010, duration: 0), .init(firstSample: 5_010, duration: 0.0004),
                      .init(firstSample: 5_010, duration: -3), .init(firstSample: .nan, duration: 5),
                      .init(firstSample: 5_010, duration: .infinity)] {
            XCTAssertNil(T(video: track).placed(partID: "p", on: clock).video, "\(track)")
        }
    }

    func testAFirstSampleFromBeforeTheSessionsZeroIsHeldAtZero() {
        let placed = T(video: .init(firstSample: 4_999.2, duration: 10)).placed(partID: "p", on: clock)
        XCTAssertEqual(placed.video?.tZero, .zero)
    }

    // MARK: - Several parts

    private func part(_ id: String, video: (Double, Double)?, audio: (Double, Double)?,
                      endedBy: SessionTimeline.GapReason? = nil) -> T.PlacedPart {
        T(video: video.map { .init(firstSample: 5_000 + $0.0, duration: $0.1) },
          audio: audio.map { .init(firstSample: 5_000 + $0.0, duration: $0.1) })
            .placed(partID: id, on: clock, endedBy: endedBy)
    }

    func testTheGapBetweenTwoPartsCarriesTheReasonTheFirstEnded() {
        let parts = [
            part("part-1", video: (0, 120), audio: (0.2, 119.8), endedBy: .stall),
            part("part-2", video: (126.5, 80), audio: (126.6, 79.9), endedBy: .pause),
            part("part-3", video: (300, 20), audio: (300.1, 19.9)),
        ]
        let (tracks, gaps) = T.tracksAndGaps(parts)

        XCTAssertEqual(tracks.map(\.track), [.video, .audio])
        XCTAssertEqual(tracks[0].parts.map(\.partID), ["part-1", "part-2", "part-3"])
        XCTAssertEqual(tracks[1].parts.map(\.tZero), [t(0.2), t(126.6), t(300.1)])
        XCTAssertEqual(gaps, [
            .init(track: .video, from: t(120), to: t(126.5), reason: .stall),
            .init(track: .video, from: t(206.5), to: t(300), reason: .pause),
            .init(track: .audio, from: t(120), to: t(126.6), reason: .stall),
            .init(track: .audio, from: t(206.5), to: t(300.1), reason: .pause),
        ])
    }

    func testAGapWithNoReasonGivenIsARestart() {
        let (_, gaps) = T.tracksAndGaps([part("a", video: (0, 10), audio: nil), part("b", video: (25, 10), audio: nil)])
        XCTAssertEqual(gaps, [.init(track: .video, from: t(10), to: t(25), reason: .restart)])
    }

    func testPartsThatTouchOrOverlapLeaveNoGap() {
        let (tracks, gaps) = T.tracksAndGaps([part("a", video: (0, 10), audio: nil, endedBy: .pause),
                                              part("b", video: (10, 5), audio: nil, endedBy: .pause),
                                              part("c", video: (14, 5), audio: nil)])
        XCTAssertEqual(tracks.first?.parts.count, 3)
        XCTAssertEqual(gaps, [])
    }

    func testPartsAreListedInTimeOrderHoweverTheyWereGiven() {
        let (tracks, gaps) = T.tracksAndGaps([part("late", video: (50, 5), audio: nil),
                                              part("early", video: (0, 5), audio: nil, endedBy: .stall)])
        XCTAssertEqual(tracks.first?.parts.map(\.partID), ["early", "late"])
        XCTAssertEqual(gaps, [.init(track: .video, from: t(5), to: t(50), reason: .stall)])
    }

    func testATrackNoPartHasIsNotListed() {
        let (tracks, gaps) = T.tracksAndGaps([part("a", video: (0, 10), audio: nil)])
        XCTAssertEqual(tracks.map(\.track), [.video])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(T.tracksAndGaps([]).tracks, [])
    }

    func testASoundlessPartBetweenTwoWithSoundIsAGapInTheSound() {
        let (_, gaps) = T.tracksAndGaps([part("a", video: (0, 10), audio: (0, 10), endedBy: .stall),
                                         part("b", video: (12, 10), audio: nil, endedBy: .pause),
                                         part("c", video: (30, 10), audio: (30, 10))])
        XCTAssertTrue(gaps.contains(.init(track: .audio, from: t(10), to: t(30), reason: .stall)),
                      "the sound's gap runs from where it last had sound to where it has it again")
    }

    // MARK: - The timeline it gives

    func testThePlacedPartsWriteATimelineThatReadsBack() throws {
        let (tracks, gaps) = T.tracksAndGaps([part("part-1", video: (0, 120), audio: (0.2, 119.8), endedBy: .stall),
                                              part("part-2", video: (126.5, 80), audio: (126.6, 79.9))])
        let timeline = SessionTimeline(wallStart: clock.wallStartMilliseconds, tracks: tracks, gaps: gaps)
        let read = try SessionTimeline.decode(timeline.encoded())
        XCTAssertEqual(read, timeline.normalized())
        XCTAssertEqual(read.clearSpans(.video).map(\.partID), ["part-1", "part-2"])
    }

    func testAPlacedPartIsKeptAndReadBackUnchanged() throws {
        let placed = part("part-1", video: (0.4, 60), audio: (0.65, 59.5), endedBy: .stall)
        let read = try JSONDecoder().decode(T.PlacedPart.self, from: JSONEncoder().encode(placed))
        XCTAssertEqual(read, placed)
    }
}
