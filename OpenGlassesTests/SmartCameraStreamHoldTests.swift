import XCTest
@testable import OpenGlasses

/// Smart camera used to start the glasses stream and never stop it: one vision question left the
/// camera streaming until the glasses disconnected (build 717, once ChatGPT models took photos).
@MainActor
final class SmartCameraStreamHoldTests: XCTestCase {

    private final class Counts {
        var claims = 0
        var releases = 0
    }

    private func makeHold(_ counts: Counts, claimFails: Bool = false) -> SmartCameraStreamHold {
        SmartCameraStreamHold(
            claim: {
                counts.claims += 1
                if claimFails { throw CameraError.captureFailed }
            },
            release: { counts.releases += 1 })
    }

    private func settle(_ duration: Duration = .milliseconds(250)) async {
        try? await Task.sleep(for: duration)
    }

    func testAHeldStreamIsGivenBackAfterTheWindow() async throws {
        let counts = Counts()
        let hold = makeHold(counts)
        try await hold.take()
        hold.keep(for: .milliseconds(40))
        XCTAssertTrue(hold.isHeld)
        await settle()
        XCTAssertEqual(counts.releases, 1)
        XCTAssertFalse(hold.isHeld)
    }

    func testAFollowUpPushesTheReleaseBack() async throws {
        let counts = Counts()
        let hold = makeHold(counts)
        try await hold.take()
        hold.keep(for: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(150))
        hold.keep(for: .milliseconds(300))   // the follow-up question used the stream again
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counts.releases, 0, "re-armed, so the first window's release is called off")
        await settle(.milliseconds(400))
        XCTAssertEqual(counts.releases, 1)
    }

    func testTakingAgainCallsOffAPendingRelease() async throws {
        let counts = Counts()
        let hold = makeHold(counts)
        try await hold.take()
        hold.keep(for: .milliseconds(80))
        try await hold.take()   // a new capture began inside the window
        await settle()
        XCTAssertEqual(counts.releases, 0, "nothing re-armed it, and the old release must not land mid-capture")
        XCTAssertTrue(hold.isHeld)
    }

    func testAlwaysModeKeepsTheStream() async throws {
        let counts = Counts()
        let hold = makeHold(counts)
        try await hold.take()
        hold.keep(for: nil)
        await settle()
        XCTAssertEqual(counts.releases, 0)
        await hold.giveBack()
        XCTAssertEqual(counts.releases, 1)
    }

    func testAFailedClaimHoldsNothingAndGivesNothingBack() async {
        let counts = Counts()
        let hold = makeHold(counts, claimFails: true)
        do {
            try await hold.take()
            XCTFail("the claim throws")
        } catch {}
        XCTAssertFalse(hold.isHeld)
        hold.keep(for: .milliseconds(20))
        await hold.giveBack()
        await settle()
        XCTAssertEqual(counts.releases, 0)
    }

    func testGivenBackOnlyOnce() async throws {
        let counts = Counts()
        let hold = makeHold(counts)
        try await hold.take()
        hold.keep(for: .milliseconds(40))
        await hold.giveBack()
        await settle()
        await hold.giveBack()
        XCTAssertEqual(counts.releases, 1)
    }

    func testReleaseDelayFollowsTheCooldownExceptUnderAlways() {
        XCTAssertEqual(SmartCameraStreamHold.releaseDelay(cameraBehavior: "smart", cooldown: 5),
                       .seconds(5))
        XCTAssertEqual(SmartCameraStreamHold.releaseDelay(cameraBehavior: nil, cooldown: 2.5),
                       .milliseconds(2500))
        XCTAssertEqual(SmartCameraStreamHold.releaseDelay(cameraBehavior: "never", cooldown: -1),
                       .zero)
        XCTAssertNil(SmartCameraStreamHold.releaseDelay(cameraBehavior: "always", cooldown: 5))
    }

    /// The source check: smart camera takes its hold rather than starting the stream outright,
    /// because the bare start was the one nothing ever stopped.
    func testSmartCameraClaimsRatherThanStarting() throws {
        let source = try String(contentsOf: Self.appSource, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func smartCameraCapture("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.upperBound]
        XCTAssertFalse(body.contains("cameraService.startStreaming()"),
                       "a bare start in smart camera is never stopped")
        XCTAssertTrue(body.contains("smartCameraHold.take()"))
        XCTAssertTrue(body.contains("defer { keepSmartCameraStream() }"))
    }

    private static var appSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift")
    }
}
