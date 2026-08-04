import XCTest
import AVFoundation
@testable import OpenGlasses

final class MicRoutePolicyTests: XCTestCase {

    // MARK: - Category options

    func testPhoneRouteExcludesAllBluetoothOptions() {
        // With any Bluetooth option present, iOS re-routes input to the
        // glasses on its own — "phone mic" must mean phone mic.
        for mix in [true, false] {
            let options = MicRoutePolicy.categoryOptions(for: .phone, mixWithOthers: mix)
            XCTAssertFalse(options.contains(.allowBluetoothHFP))
            XCTAssertFalse(options.contains(.allowBluetoothA2DP))
            XCTAssertTrue(options.contains(.defaultToSpeaker))
            XCTAssertEqual(options.contains(.mixWithOthers), mix)
        }
    }

    func testBluetoothRoutesAllowBluetooth() {
        for route in [MicRoute.glasses, .headset] {
            let options = MicRoutePolicy.categoryOptions(for: route, mixWithOthers: true)
            XCTAssertTrue(options.contains(.allowBluetoothHFP))
            XCTAssertTrue(options.contains(.allowBluetoothA2DP))
            XCTAssertTrue(options.contains(.mixWithOthers))
        }
    }

    // MARK: - Preferred input

    private let mixedPorts: [(name: String, type: AVAudioSession.Port)] = [
        ("iPhone Microphone", .builtInMic),
        ("Ray-Ban Meta Glasses", .bluetoothHFP),
        ("AirPods Pro", .bluetoothHFP),
    ]

    func testGlassesRoutePicksGlassesPort() {
        XCTAssertEqual(MicRoutePolicy.preferredInputIndex(for: .glasses, ports: mixedPorts), 1)
    }

    func testHeadsetRoutePicksNonGlassesBluetoothPort() {
        XCTAssertEqual(MicRoutePolicy.preferredInputIndex(for: .headset, ports: mixedPorts), 2)
    }

    func testHeadsetRouteNeverFallsBackToGlasses() {
        // Only the glasses are around: preferring them would put the call
        // screen over the HUD this mode exists to keep — so prefer nothing.
        let onlyGlasses: [(name: String, type: AVAudioSession.Port)] = [
            ("iPhone Microphone", .builtInMic),
            ("Oakley Meta HSTN", .bluetoothLE),
        ]
        XCTAssertNil(MicRoutePolicy.preferredInputIndex(for: .headset, ports: onlyGlasses))
    }

    func testPhoneRoutePrefersNothing() {
        XCTAssertNil(MicRoutePolicy.preferredInputIndex(for: .phone, ports: mixedPorts))
    }

    func testGlassesRouteMatchesLEAudioAndAllMarkerNames() {
        // iOS 26: glasses audio may ride Bluetooth LE (LC3), not classic HFP.
        for name in ["Ray-Ban Meta", "rayban display", "Oakley Vanguard", "Meta Glasses"] {
            let ports: [(name: String, type: AVAudioSession.Port)] = [(name, .bluetoothLE)]
            XCTAssertEqual(
                MicRoutePolicy.preferredInputIndex(for: .glasses, ports: ports), 0,
                "expected \(name) to be recognised as glasses"
            )
        }
    }

    func testNonBluetoothPortsAreNeverPreferred() {
        // A wired "glasses" accessory name on a non-Bluetooth port is not a mic route.
        let ports: [(name: String, type: AVAudioSession.Port)] = [
            ("Meta USB Dock", .usbAudio)
        ]
        XCTAssertNil(MicRoutePolicy.preferredInputIndex(for: .glasses, ports: ports))
        XCTAssertNil(MicRoutePolicy.preferredInputIndex(for: .headset, ports: ports))
    }

    // MARK: - Config migration

    func testMicRouteMigratesFromLegacyBoolean() {
        let defaults = UserDefaults.standard
        let savedRoute = defaults.string(forKey: "micRoute")
        let savedLegacy = defaults.object(forKey: "useGlassesMicForWakeWord")
        defer {
            defaults.set(savedRoute, forKey: "micRoute")
            defaults.set(savedLegacy, forKey: "useGlassesMicForWakeWord")
        }

        // Unset route + legacy default (true) → glasses.
        defaults.removeObject(forKey: "micRoute")
        defaults.removeObject(forKey: "useGlassesMicForWakeWord")
        XCTAssertEqual(Config.micRoute, .glasses)

        // Legacy explicitly off → phone.
        defaults.set(false, forKey: "useGlassesMicForWakeWord")
        XCTAssertEqual(Config.micRoute, .phone)

        // Setting headset keeps the legacy boolean honest (not glasses).
        Config.setMicRoute(.headset)
        XCTAssertEqual(Config.micRoute, .headset)
        XCTAssertFalse(Config.useGlassesMicForWakeWord)

        // Legacy setter round-trips through the route.
        Config.setUseGlassesMicForWakeWord(true)
        XCTAssertEqual(Config.micRoute, .glasses)
        XCTAssertTrue(Config.useGlassesMicForWakeWord)
    }
}
