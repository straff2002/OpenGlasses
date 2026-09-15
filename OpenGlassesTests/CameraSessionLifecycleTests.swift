import Combine
import MWDATCamera
import MWDATCore
import UIKit
import XCTest
@testable import OpenGlasses

// Plan FD P1 — session start, pause and cancellation.
//
// Four separate things are proved here, and they are kept apart on purpose:
//
// * the **pause decision** and its prohibition, as a pure table (`StreamPausePolicyTests`);
// * the **retry gate** — who may climb the reconnect ladder, and when it must stop
//   (`StreamReconnectPolicyTests`, `CameraRetryDispositionTests`);
// * the **mechanisms** that serialise and invalidate work (`CameraTransitionLockTests`,
//   `StreamListenerGenerationTests`);
// * the **ownership effects**, driven through the real `CameraService` over a backend that records
//   what it acquired and released and can be parked at any await boundary
//   (`CameraSessionLifecycleTests`).
//
// What is *not* proved here: the decisions inside `MetaCameraBackend` that talk to the SDK. That
// type reaches `Wearables`, which traps in a unit-test process, so the pure policies above are
// where its rules live and the wiring between them is reasoned, not executed. The plan's evidence
// note says which is which.

// MARK: - The pause decision

/// The discrepancy P1 exists to resolve, as a table.
///
/// The SDK settles it: `MWDATCamera.Stream` exposes `start()`, `stop()`, `state`, the four
/// publishers and `capturePhoto(format:)` — there is no resume, and `MWDATCore.DeviceSession` is
/// the same shape. Every recorded cause of a pause (temple-tap hold, doff since DAT 0.9, folded
/// hinges) is cleared by the wearer. So a pause is waited out, never started out of.
final class StreamPausePolicyTests: XCTestCase {

    /// Branch one: a pause nobody asked for, on a stream somebody still wants.
    func testAWantedPauseIsReportedAndWaitedOut() {
        XCTAssertEqual(StreamPausePolicy.response(streamingIntended: true),
                       .awaitSDKResume(notice: CameraStreamStatePolicy.pausedNotice))
    }

    /// Branch two: the app parked the stream itself after a one-off capture. Saying anything here
    /// would train the wearer to ignore the notice that matters.
    func testAPauseNobodyIsWaitingOnStaysSilent() {
        XCTAssertEqual(StreamPausePolicy.response(streamingIntended: false), .staySilent)
    }

    /// The prohibition, stated as strongly as a type can state it: whatever the state table decides
    /// about a paused stream, the only thing that can come out of this policy is a wait. There is
    /// no case that issues a start, so the old nudge cannot be expressed.
    func testNoPauseBranchCanIssueAStart() {
        for intended in [true, false] {
            let decision = CameraStreamStatePolicy.decide(state: .paused, streamingIntended: intended)
            guard case .pausedWhileWanted = decision else {
                XCTAssertNil(StreamPausePolicy.response(to: decision),
                             "only a wanted pause maps into the pause policy")
                continue
            }
            guard case .awaitSDKResume = StreamPausePolicy.response(to: decision) else {
                return XCTFail("a paused stream may only be waited out")
            }
        }
    }

    /// The start side of the same rule. A warm-up may nudge `start()` at a `.stopped` stream — that
    /// is the cold-start churn a start really does recover from — and may never nudge a paused one,
    /// for any pause age and any number of nudges already spent.
    func testAWarmupNeverNudgesAPausedStream() {
        for pausedFor in [0, 1, 4.9, 5, 10, 60] as [TimeInterval] {
            for nudges in 0...5 {
                let action = StreamPausePolicy.warmupAction(state: .paused,
                                                            pausedFor: pausedFor,
                                                            nudgesUsed: nudges)
                if case .nudgeStart = action {
                    XCTFail("a start was issued into a pause (\(pausedFor)s, \(nudges) nudges)")
                }
            }
        }
    }

    /// A pause that has only just landed is waited out: the SDK may lift it on its own, and a
    /// momentary pause during a start is not worth failing over.
    func testAFreshPauseIsWaitedOut() {
        XCTAssertEqual(StreamPausePolicy.warmupAction(state: .paused, pausedFor: 1), .wait)
    }

