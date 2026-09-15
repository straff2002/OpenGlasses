import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan FE P2: `WakeWordService`'s start sequence, driven through injected seams.
///
/// The service's real start touches a microphone route, an `AVAudioEngine` and an
/// `SFSpeechRecognizer`, none of which behave in a simulator — so the engine, the recognizer, the
/// authorization prompt and the session activation are substituted, and what is asserted is the
/// sequence of calls the service makes and the state it leaves behind. Effects are real: the same
/// generation, intent and health logic runs as on device.
///
/// No sleeps. Where a test has to wait for a fire-and-forget `Task`, it polls a signal with a
/// deadline.
@MainActor
final class WakeWordListenerRecoveryTests: XCTestCase {

    // MARK: - Harness

    /// Records what the start sequence did and stands in for the audio graph it would have built.
    private final class Harness {
        enum Call: String, Equatable {
            case permissions, recognizerAvailability, configureSession, cleanup, startRecognition
        }

        var calls: [Call] = []
        /// What the service observes when it asks about the graph.
        var graph = ListenerGraphSnapshot()
        /// Whether the audio-session lease is held. `configureSession` takes it; nothing in the
        /// start sequence may ever give it back.
        var leaseHeld = false
        var permissionGranted = true
        var recognizerAvailable = true
        /// Errors thrown by the next `startRecognition` calls, consumed in order.
        var startFailures: [Error] = []
        /// Whether the tap was still installed at the moment each `startRecognition` was called.
        var tapInstalledAtStart: [Bool] = []
        /// Run inside the authorization await — where a test lands a stop mid-start.
        var duringPermissions: (@MainActor () -> Void)?
        /// Run inside the session activation.
        var duringConfigure: (@MainActor () -> Void)?
        /// Awaited inside the authorization await, to hold a start open.
        var permissionGate: AsyncGate?

        var count: (Call) -> Int { { call in self.calls.filter { $0 == call }.count } }

