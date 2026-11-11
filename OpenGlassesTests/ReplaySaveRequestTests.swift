import XCTest
@testable import OpenGlasses

/// Instant Replay P0/P2 — what a save asks for, what it will do, what the wearer hears, and the
/// passthrough composition's plan.
final class ReplaySaveRequestTests: XCTestCase {

    private let running = ReplayBufferPolicy.Decision.run(
        ReplayBufferPlan(bufferSeconds: 60, width: 720, height: 1280, frameRate: 15))

    // MARK: - Reading the request

    func testThirtySecondsToRecordingsByDefault() {
        let request = ReplaySaveRequest(arguments: [:])
        XCTAssertEqual(request.seconds, 30)
        XCTAssertEqual(request.destination, .recordings)
        XCTAssertNil(request.caption)
    }

    func testSecondsMinutesAndStringsAreRead() {
        XCTAssertEqual(ReplaySaveRequest(arguments: ["seconds": 45]).seconds, 45)
        XCTAssertEqual(ReplaySaveRequest(arguments: ["seconds": "20"]).seconds, 20)
        XCTAssertEqual(ReplaySaveRequest(arguments: ["minutes": 1]).seconds, 60)
        XCTAssertEqual(ReplaySaveRequest(arguments: ["seconds": -5]).seconds, 30)
        XCTAssertEqual(ReplaySaveRequest(arguments: ["caption": "  "]).caption, nil)
    }

    func testOnlyANamedDestinationLeavesRecordings() {
        XCTAssertEqual(ReplayDestination(argument: "job"), .job)
        XCTAssertEqual(ReplayDestination(argument: "Photos"), .photos)
        XCTAssertEqual(ReplayDestination(argument: "camera roll"), .photos)
        XCTAssertEqual(ReplayDestination(argument: nil), .recordings)
        XCTAssertEqual(ReplayDestination(argument: "my email"), .recordings,
                       "an unknown destination is never somewhere the wearer did not name")
    }

    // MARK: - The decision

    func testNotRunningRefusesWithTheReason() {
        let decision = ReplaySaveDecision.decide(ReplaySaveRequest(), buffer: .off(.medicalCompliance),
                                                 jobOpen: true, jobClipMaximum: 60)
        XCTAssertEqual(decision, .refuse(.notRunning(.medicalCompliance)))
    }

    func testTheAskIsHeldToTheBuffer() {
        let decision = ReplaySaveDecision.decide(ReplaySaveRequest(seconds: 300), buffer: running,
                                                 jobOpen: false, jobClipMaximum: 60)
        XCTAssertEqual(decision, .save(seconds: 60, destination: .recordings, cappedForJob: false))
    }

    func testTheJobNeedsAnOpenJob() {
        let decision = ReplaySaveDecision.decide(ReplaySaveRequest(destination: .job), buffer: running,
                                                 jobOpen: false, jobClipMaximum: 60)
        XCTAssertEqual(decision, .refuse(.noOpenJob))
    }

    func testAJobClipIsCappedAtTheJobClipMaximum() {
        let twoMinutes = ReplayBufferPolicy.Decision.run(
            ReplayBufferPlan(bufferSeconds: 120, width: 720, height: 1280, frameRate: 15))
        let decision = ReplaySaveDecision.decide(ReplaySaveRequest(seconds: 120, destination: .job),
                                                 buffer: twoMinutes, jobOpen: true, jobClipMaximum: 60)
        XCTAssertEqual(decision, .save(seconds: 60, destination: .job, cappedForJob: true))
    }

    // MARK: - What the wearer hears

    func testTheReplies() {
        func saved(_ dest: ReplayDestination, asked: TimeInterval, kept: TimeInterval,
                   capped: Bool = false, photos: Bool? = nil) -> String {
            ReplaySaveOutcome(result: .saved(destination: dest, askedSeconds: asked, keptSeconds: kept,
                                             cappedForJob: capped, photosLanded: photos)).spoken
        }
        XCTAssertEqual(saved(.recordings, asked: 30, kept: 31.9), "Saved the last 30 seconds to Recordings.")
        XCTAssertEqual(saved(.job, asked: 30, kept: 30.5), "Saved the last 30 seconds to the job.")
        XCTAssertEqual(saved(.recordings, asked: 60, kept: 61), "Saved the last minute to Recordings.")
        XCTAssertEqual(saved(.recordings, asked: 60, kept: 40),
                       "I only have the last 40 seconds; saved those to Recordings.")
        XCTAssertEqual(saved(.job, asked: 60, kept: 60, capped: true),
                       "A job clip is at most a minute, so I saved the last minute to the job.")
        XCTAssertEqual(saved(.photos, asked: 30, kept: 30, photos: true),
                       "Saved the last 30 seconds to Recordings and Photos.")
        XCTAssertEqual(saved(.photos, asked: 30, kept: 30, photos: false),
                       "Saved the last 30 seconds to Recordings. It couldn't be added to Photos.")
        XCTAssertEqual(ReplaySaveOutcome(result: .refused(.notRunning(.cameraOff))).spoken,
                       "Instant Replay isn't running: the camera's off.")
    }

    func testTheSegmentCutIsNotAShortfall() {
        XCTAssertFalse(ReplaySaveOutcome.isShort(kept: 29.3, asked: 30))
        XCTAssertTrue(ReplaySaveOutcome.isShort(kept: 28.5, asked: 30))
    }

    // MARK: - The passthrough composition plan

    func testSegmentsAreInsertedBackToBackAtTheirOwnLengths() {
        let plan = ReplayCompositionPlan(fileNames: ["a", "b", "c"], durations: [2, 1.5, 2])
        XCTAssertEqual(plan.inserts, [
            .init(fileName: "a", at: 0, duration: 2),
            .init(fileName: "b", at: 2, duration: 1.5),
            .init(fileName: "c", at: 3.5, duration: 2),
        ])
        XCTAssertEqual(plan.totalSeconds, 5.5)
    }

    func testAnEmptySegmentIsLeftOut() {
        let plan = ReplayCompositionPlan(fileNames: ["a", "b"], durations: [0, 2])
        XCTAssertEqual(plan.inserts.map(\.fileName), ["b"])
        XCTAssertEqual(plan.inserts.first?.at, 0)
    }

    func testThePlanFromASpanCoversItsSegments() throws {
        var ring = ReplaySegmentRing(capacity: 31)
        for i in 0..<16 {
            ring.append(ReplaySegment(fileName: "s\(i)", firstFrameAt: Double(i) * 2,
                                      lastFrameAt: Double(i) * 2 + 2 - 1.0 / 15, frameCount: 30,
                                      width: 2, height: 2, hadDroppedFrames: false, filterWasOn: true))
        }
        let span = try XCTUnwrap(ring.span(coveringLast: 30, now: 32))
        let plan = ReplayCompositionPlan(span: span, frameRate: 15)
        XCTAssertEqual(plan.inserts.count, span.segments.count)
        XCTAssertEqual(plan.totalSeconds, Double(span.segments.count) * 2, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(plan.totalSeconds, 30)
    }
}
