import XCTest
@testable import OpenGlasses

/// Build 717: since the camera and the lens share one session, handing the session back no longer
/// stops it. A Display dropped after a failed draw was left running on it, and every later
/// `addDisplay()` failed with `capabilityAlreadyActive` until the camera let go.
@MainActor
final class DisplayRetireTests: XCTestCase {

    private func run(_ phases: [DisplayCapabilityPhase], timeout: TimeInterval = 3)
        async throws -> (outcome: DisplayStopWait.Outcome, waited: TimeInterval, sleeps: Int) {
        var index = 0
        var sleeps = 0
        let result = try await DisplayStopWait.wait(
            timeout: timeout, pollInterval: 0.1,
            phase: {
                defer { index = min(index + 1, phases.count - 1) }
                return phases[index]
            },
            sleep: { _ in sleeps += 1 })
        return (result.outcome, result.waited, sleeps)
    }

    func testAnAlreadyStoppedDisplayIsNotWaitedFor() async throws {
        let result = try await run([.stopped])
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.sleeps, 0)
    }

    func testWaitsThroughStoppingToStopped() async throws {
        let result = try await run([.started, .stopping, .stopping, .stopped])
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.sleeps, 3)
        XCTAssertEqual(result.waited, 0.3, accuracy: 0.0001)
    }

    func testGivesUpAtTheTimeoutWithoutThrowing() async throws {
        let result = try await run([.stopping], timeout: 1)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.waited, 1, accuracy: 0.0001)
        XCTAssertEqual(result.sleeps, 10)
    }

    func testOnlyARunningDisplayIsStopped() {
        XCTAssertTrue(DisplayCapabilityPhase.needsStop(.started))
        XCTAssertTrue(DisplayCapabilityPhase.needsStop(.starting))
        XCTAssertFalse(DisplayCapabilityPhase.needsStop(.stopping))
        XCTAssertFalse(DisplayCapabilityPhase.needsStop(.stopped))
    }

    // MARK: - The backend's order of work (source checks: `Display` is the SDK's and has no fake)

    func testDroppingTheSessionStopsTheDisplayBeforeHandingTheSessionBack() throws {
        let source = try backendSource()
        let drop = try slice(source, from: "private func dropSession(", to: "\n    }\n")
        let retire = try XCTUnwrap(drop.range(of: "retireDisplay()"),
                                   "a dropped Display must be stopped: the shared session outlives it")
        let handBack = try XCTUnwrap(drop.range(of: "session?.stop()"))
        XCTAssertLessThan(retire.lowerBound, handBack.lowerBound,
                          "stop the Display while we still hold the session")
    }

    func testANewDisplayWaitsForTheRetiredOne() throws {
        let source = try backendSource()
        let ensure = try slice(source, from: "private func ensureDisplay()", to: "\n    }\n")
        let wait = try XCTUnwrap(ensure.range(of: "DisplayStopWait.wait"))
        let add = try XCTUnwrap(ensure.range(of: "session.addDisplay()"))
        XCTAssertLessThan(wait.lowerBound, add.lowerBound,
                          "adding a Display while the dropped one is active is refused")
    }

    private func backendSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Display/MetaDisplayBackend.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let head = try XCTUnwrap(text.range(of: start), "\(start) not found")
        let tail = try XCTUnwrap(text.range(of: end, range: head.upperBound..<text.endIndex))
        return text[head.lowerBound..<tail.upperBound]
    }
}
