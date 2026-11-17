import XCTest
@testable import OpenGlasses

/// The Display capability is only sent to once it is `started` (Meta's display guide). A build-705
/// report showed every first send going to a display still `starting`: unanswered past the 4 s
/// deadline, the session torn down, the next frame the same.
@MainActor
final class DisplayStartWaitTests: XCTestCase {

    /// Phases read in turn; the last one repeats.
    private func run(_ phases: [DisplayCapabilityPhase], timeout: TimeInterval = DisplayStartWait.timeout)
        async throws -> (outcome: DisplayStartWait.Outcome, waited: TimeInterval, sleeps: Int) {
        var reads = 0
        var sleeps = 0
        let result = try await DisplayStartWait.wait(
            timeout: timeout,
            phase: {
                defer { reads += 1 }
                return phases[min(reads, phases.count - 1)]
            },
            sleep: { _ in sleeps += 1 }
        )
        return (result.outcome, result.waited, sleeps)
    }

    func testAlreadyStartedSendsAtOnce() async throws {
        let result = try await run([.started])
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.sleeps, 0)
    }

    func testStartingWaitsUntilStarted() async throws {
        let result = try await run([.starting, .starting, .starting, .started])
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.sleeps, 3)
        XCTAssertEqual(result.waited, 0.3, accuracy: 0.0001)
    }

    func testAStartThatNeverArrivesTimesOut() async throws {
        let result = try await run([.starting], timeout: 1)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.waited, 1, accuracy: 0.05)
    }

    func testFallingToStoppedAfterStartingEndsTheWait() async throws {
        let result = try await run([.starting, .stopping])
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.sleeps, 1)
    }

    /// `start()` is synchronous; the phase may still read `stopped` for a moment after it.
    func testStoppedStraightAfterStartIsGivenAGrace() async throws {
        let result = try await run([.stopped, .stopped, .starting, .started])
        XCTAssertEqual(result.outcome, .started)
    }

    func testStoppedThroughTheGraceIsAFailedStart() async throws {
        let result = try await run([.stopped])
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.waited, DisplayStartWait.stoppedGrace, accuracy: 0.05)
    }

    func testTheWaitIsAsLongAsTheSessionsAndLongerThanASend() {
        XCTAssertEqual(DisplayStartWait.timeout, 10)
        XCTAssertGreaterThan(DisplayStartWait.timeout, HUDSendDeadline.seconds)
    }

    /// A timed-out send keeps the session; only the third in a row rebuilds it.
    func testOnlyRepeatedTimeoutsRebuildTheSession() {
        XCTAssertFalse(HUDSendDeadline.rebuildsSession(afterConsecutiveTimeouts: 1))
        XCTAssertFalse(HUDSendDeadline.rebuildsSession(afterConsecutiveTimeouts: 2))
        XCTAssertTrue(HUDSendDeadline.rebuildsSession(afterConsecutiveTimeouts: 3))
        XCTAssertTrue(HUDSendDeadline.rebuildsSession(afterConsecutiveTimeouts: 4))
    }

    /// The service counts timeouts, a sent frame clears the count, and a timeout short of the limit
    /// returns before the backend is reset. Read from the source: the render queue needs a backend.
    func testTheServiceKeepsTheSessionThroughATimeout() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/GlassesDisplayService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("if outcome == .sent { consecutiveSendTimeouts = 0 }"))
        guard let start = source.range(of: "private func handleRenderError"),
              let keep = source.range(of: "HUDSendDeadline.rebuildsSession(afterConsecutiveTimeouts:", range: start.upperBound..<source.endIndex),
              let reset = source.range(of: "activeBackend.resetAfterError()", range: start.upperBound..<source.endIndex) else {
            return XCTFail("handleRenderError's timeout rule not found")
        }
        XCTAssertLessThan(keep.lowerBound, reset.lowerBound, "the timeout rule is decided before the reset")
    }

    /// A display that did not start is a failure to rebuild from, never a picture to resend as text.
    func testADisplayThatDidNotStartIsNotRetriedAsText() {
        XCTAssertFalse(GlassesDisplayService.retriesWithoutPicture(after: GlassesDisplayError.displayDidNotStart))
        XCTAssertTrue(GlassesDisplayService.retriesWithoutPicture(after: GlassesDisplayError.sendTimedOut))
    }

    /// The backend waits after every `start()` and before it hands the display to a send. Read from
    /// the source: the SDK's `Display` cannot be made in a headless test.
    func testTheBackendWaitsForStartedBeforeItSends() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Display/MetaDisplayBackend.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "private func ensureDisplay()"),
              let end = source.range(of: "private func awaitStarted", range: start.upperBound..<source.endIndex) else {
            return XCTFail("ensureDisplay / awaitStarted not found")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        let starts = body.components(separatedBy: "display.start()").count - 1
        let waits = body.components(separatedBy: "try await awaitStarted(display)").count - 1
        XCTAssertEqual(starts, 2, "a new display and a restarted one")
        XCTAssertEqual(waits, 2, "each start is followed by the wait")
        XCTAssertTrue(body.contains("if display.state != .started { try await awaitStarted(display) }"),
                      "a reused display still starting is waited for too")
    }
}