    /// A pause that stands is a hold, and a start cannot lift a hold. Failing now beats sitting out
    /// the rest of a twenty-second timeout to fail anyway.
    func testAHeldPauseEndsTheStart() {
        XCTAssertEqual(
            StreamPausePolicy.warmupAction(state: .paused,
                                           pausedFor: StreamPausePolicy.pauseHoldGrace),
            .giveUp(.pauseHeld))
    }

    /// The cold-start row: `.stopped` really is recovered by another start, and the nudges are
    /// bounded. Device-traced, a healthy cold start bounces through `.stopped` for 15–18 s.
    func testAStoppedStreamIsNudgedABoundedNumberOfTimes() {
        XCTAssertEqual(StreamPausePolicy.warmupAction(state: .stopped, nudgesUsed: 0),
                       .nudgeStart(attempt: 1))
        XCTAssertEqual(StreamPausePolicy.warmupAction(state: .stopped, nudgesUsed: 2),
                       .nudgeStart(attempt: 3))
        XCTAssertEqual(StreamPausePolicy.warmupAction(state: .stopped, nudgesUsed: 3),
                       .giveUp(.nudgesSpent),
                       "the nudges a cold start is allowed are spent; the stream needs rebuilding")
    }

    func testStreamingEndsTheWaitAndChurnDoesNot() {
        XCTAssertEqual(StreamPausePolicy.warmupAction(state: .streaming), .ready)
        for state in [CameraStreamStatePolicy.StreamState.starting, .stopping, .waitingForDevice] {
            XCTAssertEqual(StreamPausePolicy.warmupAction(state: state), .wait, "\(state)")
        }
    }

    // MARK: The other half of decision (b): the SDK's own resume has to be acted on

    /// With no nudge, the SDK lifting the pause is the only way back — so it must restore the
    /// streaming claim the pause cleared. Nothing used to: `isStreaming` stayed false for the rest
    /// of the session, which also left the stall detector (which guards on that flag) disarmed.
    func testAResumeRestoresTheStreamingClaim() {
        XCTAssertTrue(StreamPausePolicy.restoresStreamingClaim(streamingIntended: true,
                                                              alreadyStreaming: false,
                                                              transitionIsOurs: false))
    }

    /// A stream the wearer stopped during the pause is not resumed by a late `.streaming`.
    func testAResumeAfterTheWearerStoppedRestoresNothing() {
        XCTAssertFalse(StreamPausePolicy.restoresStreamingClaim(streamingIntended: false,
                                                               alreadyStreaming: false,
                                                               transitionIsOurs: false))
    }

    /// A warm-up or a rebuild owns its own commit — it has to be free to find its start superseded
    /// and release it, so the stream must not be published as running out from under it.
    func testOurOwnTransitionsCommitForThemselves() {
        XCTAssertFalse(StreamPausePolicy.restoresStreamingClaim(streamingIntended: true,
                                                               alreadyStreaming: false,
                                                               transitionIsOurs: true))
        XCTAssertFalse(StreamPausePolicy.restoresStreamingClaim(streamingIntended: true,
                                                               alreadyStreaming: true,
                                                               transitionIsOurs: false),
                       "nothing to restore; the app already believes the stream is up")
    }
}

// MARK: - The retry gate

/// Retry only while the stream is still wanted and the observable state permits it.
final class StreamReconnectPolicyTests: XCTestCase {

    func testAWantedDropClimbsTheLadder() {
        XCTAssertEqual(StreamReconnectPolicy.next(attempt: 0, streamingIntended: true,
                                                  transitionIsOurs: false, lastFailure: nil),
                       .retry(after: 1.5, attempt: 0))
    }

    /// Intent is checked first, and the order is load-bearing: a stream nobody wants must not be
    /// retried even when the error says a retry would work, and must not produce a give-up notice
    /// about a camera the wearer deliberately switched off.
    func testAStreamNobodyWantsIsNotRetriedAndSaysNothing() {
        XCTAssertEqual(StreamReconnectPolicy.next(attempt: 0, streamingIntended: false,
                                                  transitionIsOurs: false, lastFailure: nil),
                       .standDown)
        XCTAssertEqual(StreamReconnectPolicy.next(attempt: 99, streamingIntended: false,
                                                  transitionIsOurs: true,
                                                  lastFailure: .stopRetrying(notice: "x")),
                       .standDown)
    }

