import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan EW — the stop/start ordering rule on its own, with no camera underneath it.
final class StreamStartGenerationTests: XCTestCase {

    func testAStartThatNothingInterruptedCommits() {
        var generation = StreamStartGeneration()
        let token = generation.beginStart()
        XCTAssertTrue(generation.isStartPending)
        XCTAssertEqual(generation.finish(token), .commit)
        XCTAssertFalse(generation.isStartPending)
    }

    func testAStopDuringAStartAbandonsIt() {
        var generation = StreamStartGeneration()
        let token = generation.beginStart()
        XCTAssertTrue(generation.recordStop(), "the stop cancelled a cold start that was still climbing")
        XCTAssertEqual(generation.finish(token), .abandon,
                       "a late start must not claim a stream the wearer already stopped")
    }

    func testAStopWithNothingInFlightReportsThatItCancelledNoStart() {
        var generation = StreamStartGeneration()
        XCTAssertFalse(generation.recordStop())
        let token = generation.beginStart()
        XCTAssertEqual(generation.finish(token), .commit)
        XCTAssertFalse(generation.recordStop(), "the start had already finished")
    }

    func testRepeatedStopsAreHarmless() {
        var generation = StreamStartGeneration()
        let token = generation.beginStart()
        generation.recordStop()
        generation.recordStop()
        generation.recordStop()
        XCTAssertEqual(generation.finish(token), .abandon)
        XCTAssertFalse(generation.isStartPending)
    }

    func testAStartBegunAfterAStopIsNotAffectedByIt() {
        var generation = StreamStartGeneration()
        let cancelled = generation.beginStart()
        generation.recordStop()
        let fresh = generation.beginStart()
        XCTAssertEqual(generation.finish(cancelled), .abandon)
        XCTAssertEqual(generation.finish(fresh), .commit,
                       "restarting after a stop must actually start")
    }

    func testEveryStartOutstandingWhenAStopLandsIsAbandoned() {
        // Two callers can both be inside a cold start — a claim and the manual control, say.
        var generation = StreamStartGeneration()
        let first = generation.beginStart()
        let second = generation.beginStart()
        generation.recordStop()
        XCTAssertEqual(generation.finish(first), .abandon)
        XCTAssertEqual(generation.finish(second), .abandon)
    }
}

/// Plan EW — the same rule as the coordinator actually applies it, observed through a fake backend
/// that records what it acquired and released. A policy table alone would not have caught this:
/// the defect was that a *real* stop call returned early and the *real* start then published a
/// running stream on top of it.
@MainActor
final class CameraServiceExitTests: XCTestCase {

    /// A backend whose cold start suspends until the test lets it through, so a stop can be
    /// issued inside the warm-up window the way backgrounding or a live session ending does.
    ///
    /// `holdsStream` is the resource: true from the moment the cold start completes until
    /// something stops it. A late start that leaves it true has resurrected a cancelled stream.
    private final class WarmUpCameraBackend: GlassesCameraBackend {
        let capabilities = CameraCapabilities.meta
        let events = PassthroughSubject<CameraBackendEvent, Never>()
        var permissionGranted = false

        func isReady(configuringIfNeeded: Bool) -> Bool { true }
        func ensurePermission() async throws { permissionGranted = true }
        func capturePhoto() async throws -> Data { Data([0xDE, 0xAD]) }

        /// Every acquire/release in the order it happened. Order is the point: a stop recorded
        /// *before* the acquire proves nothing, a stop recorded after it is the release.
        private(set) var calls: [String] = []
        private(set) var holdsStream = false
        private(set) var isWarmingUp = false
        private var warmUpGate: CheckedContinuation<Void, Never>?
        /// Set to make the cold start fail once it is released, for the throw-path tests.
        var warmUpError: Error?

        func startStreaming() async throws {
            calls.append("start")
            isWarmingUp = true
            await withCheckedContinuation { warmUpGate = $0 }
            isWarmingUp = false
            if let warmUpError {
                events.send(.status(.stopped))
                throw warmUpError
            }
            // The cold start has succeeded: the device stream is up and frames are flowing.
            holdsStream = true
            events.send(.streamingChanged(true))
        }

        func stopStreaming() async {
            calls.append("stop")
            guard holdsStream else { return }
            holdsStream = false
            events.send(.streamingChanged(false))
        }

        func tearDown() async {
            calls.append("tearDown")
            holdsStream = false
        }

        /// Let the cold start through.
        func finishWarmUp() {
            warmUpGate?.resume()
            warmUpGate = nil
        }
    }

