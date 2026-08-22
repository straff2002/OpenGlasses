import XCTest
@testable import OpenGlasses

/// The encode bitrate used to be a constant (1.5 Mbps) regardless of frame size — starving
/// 720×1280 and overspending at 360×640. These cover the derivation itself: scaling with pixel
/// count and frame rate, the clamps, the override escape hatch, and the concrete values the
/// glasses' streaming tiers land on.
@MainActor
final class VideoBitratePolicyTests: XCTestCase {

    // Encoded sizes of the three `StreamingResolution` tiers the glasses stream at.
    private let high = (width: 720, height: 1280)
    private let medium = (width: 504, height: 896)
    private let low = (width: 360, height: 640)

    private func disk(_ size: (width: Int, height: Int), fps: Double = 30) -> Int {
        VideoBitratePolicy.bitrate(width: size.width, height: size.height,
                                   frameRate: fps, profile: .disk)
    }

    // MARK: - Scaling with the picture

    func testDiskBitrateHitsTheTargetAtTheGlassesHighTier() {
        // The whole point of the change: 720×1280@30 targets ~8 Mbps, not 1.5.
        XCTAssertEqual(disk(high), 8_000_000)
    }

    func testDiskBitrateScalesWithPixelCount() {
        XCTAssertEqual(disk(medium), 3_900_000)
        XCTAssertEqual(disk(low), 2_000_000)
        XCTAssertGreaterThan(disk(high), disk(medium))
        XCTAssertGreaterThan(disk(medium), disk(low))
    }

    func testBitrateIsLinearInPixelCount() {
        // Twice the pixels, twice the bits (both well inside the clamps).
        let single = disk((width: 640, height: 360))
        let double = disk((width: 640, height: 720))
        XCTAssertEqual(Double(double) / Double(single), 2, accuracy: 0.02)
    }

    func testFrameRateRaisesTheBitrateSubLinearly() {
        let fast = disk(high, fps: 30)
        let slow = disk(high, fps: 15)
        XCTAssertLessThan(slow, fast, "fewer frames per second need fewer bits per second")
        XCTAssertGreaterThan(slow, fast / 2,
                             "halving the frame rate must not halve the bitrate — each frame carries more motion")
    }

    func testResultIsRoundedToWholeHundredKilobits() {
        for fps in [10.0, 15.0, 24.0, 30.0] {
            for size in [high, medium, low] {
                XCTAssertEqual(disk(size, fps: fps) % 100_000, 0)
            }
        }
    }

    // MARK: - Clamps

    func testTinyFramesGetTheProfileFloor() {
        XCTAssertEqual(disk((width: 64, height: 64)), VideoBitratePolicy.Profile.disk.minimum)
    }

    func testHugeFramesGetTheProfileCeiling() {
        XCTAssertEqual(disk((width: 3840, height: 2160)), VideoBitratePolicy.Profile.disk.maximum)
    }

    func testDegenerateInputsFallBackToTheFloorInsteadOfTrapping() {
        XCTAssertEqual(disk((width: 0, height: 1280)), VideoBitratePolicy.Profile.disk.minimum)
        XCTAssertEqual(disk((width: -720, height: 1280)), VideoBitratePolicy.Profile.disk.minimum)
        XCTAssertEqual(disk(high, fps: 0), disk(high, fps: 1),
                       "a zero frame rate is floored, not divided by")
        XCTAssertEqual(
            VideoBitratePolicy.bitrate(width: 720, height: 1280, frameRate: .nan, profile: .disk),
            VideoBitratePolicy.Profile.disk.minimum)
    }

    // MARK: - Explicit override

    func testOverrideWinsOverTheDerivedValue() {
        XCTAssertEqual(
            VideoBitratePolicy.bitrate(width: 720, height: 1280, frameRate: 30,
                                       profile: .disk, override: 2_500_000),
            2_500_000)
    }

    func testOverrideIsNotClampedIntoTheProfile() {
        // An override is a deliberate choice, so it is allowed outside the derived bounds.
        XCTAssertEqual(
            VideoBitratePolicy.bitrate(width: 720, height: 1280, frameRate: 30,
                                       profile: .disk, override: 20_000_000),
            20_000_000)
        XCTAssertEqual(
            VideoBitratePolicy.bitrate(width: 720, height: 1280, frameRate: 30,
                                       profile: .disk, override: 300_000),
            300_000)
    }

    func testNonPositiveOverrideIsTreatedAsUnset() {
        // `Config.recordingBitrateOverride` is nil when unset, but a stored 0 must not win.
        for override in [nil, 0, -1] as [Int?] {
            XCTAssertEqual(
                VideoBitratePolicy.bitrate(width: 720, height: 1280, frameRate: 30,
                                           profile: .disk, override: override),
                8_000_000)
        }
    }

    // MARK: - RTMP profile

