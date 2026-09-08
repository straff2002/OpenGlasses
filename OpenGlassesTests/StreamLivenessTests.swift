import XCTest
@testable import OpenGlasses

/// Plan EO P1. The stall detector watched one clock — the moment a decoded image reached the
/// main actor — and rebuilt the whole stream when it stood still for 1.5 s. With a decoder in the
/// path that clock stops for two entirely different reasons, and the responses are opposites: a
/// link that has gone quiet wants the stream rebuilt, while a decoder waiting for a keyframe
/// wants to be left alone, because rebuilding the stream restarts exactly the wait it is stuck
/// in. One clock cannot tell them apart, so there are two.
final class StreamLivenessTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Frames arriving and pictures coming out of them is the healthy case, and nothing about it
    /// should be interesting.
    func testAStreamProducingPicturesIsHealthy() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start + 1)
        XCTAssertEqual(liveness.verdict(now: start + 2), .healthy)
    }

    /// Nothing arriving at all is the stall the detector was written for: the glasses stopped
    /// sending, and only a stream rebuild fixes that.
    func testNothingArrivingIsALinkStall() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start)
        XCTAssertEqual(liveness.verdict(now: start + 1.6), .linkStalled)
    }

    /// Samples arriving and none of them becoming a picture is a decoder problem wearing a link
    /// stall's clothes. Reading it as a link stall is what would tear down a perfectly good
    /// stream.
    func testSamplesWithoutPicturesIsADecodeStall() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start)
        // Frames keep coming at 15 fps for two seconds; not one of them decodes.
        for tick in stride(from: 0.0, through: 2.0, by: 1.0 / 15.0) {
            liveness.sampleArrived(at: start + tick)
        }
        XCTAssertEqual(liveness.verdict(now: start + 2), .decodeStalled)
    }

    /// The threshold is the one the stream-level detector has always used, so a link stall is
    /// still caught exactly as fast as it was before the decoder existed.
    func testTheThresholdIsUnchangedFromTheStreamOnlyDetector() {
        XCTAssertEqual(StreamLiveness.stallThreshold, 1.5)
    }

    /// A decoded picture implies a sample: it refreshes both clocks. That is what keeps a raw
    /// stream — which never reports samples separately — reading as healthy.
    func testAPictureRefreshesBothClocks() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start + 5)
        XCTAssertEqual(liveness.lastSample, start + 5)
        XCTAssertEqual(liveness.lastPicture, start + 5)
        XCTAssertEqual(liveness.verdict(now: start + 6), .healthy)
    }

    /// Handing the app the *previous* picture again is not progress. If a held frame refreshed
    /// the picture clock the app would look alive while showing a still, and the decoder would
    /// never be rebuilt.
    func testAHeldFrameRefreshesNothing() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start)
        liveness.sampleArrived(at: start + 2)
        liveness.heldFrameDelivered()
        XCTAssertEqual(liveness.lastPicture, start, "a held frame is not a picture produced")
        XCTAssertEqual(liveness.lastSample, start + 2, "and it is not a sample either")
        XCTAssertEqual(liveness.verdict(now: start + 2), .decodeStalled)
    }

    /// An empty frame — the SDK helper produced nothing and there is no data buffer either — is
    /// not evidence that the link is alive, so it must stamp neither clock. If it refreshed the
    /// sample clock, a run of empties would keep `lastSample` fresh forever while `lastPicture`
    /// went stale: the verdict would read `decodeStalled`, the decoder would be rebuilt every
    /// 1.5 s, and the stream — the only lever that helps when nothing decodable is arriving —
    /// would never be rebuilt at all. Before the decoder existed this same situation (frames whose
    /// `makeUIImage()` returned nil) stalled the stream detector and rebuilt the stream; it still
    /// must.
    func testARunOfEmptyFramesReadsAsALinkStallNotADecodeStall() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start)

        // 15 fps of nothing for two seconds, each frame put through the rule the pipeline applies.
        for tick in stride(from: 0.0, through: 2.0, by: 1.0 / 15.0) {
            switch StreamCodecPolicy.action(for: .empty) {
            case .emit, .decode:
                liveness.sampleArrived(at: start + tick)
            case .drop:
                break   // stamps nothing, deliberately
            }
        }

        XCTAssertEqual(liveness.verdict(now: start + 2), .linkStalled,
                       "empty frames must rebuild the stream, not a decoder that is not at fault")
    }

    /// A stream restart starts both clocks again, so a 20-second cold start is not read as a
    /// stall the instant the detector arms.
    func testARestartClearsBothClocks() {
        var liveness = StreamLiveness(now: start)
        XCTAssertEqual(liveness.verdict(now: start + 10), .linkStalled)
        liveness.restart(at: start + 10)
        XCTAssertEqual(liveness.verdict(now: start + 10), .healthy)
    }

    // MARK: - The keyframe hold

    /// A session that has just been built cannot start mid-GOP. Feeding it non-keyframe samples
    /// produces smeared, half-referenced pictures, and those would reach a vision model, a
    /// recording and the lens as if they were real.
    func testAFreshHoldWithholdsNonKeyframes() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.isHolding)
        XCTAssertFalse(hold.admits(keyframe: false))
        XCTAssertFalse(hold.admits(keyframe: false))
        XCTAssertTrue(hold.isHolding, "nothing but a keyframe ends it")
    }

    /// The first keyframe both passes and ends the hold — it is the one frame that may safely
    /// start a session.
    func testAKeyframeEndsTheHold() {
        var hold = KeyframeHold()
        XCTAssertFalse(hold.admits(keyframe: false))
        XCTAssertTrue(hold.admits(keyframe: true))
        XCTAssertFalse(hold.isHolding)
        XCTAssertTrue(hold.admits(keyframe: false),
                      "once the session has a keyframe, the frames that reference it are fine")
    }

    /// Every rebuild re-arms the hold, because a new session knows nothing about the old one's
    /// reference frames.
    func testARebuildReArmsTheHold() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(keyframe: true))
        hold.rearm()
        XCTAssertTrue(hold.isHolding)
        XCTAssertFalse(hold.admits(keyframe: false))
    }
}