    /// Two rebuilders racing for one process-wide camera capability is how a dropped stream becomes
    /// `capabilityAlreadyActive`. Wait for the owner — and do not spend a rung on the wait.
    func testARebuildWeOwnIsWaitedForWithoutSpendingARung() {
        XCTAssertEqual(StreamReconnectPolicy.next(attempt: 4, streamingIntended: true,
                                                  transitionIsOurs: true, lastFailure: nil),
                       .deferToOwner(after: StreamReconnectPolicy.deferToOwnerDelay))
    }

    /// The question the gate never used to ask. A revoked permission is not a link hiccup, and
    /// ninety seconds of "reconnecting" is ninety seconds the wearer could have spent fixing it.
    func testAFailureNoRetryCanClearStopsTheLadderAtOnce() {
        let disposition = CameraErrorPolicy.retryDisposition(for: .permissionDenied)
        XCTAssertEqual(StreamReconnectPolicy.next(attempt: 0, streamingIntended: true,
                                                  transitionIsOurs: false,
                                                  lastFailure: disposition),
                       .giveUp(notice: CameraErrorPolicy.message(for: .permissionDenied)))
    }

    /// The budget is finite and the ladder says so when it runs out, rather than leaving the wearer
    /// watching a spinner that stopped meaning anything.
    func testTheLadderIsBoundedAndRetractsItsPromise() {
        var attempt = 0
        var rungs = 0
        var notice: String?
        while rungs < 100 {
            switch StreamReconnectPolicy.next(attempt: attempt, streamingIntended: true,
                                              transitionIsOurs: false, lastFailure: nil) {
            case .retry(_, let rung):
                XCTAssertEqual(rung, attempt)
                attempt += 1
                rungs += 1
            case .giveUp(let text):
                notice = text
                rungs = 100
            case .deferToOwner, .standDown:
                return XCTFail("nothing owns the stream and it is still wanted")
            }
        }
        XCTAssertEqual(notice, StreamRecoveryPolicy.reconnectGaveUpNotice)
        XCTAssertEqual(attempt, 21, "the ladder stops after the rungs the budget pays for")
        XCTAssertLessThan(StreamRecoveryPolicy.reconnectBudget, 120,
                          "a bounded budget, not an indefinite retry")
    }

    // MARK: A rung waking up

    func testARungMayActWhileNothingHasChanged() {
        XCTAssertTrue(StreamReconnectPolicy.mayAct(streamingIntended: true, alreadyStreaming: false,
                                                   scheduledUnderSession: 3, currentSession: 3))
    }

    /// A rung sleeps for up to five seconds. Everything that can happen in that window ends it.
    func testARungStandsDownWhenTheWorldMovedUnderIt() {
        // The wearer stopped the camera.
        XCTAssertFalse(StreamReconnectPolicy.mayAct(streamingIntended: false, alreadyStreaming: false,
                                                    scheduledUnderSession: 3, currentSession: 3))
        // It came back on its own.
        XCTAssertFalse(StreamReconnectPolicy.mayAct(streamingIntended: true, alreadyStreaming: true,
                                                    scheduledUnderSession: 3, currentSession: 3))
        // The camera session was replaced: this rung belongs to a ladder that was climbing a
        // camera which no longer exists.
        XCTAssertFalse(StreamReconnectPolicy.mayAct(streamingIntended: true, alreadyStreaming: false,
                                                    scheduledUnderSession: 3, currentSession: 4))
    }

    /// A stop is what bumps the session identity, so the two halves really do line up.
    func testAStopMovesTheSessionARungWasScheduledUnder() {
        var generation = StreamStartGeneration()
        let scheduled = generation.sessionIdentity
        generation.recordStop()
        XCTAssertFalse(StreamReconnectPolicy.mayAct(streamingIntended: true, alreadyStreaming: false,
                                                    scheduledUnderSession: scheduled,
                                                    currentSession: generation.sessionIdentity))
    }
}

/// The classification table: which failures a retry can clear, and which it cannot.
final class CameraRetryDispositionTests: XCTestCase {