    func testRTMPStaysWellBelowTheDiskBitrateForTheSameFrame() {
        let rtmp = VideoBitratePolicy.bitrate(width: 720, height: 1280, frameRate: 15,
                                              profile: .rtmp)
        XCTAssertEqual(rtmp, 3_100_000, "720p at the broadcaster's 15fps sits inside the usual ingest band")
        XCTAssertLessThan(rtmp, disk(high, fps: 15), "an uplink-bound encode spends less than a disk-bound one")
        XCTAssertGreaterThan(rtmp, 1_500_000, "still an improvement on the old constant")
    }

    func testRTMPCeilingIsLowerThanDisk() {
        XCTAssertLessThan(VideoBitratePolicy.Profile.rtmp.maximum, VideoBitratePolicy.Profile.disk.maximum)
        // Even a 4K landscape geometry cannot push the uplink past the RTMP ceiling.
        XCTAssertEqual(
            VideoBitratePolicy.bitrate(width: 3840, height: 2160, frameRate: 30, profile: .rtmp),
            VideoBitratePolicy.Profile.rtmp.maximum)
    }

    // MARK: - Feeding the storage verdict

    func testStorageVerdictConsumesTheDerivedBitrate() {
        // The verdict's minutes-remaining estimate is only honest at the rate actually written:
        // the derived 720p rate must shrink it against the old 1.5 Mbps constant.
        let derived = disk(high)
        guard case .low(let atDerived) = VideoRecordingService.storageVerdict(
                  freeBytes: 1_000_000_000, videoBitrate: derived),
              case .low(let atOldConstant) = VideoRecordingService.storageVerdict(
                  freeBytes: 1_000_000_000, videoBitrate: 1_500_000) else {
            return XCTFail("1 GB free should be low at both rates")
        }
        XCTAssertLessThan(atDerived, atOldConstant,
                          "8 Mbps fills the disk faster than 1.5 Mbps — the warning must say so")
    }

    // MARK: - Settings preview (tier → size → bitrate)

    func testEncodedSizeMapsEveryResolutionTier() {
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "low").width, low.width)
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "low").height, low.height)
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "medium").width, medium.width)
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "medium").height, medium.height)
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "high").width, high.width)
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "high").height, high.height)
    }

    func testEncodedSizeFallsThroughToHighLikeCameraService() {
        // `CameraService` maps anything unrecognised to `.high`; the Settings preview must not
        // disagree with what the camera would actually do.
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "garbage").width, high.width)
        XCTAssertEqual(StreamConfigPolicy.encodedSize(for: "").width, high.width)
    }

    func testSettingsPreviewMatchesWhatTheRecorderWouldPick() {
        // The "Automatic (~N Mbps)" label derives from the tier the same way the recorder
        // derives from a real frame — same tier in, same number out.
        for tier in ["low", "medium", "high"] {
            let size = StreamConfigPolicy.encodedSize(for: tier)
            XCTAssertEqual(
                VideoBitratePolicy.bitrate(width: size.width, height: size.height,
                                           frameRate: 30, profile: .disk),
                disk((width: size.width, height: size.height)))
        }
    }

    // MARK: - Settings label formatting

    func testMegabitLabelDropsTrailingZeroOnWholeNumbers() {
        XCTAssertEqual(VideoBitratePolicy.megabitLabel(8_000_000), "8 Mbps")
        XCTAssertEqual(VideoBitratePolicy.megabitLabel(2_000_000), "2 Mbps")
        XCTAssertEqual(VideoBitratePolicy.megabitLabel(12_000_000), "12 Mbps")
    }

    func testMegabitLabelKeepsOneDecimalWhenItCarriesInformation() {
        XCTAssertEqual(VideoBitratePolicy.megabitLabel(3_100_000), "3.1 Mbps")
        XCTAssertEqual(VideoBitratePolicy.megabitLabel(5_700_000), "5.7 Mbps")
        XCTAssertEqual(VideoBitratePolicy.megabitLabel(800_000), "0.8 Mbps")
    }

    func testEveryTierRendersALabelSettingsCanShow() {
        // What the "Automatic (~N Mbps at Xp)" row reduces to, for each tier at the default
        // 15 fps: a label that is never empty and never a bare number.
        let expected = ["low": "1.4 Mbps", "medium": "2.8 Mbps", "high": "5.7 Mbps"]
        for (tier, label) in expected {
            let size = StreamConfigPolicy.encodedSize(for: tier)
            let bps = VideoBitratePolicy.bitrate(width: size.width, height: size.height,
                                                 frameRate: 15, profile: .disk)
            XCTAssertEqual(VideoBitratePolicy.megabitLabel(bps), label, "tier \(tier)")
        }
    }

    // MARK: - CGSize convenience

    func testSizeConvenienceMatchesTheIntegerForm() {
        XCTAssertEqual(
            VideoBitratePolicy.bitrate(for: CGSize(width: 720, height: 1280),
                                       frameRate: 30, profile: .disk),
            disk(high))
    }
}