        @MainActor
        func install(on service: WakeWordService) {
            service.permissionOverride = { [weak self] in
                guard let self else { return false }
                self.calls.append(.permissions)
                self.duringPermissions?()
                if let gate = self.permissionGate { await gate.wait() }
                return self.permissionGranted
            }
            service.recognizerAvailabilityOverride = { [weak self] in
                guard let self else { return false }
                self.calls.append(.recognizerAvailability)
                return self.recognizerAvailable
            }
            service.audioSessionConfigureOverride = { [weak self] in
                guard let self else { return }
                self.calls.append(.configureSession)
                self.leaseHeld = true
                self.duringConfigure?()
            }
            service.cleanupAudioEngineOverride = { [weak self] in
                guard let self else { return }
                self.calls.append(.cleanup)
                self.graph = ListenerGraphSnapshot()
            }
            service.startRecognitionOverride = { [weak self] in
                guard let self else { return }
                self.calls.append(.startRecognition)
                self.tapInstalledAtStart.append(self.graph.tapInstalled)
                if !self.startFailures.isEmpty {
                    throw self.startFailures.removeFirst()
                }
                self.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true,
                                                   recognition: .running)
            }
            service.graphSnapshotOverride = { [weak self] in self?.graph ?? ListenerGraphSnapshot() }
            service.leaseHeldOverride = { [weak self] in self?.leaseHeld ?? false }
        }
    }

    /// A one-shot gate a test opens when it wants a suspended start to carry on.
    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    private var service: WakeWordService!
    private var harness: Harness!
    private var silentModeBefore = false

    override func setUp() {
        super.setUp()
        silentModeBefore = Config.silentMode
        Config.setSilentMode(false)
        service = WakeWordService()
        harness = Harness()
        harness.install(on: service)
    }

    override func tearDown() {
        Config.setSilentMode(silentModeBefore)
        service = nil
        harness = nil
        super.tearDown()
    }

    /// Poll a signal until it holds or the deadline passes. Returns whether it held.
    @discardableResult
    private func poll(until condition: @MainActor () -> Bool,
                      timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    private func startHealthyListener() async throws {
        try await service.startListening()
        XCTAssertTrue(service.isListening)
        harness.calls.removeAll()
        harness.tapInstalledAtStart.removeAll()
    }

    // MARK: - Broken listening is rebuilt

    /// The headline defect. The flag says listening, the engine is gone, and the old guard
    /// returned at `guard !isListening else { return }` having rebuilt nothing — so every
    /// auto-start path in the app was a silent no-op until the wearer relaunched.
    func testStaleFlagWithStoppedEngineRebuildsOnceAndLeavesOneListener() async throws {
        service.isListening = true
        harness.graph = ListenerGraphSnapshot()   // the disruption took the engine with it

        try await service.startListening()

        XCTAssertEqual(harness.count(.startRecognition), 1, "exactly one listener, not two")
        XCTAssertEqual(harness.count(.cleanup), 1, "the dead graph is torn down exactly once")
        XCTAssertTrue(service.isListening)
        XCTAssertTrue(harness.graph.engineRunning)
        XCTAssertEqual(harness.graph.recognition, .running)
    }

    /// Engine running alone does not prove recognition works, and the old tap must come out
    /// before the new one goes in — two taps on one input node is the orphaned-mic shape.
    func testEndedRecognitionRebuildsAndRemovesTheOldTapFirst() async throws {
        service.isListening = true
        harness.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true,
                                              recognition: .ended(failed: false))

        try await service.startListening()

        let cleanupIndex = harness.calls.firstIndex(of: .cleanup)
        let startIndex = harness.calls.firstIndex(of: .startRecognition)
        XCTAssertNotNil(cleanupIndex)
        XCTAssertNotNil(startIndex)
        XCTAssertLessThan(cleanupIndex!, startIndex!, "cleanup has to precede the new recognizer")
        XCTAssertEqual(harness.tapInstalledAtStart, [false],
                       "the old tap was still installed when the new recognizer was created")
        XCTAssertEqual(harness.count(.startRecognition), 1)
        XCTAssertTrue(service.isListening)
    }

    /// The recognizer's error path clears the flag and leaves an ended task beside a live engine.
    /// The next start has to recognise that as broken rather than as a cold start.
    func testInterruptionRecoveryRebuildsFromAnErroredRecognizer() async throws {
        try await startHealthyListener()
        // What the error path leaves behind: flag down, engine still up, recognition ended badly.
        service.isListening = false
        harness.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true,
                                              recognition: .ended(failed: true))

        try await service.autoStartListening()

        XCTAssertEqual(harness.count(.cleanup), 1)
        XCTAssertEqual(harness.count(.startRecognition), 1)
        XCTAssertTrue(service.isListening)
    }

    /// The whole point of the phase, driven through the real fire-and-forget recovery entry point:
    /// `resumeListening()` used to open with the same `guard !isListening`, so a stale flag made it
    /// a no-op too.
    func testResumeListeningRecoversAListenerTheFlagClaimsIsAlreadyUp() async throws {
        try await startHealthyListener()
        harness.graph = ListenerGraphSnapshot()    // engine lost; `isListening` still true

        service.resumeListening()

        let recovered = await poll { self.harness.count(.startRecognition) == 1 }
        XCTAssertTrue(recovered, "a stale flag must not suppress recovery")
        XCTAssertTrue(service.isListening)
    }

    // MARK: - Healthy listening is left alone

    func testRepeatedStartOnAHealthyListenerDoesNotRebuild() async throws {
        try await startHealthyListener()

        try await service.startListening()
        try await service.startListening()

        XCTAssertEqual(harness.calls, [], "a working listener answers the request by existing")
        XCTAssertTrue(service.isListening)
    }

    // MARK: - Coalescing

    func testSimultaneousStartsRunOneStartSequenceAndBothCallersGetTheResult() async throws {
        let gate = AsyncGate()
        harness.permissionGate = gate

        let first = Task { @MainActor in try await self.service.startListening() }
        let entered = await poll { self.harness.count(.permissions) == 1 }
        XCTAssertTrue(entered, "the first start should have reached the authorization await")

        let second = Task { @MainActor in try await self.service.startListening() }
        let coalesced = await poll { self.service.coalescedStartCount == 1 }
        XCTAssertTrue(coalesced, "the second caller should have joined the start already climbing")

        await gate.open()
        try await first.value
        try await second.value

        XCTAssertEqual(harness.count(.permissions), 1, "one authorization await, not two")
        XCTAssertEqual(harness.count(.startRecognition), 1, "one microphone, not two")
        XCTAssertTrue(service.isListening)
    }

    // MARK: - Stop wins the races

    func testStopDuringThePermissionWaitLeavesNoListener() async throws {
        harness.duringPermissions = { [weak self] in self?.service.stopListening() }

        try await service.startListening()

        XCTAssertFalse(service.isListening)
        XCTAssertEqual(harness.count(.startRecognition), 0, "the late start must not open a mic")
        XCTAssertEqual(harness.count(.configureSession), 0)
        XCTAssertFalse(harness.leaseHeld, "nothing was acquired, so nothing may be released")
    }

    func testStopDuringSessionActivationLeavesNoListenerAndKeepsTheLease() async throws {
        harness.duringConfigure = { [weak self] in self?.service.stopListening() }

        try await service.startListening()

        XCTAssertFalse(service.isListening)
        XCTAssertEqual(harness.count(.startRecognition), 0)
        XCTAssertTrue(harness.leaseHeld,
                      "wake word is the baseline session owner; a late start neither claims a "
                      + "listener nor surrenders ownership")
    }

    func testExplicitStopBlocksAutomaticRestartsUntilSomebodyAsksAgain() async throws {
        try await startHealthyListener()
        service.stopListening()
        XCTAssertFalse(service.isListening)
        harness.calls.removeAll()

        try await service.autoStartListening()
        XCTAssertEqual(harness.count(.startRecognition), 0,
                       "a route change does not undo the wearer's stop")
        XCTAssertFalse(service.isListening)

        try await service.startListening()
        XCTAssertEqual(harness.count(.startRecognition), 1)
        XCTAssertTrue(service.isListening)
    }

    func testResumeListeningAfterAnExplicitStopDoesNotRestart() async throws {
        try await startHealthyListener()
        service.stopListening()
        harness.calls.removeAll()

        service.resumeListening()

        let restarted = await poll(until: { self.harness.count(.startRecognition) > 0 },
                                   timeout: 0.3)
        XCTAssertFalse(restarted)
        XCTAssertFalse(service.isListening)
    }

    // MARK: - Other consumers

    /// The shared-engine handoff hands a running engine to dictation. An automatic restart must
    /// not barge in on it, and the explicit ask that follows must not tear the engine out from
    /// under the consumer riding it.
    func testSharedEnginePauseIsNotRebuiltAndResumesThroughTheExistingPath() async throws {
        try await startHealthyListener()
        service.addAudioBufferConsumer(id: "dictation") { _ in }

        service.pauseRecognitionForSharedEngine()
        // What the handoff leaves: the engine and its tap alive, no wake-word recognizer.
        harness.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true,
                                              recognition: .none)
        XCTAssertEqual(service.deliberatePause, .sharedEngine)
        XCTAssertFalse(service.isListening)

        try await service.autoStartListening()
        XCTAssertEqual(harness.count(.startRecognition), 0, "an automatic restart must stand off")
        XCTAssertEqual(harness.count(.cleanup), 0, "the consumer's engine must not be torn down")
        XCTAssertEqual(service.deliberatePause, .sharedEngine)

        try await service.startListening()
        XCTAssertEqual(harness.count(.startRecognition), 1)
        XCTAssertEqual(harness.count(.cleanup), 0, "resuming reuses the running engine")
        XCTAssertNil(service.deliberatePause)
        XCTAssertTrue(service.isListening)

        service.removeAudioBufferConsumer(id: "dictation")
    }

    /// A deliberate pause is a claim on a *running* graph. When a route flap takes the engine, the
    /// claim is void — otherwise the automatic restart stands off for a consumer whose engine no
    /// longer exists, and nothing is listening and nothing is feeding the consumers either.
    func testAnAudioDisruptionVoidsASharedEnginePauseSoRecoveryCanRun() async throws {
        try await startHealthyListener()
        service.addAudioBufferConsumer(id: "captions") { _ in }
        service.pauseRecognitionForSharedEngine()
        XCTAssertEqual(service.deliberatePause, .sharedEngine)

        service.pauseForAudioDisruption()          // the route flap
        harness.graph = ListenerGraphSnapshot()    // which took the engine and its tap with it
        XCTAssertNil(service.deliberatePause)
        XCTAssertFalse(service.isListening)

        try await service.autoStartListening()     // the matching recovery
        XCTAssertEqual(harness.count(.startRecognition), 1)
        XCTAssertTrue(service.isListening)

        service.removeAudioBufferConsumer(id: "captions")
    }

    /// The same disruption keeps intent: an interruption is not the wearer switching listening off.
    func testAnAudioDisruptionKeepsIntentSoTheRecoveryPathIsAllowed() async throws {
        try await startHealthyListener()
        harness.graph = ListenerGraphSnapshot()

        service.pauseForAudioDisruption()
        try await service.autoStartListening()

        XCTAssertTrue(service.isListening)
        XCTAssertEqual(harness.count(.startRecognition), 1)
    }

    // MARK: - Refusals

    func testSilentModeRefusesToStartAndAsksForNothing() async throws {
        Config.setSilentMode(true)

        try await service.startListening()

        XCTAssertEqual(harness.calls, [], "push-to-talk never even asks for the microphone")
        XCTAssertFalse(service.isListening)
    }

    func testDeniedPermissionThrowsAndLeavesNoListener() async {
        harness.permissionGranted = false

        do {
            try await service.startListening()
            XCTFail("a denied microphone must be reported, not swallowed")
        } catch {
            XCTAssertFalse(service.isListening)
            XCTAssertEqual(harness.count(.startRecognition), 0)
        }
    }

    // MARK: - Rebuild uses the existing APIs only

    /// A rebuild is `cleanupAudioEngine()` then `startRecognition()`. It must not re-run the
    /// session configuration, because that is where ownership is assumed — the lease a rebuild
    /// starts with is the lease it ends with, which is what lets other consumers coexist on it.
    func testARebuildDoesNotReacquireTheSessionLease() async throws {
        service.isListening = true
        harness.graph = ListenerGraphSnapshot()

        try await service.startListening()

        let afterConfigure = harness.calls.drop { $0 != .configureSession }.dropFirst()
        XCTAssertEqual(Array(afterConfigure), [.cleanup, .startRecognition],
                       "the rebuild itself is cleanup + start, nothing else")
        XCTAssertEqual(harness.count(.configureSession), 1)
        XCTAssertTrue(harness.leaseHeld)
    }

    /// The `!pla` retry does re-activate the session — that is the documented recovery for a route
    /// flap mid-start — and it is still one listener at the end, not one per attempt.
    func testAFailedAttemptRetriesWithoutLeavingASecondListener() async throws {
        struct Flap: Error {}
        harness.startFailures = [Flap()]

        try await service.startListening()

        XCTAssertEqual(harness.count(.startRecognition), 2, "one failed attempt, then one success")
        XCTAssertTrue(service.isListening)
        XCTAssertEqual(harness.graph.recognition, .running)
    }

    // MARK: - Flag-writer audit

    /// Every path that takes the recognizer down leaves the flag down with it. A flag claiming a
    /// listener that has no recognition task is the state the whole phase exists to make
    /// impossible.
    func testNoTeardownPathLeavesTheFlagClaimingAListener() async throws {
        try await startHealthyListener()
        service.pauseRecognitionPublic()
        XCTAssertFalse(service.isListening)
        harness.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true,
                                              recognition: .none)

        try await service.startListening()
        service.pauseRecognitionForSharedEngine()
        XCTAssertFalse(service.isListening)
        harness.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true,
                                              recognition: .none)

        try await service.startListening()
        service.stopListening()
        XCTAssertFalse(service.isListening)

        await service.deactivateAudioSession()
        XCTAssertFalse(service.isListening)
    }

    /// A start that never manages to bring a recognizer up must not report one.
    func testAStartThatFailsEveryAttemptLeavesTheFlagDown() async {
        struct Broken: Error {}
        harness.startFailures = [Broken(), Broken(), Broken()]

        do {
            try await service.startListening()
            XCTFail("three failed attempts must be reported")
        } catch {
            XCTAssertFalse(service.isListening)
            XCTAssertEqual(harness.count(.startRecognition), 3)
        }
    }
}