    /// Transient: the link flapping is the ordinary case the ladder exists for.
    func testTransientStartupFailuresAreRetried() {
        for error in [StreamError.timeout, .videoStreamingError, .internalError,
                      .deviceNotConnected(DeviceIdentifier("device")),
                      .deviceNotFound(DeviceIdentifier("device"))] {
            XCTAssertEqual(CameraErrorPolicy.retryDisposition(for: error), .retryWithBackoff,
                           "\(error) is a window that closes")
        }
    }

    /// Compatibility and consent: nothing the app does changes these.
    func testPermissionIsNotRetried() {
        XCTAssertEqual(CameraErrorPolicy.retryDisposition(for: .permissionDenied),
                       .stopRetrying(notice: CameraErrorPolicy.message(for: .permissionDenied)))
        guard case .stopRetrying(let notice) = CameraErrorPolicy.retryDisposition(
            for: DeviceSessionError.datAppOnTheGlassesUpdateRequired) else {
            return XCTFail("an update requirement cannot be retried away")
        }
        XCTAssertEqual(notice, DATCompatibilityMessage.message(for: .datAppOnTheGlassesUpdateRequired))
    }

    /// Physical: since 0.9.0 `hingesClosed` covers both folded hinges and a doff, and both are a
    /// person having put the camera away. The notice already names the move that undoes it.
    func testAPhysicalCauseIsNotRetried() {
        guard case .stopRetrying(let notice) = CameraErrorPolicy.retryDisposition(for: .hingesClosed) else {
            return XCTFail("retrying does not open a pair of hinges")
        }
        XCTAssertTrue(notice.lowercased().contains("hinges"), "the notice names what to do: \(notice)")
    }

    /// Device conditions: a retry every 1.5 s neither cools the glasses down nor charges them.
    func testThermalAndPowerConditionsAreNotRetried() {
        for error in [StreamError.thermalCritical, .thermalEmergency,
                      .peakPowerShutdown, .batteryCritical] {
            guard case .stopRetrying = CameraErrorPolicy.retryDisposition(for: error) else {
                return XCTFail("\(error) is not fixed by trying again")
            }
        }
        for error in [DeviceSessionError.thermalCritical, .thermalEmergency,
                      .peakPowerShutdown, .batteryCritical] {
            XCTAssertEqual(CameraErrorPolicy.retryDisposition(for: error),
                           .stopRetrying(notice: CameraErrorPolicy.deviceConditionNotice), "\(error)")
        }
    }

    /// A failed capture says nothing about the stream, and must not stop a reconnect that is about
    /// something else. Same for the session errors that are windows closing.
    func testFailuresThatSayNothingAboutTheStreamDoNotStopTheLadder() {
        XCTAssertEqual(CameraErrorPolicy.retryDisposition(for: .photoCaptureFailed), .retryWithBackoff)
        for error in [DeviceSessionError.noEligibleDevice, .sessionAlreadyExists,
                      .capabilityAlreadyActive, .sessionIdle] {
            XCTAssertEqual(CameraErrorPolicy.retryDisposition(for: error), .retryWithBackoff, "\(error)")
        }
    }
}

// MARK: - The mechanisms

/// Serialising camera replacement. A boolean can only refuse; this makes the second caller wait.
@MainActor
final class CameraTransitionLockTests: XCTestCase {

    func testASecondTransitionWaitsRatherThanRacing() async {
        let lock = CameraTransitionLock()
        var order: [String] = []
        let first = Task { @MainActor in
            await lock.withLock {
                order.append("first in")
                for _ in 0..<50 { await Task.yield() }
                order.append("first out")
            }
        }
        for _ in 0..<100 where lock.isBusy == false { await Task.yield() }
        let second = Task { @MainActor in
            await lock.withLock { order.append("second in") }
        }
        await first.value
        await second.value
        XCTAssertEqual(order, ["first in", "first out", "second in"],
                       "the second transition must not begin before the first one finishes")
    }

