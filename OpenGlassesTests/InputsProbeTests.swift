#if DAT_EXPERIMENTAL
import XCTest
@testable import OpenGlasses

/// The Inputs probe end to end, with a fake channel behind `InputsSource` (Plan JV P2). Compiled
/// only in a flagged project: the ordinary suite has no experimental code to test. Never touches
/// `Wearables.shared`.
@MainActor
final class InputsProbeTests: XCTestCase {

    // MARK: - Fakes

    @MainActor
    private final class FakeChannel: InputsChannel {
        let handlers: InputsChannelHandlers
        var stopCount = 0
        var state: InputsProbeState
        init(handlers: InputsChannelHandlers, state: InputsProbeState) {
            self.handlers = handlers
            self.state = state
        }
        func stop() { stopCount += 1 }
    }

    @MainActor
    private final class FakeSource: InputsSource {
        var opened: [(deviceId: String, channel: FakeChannel)] = []
        var failure: InputsProbeFailure?
        /// When set, `open` waits on it, so a test can stop the probe mid-start.
        var holds = false
        var hold: CheckedContinuation<Void, Never>?
        /// The state the capability is in when `open` returns. Adding only begins activation.
        var stateAtOpen: InputsProbeState = .activating

        func open(deviceId: String, handlers: InputsChannelHandlers) async throws -> InputsChannel {
            if holds { await withCheckedContinuation { hold = $0 } }
            if let failure { throw failure }
            let channel = FakeChannel(handlers: handlers, state: stateAtOpen)
            opened.append((deviceId, channel))
            return channel
        }

        var last: FakeChannel? { opened.last?.channel }
    }

    private lazy var source = FakeSource()
    private lazy var ledger = InputsProbeLedger()
    private var verdict: DATExperimentalPolicy.Verdict = .runs
    private var battery: Int? = 80
    private var audio = false

    private func probe(timeLimit: Duration = InputsProbePolicy.timeLimit) -> InputsProbe {
        InputsProbe(source: source, ledger: ledger, timeLimit: timeLimit,
                    verdict: { [unowned self] in self.verdict },
                    battery: { [unowned self] in self.battery },
                    userAudioPlaying: { [unowned self] in self.audio })
    }

    private var stop: InputsProbeLedger.Stop? { ledger.runs.last?.stop }

    // MARK: - The configuration

    func testTheSDKConfigurationIsTheTouchpadAndBandWithBackLeftToMeta() {
        XCTAssertEqual(InputsProbeConfiguration.origins, [.captouch, .neuralBand, .neuralBandDrag])
        XCTAssertEqual(InputsProbeConfiguration.origins, InputsProbePolicy.origins)
        XCTAssertFalse(InputsProbeConfiguration.consumesBack)
        XCTAssertEqual(InputsProbeConfiguration.consumesBack, InputsProbePolicy.consumesBack)
    }

    // MARK: - Starting

    func testStartWithoutALinkIsRefusedAndOpensNothing() async {
        let probe = probe()
        let refusal = await probe.start()
        XCTAssertEqual(refusal, .notConnected)
        XCTAssertEqual(ledger.lastRefusal, .notConnected)
        XCTAssertTrue(source.opened.isEmpty)
        XCTAssertTrue(ledger.runs.isEmpty)
        XCTAssertFalse(probe.isRunning)
    }

    func testStartIsRefusedWhereTheLaneMayNotRun() async {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        verdict = .heldOnThisChannel
        let refusal = await probe.start()
        XCTAssertEqual(refusal, .heldOnThisChannel)
        XCTAssertTrue(source.opened.isEmpty)
    }

    func testOneRunAtATimeOnTheConnectedDevice() async {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        let first = await probe.start()
        XCTAssertNil(first)
        XCTAssertEqual(probe.phase, .starting)
        try? XCTUnwrap(source.last).handlers.onState(.active)
        XCTAssertEqual(probe.phase, .running)
        XCTAssertEqual(source.opened.map(\.deviceId), ["g1"])
        XCTAssertEqual(ledger.current?.batteryAtStart, 80)
        let second = await probe.start()
        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(source.opened.count, 1)
        probe.stop()
    }

    func testAFailedAddIsRecordedAndEndsTheRun() async {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        source.failure = .capabilityNotAdded
        _ = await probe.start()
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(stop?.reason, .failed)
        XCTAssertTrue(ledger.runs.last?.entries.contains {
            if case .error(.capabilityNotAdded, _) = $0 { return true }
            return false
        } == true)
    }

    // MARK: - Recording

