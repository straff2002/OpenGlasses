import XCTest
@testable import OpenGlasses

/// The pure mapping registration × device list × per-device state → connection phase.
///
/// The bug these pin down: registration and the device list describe a pair that has been
/// *added*, and the app read either as "connected" — a pair in its case for days stayed connected.
/// Only a device's link state `.connected` means connected.
final class GlassesConnectionPhaseTests: XCTestCase {

    private func snapshot(_ registration: GlassesRegistration = .registered,
                          devices: [String] = [],
                          states: [String: GlassesDeviceState] = [:]) -> GlassesConnectionSnapshot {
        var s = GlassesConnectionSnapshot(registration: registration)
        s.apply(.devices(devices))
        for (id, state) in states { s.apply(.deviceState(id: id, state)) }
        return s
    }

    private func linked(_ link: GlassesLinkState, battery: Int? = nil,
                        charging: GlassesChargingState = .unknown) -> GlassesDeviceState {
        GlassesDeviceState(link: link, batteryLevel: battery, charging: charging)
    }

    // MARK: - Registration

    func testRegistrationRawValuesMapLikeTheRestOfTheApp() {
        XCTAssertEqual(GlassesRegistration(stateRaw: 0), .notRegistered)
        XCTAssertEqual(GlassesRegistration(stateRaw: 1), .notRegistered)
        XCTAssertEqual(GlassesRegistration(stateRaw: 2), .registering)
        XCTAssertEqual(GlassesRegistration(stateRaw: 3), .registered)
        XCTAssertEqual(GlassesRegistration(stateRaw: -1), .notRegistered)
    }

    // MARK: - Single device

    func testNotRegisteredWithNoDevicesIsNoGlassesAdded() {
        XCTAssertEqual(snapshot(.notRegistered).phase, .noGlassesAdded)
        XCTAssertEqual(snapshot(.registering).phase, .noGlassesAdded,
                       "a first registration still in flight has added nothing yet")
    }

    func testRegisteredWithNoDevicesIsAddedButNotConnected() {
        let phase = snapshot(.registered).phase
        XCTAssertEqual(phase, .addedDisconnected)
        XCTAssertFalse(phase.isConnected, "registration is not a link")
        XCTAssertTrue(phase.glassesAdded)
    }

    func testListedDeviceWithNoReportedStateIsNotConnected() {
        // The exact bug: the device list reports an id, and the app said "connected".
        XCTAssertEqual(snapshot(devices: ["a"]).phase, .addedDisconnected)
    }

    func testListedDeviceLinkDisconnectedIsAddedDisconnected() {
        let s = snapshot(devices: ["a"], states: ["a": linked(.disconnected)])
        XCTAssertEqual(s.phase, .addedDisconnected)
        XCTAssertFalse(s.phase.isConnected)
    }

    func testListedDeviceLinkConnectingIsConnectingNeverConnected() {
        let phase = snapshot(devices: ["a"], states: ["a": linked(.connecting)]).phase
        XCTAssertEqual(phase, .connecting)
        XCTAssertFalse(phase.isConnected)
        XCTAssertTrue(phase.isConnecting)
    }

    func testListedDeviceLinkConnectedIsConnected() {
        let phase = snapshot(devices: ["a"], states: ["a": linked(.connected)]).phase
        XCTAssertEqual(phase, .connected)
        XCTAssertTrue(phase.isConnected)
    }