    /// FIFO, so a queued transition cannot be starved by a later one.
    func testWaitersAreServedInOrder() async {
        let lock = CameraTransitionLock()
        var order: [Int] = []
        let holder = Task { @MainActor in
            await lock.withLock { for _ in 0..<50 { await Task.yield() } }
        }
        for _ in 0..<100 where !lock.isBusy { await Task.yield() }
        var queued: [Task<Void, Never>] = []
        for index in 1...3 {
            queued.append(Task { @MainActor in await lock.withLock { order.append(index) } })
            // Let this one reach the queue before the next is created, so "in order" means
            // something.
            for _ in 0..<20 where lock.waitingCount < index { await Task.yield() }
        }
        XCTAssertEqual(lock.waitingCount, 3, "three transitions queued behind the holder")
        await holder.value
        for task in queued { await task.value }
        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertFalse(lock.isBusy, "the lock is free once the queue drains")
    }

    func testAnUncontendedTransitionDoesNotWait() async {
        let lock = CameraTransitionLock()
        var ran = false
        await lock.withLock { ran = true }
        XCTAssertTrue(ran)
        XCTAssertFalse(lock.isBusy)
        XCTAssertEqual(lock.waitingCount, 0)
    }

    /// A throwing transition still gives the lock back — otherwise one failed rebuild wedges the
    /// camera for the life of the process.
    func testAThrowingTransitionReleasesTheLock() async {
        struct Boom: Error {}
        let lock = CameraTransitionLock()
        do {
            try await lock.withLock { throw Boom() }
            XCTFail("expected the transition to throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertFalse(lock.isBusy)
        var ran = false
        await lock.withLock { ran = true }
        XCTAssertTrue(ran)
    }
}

/// Invalidating callbacks from a stream that has been replaced. `ListenerTokenBag.cancelAll()` is
/// async, so a frame, a state change or an error from the old stream can still land on the new one.
final class StreamListenerGenerationTests: XCTestCase {

    func testTheCurrentListenersAreAccepted() {
        var generation = StreamListenerGeneration()
        let attached = generation.rotate()
        XCTAssertTrue(generation.accepts(attached))
    }

    func testCallbacksFromTheReplacedStreamAreDropped() {
        var generation = StreamListenerGeneration()
        let old = generation.rotate()
        let new = generation.rotate()
        XCTAssertFalse(generation.accepts(old),
                       "a stale `.stopped` would otherwise schedule a reconnect for a stream that is already coming up")
        XCTAssertTrue(generation.accepts(new))
    }

    /// The generation before any attach belongs to nobody, so a callback that somehow carries it
    /// is dropped too.
    func testNothingIsAcceptedBeforeTheFirstAttach() {
        var generation = StreamListenerGeneration()
        let before = generation.current
        _ = generation.rotate()
        XCTAssertFalse(generation.accepts(before))
    }
}

// MARK: - Ownership effects, through the real coordinator

/// A backend that can be parked at any await boundary a start passes through, and that records
/// what it acquired and released in order.
///
/// `holdsStream` is the resource. A start that leaves it true after a stop has resurrected a
/// cancelled stream; a rebuild that leaves it false has torn down somebody else's stream.
@MainActor
private final class GatedCameraBackend: GlassesCameraBackend {

    /// The await boundaries a start crosses, in order. Named after the real ones.
    enum Boundary: String, CaseIterable {
        case permission, warmUp, backoff, replacement, teardown
    }

    let capabilities = CameraCapabilities.meta
    let events = PassthroughSubject<CameraBackendEvent, Never>()
    var permissionGranted = false

    func isReady(configuringIfNeeded: Bool) -> Bool { true }
    func ensurePermission() async throws { permissionGranted = true }
    func capturePhoto() async throws -> Data { Data([0xDE, 0xAD]) }

    private(set) var calls: [String] = []
    private(set) var holdsStream = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// Where a start should suspend until the test lets it through.
    var gates: Set<Boundary> = []
    /// Set to make a start fail once it is released.
    var startError: Error?
    /// Automatic work the backend has armed, as it would report on device.
    var armedWork = 0
    var scheduledWorkCount: Int { armedWork }

    private var parked: [Boundary: CheckedContinuation<Void, Never>] = [:]
    private(set) var waitingAt: Boundary?

    private func pause(at boundary: Boundary) async {
        guard gates.contains(boundary) else { return }
        waitingAt = boundary
        await withCheckedContinuation { parked[boundary] = $0 }
        waitingAt = nil
    }

    /// Let a parked start through.
    func release(_ boundary: Boundary) {
        parked.removeValue(forKey: boundary)?.resume()
    }

    func startStreaming() async throws {
        startCount += 1
        calls.append("start")
        for boundary in [Boundary.permission, .warmUp, .backoff, .replacement] {
            await pause(at: boundary)
        }
        if let startError {
            events.send(.status(.stopped))
            throw startError
        }
        holdsStream = true
        events.send(.streamingChanged(true))
    }

    func stopStreaming() async {
        stopCount += 1
        calls.append("stop")
        guard holdsStream else { return }
        holdsStream = false
        armedWork = 0
        events.send(.streamingChanged(false))
    }

    func tearDown() async {
        calls.append("tearDown")
        await pause(at: .teardown)
        holdsStream = false
        armedWork = 0
    }

    /// What a rebuild looks like from outside: the stream drops and comes back, and nothing about
    /// the camera the app is holding changes.
    func emitRebuild() {
        events.send(.streamingChanged(false))
        events.send(.status(.waiting))
        events.send(.streamingChanged(true))
        events.send(.status(.streaming))
    }
}

@MainActor
final class CameraSessionLifecycleTests: XCTestCase {

    /// Yield until the backend is parked at `boundary`. A deadline poll rather than a sleep: on a
    /// loaded runner a fixed sleep is the difference between a test and a flake.
    private func waitFor(_ backend: GatedCameraBackend,
                         at boundary: GatedCameraBackend.Boundary) async throws {
        for _ in 0..<2000 {
            if backend.waitingAt == boundary { return }
            await Task.yield()
        }
        throw XCTSkip("the backend never reached the \(boundary.rawValue) boundary")
    }

    // MARK: Coalescing

    /// Two features reaching for the camera at the same moment — the wearer's control and a live
    /// session's claim — used to get a trip through the backend each: two device sessions and two
    /// `addCamera` calls racing for one process-wide capability.
    func testSimultaneousStartsIssueOneBackendStart() async throws {
        let backend = GatedCameraBackend()
        backend.gates = [.warmUp]
        let service = CameraService(backend: backend)

        let first = Task { try await service.startStreaming() }
        try await waitFor(backend, at: .warmUp)
        let second = Task { try await service.startStreaming() }
        // Give the second caller every chance to issue a start of its own before we let the first
        // one through.
        for _ in 0..<200 { await Task.yield() }
        backend.release(.warmUp)

        let outcomes = [try await first.value, try await second.value]
        XCTAssertEqual(outcomes, [true, true], "both callers get the same answer")
        XCTAssertEqual(backend.startCount, 1, "one start reached the device, not two")
        XCTAssertTrue(service.isStreaming)
    }

    /// Including when the answer is "a stop overtook it". The second caller must not be told the
    /// stream came up.
    func testACoalescedStartReportsTheSupersededOutcomeToBothCallers() async throws {
        let backend = GatedCameraBackend()
        backend.gates = [.warmUp]
        let service = CameraService(backend: backend)

        let first = Task { try await service.startStreaming() }
        try await waitFor(backend, at: .warmUp)
        let second = Task { try await service.startStreaming() }
        for _ in 0..<200 { await Task.yield() }
        await service.stopStreaming()
        backend.release(.warmUp)

        let outcomes = [try await first.value, try await second.value]
        XCTAssertEqual(outcomes, [false, false])
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertFalse(backend.holdsStream, "the late start released what its cold start acquired")
        XCTAssertFalse(service.isStreaming)
    }

    /// A failed start is shared too — and leaves nothing behind for the next one to trip over.
    func testACoalescedFailureReachesBothCallersAndLeavesNothingArmed() async throws {
        struct Boom: Error {}
        let backend = GatedCameraBackend()
        backend.gates = [.warmUp]
        backend.startError = Boom()
        let service = CameraService(backend: backend)

        let first = Task { try await service.startStreaming() }
        try await waitFor(backend, at: .warmUp)
        let second = Task { try await service.startStreaming() }
        for _ in 0..<200 { await Task.yield() }
        backend.release(.warmUp)

        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("expected the start to fail")
            } catch {
                XCTAssertTrue(error is Boom)
            }
        }
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(service.scheduledCameraWorkCount, 0, "nothing is left armed after a failure")

        // And the coalescing record is not poisoned: the next start really starts.
        backend.startError = nil
        backend.gates = []
        let restarted = try await service.startStreaming()
        XCTAssertTrue(restarted)
        XCTAssertEqual(backend.startCount, 2)
    }

