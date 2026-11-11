import XCTest
@testable import OpenGlasses

/// Instant Replay P0 — when the buffer may exist, and what it costs on disk.
final class InstantReplayPolicyTests: XCTestCase {

    private let plan = ReplayBufferPlan(bufferSeconds: 60, width: 720, height: 1280, frameRate: 15)

    private func conditions(setting: Bool = true, org: Bool = false, streaming: Bool = true,
                            hipaa: Bool = false, posture: PowerPosture = .normal,
                            free: Int64? = 50_000_000_000) -> ReplayBufferPolicy.Conditions {
        .init(settingOn: setting, orgPinnedOff: org, glassesStreaming: streaming,
              medicalCompliance: hipaa, posture: posture, freeBytes: free, plan: plan)
    }

    // MARK: - Every condition

    func testRunsOnlyWhenEveryConditionHolds() {
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions()), .run(plan))
    }

    func testOffByTheSettingAndByAnOrganisationPin() {
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(setting: false)), .off(.settingOff))
        // A pin reads the setting as off; the reason is the organisation, not the switch.
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(setting: false, org: true)), .off(.organisationOff))
    }

    func testNeverWithoutAStreamTheWearerStarted() {
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(streaming: false)), .off(.cameraOff))
    }

    func testOffInMedicalComplianceWhateverElseHolds() {
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(hipaa: true)), .off(.medicalCompliance))
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(streaming: false, hipaa: true)),
                       .off(.medicalCompliance))
    }

    func testARaisedPowerPostureStopsTheBuffer() {
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(posture: .conserve)), .off(.power))
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(posture: .reserve)), .off(.power))
    }

    func testStorageMustLeaveTwiceTheBufferAndTheRecordersLowStorageLine() {
        let line = 2 * plan.bufferBytes + ReplayBufferPolicy.storageFloorBytes
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(free: line - 1)), .off(.lowStorage))
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(free: line)), .run(plan))
        // A phone that cannot say how much it has is not one that is out of it.
        XCTAssertEqual(ReplayBufferPolicy.decide(conditions(free: nil)), .run(plan))
    }

    @MainActor
    func testTheStorageFloorIsTheRecordersOwnLowStorageLine() {
        XCTAssertEqual(ReplayBufferPolicy.storageFloorBytes, VideoRecordingService.lowStorageBytes)
    }

    func testEveryOffReasonSaysSomethingTheWearerCanRead() {
        for reason in ReplayOffReason.allCases {
            XCTAssertTrue(reason.spoken.hasPrefix("Instant Replay isn't running: "), reason.rawValue)
            XCTAssertFalse(reason.statusLine.isEmpty)
        }
        XCTAssertEqual(ReplayOffReason.cameraOff.spoken, "Instant Replay isn't running: the camera's off.")
        XCTAssertEqual(ReplayOffReason.medicalCompliance.spoken,
                       "Instant Replay isn't running: it's off in Medical Compliance mode.")
    }

    // MARK: - The plan's sizes

    func testSizesForEachTierAtFifteenFramesASecond() {
        let high = ReplayBufferPlan(bufferSeconds: 60, width: 720, height: 1280, frameRate: 15)
        let medium = ReplayBufferPlan(bufferSeconds: 60, width: 504, height: 896, frameRate: 15)
        let low = ReplayBufferPlan(bufferSeconds: 60, width: 360, height: 640, frameRate: 15)
        XCTAssertEqual(high.bitrate, 5_700_000)
        XCTAssertEqual(medium.bitrate, 2_800_000)
        XCTAssertEqual(low.bitrate, 1_400_000)
        // 60 s plus one 2 s segment of overhead.
        XCTAssertEqual(high.bufferBytes, 44_175_000)
        XCTAssertEqual(medium.bufferBytes, 21_700_000)
        XCTAssertEqual(low.bufferBytes, 10_850_000)
        XCTAssertEqual(high.bytes(forSeconds: 30), 21_375_000)
        XCTAssertEqual(high.footerSizeLine, "Keeps up to about 44 MB on the phone while the camera is on.")
        XCTAssertEqual(low.footerSizeLine, "Keeps up to about 11 MB on the phone while the camera is on.")
    }

    func testSizesAtThirtyFramesASecondScaleBySquareRoot() {
        let high30 = ReplayBufferPlan(bufferSeconds: 60, width: 720, height: 1280, frameRate: 30)
        XCTAssertEqual(high30.bitrate, 8_000_000)
        let medium30 = ReplayBufferPlan(bufferSeconds: 60, width: 504, height: 896, frameRate: 30)
        XCTAssertEqual(medium30.bitrate, 3_900_000)
        XCTAssertGreaterThan(high30.bufferBytes, ReplayBufferPlan(bufferSeconds: 60, width: 720,
                                                                 height: 1280, frameRate: 15).bufferBytes)
    }

    func testCapacityHoldsTheBufferPlusTheSegmentBeingWritten() {
        XCTAssertEqual(ReplayBufferPlan(bufferSeconds: 30, width: 2, height: 2, frameRate: 15).capacity, 16)
        XCTAssertEqual(ReplayBufferPlan(bufferSeconds: 60, width: 2, height: 2, frameRate: 15).capacity, 31)
        XCTAssertEqual(ReplayBufferPlan(bufferSeconds: 120, width: 2, height: 2, frameRate: 15).capacity, 61)
    }

    func testAnUnofferedLengthFallsBackToTheMinute() {
        XCTAssertEqual(ReplayBufferPlan(bufferSeconds: 45, width: 2, height: 2, frameRate: 15).bufferSeconds, 60)
    }

    func testTheEstimateUsesTheTiersEncodedSizeUntilAFrameSaysOtherwise() {
        let estimate = ReplayBufferPlan.estimate(bufferSeconds: 60, resolution: "medium", frameRate: 15)
        XCTAssertEqual(estimate.width, 504)
        XCTAssertEqual(estimate.height, 896)
    }
}
