import Combine
import XCTest
@testable import OpenGlasses

/// `GlassesConnectionService` driven through a fake `GlassesLinkSource` — never `Wearables`, which
/// fatals in the test process. Covers the published truth (`phase`, `isConnected`, battery) and
/// the per-device listener lifecycle.
@MainActor
final class GlassesConnectionServiceTests: XCTestCase {

    // MARK: - Fake source

    @MainActor
    final class FakeObservation: GlassesLinkObservation {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    @MainActor
    final class FakeLinkSource: GlassesLinkSource {
        var activates = true
        var registration: GlassesRegistration = .notRegistered
        var devices: [String] = []
        var names: [String: String] = [:]
        /// Devices the source cannot resolve (`deviceForIdentifier` returning nil).
        var unknownDevices: Set<String> = []
        /// A state the source delivers synchronously on subscription, like the SDK's immediate
        /// delivery (which reaches the service a main-queue hop later).
        var initialStates: [String: GlassesDeviceState] = [:]

        private var registrationHandler: (@MainActor @Sendable (GlassesRegistration) -> Void)?
        private var devicesHandler: (@MainActor @Sendable ([String]) -> Void)?
        /// Every per-device subscription ever made, in order, with its handler.
        private(set) var stateSubscriptions: [(id: String, observation: FakeObservation,
                                               handler: @MainActor @Sendable (GlassesDeviceState) -> Void)] = []
        private(set) var serviceObservations: [FakeObservation] = []

        func activate() -> Bool { activates }
        func deviceName(for id: String) -> String? { names[id] }

        func observeRegistration(_ onChange: @escaping @MainActor @Sendable (GlassesRegistration) -> Void) -> GlassesLinkObservation {
            registrationHandler = onChange
            let o = FakeObservation(); serviceObservations.append(o); return o
        }

        func observeDevices(_ onChange: @escaping @MainActor @Sendable ([String]) -> Void) -> GlassesLinkObservation {
            devicesHandler = onChange
            let o = FakeObservation(); serviceObservations.append(o); return o
        }

        func observeDeviceState(for id: String,
                                _ onChange: @escaping @MainActor @Sendable (GlassesDeviceState) -> Void) -> GlassesLinkObservation? {
            guard !unknownDevices.contains(id) else { return nil }
            let o = FakeObservation()
            stateSubscriptions.append((id, o, onChange))
            if let initial = initialStates[id] { onChange(initial) }
            return o
        }

        // Drive

        func sendRegistration(_ r: GlassesRegistration) { registration = r; registrationHandler?(r) }
        func sendDevices(_ ids: [String]) { devices = ids; devicesHandler?(ids) }
        /// Deliver through the *latest* subscription for `id`.
        func sendState(_ id: String, _ state: GlassesDeviceState) {
            stateSubscriptions.last { $0.id == id }?.handler(state)
        }
        func subscriptions(for id: String) -> [FakeObservation] {
            stateSubscriptions.filter { $0.id == id }.map(\.observation)
        }
    }

    private func connected(battery: Int? = nil, charging: GlassesChargingState = .unknown) -> GlassesDeviceState {
        GlassesDeviceState(link: .connected, batteryLevel: battery, charging: charging)
    }

    private func make(_ source: FakeLinkSource, observe: Bool = true) -> GlassesConnectionService {
        GlassesConnectionService(source: source, observeNow: observe)
    }

    // MARK: - Start

    func testNothingIsObservedUntilAsked() {
        let source = FakeLinkSource()
        source.registration = .registered
        let service = make(source, observe: false)
        XCTAssertEqual(service.phase, .noGlassesAdded)
        XCTAssertTrue(source.serviceObservations.isEmpty)

        service.startObserving()
        XCTAssertEqual(service.phase, .addedDisconnected)
        XCTAssertEqual(source.serviceObservations.count, 2)

        service.startObserving()
        XCTAssertEqual(source.serviceObservations.count, 2, "idempotent")
    }

    func testAnUnavailableSourceSaysSoAndStaysDisconnected() {
        let source = FakeLinkSource()
        source.activates = false
        let service = make(source)
        XCTAssertEqual(service.connectionStatus, "Meta SDK unavailable")
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(source.serviceObservations.isEmpty)
    }

    func testDevicesAlreadyListedAtStartAreSubscribed() {
        let source = FakeLinkSource()
        source.registration = .registered
        source.devices = ["a"]
        source.initialStates = ["a": connected(battery: 70)]
        source.names = ["a": "Ray-Ban Meta"]
        let service = make(source)
        XCTAssertEqual(service.phase, .connected)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.deviceName, "Ray-Ban Meta")
        XCTAssertEqual(service.batteryLevel, 70)
        XCTAssertEqual(service.connectionStatus, "Connected to Ray-Ban Meta")
    }

    // MARK: - The bug