    func testEveryInputStateAndErrorIsRecordedWithTheWearersAudio() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        channel.handlers.onState(.active)
        channel.handlers.onInput(GlassesInput(kind: .select, origin: .captouch))
        audio = true
        channel.handlers.onInput(GlassesInput(kind: .nav(.right), origin: .captouch))
        channel.handlers.onFailure(.communicationError)
        let run = try XCTUnwrap(ledger.runs.last)
        XCTAssertEqual(run.inputCount, 2)
        let kinds: [String] = run.entries.map {
            switch $0 {
            case .input(let input, _, let playing): return "\(input.kind.reportToken)\(playing ? "+audio" : "")"
            case .moves(_, let count, _, _, _): return "drag-move×\(count)"
            case .state(let state, _): return "state-\(state.rawValue)"
            case .error(let failure, _): return "error-\(failure.rawValue)"
            }
        }
        XCTAssertEqual(kinds, ["state-active", "select", "nav-right+audio", "error-communicationError"])
        probe.stop()
    }

    // MARK: - Activation

    func testTheRunIsRunningOnlyOnceTheCapabilityIsActive() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        XCTAssertEqual(probe.phase, .starting, "adding Inputs only begins activation")
        XCTAssertTrue(probe.isRunning)
        channel.handlers.onState(.activating)
        XCTAssertEqual(probe.phase, .starting)
        channel.handlers.onState(.active)
        XCTAssertEqual(probe.phase, .running)
        probe.stop()
    }

    func testACapabilityAlreadyActiveWhenOpenedIsRunningAtOnce() async {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        source.stateAtOpen = .active
        _ = await probe.start()
        XCTAssertEqual(probe.phase, .running, "the state publisher does not replay an early .active")
        probe.stop()
    }

    func testAnActivationTimeoutRemovesTheCapability() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        channel.handlers.onState(.activating)
        channel.handlers.onFailure(.activationTimeout)
        XCTAssertEqual(channel.stopCount, 1, "a failed capability stays attached until it is removed")
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(stop?.reason, .capabilityFailed)
        channel.handlers.onState(.inactive)
        XCTAssertEqual(ledger.runs.last?.entries.count, 2, "the old run hears nothing after it stopped")
    }

    // MARK: - Stopping

    func testTheWearersStopRemovesTheCapabilityAndRecordsTheBattery() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        battery = 77
        probe.stop()
        XCTAssertEqual(channel.stopCount, 1)
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(stop?.reason, .wearerStopped)
        XCTAssertEqual(stop?.battery, 77)
        probe.stop()
        XCTAssertEqual(channel.stopCount, 1, "a second Stop does nothing")
    }

    func testALinkDropStopsTheRun() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1", "g2"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        probe.update(connectedDeviceIds: ["g1", "g2"])
        XCTAssertTrue(probe.isRunning, "the same link is not a drop")
        battery = nil
        probe.update(connectedDeviceIds: ["g2"])
        XCTAssertEqual(channel.stopCount, 1)
        XCTAssertEqual(stop?.reason, .linkDown)
        XCTAssertNil(stop?.battery, "no reading once the link is down")
    }

    func testTheSessionEndingStopsTheRun() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        channel.handlers.onEnded()
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(stop?.reason, .sessionEnded)
    }

    func testTheEventStreamFinishingStopsTheRun() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        channel.handlers.onState(.active)
        channel.handlers.onInputsEnded()
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(stop?.reason, .inputsEnded)
        XCTAssertEqual(channel.stopCount, 1)
    }

    func testTheRunStopsItselfAtTheTimeLimit() async throws {
        let probe = probe(timeLimit: .milliseconds(50))
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let channel = try XCTUnwrap(source.last)
        let deadline = Date().addingTimeInterval(5)
        while probe.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(stop?.reason, .timeLimit)
        XCTAssertEqual(channel.stopCount, 1)
    }

    func testAStopWhileStartingClosesTheChannelThatArrivesLate() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        source.holds = true
        let starting = Task { await probe.start() }
        while source.hold == nil { await Task.yield() }
        XCTAssertEqual(probe.phase, .starting)
        probe.stop()
        XCTAssertEqual(stop?.reason, .wearerStopped)
        source.hold?.resume()
        _ = await starting.value
        let channel = try XCTUnwrap(source.last)
        XCTAssertEqual(channel.stopCount, 1, "the late channel is closed at once")
        XCTAssertFalse(probe.isRunning)
    }

    func testCallbacksFromAnEndedRunAreIgnored() async throws {
        let probe = probe()
        probe.update(connectedDeviceIds: ["g1"])
        _ = await probe.start()
        let old = try XCTUnwrap(source.last)
        probe.stop()
        _ = await probe.start()
        old.handlers.onInput(GlassesInput(kind: .back, origin: .captouch))
        old.handlers.onFailure(.communicationError)
        old.handlers.onInputsEnded()
        old.handlers.onEnded()
        XCTAssertTrue(probe.isRunning)
        XCTAssertEqual(ledger.current?.inputCount, 0)
        probe.stop()
    }
}
#endif