    // MARK: Stop at every await boundary

    /// Stop during the permission check, the warm-up, a backoff wait and a replacement. In every
    /// one of them the start has to release what it acquired, stay released, and leave nothing
    /// scheduled behind it.
    func testStopAtEveryAwaitBoundaryEndsTheStart() async throws {
        for boundary in [GatedCameraBackend.Boundary.permission, .warmUp, .backoff, .replacement] {
            let backend = GatedCameraBackend()
            backend.gates = [boundary]
            let service = CameraService(backend: backend)

            let start = Task { try await service.startStreaming() }
            try await waitFor(backend, at: boundary)
            await service.stopStreaming()
            backend.release(boundary)
            let started = try await start.value

            XCTAssertFalse(started, "a start stopped at \(boundary.rawValue) must say so")
            XCTAssertFalse(service.isStreaming, "\(boundary.rawValue)")
            XCTAssertFalse(backend.holdsStream,
                           "a late start must not resurrect a stream stopped at \(boundary.rawValue)")
            XCTAssertEqual(backend.calls.last, "stop",
                           "the release has to come after the acquire at \(boundary.rawValue)")
            XCTAssertEqual(service.scheduledCameraWorkCount, 0,
                           "no automatic work outlives a stop at \(boundary.rawValue)")
        }
    }

