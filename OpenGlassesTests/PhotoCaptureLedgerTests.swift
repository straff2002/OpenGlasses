import XCTest
@testable import OpenGlasses

/// `PhotoCaptureLedger`: each glasses photo answers the capture that asked for it, a timer only
/// resolves its own capture, and a photo that lands after its capture timed out is drained.
final class PhotoCaptureLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testAPhotoAnswersThePendingCapture() throws {
        var ledger = PhotoCaptureLedger()
        let token = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertEqual(ledger.pending, token)
        XCTAssertTrue(ledger.mustHold(at: at(1)))
        XCTAssertEqual(ledger.photoArrived(at: at(3)), .answers(token))
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(ledger.mustHold(at: at(3)))
    }

    /// Case (a): capture 1's photo lands at 3 s, capture 2 starts at 5 s, capture 1's timer fires
    /// at 8 s. The timer must not resolve capture 2.
    func testAnEarlierCapturesTimerDoesNotResolveALaterCapture() throws {
        var ledger = PhotoCaptureLedger()
        let first = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertEqual(ledger.photoArrived(at: at(3)), .answers(first))
        let second = try XCTUnwrap(ledger.issue(at: at(5)))
        XCTAssertFalse(ledger.timedOut(first), "the first capture's timer belongs to the first capture")
        XCTAssertEqual(ledger.pending, second, "the second capture still waits for its own photo")
        XCTAssertEqual(ledger.photoArrived(at: at(9)), .answers(second))
    }

    func testATimeoutResolvesItsOwnCaptureOnce() throws {
        var ledger = PhotoCaptureLedger()
        let token = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertTrue(ledger.timedOut(token))
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(ledger.timedOut(token), "a second firing resolves nothing")
    }

    /// Case (b): capture 1 times out at 8 s; its real photo arrives at 12 s. It is drained, never
    /// handed to a later capture.
    func testALatePhotoIsDrainedAndNeverAnswersALaterCapture() throws {
        var ledger = PhotoCaptureLedger()
        let first = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertTrue(ledger.timedOut(first))
        XCTAssertEqual(ledger.latePhotosOwed(at: at(9)), 1)
        XCTAssertTrue(ledger.mustHold(at: at(9)), "a new capture holds while a photo is owed")
        XCTAssertEqual(ledger.photoArrived(at: at(12)), .drainedLate(first))
        XCTAssertEqual(ledger.latePhotosOwed(at: at(12)), 0)
        XCTAssertFalse(ledger.mustHold(at: at(12)))

        let second = try XCTUnwrap(ledger.issue(at: at(12)))
        XCTAssertEqual(ledger.photoArrived(at: at(15)), .answers(second))
    }

    /// Should a request be made while a late photo is owed, the photos are matched oldest first:
    /// the late one is drained and the new one answers its own capture.
    func testPhotosAreMatchedOldestFirst() throws {
        var ledger = PhotoCaptureLedger()
        let first = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertTrue(ledger.timedOut(first))
        let second = try XCTUnwrap(ledger.issue(at: at(9)))
        XCTAssertEqual(ledger.photoArrived(at: at(11)), .drainedLate(first))
        XCTAssertEqual(ledger.pending, second)
        XCTAssertEqual(ledger.photoArrived(at: at(13)), .answers(second))
    }

    func testAPendingCaptureIsNeverReplaced() throws {
        var ledger = PhotoCaptureLedger()
        let first = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertNil(ledger.issue(at: at(1)), "a second request is refused while one is pending")
        XCTAssertEqual(ledger.pending, first)
    }

    func testAPhotoNobodyAskedForIsUnexpected() {
        var ledger = PhotoCaptureLedger()
        XCTAssertEqual(ledger.photoArrived(at: at(0)), .unexpected)
    }

    func testARefusedRequestOwesNothing() throws {
        var ledger = PhotoCaptureLedger()
        let token = try XCTUnwrap(ledger.issue(at: at(0)))
        ledger.rejected(token)
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(ledger.mustHold(at: at(0)))
        XCTAssertEqual(ledger.photoArrived(at: at(1)), .unexpected)
        XCTAssertFalse(ledger.timedOut(token), "a refused request's timer resolves nothing")
    }

    func testAnSDKAbortResolvesThePendingCaptureAndForgetsLatePhotos() throws {
        var ledger = PhotoCaptureLedger()
        let first = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertTrue(ledger.timedOut(first))
        let second = try XCTUnwrap(ledger.issue(at: at(9)))
        XCTAssertEqual(ledger.aborted(), second)
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(ledger.mustHold(at: at(9)))
        XCTAssertFalse(ledger.timedOut(second), "the aborted capture's timer resolves nothing")
        XCTAssertEqual(ledger.photoArrived(at: at(10)), .unexpected)
    }

    func testAnAbortWithNothingPendingStillForgetsLatePhotos() throws {
        var ledger = PhotoCaptureLedger()
        let token = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertTrue(ledger.timedOut(token))
        XCTAssertNil(ledger.aborted())
        XCTAssertEqual(ledger.latePhotosOwed(at: at(9)), 0)
    }

    func testALostLatePhotoStopsHoldingAfterTheHorizon() throws {
        var ledger = PhotoCaptureLedger()
        let token = try XCTUnwrap(ledger.issue(at: at(0)))
        XCTAssertTrue(ledger.timedOut(token))
        XCTAssertTrue(ledger.mustHold(at: at(PhotoCaptureLedger.owedHorizon - 1)))
        XCTAssertFalse(ledger.mustHold(at: at(PhotoCaptureLedger.owedHorizon)))
        let next = try XCTUnwrap(ledger.issue(at: at(PhotoCaptureLedger.owedHorizon + 1)))
        XCTAssertEqual(ledger.photoArrived(at: at(PhotoCaptureLedger.owedHorizon + 3)), .answers(next))
    }

    func testTheTimingsLeaveRoomForALatePhoto() {
        XCTAssertGreaterThan(PhotoCaptureLedger.owedHorizon,
                             PhotoCaptureLedger.captureTimeout + PhotoCaptureLedger.holdWait,
                             "a late photo is still expected for the whole of a following capture's hold")
    }
}