    func testRegisteredWithADeviceListedIsNotConnectedUntilTheLinkSaysSo() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendRegistration(.registered)
        source.sendDevices(["a"])
        XCTAssertFalse(service.isConnected, "glasses in their case: registered and listed, no link")
        XCTAssertEqual(service.phase, .addedDisconnected)
        XCTAssertEqual(service.connectionStatus, "Not connected")

        source.sendState("a", GlassesDeviceState(link: .connecting))
        XCTAssertEqual(service.phase, .connecting)
        XCTAssertFalse(service.isConnected, "connecting is never connected")
        XCTAssertEqual(service.connectionStatus, "Connecting…")

        source.sendState("a", connected(battery: 55))
        XCTAssertEqual(service.phase, .connected)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.batteryLevel, 55)

        source.sendState("a", GlassesDeviceState(link: .disconnected, batteryLevel: 55))
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(service.batteryLevel, "a stale battery is not presented as live")
    }

    func testChargingIsPublishedOnlyWhileConnected() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        source.sendState("a", connected(battery: 40, charging: .charging))
        XCTAssertTrue(service.isCharging)
        source.sendState("a", GlassesDeviceState(link: .disconnected, batteryLevel: 40, charging: .charging))
        XCTAssertFalse(service.isCharging)
    }

    func testWornIsPublishedOnlyWhileConnected() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        source.sendState("a", GlassesDeviceState(link: .connected, worn: true))
        XCTAssertEqual(service.isWorn, true)
        source.sendState("a", GlassesDeviceState(link: .connected, worn: false))
        XCTAssertEqual(service.isWorn, false)
        source.sendState("a", GlassesDeviceState(link: .disconnected, worn: true))
        XCTAssertNil(service.isWorn)
    }

    // MARK: - Thermal and compatibility (Plan HX P1)

    func testThermalIsPublishedOnlyWhileConnected() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        XCTAssertNil(service.thermal, "nothing is read before the device reports")

        source.sendState("a", GlassesDeviceState(link: .connecting, thermal: .severe))
        XCTAssertNil(service.thermal, "connecting is not connected")

        source.sendState("a", GlassesDeviceState(link: .connected, thermal: .severe))
        XCTAssertEqual(service.thermal, .severe)
        source.sendState("a", GlassesDeviceState(link: .connected, thermal: .normal))
        XCTAssertEqual(service.thermal, .normal)
        source.sendState("a", GlassesDeviceState(link: .connected, thermal: nil))
        XCTAssertNil(service.thermal, "a device that stops saying shows nothing")

        // The SDK may still hold the reading for a pair that has gone into its case.
        source.sendState("a", GlassesDeviceState(link: .connected, thermal: .critical))
        source.sendState("a", GlassesDeviceState(link: .disconnected, thermal: .critical))
        XCTAssertNil(service.thermal, "a hot reading must not outlive the link")
    }

    func testCompatibilityIsPublishedOnlyWhileConnected() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        XCTAssertNil(service.compatibility)

        source.sendState("a", GlassesDeviceState(link: .connecting, compatibility: .sdkUpdateRequired))
        XCTAssertNil(service.compatibility, "connecting is not connected")

        source.sendState("a", GlassesDeviceState(link: .connected))
        XCTAssertEqual(service.compatibility, .undefined,
                       "connected glasses that have not said are undefined, not absent")
        source.sendState("a", GlassesDeviceState(link: .connected, compatibility: .deviceUpdateRequired))
        XCTAssertEqual(service.compatibility, .deviceUpdateRequired)

        source.sendState("a", GlassesDeviceState(link: .disconnected, compatibility: .deviceUpdateRequired))
        XCTAssertNil(service.compatibility, "a requirement must not outlive the link")
    }

    func testThermalAndCompatibilityGoWithTheDeviceAndWithTheObservation() {
        let source = FakeLinkSource()
        let service = make(source)
        let hot = GlassesDeviceState(link: .connected, thermal: .emergency,
                                     compatibility: .sdkUpdateRequired)
        source.sendDevices(["a"])
        source.sendState("a", hot)
        XCTAssertEqual(service.thermal, .emergency)
        XCTAssertEqual(service.compatibility, .sdkUpdateRequired)

        // Removed from the list while connected: nothing of it is left to read.
        source.sendDevices([])
        XCTAssertNil(service.thermal)
        XCTAssertNil(service.compatibility)

        // Back in the list, it starts from nothing rather than from memory.
        source.sendDevices(["a"])
        XCTAssertNil(service.thermal)
        XCTAssertNil(service.compatibility)

        source.sendState("a", hot)
        service.stopObserving()
        XCTAssertNil(service.thermal)
        XCTAssertNil(service.compatibility)
    }

    func testThermalAndCompatibilityAreTheActiveDevices() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a", "b"])
        source.sendState("a", GlassesDeviceState(link: .disconnected, thermal: .critical,
                                                 compatibility: .sdkUpdateRequired))
        source.sendState("b", GlassesDeviceState(link: .connected, thermal: .light,
                                                 compatibility: .compatible))
        XCTAssertEqual(service.thermal, .light, "the connected pair's reading, not the one in its case")
        XCTAssertEqual(service.compatibility, .compatible)
    }

    func testThermalAndCompatibilityArePublishedBeforeThePhase() {
        // `AppState` hears the phase and reads the details back, as it does for the battery.
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        var seen: [(GlassesThermal?, GlassesCompatibility?)] = []
        let token = service.$phase.dropFirst().sink { _ in
            seen.append((service.thermal, service.compatibility))
        }
        source.sendState("a", GlassesDeviceState(link: .connected, thermal: .moderate,
                                                 compatibility: .deviceUpdateRequired))
        token.cancel()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, .moderate)
        XCTAssertEqual(seen.first?.1, .deviceUpdateRequired)
    }

    // MARK: - Listener lifecycle

    func testOneSubscriptionPerDeviceAndCancelledWhenTheDeviceLeaves() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a", "b"])
        XCTAssertEqual(service.observedDeviceCount, 2)
        source.sendDevices(["a", "b"])
        XCTAssertEqual(source.stateSubscriptions.count, 2, "a repeated list does not resubscribe")

        source.sendDevices(["b"])
        XCTAssertEqual(service.observedDeviceCount, 1)
        XCTAssertTrue(source.subscriptions(for: "a").allSatisfy(\.cancelled))
        XCTAssertFalse(source.subscriptions(for: "b").contains(where: \.cancelled))
    }

    func testDeviceRemovedWhileConnectedDropsTheConnection() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendRegistration(.registered)
        source.sendDevices(["a"])
        source.sendState("a", connected(battery: 90))
        XCTAssertTrue(service.isConnected)

        source.sendDevices([])
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.phase, .addedDisconnected)
        XCTAssertNil(service.batteryLevel)
        XCTAssertNil(service.deviceName)
    }

    func testALateCallbackFromACancelledSubscriptionIsIgnored() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        let stale = source.stateSubscriptions[0].handler
        source.sendDevices([])
        // The SDK's async cancel can lose the race with a delivery already in flight.
        stale(connected())
        XCTAssertFalse(service.isConnected)

        // Even after the same device is listed again: only its new subscription speaks for it.
        source.sendDevices(["a"])
        stale(connected())
        XCTAssertFalse(service.isConnected)
        source.sendState("a", connected())
        XCTAssertTrue(service.isConnected)
    }

    func testAnUnresolvableDeviceIsListedButNeverConnected() {
        let source = FakeLinkSource()
        source.unknownDevices = ["a"]
        let service = make(source)
        source.sendRegistration(.registered)
        source.sendDevices(["a"])
        XCTAssertEqual(service.phase, .addedDisconnected)
        XCTAssertEqual(service.observedDeviceCount, 1)
    }

    func testRegistrationRevokedThenDeviceListClearedIsNoGlassesAdded() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendRegistration(.registered)
        source.sendDevices(["a"])
        source.sendState("a", connected())
        source.sendRegistration(.notRegistered)
        XCTAssertTrue(service.isConnected, "the link, not the registration flag, says connected")
        source.sendDevices([])
        XCTAssertEqual(service.phase, .noGlassesAdded)
        XCTAssertFalse(service.isConnected)
    }

    func testMultiDeviceConnectedIfAnyIs() {
        let source = FakeLinkSource()
        source.names = ["a": "Old pair", "b": "New pair"]
        let service = make(source)
        source.sendDevices(["a", "b"])
        source.sendState("b", connected(battery: 33))
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.deviceName, "New pair")
        XCTAssertEqual(service.batteryLevel, 33)
    }

    func testStopObservingCancelsEverythingAndForgets() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendRegistration(.registered)
        source.sendDevices(["a"])
        source.sendState("a", connected())

        service.stopObserving()
        XCTAssertTrue(source.serviceObservations.allSatisfy(\.cancelled))
        XCTAssertTrue(source.subscriptions(for: "a").allSatisfy(\.cancelled))
        XCTAssertEqual(service.observedDeviceCount, 0)
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.phase, .noGlassesAdded)

        service.startObserving()
        XCTAssertEqual(source.serviceObservations.count, 4, "observing can start again")
    }

    func testPhaseIsPublishedAfterItsDetails() {
        // AppState mirrors `$phase` and reads the battery for its device event; the details must
        // already be current when the phase fires (willSet).
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        var seen: [(GlassesConnectionPhase, Int?, Bool)] = []
        let token = service.$phase.dropFirst().sink { phase in
            seen.append((phase, service.batteryLevel, service.isConnected))
        }
        source.sendState("a", connected(battery: 12))
        token.cancel()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, .connected)
        XCTAssertEqual(seen.first?.1, 12)
        XCTAssertEqual(seen.first?.2, true)
    }
}
