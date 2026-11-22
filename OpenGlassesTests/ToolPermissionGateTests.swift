import XCTest
import HealthKit
@testable import OpenGlasses

/// The Settings permission prompt for a tool asks for what the tool actually uses. The fitness
/// coach once asked for step count and active energy while the tool read workouts and saved
/// workouts and energy; the sets now live on the tool and the gate reads them.
final class ToolPermissionGateTests: XCTestCase {

    func testFitnessCoachReadsWorkoutsAndActiveEnergy() {
        let expected: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        ]
        XCTAssertEqual(FitnessCoachingTool.healthKitReadTypes, expected)
    }

    func testFitnessCoachSharesWorkoutsAndActiveEnergy() {
        let expected: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        ]
        XCTAssertEqual(FitnessCoachingTool.healthKitShareTypes, expected)
    }

    /// The gate's source names the tool's sets rather than its own list, so the prompt and
    /// the tool cannot drift apart again.
    func testGateAsksForTheToolsOwnTypes() throws {
        let source = try gateSource()
        let fitnessCase = try XCTUnwrap(source.range(of: "case \"fitness_coach\":"))
        let nextCase = source.range(of: "case \"health_summary\":", range: fitnessCase.upperBound..<source.endIndex)
        let body = String(source[fitnessCase.upperBound..<(nextCase?.lowerBound ?? source.endIndex)])
        XCTAssertTrue(body.contains("FitnessCoachingTool.healthKitShareTypes"), "the gate must share what the tool shares")
        XCTAssertTrue(body.contains("FitnessCoachingTool.healthKitReadTypes"), "the gate must read what the tool reads")
        XCTAssertFalse(body.contains("stepCount"), "the fitness coach never reads step count from HealthKit")
    }

    /// Plan MZ: the ring writes heart rate, oxygen, sleep and steps, and the permission it asks for
    /// at pairing is exactly that set, from the writer itself.
    func testTheRingSharesWhatItsWriterWrites() {
        let expected: Set<HKSampleType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.oxygenSaturation),
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.stepCount),
        ]
        XCTAssertEqual(RingHealthWriter.shareTypes, expected)
    }

    func testTheGateAsksForTheRingWritersOwnTypes() throws {
        let source = try gateSource()
        let ringCase = try XCTUnwrap(source.range(of: "case \"ring\":"))
        let end = source.range(of: "default:", range: ringCase.upperBound..<source.endIndex)
        let body = String(source[ringCase.upperBound..<(end?.lowerBound ?? source.endIndex)])
        XCTAssertTrue(body.contains("toShare: RingHealthWriter.shareTypes"), "the gate must share what the ring writes")
        XCTAssertTrue(body.contains("read: []"), "the ring adds no read types")
    }

    func testFitnessCoachIsAPermissionTool() {
        XCTAssertEqual(ToolPermissionGate.permissionName(for: "fitness_coach"), "HealthKit access")
    }

    private func gateSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenGlassesTests
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("OpenGlasses/Sources/App/Views/ToolPermissionGate.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