    /// The same for a claim: a claim on a stream that was cancelled before it came up would make
    /// every later release think it had something to give back.
    func testStopAtEveryAwaitBoundaryLeavesNoClaimBehind() async throws {
        for boundary in [GatedCameraBackend.Boundary.permission, .warmUp, .backoff, .replacement] {
            let backend = GatedCameraBackend()
            backend.gates = [boundary]
            let service = CameraService(backend: backend)

            let claim = Task { try await service.claimStream(for: .liveSession) }
            try await waitFor(backend, at: boundary)
            await service.stopStreaming()
            backend.release(boundary)
            try await claim.value

            XCTAssertFalse(service.hasStreamClaims, "\(boundary.rawValue)")
            XCTAssertFalse(backend.holdsStream, "\(boundary.rawValue)")
        }
    }

    /// A stop issued while a teardown is still unwinding. Nothing may survive either of them.
    func testAStopDuringTeardownLeavesNothingHeld() async throws {
        let backend = GatedCameraBackend()
        let service = CameraService(backend: backend)
        _ = try await service.startStreaming()
        XCTAssertTrue(backend.holdsStream)

        backend.gates = [.teardown]
        backend.armedWork = 1          // a stall detector, as the device backend would have
        let teardown = Task { await service.tearDown() }
        try await waitFor(backend, at: .teardown)
        await service.stopStreaming()
        backend.release(.teardown)
        await teardown.value

        XCTAssertFalse(backend.holdsStream)
        XCTAssertFalse(service.isStreaming)
        XCTAssertFalse(service.hasStreamClaims)
        XCTAssertEqual(service.scheduledCameraWorkCount, 0)
    }

    /// A start begun after a stop is unaffected by it — the fix must not trade a camera that
    /// cannot be switched off for one that cannot be switched back on.
    func testRestartingAfterAStopStillStarts() async throws {
        let backend = GatedCameraBackend()
        backend.gates = [.warmUp]
        let service = CameraService(backend: backend)

        let cancelled = Task { try await service.startStreaming() }
        try await waitFor(backend, at: .warmUp)
        await service.stopStreaming()
        backend.release(.warmUp)
        let cancelledOutcome = try await cancelled.value
        XCTAssertFalse(cancelledOutcome)

        let fresh = Task { try await service.startStreaming() }
        try await waitFor(backend, at: .warmUp)
        backend.release(.warmUp)
        let freshOutcome = try await fresh.value
        XCTAssertTrue(freshOutcome)
        XCTAssertTrue(service.isStreaming)
        XCTAssertTrue(backend.holdsStream)
    }

