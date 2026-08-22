import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23: the button read **Streaming**, the glasses played their camera-stop
/// tone, and nothing was ever described. The state observer treated `.paused` as merely "waiting" —
/// it did not clear `isStreaming`, reported nothing, and never tried to resume. So the UI claimed
/// to be streaming while the camera was off.
///
/// `.paused` became load-bearing with DAT 0.9, which pauses the stream when the glasses are
/// **doffed** — i.e. every time someone takes them off to look at their phone, which is exactly
/// what a person does while testing.
final class CameraStreamStatePolicyTests: XCTestCase {

    /// The regression, stated as a rule: a paused stream is not a streaming one.
    func testAPausedStreamIsNotStreaming() {
        XCTAssertFalse(CameraStreamStatePolicy.isStreaming(.paused))
        XCTAssertFalse(CameraStreamStatePolicy.isStreaming(.stopped))
        XCTAssertTrue(CameraStreamStatePolicy.isStreaming(.streaming))
    }

    /// A pause we did not ask for is the one thing the wearer can fix, so it must be reported.
    func testAPauseDuringAWantedStreamIsReported() {
        let decision = CameraStreamStatePolicy.decide(state: .paused, streamingIntended: true)
        guard case .pausedWhileWanted(let notice) = decision else {
            return XCTFail("a wanted stream that pauses must produce a notice, got \(decision)")
        }
        XCTAssertTrue(notice.lowercased().contains("glasses"),
                      "the notice has to name the thing to do something about")
    }

    /// A pause we caused ourselves — parking the stream after a one-off capture — must stay quiet.
    /// Announcing it would train the wearer to ignore the notice that matters.
    func testAPauseWeAskedForIsSilent() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .paused, streamingIntended: false),
                       .waiting)
    }

    /// Lifecycle churn is not a condition anyone can act on.
    func testTransientStatesAreJustWaiting() {
        for state in [CameraStreamStatePolicy.StreamState.starting, .stopping, .waitingForDevice] {
            XCTAssertEqual(CameraStreamStatePolicy.decide(state: state, streamingIntended: true),
                           .waiting, "\(state) is transient")
        }
    }

    /// A stop is a stop whether or not we wanted the stream — it does not come back on its own.
    func testStoppedIsStoppedRegardlessOfIntent() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .stopped, streamingIntended: true), .stopped)
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .stopped, streamingIntended: false), .stopped)
    }

    func testStreamingIsStreamingWhicheverWayIntentPoints() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .streaming, streamingIntended: true), .streaming)
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .streaming, streamingIntended: false), .streaming)
    }
}