    func testLinkDroppingTakesThePhaseWithIt() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected)])
        s.apply(.deviceState(id: "a", linked(.disconnected)))
        XCTAssertEqual(s.phase, .addedDisconnected, "into the case: added, not connected")
        s.apply(.deviceState(id: "a", linked(.connecting)))
        XCTAssertEqual(s.phase, .connecting)
        s.apply(.deviceState(id: "a", linked(.connected)))
        XCTAssertEqual(s.phase, .connected)
    }

    // MARK: - Removal and revocation

    func testDeviceRemovedWhileConnectedIsNoLongerConnected() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected, battery: 80)])
        s.apply(.devices([]))
        XCTAssertEqual(s.phase, .addedDisconnected, "still registered, nothing reachable")
        XCTAssertNil(s.liveBatteryLevel)
        XCTAssertTrue(s.deviceStates.isEmpty, "a removed device's state goes with it")
    }

    func testRemovedDeviceComingBackStartsFromDisconnected() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected)])
        s.apply(.devices([]))
        s.apply(.devices(["a"]))
        XCTAssertEqual(s.phase, .addedDisconnected,
                       "its old connected state must not be remembered across the gap")
    }

    func testLateStateForARemovedDeviceIsIgnored() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.disconnected)])
        s.apply(.devices([]))
        s.apply(.deviceState(id: "a", linked(.connected)))
        XCTAssertEqual(s.phase, .addedDisconnected)
        XCTAssertTrue(s.deviceStates.isEmpty)
    }

    func testRegistrationRevokedAndDeviceListClearedIsNoGlassesAdded() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected)])
        s.apply(.registration(.notRegistered))
        s.apply(.devices([]))
        XCTAssertEqual(s.phase, .noGlassesAdded)
    }

    func testRegistrationDroppingWhileTheLinkIsUpFollowsTheLink() {
        // Documented choice: the link is the observation; registration has been seen bouncing
        // during a healthy session, and unregistering empties the device list anyway.
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected)])
        s.apply(.registration(.notRegistered))
        XCTAssertEqual(s.phase, .connected)
        s.apply(.registration(.registered))
        XCTAssertEqual(s.phase, .connected, "and the bounce back changes nothing")
    }

    // MARK: - Multi-device

    func testAnyConnectedDeviceMakesTheGlassesConnected() {
        let s = snapshot(devices: ["a", "b"],
                         states: ["a": linked(.disconnected), "b": linked(.connected)])
        XCTAssertEqual(s.phase, .connected)
        XCTAssertEqual(s.activeDeviceId, "b", "the connected pair is the one described")
    }

    func testConnectingBeatsDisconnectedButNotConnected() {
        let connecting = snapshot(devices: ["a", "b"],
                                  states: ["a": linked(.disconnected), "b": linked(.connecting)])
        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertEqual(connecting.activeDeviceId, "b")

        let mixed = snapshot(devices: ["a", "b"],
                             states: ["a": linked(.connecting), "b": linked(.connected)])
        XCTAssertEqual(mixed.phase, .connected)
        XCTAssertEqual(mixed.activeDeviceId, "b")
    }

    func testTwoConnectedDevicesPreferTheSDKsListOrder() {
        let s = snapshot(devices: ["a", "b"],
                         states: ["a": linked(.connected, battery: 10), "b": linked(.connected, battery: 90)])
        XCTAssertEqual(s.activeDeviceId, "a")
        XCTAssertEqual(s.liveBatteryLevel, 10)
    }

    func testAllDisconnectedDescribesTheFirstListed() {
        let s = snapshot(devices: ["a", "b"],
                         states: ["a": linked(.disconnected), "b": linked(.disconnected)])
        XCTAssertEqual(s.phase, .addedDisconnected)
        XCTAssertEqual(s.activeDeviceId, "a")
    }

    func testTheConnectedDeviceLeavingHandsOverToTheOther() {
        var s = snapshot(devices: ["a", "b"],
                         states: ["a": linked(.connected), "b": linked(.disconnected)])
        s.apply(.devices(["b"]))
        XCTAssertEqual(s.phase, .addedDisconnected)
        XCTAssertEqual(s.activeDeviceId, "b")
    }

    func testDuplicateIdsInTheDeviceListCollapse() {
        var s = snapshot(devices: ["a", "a", "b"])
        XCTAssertEqual(s.deviceIds, ["a", "b"])
        s.apply(.deviceState(id: "a", linked(.connected)))
        XCTAssertEqual(s.phase, .connected)
    }

    // MARK: - Battery and name

    func testBatteryIsLiveOnlyWhileConnected() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected, battery: 64, charging: .charging)])
        XCTAssertEqual(s.liveBatteryLevel, 64)
        XCTAssertEqual(s.liveCharging, .charging)

        // In the case the SDK may still hold a reading, but it is not live.
        s.apply(.deviceState(id: "a", linked(.disconnected, battery: 64, charging: .charging)))
        XCTAssertNil(s.liveBatteryLevel, "a stale battery is hidden, not shown as live")
        XCTAssertEqual(s.liveCharging, .unknown)

        s.apply(.deviceState(id: "a", linked(.connecting, battery: 64)))
        XCTAssertNil(s.liveBatteryLevel, "connecting is not connected")
    }

    func testBatteryFollowsTheDeviceStateUpdates() {
        var s = snapshot(devices: ["a"], states: ["a": linked(.connected, battery: 64)])
        s.apply(.deviceState(id: "a", linked(.connected, battery: 63)))
        XCTAssertEqual(s.liveBatteryLevel, 63)
        s.apply(.deviceState(id: "a", linked(.connected, battery: nil)))
        XCTAssertNil(s.liveBatteryLevel, "a device that stops reporting shows nothing")
    }

    func testNameIsTheActiveDevicesAndIgnoredForUnlistedIds() {
        var s = snapshot(devices: ["a", "b"], states: ["b": linked(.connected)])
        s.apply(.deviceName(id: "a", "Spare"))
        s.apply(.deviceName(id: "b", "Ray-Ban Meta"))
        s.apply(.deviceName(id: "z", "Ghost"))
        XCTAssertEqual(s.activeDeviceName, "Ray-Ban Meta")
        XCTAssertNil(s.deviceNames["z"])
    }

    // MARK: - Phase surface

    func testPhaseFlags() {
        XCTAssertFalse(GlassesConnectionPhase.noGlassesAdded.glassesAdded)
        for phase: GlassesConnectionPhase in [.addedDisconnected, .connecting, .connected] {
            XCTAssertTrue(phase.glassesAdded)
        }
        XCTAssertEqual([GlassesConnectionPhase.noGlassesAdded, .addedDisconnected, .connecting, .connected]
                        .filter(\.isConnected), [.connected])
    }

    func testStatusText() {
        XCTAssertEqual(GlassesConnectionPhase.noGlassesAdded.statusText(deviceName: nil), "Not connected")
        XCTAssertEqual(GlassesConnectionPhase.addedDisconnected.statusText(deviceName: "X"), "Not connected")
        XCTAssertEqual(GlassesConnectionPhase.connecting.statusText(deviceName: "X"), "Connecting…")
        XCTAssertEqual(GlassesConnectionPhase.connected.statusText(deviceName: "X"), "Connected to X")
        XCTAssertEqual(GlassesConnectionPhase.connected.statusText(deviceName: nil), "Connected to glasses")
    }

    // MARK: - "Phone is the device" with truthful inputs

    func testPhoneIsTheDeviceOnlyWhenNothingIsAddedOrConnected() {
        // Settings' hero card and the session card ask this with the link (connected) and with
        // "added" (registered/listed now, or ever). A registered pair in its case is added.
        let away = snapshot(.registered).phase
        XCTAssertFalse(OnboardingFlow.phoneIsTheDevice(glassesConnected: away.isConnected,
                                                       glassesAdded: away.glassesAdded))
        let none = snapshot(.notRegistered).phase
        XCTAssertTrue(OnboardingFlow.phoneIsTheDevice(glassesConnected: none.isConnected,
                                                      glassesAdded: none.glassesAdded))
    }
}
