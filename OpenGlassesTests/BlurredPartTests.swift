import XCTest
@testable import OpenGlasses

/// What a blur pass's report comes to on the session's clock: the counts the manifest carries and
/// the `filter` gaps the timeline carries (Plan HE §1; Contracts/recorded-session.md §3, §4).
final class BlurredPartTests: XCTestCase {
    private typealias Report = BlurredPart.Report

    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }
    private func span(_ from: Double, _ to: Double) -> BlurredPart.Span { .init(from: t(from), to: t(to)) }

    /// A part whose video runs from 100 s to 160 s of the session.
    private let video = SessionTimeline.Part(partID: "part-1", tZero: SessionTime(seconds: 100),
                                             duration: SessionTime(seconds: 60))

    // MARK: - The counts

    func testWhatIsKeptFollowsFromWhatWasWritten() {
        let whole = Report(framesWritten: 24, framesDropped: 0, keptSound: true)
        XCTAssertTrue(whole.keptPictures)
        XCTAssertFalse(whole.keptNothing)
        let soundOnly = Report(framesWritten: 0, framesDropped: 24, keptSound: true)
        XCTAssertFalse(soundOnly.keptPictures)
        XCTAssertFalse(soundOnly.keptNothing)
        XCTAssertTrue(Report(framesWritten: 0, framesDropped: 24, keptSound: false).keptNothing)
    }

    func testTheManifestsCountIsEveryFrameDroppedAcrossTheParts() {
        let parts = [BlurredPart(partID: "part-1", framesWritten: 100, framesDropped: 3),
                     BlurredPart(partID: "part-2", framesWritten: 50, framesDropped: 0),
                     BlurredPart(partID: "part-3", framesWritten: 0, framesDropped: 12)]
        XCTAssertEqual(BlurredPart.droppedFrames(parts), 15)
        XCTAssertEqual(BlurredPart.droppedFrames([]), 0)
    }

    // MARK: - Placing a report on the session's clock

    func testAPartWithNothingDroppedHasNoGaps() {
        let part = BlurredPart(partID: "part-1", report: Report(framesWritten: 1_440, framesDropped: 0, keptSound: true),
                               video: video)
        XCTAssertEqual(part, BlurredPart(partID: "part-1", framesWritten: 1_440, framesDropped: 0))
    }

    /// One lost frame is counted and is not a gap: the picture before it is held a little longer.
    /// A gap is "no video here" to the office's rules, and one frame must not cut an action in two.
    func testARunShorterThanASecondIsCountedAndNotWrittenAsAGap() {
        let report = Report(framesWritten: 1_437, framesDropped: 3,
                            droppedRuns: [.init(from: 10, to: 10.042), .init(from: 30, to: 30.999)], keptSound: true)
        let part = BlurredPart(partID: "part-1", report: report, video: video)
        XCTAssertEqual(part.framesDropped, 3)
        XCTAssertEqual(part.gaps, [])
    }

    func testARunOfASecondOrMoreIsAGapOnTheSessionsClock() {
        let report = Report(framesWritten: 1_300, framesDropped: 140,
                            droppedRuns: [.init(from: 40, to: 44.5), .init(from: 10, to: 11), .init(from: 20, to: 20.5)],
                            keptSound: true)
        let part = BlurredPart(partID: "part-1", report: report, video: video)
        XCTAssertEqual(part.gaps, [span(110, 111), span(140, 144.5)], "in time order, moved to where the part lies")
        XCTAssertEqual(BlurredPart.gapThreshold, t(1))
    }

    func testAGapIsHeldInsideThePartItBelongsTo() {
        let report = Report(framesWritten: 100, framesDropped: 200,
                            droppedRuns: [.init(from: -5, to: 2), .init(from: 55, to: 90)], keptSound: false)
        let part = BlurredPart(partID: "part-1", report: report, video: video)
        XCTAssertEqual(part.gaps, [span(100, 102), span(155, 160)])
    }

    func testARunThatIsNotANumberIsNotAGap() {
        let report = Report(framesWritten: 100, framesDropped: 5,
                            droppedRuns: [.init(from: .nan, to: 9), .init(from: 3, to: .infinity)], keptSound: true)
        XCTAssertEqual(BlurredPart(partID: "part-1", report: report, video: video).gaps, [])
    }

    /// With no picture written the whole of the part's video is a gap, however short it was.
    func testAPartWithNoPictureLeftIsOneGapTheLengthOfItsVideo() {
        let short = SessionTimeline.Part(partID: "part-2", tZero: t(5), duration: SessionTime(milliseconds: 400))
        let report = Report(framesWritten: 0, framesDropped: 10, droppedRuns: [.init(from: 0, to: 0.4)], keptSound: true)
        XCTAssertEqual(BlurredPart(partID: "part-2", report: report, video: short).gaps, [span(5, 5.4)])
    }

    func testAPartTheJournalHasNoVideoForHasNoGaps() {
        let report = Report(framesWritten: 0, framesDropped: 1, keptSound: true)
        let part = BlurredPart(partID: "part-1", report: report, video: nil)
        XCTAssertEqual(part.gaps, [])
        XCTAssertEqual(part.framesDropped, 1)
    }

    // MARK: - The timeline's gaps

    private func gap(_ track: SessionTimeline.TrackKind, _ from: Double, _ to: Double,
                     _ reason: SessionTimeline.GapReason) -> SessionTimeline.Gap {
        .init(track: track, from: t(from), to: t(to), reason: reason)
    }

    func testWithNothingDroppedTheGapsBetweenPartsAreLeftAsTheyWere() {
        let between = [gap(.video, 60, 70, .pause), gap(.audio, 60, 70.2, .pause)]
        XCTAssertEqual(BlurredPart.timelineGaps(between: between, blurred: []), between)
        XCTAssertEqual(BlurredPart.timelineGaps(
            between: between, blurred: [BlurredPart(partID: "part-1", framesWritten: 10, framesDropped: 1)]), between)
    }

    func testAFilterGapInsideAPartIsAddedOnTheVideoTrack() {
        let between = [gap(.video, 60, 70, .pause), gap(.audio, 60, 70.2, .pause)]
        let blurred = [BlurredPart(partID: "part-1", framesWritten: 10, framesDropped: 30, gaps: [span(20, 22)])]
        XCTAssertEqual(BlurredPart.timelineGaps(between: between, blurred: blurred),
                       between + [gap(.video, 20, 22, .filter)])
    }

    /// A part none of whose pictures could be blurred has no video left, so the gap between its
    /// neighbours now runs across it. The stretch the blur emptied is cut out of that gap, so no
    /// moment of the video has two reasons; the sound's gaps are not touched.
    func testAStretchTheBlurEmptiedIsCutOutOfTheGapItLiesIn() {
        let between = [gap(.video, 60, 130, .pause), gap(.audio, 60, 70.2, .pause), gap(.audio, 100, 130, .stall)]
        let blurred = [BlurredPart(partID: "part-2", framesWritten: 0, framesDropped: 700, gaps: [span(70, 100)])]
        XCTAssertEqual(BlurredPart.timelineGaps(between: between, blurred: blurred), [
            gap(.video, 60, 70, .pause), gap(.video, 100, 130, .pause),
            gap(.audio, 60, 70.2, .pause), gap(.audio, 100, 130, .stall),
            gap(.video, 70, 100, .filter),
        ])
    }

    func testAGapWhollyInsideAStretchTheBlurEmptiedIsGone() {
        let blurred = [BlurredPart(partID: "part-1", framesWritten: 0, framesDropped: 9, gaps: [span(10, 50)])]
        XCTAssertEqual(BlurredPart.timelineGaps(between: [gap(.video, 20, 30, .stall)], blurred: blurred),
                       [gap(.video, 10, 50, .filter)])
    }

    // MARK: - On disk

    func testABlurredPartIsReadBackAsItWasWritten() throws {
        let part = BlurredPart(partID: "part-3", framesWritten: 1_200, framesDropped: 48, gaps: [span(12.5, 14.25)])
        let read = try JSONDecoder().decode(BlurredPart.self, from: JSONEncoder().encode(part))
        XCTAssertEqual(read, part)
    }
}
