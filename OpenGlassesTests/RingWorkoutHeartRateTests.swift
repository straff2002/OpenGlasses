import XCTest
@testable import OpenGlasses

/// Plan MZ §5 — a workout asks the ring for a live session and ends it; `status` and Live Coach
/// carry the heart rate only when the wearer's Health settings let a number reach the model.
@MainActor
final class RingWorkoutHeartRateTests: XCTestCase {

    private final class FakeSource: WorkoutHeartRateSource {
        var freshHeartRate: Int?
        var samples: [RingHealthSample] = []
        private(set) var begins = 0
        private(set) var ends = 0
        private(set) var samplesAskedBeforeEnd = false
        func beginWorkoutHeartRate() { begins += 1 }
        func endWorkoutHeartRate() { ends += 1 }
        func workoutHeartRateSamples(from start: Date, to end: Date) -> [RingHealthSample] {
            if ends == 0 { samplesAskedBeforeEnd = true }
            return samples
        }
    }

    private static let shared = HealthSummaryDeliveryPolicy.Inputs(
        activeModelIsLocal: false, shareHealthWithAI: true, hipaaMode: false, medicalLocalOnly: false)
    private static let withheld = HealthSummaryDeliveryPolicy.Inputs(
        activeModelIsLocal: false, shareHealthWithAI: false, hipaaMode: false, medicalLocalOnly: false)
    private static let medical = HealthSummaryDeliveryPolicy.Inputs(
        activeModelIsLocal: true, shareHealthWithAI: true, hipaaMode: true, medicalLocalOnly: false)

    private func coach(_ source: FakeSource, delivery: HealthSummaryDeliveryPolicy.Inputs) -> FitnessCoachingTool {
        var tool = FitnessCoachingTool()
        tool.heartRateSource = { source }
        tool.deliveryInputs = { delivery }
        tool.workoutSaver = { _, _, _, _ in false }
        tool.noteSaver = { _ in }
        return tool
    }

    override func setUp() async throws {
        // A workout another test left running would make this one's start a no-op.
        _ = try await coach(FakeSource(), delivery: Self.shared).execute(args: ["action": "stop_workout"])
    }

    func testAWorkoutAsksForTheHeartRateAndLetsItGo() async throws {
        let source = FakeSource()
        let tool = coach(source, delivery: Self.shared)
        let started = try await tool.execute(args: ["action": "start_workout", "workout_type": "running"])
        XCTAssertTrue(started.hasPrefix("Started a running workout"))
        XCTAssertEqual(source.begins, 1)
        XCTAssertEqual(source.ends, 0)

        source.freshHeartRate = 142
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(status.hasPrefix("A running workout is running"), status)
        XCTAssertTrue(status.contains("Heart rate now: 142 beats per minute"), status)

        _ = try await tool.execute(args: ["action": "stop_workout"])
        XCTAssertEqual(source.ends, 1)
    }

    func testTheSavedWorkoutCarriesTheRingsHeartRate() async throws {
        let source = FakeSource()
        let start = Date(timeIntervalSince1970: 1_000)
        source.samples = [RingHealthSample(start: start, end: start, value: .heartRate(beatsPerMinute: 130),
                                           syncIdentifier: "ring.p.heartRate.1000", syncVersion: 2)]
        var tool = coach(source, delivery: Self.shared)
        var handed: [RingHealthSample]?
        tool.workoutSaver = { _, _, _, heartRates in handed = heartRates; return true }
        _ = try await tool.execute(args: ["action": "start_workout"])
        let summary = try await tool.execute(args: ["action": "stop_workout"])
        XCTAssertTrue(summary.contains("Saved to Apple Health."), summary)
        XCTAssertEqual(handed, source.samples)
        XCTAssertTrue(source.samplesAskedBeforeEnd, "read before the session is let go")
        XCTAssertEqual(source.ends, 1)
    }

    func testTheWorkoutsHeartRateReplacesTheStandaloneSamplesWithinItsInterval() {
        let pairing = RingPairingID(rawValue: "p")
        let start = Date(timeIntervalSince1970: 10_000)
        let readings: [RingReading] = [
            .heartRate(bpm: 90, at: start.addingTimeInterval(-60)),    // before the workout
            .heartRate(bpm: 120, at: start.addingTimeInterval(10)),
            .heartRate(bpm: 121, at: start.addingTimeInterval(12)),    // thinned: within 5 s
            .heartRate(bpm: 250, at: start.addingTimeInterval(30)),    // implausible
            .heartRate(bpm: 140, at: start.addingTimeInterval(60)),
            .oxygen(percent: 97, at: start.addingTimeInterval(70)),
            .heartRate(bpm: 100, at: start.addingTimeInterval(700)),   // after the workout
        ]
        let samples = RingHealthWriter.workoutHeartRateSamples(readings, pairingID: pairing, from: start,
                                                               to: start.addingTimeInterval(600))
        XCTAssertEqual(samples.map(\.value), [.heartRate(beatsPerMinute: 120), .heartRate(beatsPerMinute: 140)])
        let standalone = RingHealthWriter.batch(for: readings, pairingID: pairing, cursor: RingSyncCursor(),
                                                stepBaseline: nil, calendar: .current).samples
        for sample in samples {
            let original = standalone.first { $0.syncIdentifier == sample.syncIdentifier }
            XCTAssertNotNil(original, "same sync identifier as the standalone write")
            XCTAssertEqual(sample.syncVersion, (original?.syncVersion ?? 0) + 1, "one version higher, so it replaces it")
        }
    }

    func testStatusLeavesOutTheNumberWhenItMayNotReachTheModel() async throws {
        let source = FakeSource()
        source.freshHeartRate = 150
        for delivery in [Self.withheld, Self.medical] {
            let tool = coach(source, delivery: delivery)
            _ = try await tool.execute(args: ["action": "start_workout"])
            let status = try await tool.execute(args: ["action": "status"])
            XCTAssertFalse(status.contains("150"), status)
            _ = try await tool.execute(args: ["action": "stop_workout"])
        }
    }

    func testStatusWithoutAFreshReadingOrAWorkout() async throws {
        let source = FakeSource()
        let tool = coach(source, delivery: Self.shared)
        let idle = try await tool.execute(args: ["action": "status"])
        XCTAssertEqual(idle, "No workout is running.")
        _ = try await tool.execute(args: ["action": "start_workout"])
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertFalse(status.contains("Heart rate"))
        _ = try await tool.execute(args: ["action": "stop_workout"])
    }

    func testLiveCoachAddsOneLineOnlyWhenTheNumberMayReachTheModel() {
        XCTAssertEqual(LiveCoachService.heartRateContextLine(bpm: 118, delivery: .returnToModel),
                       "Heart rate now: 118 beats per minute (from the wearer's ring, an estimate).")
        XCTAssertNil(LiveCoachService.heartRateContextLine(bpm: 118, delivery: .speakDirect))
        XCTAssertNil(LiveCoachService.heartRateContextLine(bpm: nil, delivery: .returnToModel))
        XCTAssertEqual(HealthSummaryDeliveryPolicy.decide(Self.medical), .speakDirect)
    }
}
