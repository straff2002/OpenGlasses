import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR3 — the sequencing rules, against a recording activation owner.
///
/// What is being pinned is not "a session starts". It is the three things five copies of
/// *switch, sleep, start* could not do: two requests produce one session, a Stop cancels a start
/// that has not happened yet, and no ambient event puts back what the wearer took down.
@MainActor
final class LiveSessionActivatorTests: XCTestCase {

    // MARK: - Harness

    /// Records every call in order. The sequence *is* the test.
    @MainActor
    private final class FakeOwner: LiveSessionActivationOwner {
        var activeMode: AppMode = .direct
        var activeSessions: Set<AppMode> = []
        var calls: [String] = []

        /// Suspends inside `performModeSwitch` until resumed, so a test can stand in the middle of
        /// the teardown/settle the activator awaits.
        var switchGate: CheckedContinuation<Void, Never>?
        var holdSwitch = false

        /// Same, for `startSession`.
        var startGate: CheckedContinuation<Void, Never>?
        var holdStart = false

        func isSessionActive(_ mode: AppMode) -> Bool { activeSessions.contains(mode) }

        func performModeSwitch(to mode: AppMode) async {
            calls.append("switch(\(mode.rawValue))")
            if holdSwitch {
                await withCheckedContinuation { self.switchGate = $0 }
            }
            activeMode = mode
        }

        func startSession(_ mode: AppMode) async {
            calls.append("start(\(mode.rawValue))")
            if holdStart {
                await withCheckedContinuation { self.startGate = $0 }
            }
            activeSessions.insert(mode)
        }

        func stopSession(_ mode: AppMode) {
            calls.append("stop(\(mode.rawValue))")
            activeSessions.remove(mode)
        }

        func releaseSwitch() {
            let gate = switchGate
            switchGate = nil
            gate?.resume()
        }

        func releaseStart() {
            let gate = startGate
            startGate = nil
            gate?.resume()
        }

        var startCount: Int { calls.filter { $0.hasPrefix("start(") }.count }
    }

    /// A suspension point standing in for the permission / registration wait.
    @MainActor
    private final class GateBox {
        var release: CheckedContinuation<Void, Never>?
    }

    @MainActor
    private final class Recorder {
        var spoken: [String] = []
        var sleeps: [TimeInterval] = []
    }

    private func makeActivator(_ owner: FakeOwner, _ recorder: Recorder) -> LiveSessionActivator {
        LiveSessionActivator(owner: owner,
                             speak: { recorder.spoken.append($0) },
                             sleep: { recorder.sleeps.append($0) })
    }

    private func readyGate() -> @MainActor () async -> BlindAssistantLaunchPolicy.Decision {
        { .start(.init(audioOnly: nil)) }
    }

    // MARK: - Cold launch

