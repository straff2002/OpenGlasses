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

    /// A stop we did not ask for used to fall the same way as one we did — flat `.stopped`, which
    /// cleared `isStreaming`, which disarmed the stall detector, which was the only thing left
    /// that would have rebuilt the stream. A Bluetooth hiccup therefore ended the preview until
    /// the wearer stopped and started by hand. Splitting the row is the fix.
    func testAStopDuringAWantedStreamAsksForAReconnect() {
        // Default `transitionIsOurs: false` — nothing of ours is climbing, so this really is a drop.
        let decision = CameraStreamStatePolicy.decide(state: .stopped, streamingIntended: true)
        guard case .stoppedWhileWanted(let notice) = decision else {
            return XCTFail("a wanted stream that stops must ask to reconnect, got \(decision)")
        }
        XCTAssertTrue(notice.lowercased().contains("reconnect"),
                      "the notice must say a retry is already under way — there is no button to press")
        XCTAssertTrue(notice.lowercased().contains("glasses"),
                      "the notice has to name the thing to do something about")
    }

    /// A stop we asked for — the wearer pressed stop, or the session was torn down — is an ending,
    /// not a drop. Reconnecting here would fight the user for the camera.
    func testAStopWeAskedForStaysAStop() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .stopped, streamingIntended: false),
                       .stopped)
    }

    /// The row that keeps the reconnect honest. A *healthy* cold start bounces the stream through
    /// `.stopped` for 15-18 s with the intent already set, and stall recovery stops the stream on
    /// purpose with the listeners still attached. Read as drops, those self-inflicted stops would
    /// toast "Camera dropped" on every single start and every 1.5 s frame stall, then announce a
    /// recovery the ladder that caused them is about to announce itself.
    func testOurOwnStopsAreTransientNotDrops() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .stopped, streamingIntended: true,
                                                     transitionIsOurs: true),
                       .waiting, "cold-start churn is not a drop")
    }

    /// Ownership does not resurrect a stream nobody wants: a deliberate stop is still a stop.
    func testADeliberateStopIsAStopEvenWhenItIsOurs() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .stopped, streamingIntended: false,
                                                     transitionIsOurs: true),
                       .stopped)
    }

    /// A doff during warmup is still the wearer's doing and still fixable in one move, so the
    /// pause row is deliberately NOT gated on ownership.
    func testAPauseIsStillReportedDuringOurOwnTransitions() {
        guard case .pausedWhileWanted = CameraStreamStatePolicy.decide(
            state: .paused, streamingIntended: true, transitionIsOurs: true) else {
            return XCTFail("a doff mid-warmup is still the one thing the wearer can fix")
        }
    }

    /// The placeholder copy has one job: name the two things that turn the camera off and are
    /// invisible from the phone, and set an honest expectation for the wait.
    func testColdStartHintNamesWhatTheWearerCanCheck() {
        let hint = CameraStreamStatePolicy.coldStartHint.lowercased()
        XCTAssertTrue(hint.contains("hinge"), "folded hinges are the commonest cause of a black preview")
        XCTAssertTrue(hint.contains("20 seconds"),
                      "a healthy cold start really does take this long — say so")
        XCTAssertGreaterThan(CameraStreamStatePolicy.coldStartHintDelay, 0,
                             "a quick connect must not flash advice nobody needed")
        XCTAssertLessThan(CameraStreamStatePolicy.coldStartHintDelay,
                          StreamRecoveryPolicy.observedColdStart,
                          "advice that arrives after the wait is over is not advice")
    }

    func testStreamingIsStreamingWhicheverWayIntentPoints() {
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .streaming, streamingIntended: true), .streaming)
        XCTAssertEqual(CameraStreamStatePolicy.decide(state: .streaming, streamingIntended: false), .streaming)
    }
}
