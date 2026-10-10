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
            case .emit, .decode, .convert:
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

    // MARK: - First-frame grace

    /// The loop from the 2026-09-25 device trace. A rebuilt hvc1 stream reached `.streaming`, and
    /// 1.5 s later had not delivered a frame yet. That was read as a stall and it was rebuilt again,
    /// with another ~7 s warmup. The one rebuild that got through delivered its first frame ~1.3 s
    /// after `.streaming`, so "nothing yet" at 1.5 s is a slow first frame, not a dead link.
    func testAStreamThatHasNotDeliveredYetIsNotStalledAtTheBetweenFramesThreshold() {
        var liveness = StreamLiveness(now: start)
        liveness.restart(at: start)
        XCTAssertEqual(liveness.verdict(now: start + 1.6), .healthy)
        XCTAssertEqual(liveness.verdict(now: start + StreamLiveness.firstFrameGrace), .healthy)
    }

    /// The grace ends. A stream that never sends anything is still a link stall, only judged
    /// against the longer first-frame allowance.
    func testAStreamThatNeverDeliversIsALinkStallOnceTheGraceRunsOut() {
        var liveness = StreamLiveness(now: start)
        liveness.restart(at: start)
        XCTAssertEqual(liveness.verdict(now: start + StreamLiveness.firstFrameGrace + 0.1),
                       .linkStalled)
    }

    /// The grace applies only to the first frame. Once anything has arrived, a gap between frames
    /// is caught at 1.5 s exactly as before.
    func testOnceAFrameHasArrivedTheBetweenFramesThresholdApplies() {
        var liveness = StreamLiveness(now: start)
        liveness.restart(at: start)
        liveness.pictureProduced(at: start + 1.3)
        XCTAssertEqual(liveness.verdict(now: start + 1.3 + 1.6), .linkStalled)
    }

    /// The grace is for a *first* frame. It has to be longer than the between-frames threshold,
    /// or it would change nothing.
    func testTheFirstFrameGraceIsLongerThanTheStallThreshold() {
        XCTAssertGreaterThan(StreamLiveness.firstFrameGrace, StreamLiveness.stallThreshold)
    }

    /// A rebuilt decoder holds every sample until the next keyframe. Samples arriving keep the
    /// link clock on its short threshold, but the picture clock waits out the grace. Otherwise an
    /// encoder whose keyframe interval is longer than 1.5 s would have its decoder rebuilt, and
    /// its hold re-armed, before any keyframe arrived.
    func testARebuiltDecoderGetsTheGraceForItsFirstPicture() {
        var liveness = StreamLiveness(now: start)
        liveness.restart(at: start)   // what `rebuildDecoder()` does to the clocks
        for tick in stride(from: 0.0, through: 3.0, by: 1.0 / 15.0) {
            liveness.sampleArrived(at: start + tick)   // held: no picture yet
        }
        XCTAssertEqual(liveness.verdict(now: start + 3), .healthy)
        for tick in stride(from: 3.0, through: 5.5, by: 1.0 / 15.0) {
            liveness.sampleArrived(at: start + tick)
        }
        XCTAssertEqual(liveness.verdict(now: start + 5.5), .decodeStalled,
                       "a decoder that never produces a picture is still caught after the grace")
    }

    /// Every restart gives the clocks their first-frame grace again.
    func testARestartReturnsBothClocksToTheirGrace() {
        var liveness = StreamLiveness(now: start)
        liveness.pictureProduced(at: start)
        XCTAssertTrue(liveness.sawSampleSinceRestart)
        XCTAssertTrue(liveness.sawPictureSinceRestart)
        liveness.restart(at: start + 1)
        XCTAssertFalse(liveness.sawSampleSinceRestart)
        XCTAssertFalse(liveness.sawPictureSinceRestart)
        XCTAssertEqual(liveness.verdict(now: start + 3), .healthy)
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

    // MARK: - The keyframe hold, reading the video (Plan HW P0)

    private typealias Kind = NALUnitInspector.PictureKind
    private let idr = Kind.randomAccess(nalType: 19, leadingMayBeUndecodable: false)
    private let cra = Kind.randomAccess(nalType: 21, leadingMayBeUndecodable: true)
    private let rasl = Kind.leadingSkipped(nalType: 9)
    private let radl = Kind.leadingDecodable(nalType: 7)
    private let trailing = Kind.nonRandomAccess(nalType: 1)

    /// The field failure, stated without a decoder. The glasses stream is reported never to set
    /// `NotSync`, so the attachment calls every sample a keyframe. The video says this one is an
    /// ordinary frame, and the video is believed.
    func testAPFrameWithNoAttachmentIsRefusedWhileHolding() {
        var hold = KeyframeHold()
        XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.isHolding)
    }

    /// And the other way round: a picture the video says a decoder can start on is admitted even
    /// when its attachment says it is not a sync sample.
    func testARandomAccessPictureEndsTheHoldWhateverTheAttachmentSays() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: false))
        XCTAssertFalse(hold.isHolding)
        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: false))
    }

    /// A decoder that starts on a CRA never saw the pictures its RASL pictures reference. They
    /// are withheld like any other frame it cannot decode properly.
    func testARASLAfterACRAIsHeld() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isHolding, "the CRA itself ends the hold")
        XCTAssertTrue(hold.isSkippingLeadingPictures)
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// RADL pictures reference nothing from before the CRA, so they pass. They may sit between
    /// RASL pictures, so one passing is not the end of the leading pictures.
    func testARADLAfterACRAPassesAndTheRASLAfterItIsStillHeld() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(radl, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.isSkippingLeadingPictures)
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// The first trailing picture is the end of them: nothing after it in the stream is a
    /// leading picture of that CRA.
    func testTheFirstTrailingPictureEndsTheLeadingRule() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isSkippingLeadingPictures)
        XCTAssertTrue(hold.admits(rasl, attachmentSaysKeyframe: true),
                      "a RASL met later belongs to a CRA this decoder has the references for")
    }

    /// An IDR has no RASL pictures of its own, so a hold it released skips nothing.
    func testARASLAfterAnIDRReleasedHoldPasses() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isSkippingLeadingPictures)
        XCTAssertTrue(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// BLA_W_LP is the other type that may carry RASL pictures. The other two BLA types cannot.
    func testABLAWithLeadingPicturesSetsTheRuleAndTheOtherBLATypesDoNot() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(.randomAccess(nalType: 16, leadingMayBeUndecodable: true),
                                  attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))

        var other = KeyframeHold()
        XCTAssertTrue(other.admits(.randomAccess(nalType: 17, leadingMayBeUndecodable: false),
                                   attachmentSaysKeyframe: true))
        XCTAssertTrue(other.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// The rule is about a decoder *starting* on the CRA. One that was already running when the
    /// CRA arrived has every reference, and its RASL pictures are ordinary frames.
    func testACRAMetMidStreamDoesNotHoldItsLeadingPictures() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isSkippingLeadingPictures)
        XCTAssertTrue(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// The next random-access picture ends the leading rule as surely as a trailing one.
    func testTheNextRandomAccessPictureEndsTheLeadingRule() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isSkippingLeadingPictures)
        XCTAssertTrue(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// A rebuild forgets the leading rule along with everything else: the new session's first
    /// picture decides afresh.
    func testARearmClearsTheLeadingRule() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        hold.rearm()
        XCTAssertFalse(hold.isSkippingLeadingPictures)
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true), "holding again")
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    /// A sample the parser cannot read is judged by the attachment, exactly as every sample was
    /// before.
    func testAnUnreadableSampleFallsBackToTheAttachment() {
        var hold = KeyframeHold()
        XCTAssertFalse(hold.admits(.unparseable, attachmentSaysKeyframe: false))
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.admits(.unparseable, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isHolding)
        XCTAssertFalse(hold.isSkippingLeadingPictures)
    }

    /// An unreadable sample says nothing about whether the leading pictures have ended, so it
    /// passes without ending the rule.
    func testAnUnreadableSampleDoesNotEndTheLeadingRule() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(cra, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.admits(.unparseable, attachmentSaysKeyframe: false))
        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
    }

    // MARK: - Patience

    /// The number is part of the contract: it is what a device session reads beside the
    /// `keyframeHoldAbandoned` line.
    func testPatienceIsTwoHundredAndFortySamples() {
        XCTAssertEqual(KeyframeHold.patience, 240)
    }

    /// A stream with no picture the parser recognises as a place to start would be held for
    /// ever. One short of patience the hold is still holding; the sample that reaches it is
    /// judged by the attachment, which is the behaviour that shipped before.
    func testPatienceRunsOutOnTheNamedSampleAndTheAttachmentDecidesFromThere() {
        var hold = KeyframeHold()
        for _ in 0..<(KeyframeHold.patience - 1) {
            XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true))
        }
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.trustsParser)
        XCTAssertEqual(hold.refusedWhileHolding, KeyframeHold.patience - 1)

        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.trustsParser)
        XCTAssertFalse(hold.isHolding)
    }

    /// Giving up on the parser is not giving up on the hold. A stream that does mark its
    /// non-keyframes is still held by the attachment.
    func testWithPatienceGoneAMarkedNonKeyframeIsStillRefused() {
        var hold = KeyframeHold()
        for _ in 0..<KeyframeHold.patience {
            XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: false))
        }
        XCTAssertFalse(hold.trustsParser)
        XCTAssertTrue(hold.isHolding)
        XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: false))
        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.isHolding)
    }

    /// The stall detector rebuilds a decoder that is waiting, every few seconds. If each rebuild
    /// restarted the count, patience would never run out on exactly the stream it exists for.
    func testARearmDoesNotRestartPatience() {
        var hold = KeyframeHold()
        for _ in 0..<100 {
            XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true))
        }
        hold.rearm()
        XCTAssertEqual(hold.refusedWhileHolding, 100)
        for _ in 0..<(KeyframeHold.patience - 101) {
            XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true))
        }
        hold.rearm()
        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true),
                      "the 240th refusal, counted across two rebuilds")
        XCTAssertFalse(hold.trustsParser)

        // And once it has run out, later rebuilds go straight to the attachment.
        hold.rearm()
        XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true))
    }

    /// Only a random-access picture actually arriving shows the parser can read this stream. It
    /// zeroes the count before patience is spent, and restores the parser's standing after.
    func testARandomAccessPictureRestoresTheParsersStanding() {
        var hold = KeyframeHold()
        for _ in 0..<200 {
            XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true))
        }
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: true))
        XCTAssertEqual(hold.refusedWhileHolding, 0)

        hold.rearm()
        for _ in 0..<KeyframeHold.patience {
            _ = hold.admits(trailing, attachmentSaysKeyframe: true)
        }
        XCTAssertFalse(hold.trustsParser)

        // Met while the decoder is running, not while holding: it counts all the same.
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: true))
        XCTAssertTrue(hold.trustsParser)
        XCTAssertEqual(hold.refusedWhileHolding, 0)

        hold.rearm()
        XCTAssertFalse(hold.admits(trailing, attachmentSaysKeyframe: true),
                       "the parser is believed again")
    }

    /// Patience counts samples the parser read and refused. One it could not read was never the
    /// parser's refusal, and leading pictures are counted like any other readable frame.
    func testOnlyReadableSamplesSpendPatience() {
        var hold = KeyframeHold()
        for _ in 0..<(KeyframeHold.patience * 2) {
            XCTAssertFalse(hold.admits(.unparseable, attachmentSaysKeyframe: false))
        }
        XCTAssertEqual(hold.refusedWhileHolding, 0)
        XCTAssertTrue(hold.trustsParser)

        XCTAssertFalse(hold.admits(rasl, attachmentSaysKeyframe: true))
        XCTAssertFalse(hold.admits(radl, attachmentSaysKeyframe: true))
        XCTAssertEqual(hold.refusedWhileHolding, 2)
    }

    /// Frames that pass once the decoder is running are not refusals.
    func testAdmittedFramesDoNotSpendPatience() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.admits(idr, attachmentSaysKeyframe: true))
        for _ in 0..<(KeyframeHold.patience * 2) {
            XCTAssertTrue(hold.admits(trailing, attachmentSaysKeyframe: true))
        }
        XCTAssertEqual(hold.refusedWhileHolding, 0)
        XCTAssertTrue(hold.trustsParser)
    }
}