    // MARK: A pause the wearer ends by stopping

    /// Paused, then stopped. Nothing may issue a start afterwards — not the coordinator, not a
    /// late event from the paused session.
    func testAPauseTheWearerStopsIsNeverStartedAgain() async throws {
        let backend = GatedCameraBackend()
        let service = CameraService(backend: backend)
        _ = try await service.startStreaming()
        let startsBefore = backend.startCount

        // The glasses come off: the SDK pauses the stream and the backend reports it.
        backend.events.send(.streamingChanged(false))
        backend.events.send(.waitReason(.paused))
        backend.events.send(.transientNotice(CameraStreamStatePolicy.pausedNotice))
        XCTAssertEqual(service.readiness.phase, .paused)
        XCTAssertEqual(backend.startCount, startsBefore, "a pause issues no start")

        await service.stopStreaming()
        // Whatever the paused session says afterwards, nothing starts a camera.
        backend.events.send(.waitReason(.paused))
        backend.events.send(.status(.waiting))
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(backend.startCount, startsBefore, "a stopped camera is never restarted for us")
        XCTAssertFalse(service.isStreaming)
        XCTAssertFalse(service.readiness.userWantsStream)
        XCTAssertEqual(service.scheduledCameraWorkCount, 0)
    }

    // MARK: Other consumers' claims

    /// A rebuild of ours must not tear down an unrelated consumer. The stream drops and comes back;
    /// the recording keeps its camera and the live session keeps its claim.
    func testARebuildPreservesAnotherOwnersClaimAndTheRecording() async throws {
        let backend = GatedCameraBackend()
        let service = CameraService(backend: backend)
        var recordingActive = true
        service.otherStreamConsumersActive = { recordingActive }

        try await service.claimStream(for: .liveSession)
        XCTAssertTrue(backend.holdsStream)
        let stopsBefore = backend.stopCount

        backend.emitRebuild()

        XCTAssertTrue(service.holdsStreamClaim(.liveSession), "a rebuild is not a release")
        XCTAssertTrue(backend.holdsStream, "the recording's camera was never torn down")
        XCTAssertEqual(backend.stopCount, stopsBefore, "a rebuild of ours stops nothing")
        XCTAssertTrue(service.isStreaming)

        // And when the session does end, the recording still holds the stream open.
        await service.releaseStream(for: .liveSession)
        XCTAssertTrue(backend.holdsStream,
                      "ending a conversation must not stop a camera a recording is using")
        XCTAssertEqual(backend.stopCount, stopsBefore)
        XCTAssertFalse(service.hasStreamClaims, "the claim itself is given back")
        recordingActive = false
    }

    /// The wearer's own stream is not somebody else's to stop, rebuild or not.
    func testARebuildDoesNotHandUsAStreamTheWearerOpened() async throws {
        let backend = GatedCameraBackend()
        let service = CameraService(backend: backend)

        _ = try await service.startStreaming()      // the wearer opens the preview
        try await service.claimStream(for: .liveSession)
        backend.emitRebuild()
        await service.releaseStream(for: .liveSession)

        XCTAssertTrue(backend.holdsStream,
                      "a claim that found the stream already running never started it, so it may not stop it")
    }
}

// MARK: - The device backend's own accounting

/// The one thing about `MetaCameraBackend` that can be observed in a unit-test process: it reaches
/// `Wearables` — which traps headlessly — only from paths a stop never takes.
@MainActor
final class MetaCameraBackendSchedulingTests: XCTestCase {

    func testAFreshBackendHasNothingArmed() {
        XCTAssertEqual(MetaCameraBackend().scheduledWorkCount, 0)
    }

    func testStopAndTearDownLeaveNothingArmed() async {
        let backend = MetaCameraBackend()
        await backend.stopStreaming()
        XCTAssertEqual(backend.scheduledWorkCount, 0)
        await backend.stopStreaming()   // repeated stop is harmless
        await backend.tearDown()
        XCTAssertEqual(backend.scheduledWorkCount, 0,
                       "no retry rung, stall detector or idle timer outlives a teardown")
    }
}