    func testColdLaunchStartsExactlyOnce() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)

        let outcome = await activator.activate(
            .init(mode: .geminiLive, source: .launch, gate: readyGate()))

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(owner.calls, ["switch(geminiLive)", "start(geminiLive)"])
    }

    func testNoSleepIsScheduledOnAnOrdinaryStart() async {
        // The 600 ms every entry point used to guess with is gone: the wait is the mode switch
        // itself, awaited.
        let owner = FakeOwner(), recorder = Recorder()
        await makeActivator(owner, recorder).activate(
            .init(mode: .geminiLive, source: .actionButton))
        XCTAssertEqual(recorder.sleeps, [])
    }

    func testAlreadyInTheTargetModeDoesNotSwitch() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.activeMode = .geminiLive
        await makeActivator(owner, recorder).activate(
            .init(mode: .geminiLive, source: .actionButton))
        XCTAssertEqual(owner.calls, ["start(geminiLive)"])
    }

    func testAnAlreadyRunningSessionIsNotStartedAgain() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.activeMode = .geminiLive
        owner.activeSessions = [.geminiLive]
        let outcome = await makeActivator(owner, recorder).activate(
            .init(mode: .geminiLive, source: .actionButton))
        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertEqual(owner.calls, [])
    }

    func testARedialDuringTheSwitchIsNotStartedOverTheTopOf() async {
        // Plan CF's auto-redial can bring the session up as part of the switch. The activator has
        // nothing left to do — and must not start a second one.
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdSwitch = true
        let activator = makeActivator(owner, recorder)
        let task = Task { await activator.activate(.init(mode: .geminiLive, source: .appUI)) }
        while owner.switchGate == nil { await Task.yield() }
        owner.activeSessions = [.geminiLive]
        owner.releaseSwitch()
        let outcome = await task.value
        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertEqual(owner.startCount, 0)
    }

    // MARK: - Coalescing

    func testTwoConcurrentRequestsProduceOneStart() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdSwitch = true
        let activator = makeActivator(owner, recorder)

        let first = Task { await activator.activate(.init(mode: .geminiLive, source: .actionButton)) }
        while owner.switchGate == nil { await Task.yield() }
        let second = Task { await activator.activate(.init(mode: .geminiLive, source: .actionButton)) }
        await Task.yield()
        owner.releaseSwitch()

        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.started, .started], "The second request reports the first's outcome")
        XCTAssertEqual(owner.startCount, 1)
    }

    func testLaunchAndAnIntentTogetherProduceOneStart() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdSwitch = true
        let activator = makeActivator(owner, recorder)

        let launch = Task {
            await activator.activate(.init(mode: .geminiLive, source: .launch, gate: self.readyGate()))
        }
        while owner.switchGate == nil { await Task.yield() }
        let intent = Task { await activator.activate(.init(mode: .geminiLive, source: .actionButton)) }
        await Task.yield()
        owner.releaseSwitch()

        _ = await launch.value
        _ = await intent.value
        XCTAssertEqual(owner.startCount, 1)
        XCTAssertEqual(owner.calls, ["switch(geminiLive)", "start(geminiLive)"])
    }

    func testASecondRequestAfterTheFirstFinishedSeesTheRunningSession() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        await activator.activate(.init(mode: .geminiLive, source: .actionButton))
        let outcome = await activator.activate(.init(mode: .geminiLive, source: .actionButton))
        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertEqual(owner.startCount, 1)
    }

    // MARK: - Stop cancels a pending start

    func testStopDuringThePermissionWaitLeavesNothingRunning() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)

        // The gate is where permissions and the registration wait are read. A stop arriving inside
        // it must cancel the start it was about to authorise.
        let box = GateBox()
        let task = Task {
            await activator.activate(.init(mode: .geminiLive, source: .launch) {
                await withCheckedContinuation { box.release = $0 }
                return .start(.init(audioOnly: nil))
            })
        }
        while box.release == nil { await Task.yield() }
        activator.stop(.geminiLive, source: .appUI)
        box.release?.resume()

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(owner.startCount, 0)
        XCTAssertEqual(owner.calls, ["stop(geminiLive)"], "Nothing started, nothing scheduled")
    }

    func testStopDuringTheSettleWaitLeavesNothingRunning() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdSwitch = true
        let activator = makeActivator(owner, recorder)

        let task = Task { await activator.activate(.init(mode: .geminiLive, source: .launch,
                                                         gate: self.readyGate())) }
        while owner.switchGate == nil { await Task.yield() }
        activator.stop(.geminiLive, source: .appUI)
        owner.releaseSwitch()

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(owner.startCount, 0)
    }

    func testStopWhileTheSessionIsComingUpTearsItBackDown() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdStart = true
        let activator = makeActivator(owner, recorder)

        let task = Task { await activator.activate(.init(mode: .geminiLive, source: .actionButton)) }
        while owner.startGate == nil { await Task.yield() }
        activator.stop(.geminiLive, source: .appUI)
        owner.releaseStart()

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(owner.isSessionActive(.geminiLive),
                       "A stop asked for nothing to be running, so nothing is")
    }

    // MARK: - The stop latch

    func testAForegroundEventAfterAUserStopDoesNotRestart() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        await activator.activate(.init(mode: .geminiLive, source: .launch, gate: readyGate()))
        activator.stop(.geminiLive, source: .appUI)

        // The gate is the app's: it reads the latch the stop just set.
        let outcome = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
            .skip(.stoppedByUser)
        })
        XCTAssertEqual(outcome, .skipped(.stoppedByUser))
        XCTAssertEqual(owner.startCount, 1)
    }

    func testTheLatchSurvivesRepeatedForegroundEvents() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        activator.stop(.geminiLive, source: .appUI)
        XCTAssertTrue(activator.stoppedByUserThisForeground)
        for _ in 0..<3 {
            _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
                activator.stoppedByUserThisForeground ? .skip(.stoppedByUser)
                                                      : .start(.init(audioOnly: nil))
            })
        }
        XCTAssertEqual(owner.startCount, 0)
    }

    func testAnExplicitRequestAfterAStopStarts() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        activator.stop(.geminiLive, source: .appUI)

        let outcome = await activator.activate(.init(mode: .geminiLive, source: .actionButton))
        XCTAssertEqual(outcome, .started)
        XCTAssertFalse(activator.stoppedByUserThisForeground,
                       "The wearer asked again; the latch is theirs to clear")
    }

    func testASessionEndingOnItsOwnDoesNotLatch() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        activator.noteSessionEndedExternally()
        XCTAssertFalse(activator.stoppedByUserThisForeground)
    }

    // MARK: - What the wearer hears

    func testASkipSpeaksItsReasonOnce() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        for _ in 0..<3 {
            _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
                .skip(.microphonePermissionOff)
            })
        }
        XCTAssertEqual(recorder.spoken.count, 1)
        XCTAssertEqual(recorder.spoken.first,
                       BlindAssistantLaunchPolicy.SkipReason.microphonePermissionOff.spokenReason)
    }

    func testADifferentSkipIsStillReported() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
            .skip(.microphonePermissionOff)
        })
        _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
            .skip(.providerNotConfigured(.gemini))
        })
        XCTAssertEqual(recorder.spoken.count, 2)
    }

    func testASilentSkipSaysNothing() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
            .skip(.stoppedByUser)
        })
        XCTAssertEqual(recorder.spoken, [])
    }

    func testAnAudioOnlyStartSaysSoAndStillStarts() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        let outcome = await activator.activate(.init(mode: .geminiLive, source: .launch) {
            .start(.init(audioOnly: .cameraPermissionOff))
        })
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(recorder.spoken,
                       ["Starting the assistant. Camera access is off, so it can hear you but not see."])
    }

    func testAFullStartSaysNothingBeyondTheLifecycleCue() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        _ = await activator.activate(.init(mode: .geminiLive, source: .launch, gate: readyGate()))
        XCTAssertEqual(recorder.spoken, [])
    }

    func testACancellationSaysNothingOfItsOwn() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdSwitch = true
        let activator = makeActivator(owner, recorder)
        let task = Task { await activator.activate(.init(mode: .geminiLive, source: .launch,
                                                         gate: self.readyGate())) }
        while owner.switchGate == nil { await Task.yield() }
        activator.stop(.geminiLive, source: .appUI)
        owner.releaseSwitch()
        _ = await task.value
        XCTAssertEqual(recorder.spoken, [], "The stop is its own feedback")
    }

    func testASkipSpokenBeforeAStartIsSaidAgainAfterTheNextFailure() async {
        let owner = FakeOwner(), recorder = Recorder()
        let activator = makeActivator(owner, recorder)
        _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
            .skip(.microphonePermissionOff)
        })
        _ = await activator.activate(.init(mode: .geminiLive, source: .foreground, gate: readyGate()))
        activator.stop(.geminiLive, source: .appUI)
        _ = await activator.activate(.init(mode: .geminiLive, source: .foreground) {
            .skip(.microphonePermissionOff)
        })
        XCTAssertEqual(recorder.spoken.count, 2, "Something changed in between; it is news again")
    }

    // MARK: - Restart

    func testRestartIfActiveStopsSettlesAndStartsAgain() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.activeMode = .geminiLive
        owner.activeSessions = [.geminiLive]
        let activator = makeActivator(owner, recorder)

        let outcome = await activator.activate(
            .init(mode: .geminiLive, source: .siriShortcut, restartIfActive: true))

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(owner.calls, ["stop(geminiLive)", "start(geminiLive)"])
        XCTAssertEqual(recorder.sleeps, [ModeSwitchPolicy.settleDelay],
                       "The one delay left is the audio handover, and it is the shared number")
    }

    func testARequestForADifferentModeWaitsRatherThanJoining() async {
        let owner = FakeOwner(), recorder = Recorder()
        owner.holdSwitch = true
        let activator = makeActivator(owner, recorder)

        let first = Task { await activator.activate(.init(mode: .geminiLive, source: .actionButton)) }
        while owner.switchGate == nil { await Task.yield() }
        let second = Task { await activator.activate(.init(mode: .openaiRealtime, source: .actionButton)) }
        await Task.yield()
        owner.holdSwitch = false
        owner.releaseSwitch()

        _ = await first.value
        _ = await second.value
        XCTAssertEqual(owner.calls, [
            "switch(geminiLive)", "start(geminiLive)",
            "switch(openaiRealtime)", "start(openaiRealtime)",
        ])
    }
}
