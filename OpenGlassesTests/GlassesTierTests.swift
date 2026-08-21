import XCTest
@testable import OpenGlasses

/// Plan CQ P0 — the device-tier model, and the widened glasses-name markers it rests on.
final class GlassesTierTests: XCTestCase {

    // MARK: - Tier resolution

    func testNoDeviceResolvesToNil() {
        // "Not connected" and "connected but limited" are different statements. Collapsing
        // them into `.audioOnly` would tell a user with nothing paired that their glasses
        // work for voice.
        XCTAssertNil(GlassesTierPolicy.resolve(
            cameraCapabilities: nil,
            displayBackendActive: false,
            audioPortNames: ["iPhone Microphone", "AirPods Pro"]
        ))
    }

    func testBluetoothGlassesWithoutCameraOrDisplayAreAudioOnly() {
        XCTAssertEqual(
            GlassesTierPolicy.resolve(
                cameraCapabilities: nil,
                displayBackendActive: false,
                audioPortNames: ["Anko Camera Glasses"]
            ),
            .audioOnly
        )
    }

    func testDisplayBackendBeatsAudioOnly() {
        XCTAssertEqual(
            GlassesTierPolicy.resolve(
                cameraCapabilities: nil,
                displayBackendActive: true,
                audioPortNames: ["Even G2"]
            ),
            .displayOnly
        )
    }

    func testCameraBackendWins() {
        // Most-capable-wins: camera glasses are also audio devices, and Meta's Display
        // glasses are all three. The tier names the best thing available.
        XCTAssertEqual(
            GlassesTierPolicy.resolve(
                cameraCapabilities: .meta,
                displayBackendActive: true,
                audioPortNames: ["Ray-Ban Meta"]
            ),
            .camera
        )
    }

    func testStillOnlyBackendStillCountsAsCamera() {
        // A backend with no live feed is still a camera tier — what it can't do is
        // `CameraCapabilities`' job to say, not the tier's.
        let stillsOnly = CameraCapabilities(
            liveFrames: false,
            stillCapture: true,
            stillLatency: .seconds,
            concurrentWithMic: false,
            hardwareEvents: false
        )
        XCTAssertEqual(
            GlassesTierPolicy.resolve(
                cameraCapabilities: stillsOnly,
                displayBackendActive: false,
                audioPortNames: []
            ),
            .camera
        )
    }

    func testUnreachableCameraBackendDoesNotClaimCameraTier() {
        // `.unavailable` is what `CameraService.activeCapabilities` reports when nothing is
        // reachable; it must not read as a connected camera.
        XCTAssertNil(GlassesTierPolicy.resolve(
            cameraCapabilities: .unavailable,
            displayBackendActive: false,
            audioPortNames: ["AirPods Pro"]
        ))
    }

    // MARK: - Name markers (Plan CQ P0 widening)

    func testWidenedMarkersMatchTheNewDeviceClasses() {
        let names = [
            "Ray-Ban Meta",           // pre-existing
            "Oakley Meta HSTN",       // pre-existing
            "Anko Camera Glasses",    // Track B, retail badge
            "HeyCyan M02S",           // Track B, OEM platform
            "Mentra Live",            // Track A
            "Even G2",                // display tier
            "Vuzix Z100",             // display tier
        ]
        for name in names {
            XCTAssertTrue(MicRoutePolicy.looksLikeGlasses(portName: name),
                          "\(name) should be recognised as glasses")
        }
    }

    /// False-positive corpus. A marker that matches a headset is not cosmetic: the `.headset`
    /// route skips anything glasses-like, so a mismatched pair of earbuds silently stops being
    /// selectable and the `.glasses` route grabs them instead.
    func testOrdinaryHeadsetsAreNotMistakenForGlasses() {
        let names = [
            "AirPods Pro",
            "AirPods Max",
            "Beats Studio Buds",
            "WH-1000XM5",
            "Bose QuietComfort Earbuds",
            "Jabra Elite 7",
            "Pixel Buds Pro",
            "Galaxy Buds3",
            "Soundcore Liberty 4",
            "iPhone Microphone",
            "Headphones",
            "Steven's Earbuds",       // would match a bare "even"
            "G2 Speaker",             // would match a bare "g2"
            "Cyan Speaker",           // would match a bare "cyan"
        ]
        for name in names {
            XCTAssertFalse(MicRoutePolicy.looksLikeGlasses(portName: name),
                           "\(name) must not be treated as glasses")
        }
    }

    func testMarkerMatchingIsCaseInsensitive() {
        XCTAssertTrue(MicRoutePolicy.looksLikeGlasses(portName: "ANKO CAMERA GLASSES"))
        XCTAssertTrue(MicRoutePolicy.looksLikeGlasses(portName: "mentra live"))
    }
}
