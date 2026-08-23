import XCTest
@testable import OpenGlasses

/// Tests for the camera-stream claim ledger (Plan CV, camera ownership).
///
/// The rule under test is the one two features had already written by hand — stop only a stream you
/// started, and only when nothing else wants it — and the cases that matter are the ones where a
/// hand-written version gets it wrong: a claim arriving on top of somebody else's stream, and a
/// release arriving while an unclaimed consumer is still using it.
final class CameraStreamClaimsTests: XCTestCase {

    private let narration = CameraStreamClaims.Owner.sceneNarration
    private let fingerspelling = CameraStreamClaims.Owner.fingerspelling

    // MARK: - Claiming

    func testFirstClaimOnAStoppedStreamStartsIt() {
        var claims = CameraStreamClaims()
        XCTAssertEqual(claims.claim(narration, streamRunning: false), .startStream)
        XCTAssertTrue(claims.holds(narration))
        XCTAssertTrue(claims.startedStream)
    }

    func testFirstClaimOnARunningStreamDoesNotStartIt() {
        var claims = CameraStreamClaims()
        XCTAssertEqual(claims.claim(narration, streamRunning: true), .alreadyRunning)
        XCTAssertFalse(claims.startedStream,
                       "A stream we found running is not one we started, and not one we may stop")
    }

    func testSecondOwnerJoinsWithoutStartingAnything() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        XCTAssertEqual(claims.claim(fingerspelling, streamRunning: true), .alreadyRunning)
        XCTAssertEqual(claims.owners.count, 2)
    }

    func testClaimingTwiceIsANoOp() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        XCTAssertEqual(claims.claim(narration, streamRunning: true), .alreadyClaimed)
        XCTAssertEqual(claims.owners.count, 1)
    }

    // MARK: - Releasing

    func testLastClaimStopsAStreamItStarted() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        XCTAssertEqual(claims.release(narration, streamRunning: true, otherConsumersActive: false),
                       .stopStream)
        XCTAssertTrue(claims.isEmpty)
    }

    func testReleaseKeepsAStreamAnotherClaimStillWants() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        _ = claims.claim(fingerspelling, streamRunning: true)
        XCTAssertEqual(claims.release(fingerspelling, streamRunning: true, otherConsumersActive: false),
                       .keepRunning)
        XCTAssertEqual(claims.release(narration, streamRunning: true, otherConsumersActive: false),
                       .stopStream,
                       "The last claim out still stops what the first claim in started")
    }

    func testReleaseNeverStopsAStreamWeDidNotStart() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: true)
        XCTAssertEqual(claims.release(narration, streamRunning: true, otherConsumersActive: false),
                       .keepRunning)
    }

    func testReleaseKeepsAStreamAnUnclaimedConsumerIsUsing() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        XCTAssertEqual(claims.release(narration, streamRunning: true, otherConsumersActive: true),
                       .keepRunning,
                       "Recording, broadcast and live sessions hold the stream without claiming it")
    }

    func testReleasingWhatWasNeverHeldIsReported() {
        var claims = CameraStreamClaims()
        XCTAssertEqual(claims.release(narration, streamRunning: true, otherConsumersActive: false),
                       .notHeld)
    }

    func testStartedFlagIsReAnsweredByTheNextClaim() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        _ = claims.release(narration, streamRunning: true, otherConsumersActive: false)
        // Second session, and this time somebody else already has the camera up.
        XCTAssertEqual(claims.claim(narration, streamRunning: true), .alreadyRunning)
        XCTAssertEqual(claims.release(narration, streamRunning: true, otherConsumersActive: false),
                       .keepRunning,
                       "A stale startedStream from the previous session would stop somebody else's stream")
    }

    // MARK: - Abandon and reset

    func testAbandonDropsAClaimWithoutProposingAStop() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        claims.abandon(narration)
        XCTAssertTrue(claims.isEmpty)
        XCTAssertFalse(claims.startedStream)
        XCTAssertEqual(claims.release(narration, streamRunning: false, otherConsumersActive: false),
                       .notHeld)
    }

    func testResetForgetsEverything() {
        var claims = CameraStreamClaims()
        _ = claims.claim(narration, streamRunning: false)
        _ = claims.claim(fingerspelling, streamRunning: true)
        claims.reset()
        XCTAssertTrue(claims.isEmpty)
        XCTAssertFalse(claims.startedStream)
    }
}
