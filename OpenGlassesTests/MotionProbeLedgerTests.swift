import XCTest
@testable import OpenGlasses

/// Plan NB §5 — what the Motion probe keeps for the support report, in every build: aggregates per
/// prompt, never a sample. Only a flagged build has the probe that fills it. Every sample here is
/// invented.
@MainActor
final class MotionProbeLedgerTests: XCTestCase {

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private let ms: Int64 = 1_000_000

    private func twist(_ t: Int64, _ degrees: Double) -> WristSample {
        WristSample(timestampNs: t * ms, orientation: WristQuaternion(axis: .forearm, angle: WristTwist.radians(degrees)),
                    gyroscope: WristVector(x: 0, y: 0, z: 0))
    }

    func testEmptyUntilARunBegins() {
        let ledger = MotionProbeLedger()
        XCTAssertEqual(ledger.reportLines, [])
        ledger.recordBandSample(twist(0, 0))
        ledger.recordInput(GlassesInput(kind: .select, origin: .neuralBand))
        XCTAssertEqual(ledger.reportLines, [], "nothing is kept outside a run")
    }

    func testAPromptsAggregates() throws {
        let clock = Clock()
        let ledger = MotionProbeLedger(now: { clock.now })
        ledger.begin()
        ledger.beginPrompt(.twistClockwise, volume: 0.5)
        clock.now += 1.2
        ledger.recordInput(GlassesInput(kind: .drag(.down), origin: .neuralBandDrag))
        ledger.recordInput(GlassesInput(kind: .drag(.move), origin: .neuralBandDrag))
        // 31 band samples at 30 Hz turning to +60°, one without an orientation.
        for i in 0...30 {
            let t = Int64(i) * 1000 / 30
            if i == 15 {
                ledger.recordBandSample(WristSample(timestampNs: t * ms, orientation: nil,
                                                    gyroscope: WristVector(x: 0, y: 0, z: 0)))
            } else {
                ledger.recordBandSample(twist(t, Double(i) * 2))
            }
            ledger.recordOtherSample(.glasses)
        }
        ledger.recordOtherSample(.unknown)
        clock.now += 1.0
        ledger.recordInput(GlassesInput(kind: .select, origin: .neuralBand))
        ledger.endPrompt(volume: 0.5625)

        let record = try XCTUnwrap(ledger.runs.last?.prompts.first)
        XCTAssertEqual(record.samples[.neuralBand], 31)
        XCTAssertEqual(record.samples[.glasses], 31)
        XCTAssertEqual(record.samples[.unknown], 1)
        XCTAssertEqual(record.withOrientation, 30)
        XCTAssertEqual(record.withGyroscope, 31)
        XCTAssertEqual(record.bandRate ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(record.dragDowns, [1200])
        XCTAssertEqual(record.selects, [2200])
        XCTAssertEqual(record.otherInputs, 1, "the drag move")
        XCTAssertGreaterThan(record.twistNetDegrees, 40, "clockwise as the constant reads it: a positive twist")
        XCTAssertEqual(record.twistPeakDegrees, record.twistNetDegrees, accuracy: 1e-9)
        XCTAssertEqual(record.volumeChanged, true, "Meta took the twist for the volume")

        ledger.end(.finished)
        let lines = ledger.reportLines
        XCTAssertEqual(lines.first, "Glasses motion probe: 1 run since launch (30 Hz; band samples followed, others counted)")
        let line = try XCTUnwrap(lines.first { $0.contains("twistClockwise") })
        XCTAssertTrue(line.contains("samples glasses 31, neuralBand 31, unknown 1"), line)
        XCTAssertTrue(line.contains("30.0 Hz"), line)
        XCTAssertTrue(line.contains("band with orientation 30, gyroscope 31"), line)
        XCTAssertTrue(line.contains("drag down at +1200 ms · select at +2200 ms"), line)
        XCTAssertTrue(line.contains("volume changed"), line)
        XCTAssertTrue(lines.last?.contains("stopped (finished)") ?? false)
    }

    func testThePeakKeepsItsSignAndTheNetComesBack() throws {
        let ledger = MotionProbeLedger()
        ledger.begin()
        ledger.beginPrompt(.twistAnticlockwise, volume: nil)
        let path: [Double] = [0, 0, 0, 0, 0, 0, -10, -30, -45, -20, -5]
        for (i, d) in path.enumerated() { ledger.recordBandSample(twist(Int64(i) * 40, d)) }
        ledger.endPrompt(volume: nil)
        let record = try XCTUnwrap(ledger.runs.last?.prompts.first)
        XCTAssertEqual(record.twistPeakDegrees, -45, accuracy: 1e-6)
        XCTAssertEqual(record.twistNetDegrees, -5, accuracy: 1e-6)
        XCTAssertNil(record.volumeChanged, "no reading: not known")
        XCTAssertTrue(MotionProbeLedger.describe(record).contains("twist net -5°, peak -45°"))
        XCTAssertTrue(MotionProbeLedger.describe(record).contains("volume not known"))
    }

    func testEachPromptIsItsOwnWindowAndSamplesAfterTheEndAreNotKept() throws {
        let ledger = MotionProbeLedger()
        ledger.begin()
        ledger.beginPrompt(.hold, volume: 0.4)
        ledger.recordBandSample(twist(0, 0))
        ledger.beginPrompt(.twistClockwise, volume: 0.4)
        ledger.recordBandSample(twist(10, 0))
        ledger.recordBandSample(twist(20, 0))
        ledger.endPrompt(volume: 0.4)
        ledger.recordBandSample(twist(30, 0))
        let prompts = try XCTUnwrap(ledger.runs.last?.prompts)
        XCTAssertEqual(prompts.map(\.prompt), [.hold, .twistClockwise])
        XCTAssertEqual(prompts.map(\.bandSamples), [1, 2])
        XCTAssertEqual(prompts[0].volumeChanged, false, "the next prompt closes the last at its volume")
        XCTAssertEqual(prompts[1].volumeChanged, false)
    }

    func testTimesAreCappedAndRunsRollOver() throws {
        let ledger = MotionProbeLedger()
        for _ in 0..<5 {
            ledger.begin()
            ledger.beginPrompt(.hold, volume: nil)
            for _ in 0..<(MotionProbeLedger.timeCapacity + 4) {
                ledger.recordInput(GlassesInput(kind: .select, origin: .neuralBand))
            }
            ledger.end(.wearerStopped)
        }
        XCTAssertEqual(ledger.runs.count, MotionProbeLedger.runCapacity)
        let record = try XCTUnwrap(ledger.runs.last?.prompts.first)
        XCTAssertEqual(record.selects.count, MotionProbeLedger.timeCapacity)
        XCTAssertEqual(record.otherInputs, 4)
        XCTAssertEqual(ledger.reportLines.first, "Glasses motion probe: 5 runs since launch (30 Hz; band samples followed, others counted)")
        XCTAssertTrue(ledger.reportLines.contains { $0.hasPrefix("  run 3 ·") }, "numbered from the first kept")
        XCTAssertFalse(ledger.reportLines.contains { $0.hasPrefix("  run 2 ·") })
    }

    func testRefusalsAndThePolicy() {
        typealias Policy = MotionProbePolicy
        XCTAssertEqual(Policy.refusal(verdict: .notInThisBuild, connected: true, running: false, otherProbeRunning: false),
                       .notInThisBuild)
        XCTAssertEqual(Policy.refusal(verdict: .heldOnThisChannel, connected: true, running: false, otherProbeRunning: false),
                       .heldOnThisChannel)
        XCTAssertEqual(Policy.refusal(verdict: .runs, connected: true, running: true, otherProbeRunning: true),
                       .alreadyRunning)
        XCTAssertEqual(Policy.refusal(verdict: .runs, connected: true, running: false, otherProbeRunning: true),
                       .otherProbeRunning, "the Inputs probe holds the one Inputs capability")
        XCTAssertEqual(Policy.refusal(verdict: .runs, connected: false, running: false, otherProbeRunning: false),
                       .notConnected)
        XCTAssertNil(Policy.refusal(verdict: .switchedOff, connected: true, running: false, otherProbeRunning: false),
                     "the press is the switch")
        XCTAssertEqual(Policy.runLength, .seconds(60), "four prompts make the minute")
        XCTAssertEqual(MotionProbePrompt.allCases, [.hold, .twistClockwise, .twistAnticlockwise, .moveArmLeft])
        let ledger = MotionProbeLedger()
        ledger.refused(.notConnected)
        XCTAssertEqual(ledger.lastRefusal, .notConnected)
        XCTAssertEqual(ledger.reportLines, [], "a refusal alone puts nothing in the report")
    }

    func testStatesAndErrorsAreKeptByCaseName() {
        let ledger = MotionProbeLedger()
        ledger.begin()
        ledger.recordState(.starting)
        ledger.recordState(.started)
        ledger.recordError(MotionChannelFailure.sensorUnavailable.rawValue)
        ledger.end(.capabilityFailed)
        let lines = ledger.reportLines
        XCTAssertTrue(lines.contains { $0.hasSuffix("state started") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("error sensorUnavailable") })
        XCTAssertTrue(lines.contains { $0.contains("no prompt began") })
        XCTAssertTrue(lines.contains { $0.contains("stopped (capabilityFailed)") })
    }

    func testTheMotionCapabilityHoldsTheSharedSessionLikeAnyOther() {
        XCTAssertTrue(DeviceSessionOwnership.Capability.allCases.contains(.motion))
        var ownership = DeviceSessionOwnership()
        XCTAssertTrue(ownership.acquire(.inputs))
        XCTAssertFalse(ownership.acquire(.motion), "joins the session Inputs holds")
        XCTAssertTrue(ownership.isShared)
        XCTAssertFalse(ownership.release(.motion))
        XCTAssertTrue(ownership.release(.inputs), "the last holder out")
    }
}
