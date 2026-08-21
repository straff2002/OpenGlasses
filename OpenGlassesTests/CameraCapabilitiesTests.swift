import XCTest
@testable import OpenGlasses

/// Plan CQ P1 — the capability model and the gate that turns it into an answer a user can read.
final class CameraCapabilitiesTests: XCTestCase {

    /// The two device classes Plan CQ targets, as capability fixtures.
    private let documentedSDKClass = CameraCapabilities(
        liveFrames: false,          // stills go to a webhook; no local frame access
        stillCapture: true,
        stillLatency: .subSecond,   // with camera warm-up
        concurrentWithMic: true,
        hardwareEvents: true
    )
    private let captureToStorageClass = CameraCapabilities(
        liveFrames: false,
        stillCapture: true,
        stillLatency: .seconds,     // BLE trigger, then a network hop to fetch
        concurrentWithMic: false,   // camera and mic are exclusive modes
        hardwareEvents: false
    )

    // MARK: - Meta backend: the baseline the app was written against

    func testMetaBackendMakesEveryCameraFeatureAvailable() {
        for feature in CameraDependentFeature.allCases {
            XCTAssertEqual(
                CameraFeatureGate.availability(of: feature, given: .meta),
                .available,
                "\(feature.rawValue) should be available on the Meta backend"
            )
        }
        XCTAssertTrue(CameraFeatureGate.unavailableFeatures(given: .meta).isEmpty)
    }

    // MARK: - Live-frame features

    func testLiveFrameFeaturesAreUnavailableWithoutALiveFeed() {
        // This is the whole reason the gate exists: every one of these is built on
        // `CameraService.framePublisher`, and neither Plan CQ device class provides it.
        let liveOnly = CameraDependentFeature.allCases.filter(\.requiresLiveFrames)
        XCTAssertFalse(liveOnly.isEmpty, "fixture guard — the live-frame set must not be empty")

        for feature in liveOnly {
            for capabilities in [documentedSDKClass, captureToStorageClass] {
                let availability = CameraFeatureGate.availability(of: feature, given: capabilities)
                XCTAssertFalse(availability.isUsable, "\(feature.rawValue) must be refused")
                XCTAssertTrue(
                    availability.note?.contains(feature.displayName) == true,
                    "the refusal should name the feature so the copy is usable as-is"
                )
            }
        }
    }

    func testPhoneFallbackDoesNotRescueLiveFrameFeatures() {
        // The iPhone fallback is a one-shot still. It must never make a continuous feature
        // look available.
        XCTAssertFalse(
            CameraFeatureGate.availability(
                of: .signLanguage, given: .unavailable, phoneFallbackAvailable: true
            ).isUsable
        )
    }

    // MARK: - Still capture

    func testFastStillCaptureIsFullyAvailable() {
        XCTAssertEqual(
            CameraFeatureGate.availability(of: .photoCapture, given: documentedSDKClass),
            .available
        )
    }

    func testSlowStillCaptureIsAvailableButFlagged() {
        let availability = CameraFeatureGate.availability(
            of: .photoCapture, given: captureToStorageClass
        )
        XCTAssertTrue(availability.isUsable)
        guard case .degraded(let note) = availability else {
            return XCTFail("a seconds-long capture should be degraded, not silently available")
        }
        XCTAssertTrue(note.localizedCaseInsensitiveContains("seconds"))
    }

    func testNoGlassesCameraFallsBackToThePhoneAndSaysSo() {
        // Preserves the shipped behaviour that `capturePhoto()` uses the iPhone back camera
        // when the glasses camera isn't usable — but the caveat has to be surfaced, because a
        // phone in a pocket is not pointed where the user is looking.
        let availability = CameraFeatureGate.availability(of: .photoCapture, given: .unavailable)
        XCTAssertTrue(availability.isUsable)
        XCTAssertTrue(availability.note?.localizedCaseInsensitiveContains("iPhone camera") == true)
    }

    func testNoCameraAtAllWhenEvenThePhoneIsUnavailable() {
        let availability = CameraFeatureGate.availability(
            of: .photoCapture, given: .unavailable, phoneFallbackAvailable: false
        )
        XCTAssertFalse(availability.isUsable)
    }

    // MARK: - Summaries

    func testSummaryDistinguishesTheThreeCases() {
        XCTAssertEqual(CameraFeatureGate.summary(given: .meta), "Live video and photo capture")
        XCTAssertEqual(CameraFeatureGate.summary(given: documentedSDKClass), "Photo capture only")
        XCTAssertTrue(
            CameraFeatureGate.summary(given: captureToStorageClass)
                .localizedCaseInsensitiveContains("several seconds")
        )
        XCTAssertTrue(
            CameraFeatureGate.summary(given: .unavailable)
                .localizedCaseInsensitiveContains("no camera")
        )
    }

    func testUnavailableFeatureListIsExactlyTheLiveFrameSet() {
        // Photo capture survives on both classes (fast or degraded); everything continuous does not.
        let expected = Set(CameraDependentFeature.allCases.filter(\.requiresLiveFrames).map(\.rawValue))
        for capabilities in [documentedSDKClass, captureToStorageClass] {
            let blocked = Set(CameraFeatureGate.unavailableFeatures(given: capabilities).map(\.rawValue))
            XCTAssertEqual(blocked, expected)
        }
    }
}
