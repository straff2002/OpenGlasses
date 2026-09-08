import XCTest
import VideoToolbox
@testable import OpenGlasses

/// Plan EO P1. The decoder that shipped had no answer to a dead session: it threw, the frame was
/// dropped, and every frame after it hit the same dead session, so one `kVTInvalidSessionErr`
/// ended the stream for good. That status is not exotic — it is what backgrounding produces when
/// iOS reclaims the shared hardware decode service, which is precisely the moment this app is
/// supposed to keep delivering pictures.
///
/// The rule is stated here, apart from VideoToolbox, so it can be read and argued with without a
/// decompression session in the room.
final class DecoderRecoveryPolicyTests: XCTestCase {

    /// The two statuses that mean "the session is gone", not "the frame is bad". A new session
    /// for the same format fixes both, so the frame gets one more try rather than being lost.
    func testASessionThatDiedIsRebuiltAndTheFrameRetried() {
        XCTAssertEqual(DecoderRecoveryPolicy.action(status: kVTInvalidSessionErr,
                                                    consecutiveFailures: 0),
                       .rebuildAndRetry)
        XCTAssertEqual(DecoderRecoveryPolicy.action(status: kVTVideoDecoderMalfunctionErr,
                                                    consecutiveFailures: 0),
                       .rebuildAndRetry)
    }

    /// -12903 is the number the lock screen produces, and it is worth naming rather than
    /// trusting a constant to stay put.
    func testTheInvalidSessionStatusIsTheOneBackgroundingProduces() {
        XCTAssertEqual(kVTInvalidSessionErr, -12903)
    }

    /// Anything else is a frame problem. Rebuilding the session for a corrupt frame would throw
    /// away a working decoder and restart the keyframe wait for nothing, so it is only counted.
    func testAnyOtherStatusIsMerelyCounted() {
        for status in [OSStatus(-12909), kVTVideoDecoderBadDataErr, OSStatus(-1), OSStatus(1)] {
            XCTAssertEqual(DecoderRecoveryPolicy.action(status: status, consecutiveFailures: 0),
                           .countFailure, "\(status) says nothing about the session")
        }
    }

    /// Three in a row is the end of the argument, whatever the statuses were: invalidate, so the
    /// next frame builds a session from scratch instead of retrying into a decoder that has
    /// stopped working. The count passed in is the count *before* this failure, so the third one
    /// arrives as 2.
    func testTheThirdConsecutiveFailureInvalidates() {
        XCTAssertEqual(DecoderRecoveryPolicy.action(status: kVTVideoDecoderBadDataErr,
                                                    consecutiveFailures: 2),
                       .invalidate)
        XCTAssertEqual(DecoderRecoveryPolicy.action(status: kVTInvalidSessionErr,
                                                    consecutiveFailures: 2),
                       .invalidate,
                       "the limit outranks the rebuild — a session rebuilt twice already is not "
                       + "going to be fixed by a third")
        XCTAssertEqual(DecoderRecoveryPolicy.failureLimit, 3)
    }

    /// The second failure is still inside the budget: the ladder is three, not two.
    func testTheSecondConsecutiveFailureIsStillInsideTheBudget() {
        XCTAssertEqual(DecoderRecoveryPolicy.action(status: kVTVideoDecoderBadDataErr,
                                                    consecutiveFailures: 1),
                       .countFailure)
    }

    /// A success resets the count, and the reset is what the ladder means: after a good frame the
    /// next failure is a first failure again, not a third. The decoder holds the counter; the
    /// rule is that zero behaves like a fresh start.
    func testSuccessResetsTheLadder() {
        XCTAssertEqual(DecoderRecoveryPolicy.action(status: kVTVideoDecoderBadDataErr,
                                                    consecutiveFailures: 0),
                       .countFailure,
                       "a decoder whose count was cleared by a good frame must not be one "
                       + "failure away from invalidating")
    }
}