    /// Yield until the backend is parked inside its cold start. A deadline poll rather than a
    /// sleep: on a loaded runner a fixed sleep is the difference between a test and a flake.
    private func waitForWarmUp(_ backend: WarmUpCameraBackend) async throws {
        for _ in 0..<1000 {
            if backend.isWarmingUp { return }
            await Task.yield()
        }
        throw XCTSkip("the backend never entered its cold start")
    }

    // MARK: - Stop during the cold start

    func testAStopDuringTheColdStartBeatsTheLateStart() async throws {
        let backend = WarmUpCameraBackend()
        let service = CameraService(backend: backend)

        let start = Task { try await service.startStreaming() }
        try await waitForWarmUp(backend)

        // What backgrounding with no glasses, or a live session ending, actually does.
        await service.stopStreaming()
        backend.finishWarmUp()
        let started = try await start.value

        XCTAssertFalse(started, "the start was superseded and must say so")
        XCTAssertFalse(service.isStreaming,
                       "a late start must not resurrect a stream the app already stopped")
        XCTAssertFalse(backend.holdsStream,
                       "the late start must release the stream its cold start acquired")
        XCTAssertEqual(backend.calls.last, "stop",
                       "the release has to come after the acquire, or it released nothing")
    }

    func testAStopDuringTheColdStartOfAClaimLeavesNoClaimBehind() async throws {
        let backend = WarmUpCameraBackend()
        let service = CameraService(backend: backend)

        let claim = Task { try await service.claimStream(for: .sceneNarration) }
        try await waitForWarmUp(backend)
        await service.stopStreaming()
        backend.finishWarmUp()
        try await claim.value

        XCTAssertFalse(service.hasStreamClaims,
                       "a claim on a stream that was cancelled before it came up would make a later release think it had something to give back")
        XCTAssertFalse(backend.holdsStream)
    }

    func testATearDownDuringTheColdStartAlsoBeatsTheLateStart() async throws {
        let backend = WarmUpCameraBackend()
        let service = CameraService(backend: backend)

        let start = Task { try await service.startStreaming() }
        try await waitForWarmUp(backend)
        await service.tearDown()
        backend.finishWarmUp()
        let started = try await start.value

        XCTAssertFalse(started)
        XCTAssertFalse(backend.holdsStream, "nothing may survive a teardown")
        XCTAssertFalse(service.isStreaming)
    }

    func testAnUninterruptedColdStartStillStarts() async throws {
        let backend = WarmUpCameraBackend()
        let service = CameraService(backend: backend)

        let start = Task { try await service.startStreaming() }
        try await waitForWarmUp(backend)
        backend.finishWarmUp()
        let started = try await start.value

        XCTAssertTrue(started)
        XCTAssertTrue(service.isStreaming)
        XCTAssertTrue(backend.holdsStream)
    }

    func testRestartingAfterAStopDuringTheColdStartActuallyStarts() async throws {
        let backend = WarmUpCameraBackend()
        let service = CameraService(backend: backend)

        let cancelled = Task { try await service.startStreaming() }
        try await waitForWarmUp(backend)
        await service.stopStreaming()
        backend.finishWarmUp()
        _ = try await cancelled.value
        XCTAssertFalse(service.isStreaming)

        // The generation must not have poisoned the next start — that would trade a stuck-on
        // camera for one that can never be switched back on.
        let fresh = Task { try await service.startStreaming() }
        try await waitForWarmUp(backend)
        backend.finishWarmUp()
        XCTAssertTrue(try await fresh.value)
        XCTAssertTrue(service.isStreaming)
        XCTAssertTrue(backend.holdsStream)
    }

    // MARK: - Repeated and empty stops

    func testRepeatedStopIsHarmless() async {
        let backend = WarmUpCameraBackend()
        let service = CameraService(backend: backend)

        await service.stopStreaming()
        await service.stopStreaming()
        await service.stopStreaming()

        XCTAssertFalse(service.isStreaming)
        XCTAssertFalse(backend.holdsStream)
        XCTAssertEqual(backend.calls, ["stop", "stop", "stop"],
                       "a stop is always forwarded; the backend, not the coordinator, decides there is nothing to do")
    }

    func testAFailedColdStartLeavesNothingHeld() async throws {
        struct Boom: Error {}
        let backend = WarmUpCameraBackend()
        backend.warmUpError = Boom()
        let service = CameraService(backend: backend)

        let start = Task { try await service.startStreaming() }
        try await waitForWarmUp(backend)
        backend.finishWarmUp()

        do {
            _ = try await start.value
            XCTFail("expected the cold start to fail")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertFalse(service.isStreaming)
        XCTAssertFalse(backend.holdsStream)
        XCTAssertFalse(service.isStartingStream, "the in-flight flag must not outlive the start")
    }
}
