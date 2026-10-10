import Combine
import XCTest
@testable import OpenGlasses

/// `GlassesConnectionService` driven through a fake `GlassesLinkSource` — never `Wearables`, which
/// fatals in the test process. Covers the published truth (`phase`, `isConnected`, battery), the
/// per-device listener lifecycle, and the Meta camera permission: read when registration lands,
/// asked for only by the wearer (Plan HX P3).
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

    /// The Meta camera permission, faked. Every call is recorded with whether it was allowed to
    /// ask, which is how "launch never asks" is counted.
    @MainActor
    final class FakePermissionSource: GlassesCameraPermissionSource {
        /// What a read finds.
        var standing: GlassesCameraPermission = .notGranted
        /// What Meta AI answers when asked. Asking is only reached when the read is not a grant.
        var answer: GlassesCameraPermission = .granted
        private(set) var calls: [Bool] = []
        var asks: Int { calls.filter { $0 }.count }
        var reads: Int { calls.filter { !$0 }.count }
        /// Hold a read open until the test lets it go.
        var gate: CheckedContinuation<Void, Never>?
        var holdsReads = false

        func cameraPermission(asking: Bool) async -> GlassesCameraPermission {
            calls.append(asking)
            if !asking, holdsReads {
                await withCheckedContinuation { gate = $0 }
            }
            if standing.isGranted || !asking { return standing }
            standing = answer
            return answer
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
        XCTAssertEqual(service.connectionStatus, "Glasses out of reach")

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

    // MARK: - Why not connected, and the camera permission (Plan HX P3)

    private func makeRegistered(_ permissions: FakePermissionSource,
                                devices: [String] = []) async -> (GlassesConnectionService, FakeLinkSource) {
        let source = FakeLinkSource()
        source.registration = .registered
        source.devices = devices
        let service = make(source)
        service.permissionSource = permissions
        await service.pendingPermissionCheck?.value
        return (service, source)
    }

    func testRegisteredWithNothingListedSaysThePermissionIsNeededNotJustNotConnected() async {
        let permissions = FakePermissionSource()
        let (service, _) = await makeRegistered(permissions)
        XCTAssertEqual(service.phase, .addedDisconnected, "the phase is what it always was")
        XCTAssertEqual(service.cameraPermission, .notGranted)
        XCTAssertEqual(service.reachability.diagnosis, .permissionNeeded)
        XCTAssertEqual(service.connectionStatus, "Allow camera access in Meta AI")
    }

    func testTheStatusLineFollowsTheDiagnosisWhereThePhaseDoesNotMove() async {
        let permissions = FakePermissionSource()
        permissions.standing = .granted
        let (service, source) = await makeRegistered(permissions)
        XCTAssertEqual(service.reachability.diagnosis, .noDeviceSeen)
        XCTAssertEqual(service.connectionStatus, "Waiting for Meta AI to show your glasses…")

        var phases: [GlassesConnectionPhase] = []
        let token = service.$phase.dropFirst().sink { phases.append($0) }
        source.sendDevices(["a"])
        token.cancel()
        XCTAssertTrue(phases.isEmpty, "a device being listed leaves the phase at added-but-away")
        XCTAssertEqual(service.reachability.diagnosis, .linkDown)
        XCTAssertEqual(service.reachability.links, [.disconnected])
        XCTAssertEqual(service.connectionStatus, "Glasses out of reach")
    }

    func testReachabilityIsPublishedBeforeThePhaseItGoesWith() {
        let source = FakeLinkSource()
        let service = make(source)
        source.sendDevices(["a"])
        var seen: [GlassesReachabilityDiagnosis] = []
        let token = service.$phase.dropFirst().sink { _ in seen.append(service.reachability.diagnosis) }
        source.sendState("a", connected())
        token.cancel()
        XCTAssertEqual(seen, [.connected])
    }

    /// The diagnosis is a reading. Whatever the permission says, only a link makes the glasses
    /// connected.
    func testAGrantedPermissionNeverMakesTheGlassesConnected() async {
        let permissions = FakePermissionSource()
        permissions.standing = .granted
        let (service, source) = await makeRegistered(permissions, devices: ["a"])
        XCTAssertEqual(service.cameraPermission, .granted)
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.phase, .addedDisconnected)
        service.noteCameraPermission(.declined)
        source.sendState("a", connected())
        XCTAssertTrue(service.isConnected, "and a permission that reads missing never unmakes a link")
        XCTAssertEqual(service.reachability.diagnosis, .connected)
    }

    // The launch paths: none of them asks.

    func testRegistrationAlreadyLandedAtLaunchReadsThePermissionAndNeverAsks() async {
        let permissions = FakePermissionSource()
        let (service, _) = await makeRegistered(permissions)
        XCTAssertEqual(permissions.calls, [false], "one read, when the source is wired, and no request")
        XCTAssertEqual(service.cameraPermission, .notGranted)
    }

    func testRegistrationLandingAfterLaunchReadsThePermissionAndNeverAsks() async {
        let permissions = FakePermissionSource()
        let source = FakeLinkSource()
        let service = make(source)
        service.permissionSource = permissions
        await service.pendingPermissionCheck?.value
        XCTAssertTrue(permissions.calls.isEmpty, "nothing to read about an app that is not registered")

        source.sendRegistration(.registering)
        await service.pendingPermissionCheck?.value
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertEqual(service.reachability.diagnosis, .awaitingApproval)

        source.sendRegistration(.registered)
        await service.pendingPermissionCheck?.value
        XCTAssertEqual(permissions.calls, [false])
        XCTAssertEqual(service.reachability.diagnosis, .permissionNeeded)
    }

    /// Registration has been seen dipping and returning during a healthy session. Each return
    /// used to be a chance to be thrown into Meta AI; now it is a read.
    func testARegistrationBounceReadsAgainAndNeverAsks() async {
        let permissions = FakePermissionSource()
        let (service, source) = await makeRegistered(permissions)
        source.sendRegistration(.registered)
        await service.pendingPermissionCheck?.value
        XCTAssertEqual(permissions.calls, [false], "the same state again is not registration landing")

        source.sendRegistration(.notRegistered)
        source.sendRegistration(.registered)
        await service.pendingPermissionCheck?.value
        XCTAssertEqual(permissions.calls, [false, false])
        XCTAssertEqual(permissions.asks, 0)
    }

    func testADeviceListThatEmptiesReadsThePermissionAgainAndNeverAsks() async {
        let permissions = FakePermissionSource()
        permissions.standing = .granted
        let (service, source) = await makeRegistered(permissions, devices: ["a"])
        XCTAssertEqual(service.reachability.diagnosis, .linkDown)

        permissions.standing = .notGranted          // taken back in Meta AI
        source.sendDevices([])
        await service.pendingPermissionCheck?.value
        XCTAssertEqual(permissions.calls, [false, false])
        XCTAssertEqual(service.reachability.diagnosis, .permissionNeeded,
                       "not \"granted, waiting for Meta AI\" on the strength of an old reading")
    }

    func testOpeningTheGlassesScreenReadsAgainUnlessTheGlassesAreConnected() async {
        let permissions = FakePermissionSource()
        let (service, source) = await makeRegistered(permissions, devices: ["a"])
        permissions.standing = .granted             // allowed in Meta AI since launch
        await service.checkCameraPermission()
        XCTAssertEqual(permissions.calls, [false, false])
        XCTAssertEqual(service.cameraPermission, .granted)

        source.sendState("a", connected())
        await service.checkCameraPermission()
        XCTAssertEqual(permissions.calls, [false, false], "connected glasses are past the permission")
    }

    func testTwoTriggersWhileAReadIsOpenAreOneRead() async {
        let permissions = FakePermissionSource()
        permissions.holdsReads = true
        let source = FakeLinkSource()
        source.registration = .registered
        source.devices = ["a"]
        let service = make(source)
        service.permissionSource = permissions
        source.sendDevices([])                      // a second trigger, with the first still open
        while permissions.gate == nil { await Task.yield() }
        XCTAssertEqual(permissions.calls, [false])
        permissions.gate?.resume()
        await service.pendingPermissionCheck?.value
        XCTAssertEqual(permissions.calls, [false])
        XCTAssertNil(service.pendingPermissionCheck)
    }

    func testNothingIsReadBeforeObservingOrWithoutASource() async {
        let source = FakeLinkSource()
        source.registration = .registered
        let unobserved = make(source, observe: false)
        let permissions = FakePermissionSource()
        unobserved.permissionSource = permissions
        await unobserved.checkCameraPermission()
        XCTAssertTrue(permissions.calls.isEmpty, "an unconfigured SDK is never reached for a permission")

        let unwired = make(source)
        await unwired.checkCameraPermission()
        XCTAssertEqual(unwired.cameraPermission, .notChecked)
        XCTAssertEqual(unwired.reachability.diagnosis, .permissionNeeded)
    }

    // The wearer's own request.

    func testAConnectOnARegisteredUngrantedPairAsksOnce() async {
        let permissions = FakePermissionSource()
        let (service, _) = await makeRegistered(permissions)
        XCTAssertEqual(permissions.asks, 0)

        await service.requestCameraAccessForConnect()
        XCTAssertEqual(permissions.asks, 1, "asked once, inside the Connect the wearer pressed")
        XCTAssertEqual(service.cameraPermission, .granted)
        XCTAssertEqual(service.reachability.diagnosis, .noDeviceSeen)
        XCTAssertEqual(service.connectionStatus, "Waiting for Meta AI to show your glasses…")
    }

    func testAConnectThatIsDeclinedAsksOnceAndKeepsTheAnswer() async {
        let permissions = FakePermissionSource()
        permissions.answer = .declined
        let (service, _) = await makeRegistered(permissions)
        await service.requestCameraAccessForConnect()
        XCTAssertEqual(permissions.asks, 1, "a refusal is an answer, not a reason to open Meta AI again")
        XCTAssertEqual(service.cameraPermission, .declined)
        XCTAssertEqual(service.reachability.diagnosis, .permissionNeeded)
        XCTAssertTrue(service.reachability.waitsOnCameraAccess)
        XCTAssertEqual(service.connectionStatus, "Allow camera access in Meta AI")
    }

    func testAConnectWhoseRequestFailsAsksOnceAndKeepsTheSummary() async {
        let permissions = FakePermissionSource()
        let failure = GlassesCameraPermission.failed(
            SafeErrorSummary(category: .timedOut, detail: PrivacyToken("requestTimeout")))
        permissions.answer = failure
        let (service, _) = await makeRegistered(permissions)
        await service.requestCameraAccessForConnect()
        XCTAssertEqual(permissions.asks, 1, "a request that fails is not retried into Meta AI")
        XCTAssertEqual(service.cameraPermission, failure)
        XCTAssertEqual(service.reachability.reportLine,
                       "Glasses link: permissionNeeded — registration registered, devices listed 0, "
                           + "camera permission failed(requestTimeout)")
    }

    func testAConnectAsksNothingOfAnAppThatIsNotRegistered() async {
        let permissions = FakePermissionSource()
        let source = FakeLinkSource()
        let service = make(source)
        service.permissionSource = permissions
        await service.requestCameraAccessForConnect()
        source.sendRegistration(.registering)
        await service.requestCameraAccessForConnect()
        XCTAssertTrue(permissions.calls.isEmpty, "the approval did not land, so there is nothing to ask about")
    }

    func testAConnectAsksNothingOfAPairThatIsAlreadyListed() async {
        let permissions = FakePermissionSource()
        let (service, _) = await makeRegistered(permissions, devices: ["a"])
        await service.requestCameraAccessForConnect()
        XCTAssertEqual(permissions.asks, 0, "a listed device is already past the permission")
        XCTAssertEqual(service.reachability.diagnosis, .linkDown)
    }

    /// `connect()` polls the SDK for registration; the listener that maintains the snapshot is a
    /// main-queue hop behind it. The Connect reads registration back so it does not skip the ask.
    func testAConnectSeesARegistrationTheListenerHasNotDeliveredYet() async {
        let permissions = FakePermissionSource()
        let source = FakeLinkSource()
        let service = make(source)
        service.permissionSource = permissions
        source.registration = .registered           // landed in the SDK; no listener callback yet
        await service.requestCameraAccessForConnect()
        XCTAssertEqual(permissions.asks, 1)
        XCTAssertEqual(service.phase, .addedDisconnected)
    }

    func testAllowCameraAccessAsksOncePerPress() async {
        let permissions = FakePermissionSource()
        permissions.answer = .declined
        let (service, _) = await makeRegistered(permissions)
        let first = await service.requestCameraAccess()
        XCTAssertEqual(first, .declined)
        XCTAssertEqual(permissions.asks, 1)
        permissions.answer = .granted
        let second = await service.requestCameraAccess()
        XCTAssertEqual(second, .granted)
        XCTAssertEqual(permissions.asks, 2, "each press is the wearer asking again")
    }

    func testAPressOnAPermissionThatIsAlreadyGrantedAnswersWithoutLeavingForMetaAI() async {
        let permissions = FakePermissionSource()
        let (service, _) = await makeRegistered(permissions)
        permissions.standing = .granted
        let status = await service.requestCameraAccess()
        XCTAssertEqual(status, .granted)
        XCTAssertEqual(service.cameraPermission, .granted)
    }

    func testWhatACameraStartLearnedIsKept() async {
        let permissions = FakePermissionSource()
        let (service, _) = await makeRegistered(permissions)
        var published: [GlassesCameraPermission] = []
        let token = service.$cameraPermission.dropFirst().sink { published.append($0) }
        service.noteCameraPermission(.granted)
        service.noteCameraPermission(.granted)
        token.cancel()
        XCTAssertEqual(published, [.granted], "published on change")
        XCTAssertEqual(service.reachability.diagnosis, .noDeviceSeen)
        XCTAssertEqual(permissions.asks, 0)
    }

    func testStopObservingForgetsThePermissionToo() async {
        let permissions = FakePermissionSource()
        permissions.standing = .granted
        let (service, _) = await makeRegistered(permissions)
        service.stopObserving()
        XCTAssertEqual(service.cameraPermission, .notChecked)
        XCTAssertEqual(service.reachability, GlassesReachability())
    }

    /// The wiring `AppState` makes, without `AppState`: the camera is the permission source, and
    /// what a camera start learned on its way comes back through the camera's hand-over.
    func testTheCameraIsThePermissionSourceAndHandsOnWhatAStartLearned() async {
        let backend = MockCameraBackend()
        let camera = CameraService(backend: backend, phoneCamera: MockPhoneCamera())
        let source = FakeLinkSource()
        source.registration = .registered
        let service = make(source)
        service.permissionSource = camera
        camera.onGlassesCameraPermission = { [weak service] in service?.noteCameraPermission($0) }
        await service.pendingPermissionCheck?.value
        XCTAssertEqual(backend.permissionCalls, [false], "launch read it through the camera")
        XCTAssertEqual(service.reachability.diagnosis, .permissionNeeded)

        await service.requestCameraAccessForConnect()
        XCTAssertEqual(backend.permissionCalls, [false, true], "and the Connect asked once")
        XCTAssertEqual(service.reachability.diagnosis, .noDeviceSeen)

        backend.events.send(.cameraPermission(.declined))
        XCTAssertEqual(service.cameraPermission, .declined)
        XCTAssertEqual(service.reachability.diagnosis, .permissionNeeded)
        XCTAssertFalse(service.isConnected)
    }
}
