#if DAT_EXPERIMENTAL
import XCTest
@testable import OpenGlasses

/// The Motion probe end to end (Plan NB §5), with fake channels behind `WristMotionSource` and
/// `InputsSource`. Compiled only in a flagged project. Never touches `Wearables.shared`.
@MainActor
final class MotionProbeTests: XCTestCase {

    private typealias MotionFake = LensWristGestureServiceTests.FakeMotionSource

    @MainActor
    private final class FakeInputsChannel: InputsChannel {
        let handlers: InputsChannelHandlers
        var stopCount = 0
        var state: InputsProbeState = .active
        init(handlers: InputsChannelHandlers) { self.handlers = handlers }
        func stop() { stopCount += 1 }
    }

    @MainActor
    private final class FakeInputsSource: InputsSource {
        var opened: [FakeInputsChannel] = []
        var failure: InputsProbeFailure?
        func open(deviceId: String, handlers: InputsChannelHandlers) async throws -> InputsChannel {
            if let failure { throw failure }
            let channel = FakeInputsChannel(handlers: handlers)
            opened.append(channel)
            return channel
        }
    }

    private lazy var motion = MotionFake()
    private lazy var inputs = FakeInputsSource()
    private lazy var ledger = MotionProbeLedger()
    private var verdict: DATExperimentalPolicy.Verdict = .runs
    private var otherRunning = false
    private var volume: Float = 0.5

    private func probe(window: Duration = .milliseconds(30)) -> MotionProbe {
        MotionProbe(motionSource: motion, inputsSource: inputs, ledger: ledger, promptWindow: window,
                    verdict: { [unowned self] in self.verdict },
                    otherProbeRunning: { [unowned self] in self.otherRunning },
                    outputVolume: { [unowned self] in self.volume })
    }

    private let ms: Int64 = 1_000_000

    func testStartIsRefusedWithoutALinkOrWhileTheInputsProbeRuns() async {
        let probe = probe()
        var refusal = await probe.start()
        XCTAssertEqual(refusal, .notConnected)
        probe.update(connectedDeviceIds: ["pair-1"])
        otherRunning = true
        refusal = await probe.start()
        XCTAssertEqual(refusal, .otherProbeRunning)
        verdict = .heldOnThisChannel
        refusal = await probe.start()
        XCTAssertEqual(refusal, .heldOnThisChannel)
        XCTAssertTrue(motion.opened.isEmpty)
        XCTAssertTrue(inputs.opened.isEmpty)
        XCTAssertTrue(ledger.runs.isEmpty)
    }

    func testARunWalksTheFourPromptsAndRecordsEach() async throws {
        let probe = probe(window: .milliseconds(200))
        probe.update(connectedDeviceIds: ["pair-1"])
        let refusal = await probe.start()
        XCTAssertNil(refusal)
        XCTAssertEqual(probe.phase, .running)
        let channel = try XCTUnwrap(motion.last)
        let band = try XCTUnwrap(inputs.opened.last)
        for _ in 0..<20 where probe.prompt == nil { await Task.yield() }
        XCTAssertEqual(probe.prompt, .hold)
        band.handlers.onInput(GlassesInput(kind: .drag(.down), origin: .neuralBandDrag))
        for i in 0..<10 {
            channel.handlers.onSample(WristSample(timestampNs: Int64(i) * 33 * ms, orientation: .identity, gyroscope: nil))
            channel.handlers.onOtherSample(.glasses)
        }
        band.handlers.onInput(GlassesInput(kind: .select, origin: .neuralBand))
        volume = 0.6
        // Let the four windows run out.
        while probe.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        let run = try XCTUnwrap(ledger.runs.last)
        XCTAssertEqual(run.prompts.map(\.prompt), MotionProbePrompt.allCases)
        XCTAssertEqual(run.prompts[0].bandSamples, 10)
        XCTAssertEqual(run.prompts[0].samples[.glasses], 10)
        XCTAssertEqual(run.prompts[0].dragDowns.count, 1)
        XCTAssertEqual(run.prompts[0].selects.count, 1)
        XCTAssertEqual(run.prompts[0].volumeChanged, true)
        XCTAssertEqual(run.stop?.reason, .finished)
        XCTAssertEqual(channel.stopCount, 1, "Motion removed at the end")
        XCTAssertEqual(band.stopCount, 1, "Inputs removed at the end")
        XCTAssertNil(probe.prompt)
    }

    func testAMotionFailureEndsTheRunBeforeInputsIsAdded() async {
        motion.failure = .capabilityNotAdded
        let probe = probe()
        probe.update(connectedDeviceIds: ["pair-1"])
        await probe.start()
        XCTAssertFalse(probe.isRunning)
        XCTAssertTrue(inputs.opened.isEmpty)
        XCTAssertEqual(ledger.runs.last?.stop?.reason, .failed)
        XCTAssertTrue(ledger.reportLines.contains { $0.hasSuffix("error capabilityNotAdded") })
    }

    func testAnInputsFailureIsKeptAndTheMotionHalfRuns() async throws {
        inputs.failure = .capabilityUnavailable
        let probe = probe(window: .seconds(5))
        probe.update(connectedDeviceIds: ["pair-1"])
        await probe.start()
        XCTAssertTrue(probe.isRunning)
        XCTAssertTrue(ledger.reportLines.contains { $0.hasSuffix("error inputs-capabilityUnavailable") })
        probe.stop()
        XCTAssertEqual(try XCTUnwrap(motion.last).stopCount, 1)
        XCTAssertEqual(ledger.runs.last?.stop?.reason, .wearerStopped)
    }

    func testTheLinkDroppingOrAnErrorStopsIt() async throws {
        let probe = probe(window: .seconds(5))
        probe.update(connectedDeviceIds: ["pair-1"])
        await probe.start()
        probe.update(connectedDeviceIds: [])
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(ledger.runs.last?.stop?.reason, .linkDown)

        probe.update(connectedDeviceIds: ["pair-1"])
        await probe.start()
        let channel = try XCTUnwrap(motion.last)
        channel.handlers.onFailure(.sensorUnavailable)
        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(ledger.runs.last?.stop?.reason, .capabilityFailed)
        XCTAssertEqual(channel.stopCount, 1)
        channel.handlers.onSample(WristSample(timestampNs: 0))
        XCTAssertEqual(ledger.runs.last?.prompts.reduce(0) { $0 + $1.bandSamples }, 0, "a stopped run's late sample is ignored")
    }
}
#endif
