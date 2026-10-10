import Foundation
import MWDATCore

/// The glasses' connection: registration with Meta AI, and whether a pair is actually reachable.
/// Uses Meta Wearables Device Access Toolkit (MWDAT) through `GlassesLinkSource`.
///
/// The single source of truth for "are the glasses connected". `phase` is folded from what the
/// SDK reports (`GlassesConnectionSnapshot`); `isConnected`, `deviceName`, `batteryLevel`,
/// `isCharging`, `isWorn`, `thermal` and `compatibility` are derived from it and never written
/// anywhere else. Registration and the SDK's
/// device list mean glasses are *added*; only a device's link state `.connected` means connected.
///
/// It also keeps the Meta camera permission's last known status and, from that and the snapshot,
/// publishes `reachability`: why added glasses are not connected (Plan HX P3). That is a reading
/// beside the phase, never an input to it.
@MainActor
class GlassesConnectionService: ObservableObject {
    /// Where the glasses are, from "never added" to "connected".
    @Published private(set) var phase: GlassesConnectionPhase = .noGlassesAdded
    /// `phase == .connected`. Derived — there is no other writer.
    @Published private(set) var isConnected: Bool = false
    @Published var connectionStatus: String = "Not connected"
    @Published private(set) var deviceName: String?
    /// The active device's battery, only while the link is up (`liveBatteryLevel`): a pair in its
    /// case shows no battery rather than a stale one.
    @Published private(set) var batteryLevel: Int?
    /// Whether the active device is charging, only while the link is up.
    @Published private(set) var isCharging: Bool = false
    /// Whether the active device is on someone's face, only while the link is up; nil when the
    /// device does not say or the glasses are away.
    @Published private(set) var isWorn: Bool?
    /// How hot the active device says it is, only while the link is up; nil when the device does
    /// not say or the glasses are away, so `PowerPolicyService` never holds a posture on a
    /// reading from glasses it can no longer hear.
    @Published private(set) var thermal: GlassesThermal?
    /// Whether the active device and this build can work together, only while the link is up.
    /// `.undefined` is the glasses not having said; nil is the glasses being away.
    @Published private(set) var compatibility: GlassesCompatibility?
    /// The Meta camera permission as last read or asked for. Written here and nowhere else: by
    /// the checks this service makes when registration lands, by the wearer's own request, and by
    /// what a camera start learned (`noteCameraPermission(_:)`).
    @Published private(set) var cameraPermission: GlassesCameraPermission = .notChecked
    /// Registration, each listed device's link and the permission, and the diagnosis that follows
    /// from them (`GlassesReachabilityDiagnosis`). Published whenever any of them changes, which a
    /// phase alone would not show: a device being listed leaves the phase where it was.
    @Published private(set) var reachability = GlassesReachability()

    private(set) var snapshot = GlassesConnectionSnapshot()

    private let source: GlassesLinkSource
    private var serviceObservations: [GlassesLinkObservation] = []
    /// One state subscription per listed device. The generation tells a current subscription's
    /// callback from one whose device left the list (or left and came back) before it fired.
    private struct DeviceObservation {
        let generation: UUID
        var observation: GlassesLinkObservation?
    }
    private var deviceObservations: [String: DeviceObservation] = [:]
    private var isObserving = false

    /// Where the Meta camera permission is read and asked for: the camera, in the app. Set after
    /// init because the camera is built beside this service, not before it; setting it reads the
    /// permission if registration had already landed.
    weak var permissionSource: GlassesCameraPermissionSource? {
        didSet { if permissionSource != nil { checkCameraPermissionSoon() } }
    }
    /// The check in flight, if any. Held so a second trigger does not start a second one, so the
    /// wearer's request can wait for it instead of racing it, and so a test can wait for it.
    private(set) var pendingPermissionCheck: Task<Void, Never>?
    /// The wearer's own request is in flight; it may have left for Meta AI.
    private(set) var isRequestingCameraAccess = false

    /// - Parameters:
    ///   - source: `nil` means the Meta SDK. Built here rather than as a default argument because
    ///     a default argument is evaluated nonisolated and the source is main-actor bound.
    ///   - observeNow: start observing at once. `nil` means "when the user is past onboarding", so
    ///     the SDK's Bluetooth prompt still waits until they've reached for the glasses.
    ///     `isPastOnboarding` rather than `hasCompletedOnboarding`: the narrower flag left anyone
    ///     who saved an API key without finishing onboarding permanently unobserved.
    init(source: GlassesLinkSource? = nil, observeNow: Bool? = nil) {
        self.source = source ?? WearablesGlassesLinkSource()
        if observeNow ?? Config.isPastOnboarding {
            startObserving()
        }
    }

    /// Begin observing registration, the device list and each device's state. Configures the SDK
    /// on demand — callers are not required to have done it first. Idempotent.
    func startObserving() {
        guard !isObserving else { return }
        guard source.activate() else {
            connectionStatus = "Meta SDK unavailable"
            return
        }
        isObserving = true
        registrationChanged(source.registration)
        devicesChanged(source.devices)
        serviceObservations.append(source.observeRegistration { [weak self] registration in
            self?.registrationChanged(registration)
        })
        serviceObservations.append(source.observeDevices { [weak self] ids in
            self?.devicesChanged(ids)
        })
    }

    /// End every subscription and forget what they reported. Teardown, and the test seam for it.
    func stopObserving() {
        serviceObservations.forEach { $0.cancel() }
        serviceObservations.removeAll()
        deviceObservations.values.forEach { $0.observation?.cancel() }
        deviceObservations.removeAll()
        isObserving = false
        pendingPermissionCheck?.cancel()
        pendingPermissionCheck = nil
        cameraPermission = .notChecked
        snapshot = GlassesConnectionSnapshot()
        publish()
    }

    /// Number of live per-device subscriptions — for tests of the listener lifecycle.
    var observedDeviceCount: Int { deviceObservations.count }

    private func registrationChanged(_ registration: GlassesRegistration) {
        let landed = registration == .registered && snapshot.registration != .registered
        apply(.registration(registration))
        // Registration landing is when the permission is worth reading: it is what Meta AI lists
        // a device behind. Read, never asked for (see `checkCameraPermission()`).
        if landed { checkCameraPermissionSoon() }
    }

    private func devicesChanged(_ ids: [String]) {
        PrivacyLog.device(.glasses, ids.isEmpty ? .deviceListEmpty : .deviceListChanged, count: ids.count)
        let listed = Set(ids)
        for (id, entry) in deviceObservations where !listed.contains(id) {
            entry.observation?.cancel()
            deviceObservations.removeValue(forKey: id)
        }
        let emptied = ids.isEmpty && !snapshot.deviceIds.isEmpty
        apply(.devices(ids))
        // A list that empties under a registered app is most often the permission being taken
        // back in Meta AI, so what the app last knew about it is no longer worth showing.
        if emptied { checkCameraPermissionSoon() }
        for id in snapshot.deviceIds where deviceObservations[id] == nil {
            subscribe(to: id)
        }
    }

    private func subscribe(to id: String) {
        let generation = UUID()
        deviceObservations[id] = DeviceObservation(generation: generation, observation: nil)
        apply(.deviceName(id: id, source.deviceName(for: id)))
        let observation = source.observeDeviceState(for: id) { [weak self] state in
            guard let self, self.deviceObservations[id]?.generation == generation else { return }
            self.apply(.deviceState(id: id, state))
        }
        // The source may have delivered synchronously and the device may have been dropped since;
        // only keep the subscription if this generation is still the current one.
        if deviceObservations[id]?.generation == generation {
            deviceObservations[id]?.observation = observation
        } else {
            observation?.cancel()
        }
    }

    private func apply(_ event: GlassesConnectionSnapshot.Event) {
        snapshot.apply(event)
        publish()
    }

    /// Mirror the snapshot into the published properties. Details first and `phase` last, so a
    /// subscriber woken by the phase reads the name and battery that go with it.
    private func publish() {
        let newName = snapshot.activeDeviceName
        if deviceName != newName { deviceName = newName }
        let newBattery = snapshot.liveBatteryLevel
        if batteryLevel != newBattery { batteryLevel = newBattery }
        let newCharging = snapshot.liveCharging == .charging
        if isCharging != newCharging { isCharging = newCharging }
        let newWorn = snapshot.liveWorn
        if isWorn != newWorn { isWorn = newWorn }
        let newThermal = snapshot.liveThermal
        if thermal != newThermal { thermal = newThermal }
        let newCompatibility = snapshot.liveCompatibility
        if compatibility != newCompatibility { compatibility = newCompatibility }
        let newReachability = GlassesReachability(snapshot: snapshot, permission: cameraPermission)
        let newDiagnosis = newReachability.diagnosis
        let diagnosisChanged = reachability.diagnosis != newDiagnosis
        if reachability != newReachability {
            reachability = newReachability
            if diagnosisChanged {
                PrivacyLog.device(.glasses, .reachabilityRead,
                                  state: PrivacyToken.caseName(of: newDiagnosis),
                                  count: newReachability.links.count)
            }
        }
        let newPhase = snapshot.phase
        if isConnected != newPhase.isConnected { isConnected = newPhase.isConnected }
        let newStatus = newDiagnosis.statusLine(deviceName: newName)
        if phase != newPhase {
            phase = newPhase
            connectionStatus = newStatus
        } else if diagnosisChanged {
            // The phase cannot tell "nothing listed" from "listed, out of reach"; the line can.
            connectionStatus = newStatus
        } else if newPhase == .connected, connectionStatus != newStatus {
            // The name can arrive after the link does.
            connectionStatus = newStatus
        }
    }

    // MARK: - Meta camera permission (Plan HX P3)

    /// Read the Meta camera permission, without asking for it, once registration has landed.
    ///
    /// This is all that launch, a registration change and an emptied device list ever do. Asking
    /// deep-links to Meta AI, and before this the registration listener asked whenever it heard
    /// "registered" with the permission not cached — so a launch could leave for another app with
    /// nobody having pressed anything. Asking is `requestCameraAccess()`, the wearer's own.
    ///
    /// Called directly by the screen that shows the diagnosis, each time it opens. Not while a
    /// link is up: connected glasses are past the permission, and there is no line to keep honest.
    func checkCameraPermission() async {
        if !phase.isConnected { checkCameraPermissionSoon() }
        await pendingPermissionCheck?.value
    }

    private func checkCameraPermissionSoon() {
        guard isObserving, snapshot.registration == .registered, pendingPermissionCheck == nil,
              !isRequestingCameraAccess, let permissionSource else { return }
        pendingPermissionCheck = Task { [weak self] in
            let status = await permissionSource.cameraPermission(asking: false)
            guard let self, !Task.isCancelled else { return }
            self.pendingPermissionCheck = nil
            // A request that started meanwhile has the newer answer coming.
            if !self.isRequestingCameraAccess { self.noteCameraPermission(status) }
        }
    }

    /// The wearer's own request, from Connect or from "Allow camera access in Meta AI": read the
    /// permission and, when it is not granted, ask for it in Meta AI. Asked once per call.
    @discardableResult
    func requestCameraAccess() async -> GlassesCameraPermission {
        guard let permissionSource, !isRequestingCameraAccess else { return cameraPermission }
        isRequestingCameraAccess = true
        defer { isRequestingCameraAccess = false }
        await pendingPermissionCheck?.value
        let status = await permissionSource.cameraPermission(asking: true)
        noteCameraPermission(status)
        return status
    }

    /// The permission half of a Connect the wearer pressed: once registration has landed and Meta
    /// AI lists no device, ask. Nothing is asked of a pair that is already listed (it is past the
    /// permission) or of an app that is not registered (there is nothing to ask Meta AI about).
    func requestCameraAccessForConnect() async {
        guard isObserving else { return }
        // Registration is read back rather than waited for: the listener that maintains the
        // snapshot delivers a main-queue hop behind the state `connect()` just polled.
        registrationChanged(source.registration)
        guard reachability.connectShouldAskForCameraAccess else { return }
        connectionStatus = GlassesReachabilityDiagnosis.permissionNeeded.statusLine(deviceName: nil)
        await requestCameraAccess()
        connectionStatus = reachability.diagnosis.statusLine(deviceName: deviceName)
    }

    /// What something else learned about the permission: a camera start checks and asks for it
    /// too, inside the backend, and reports how that ended.
    func noteCameraPermission(_ status: GlassesCameraPermission) {
        guard cameraPermission != status else { return }
        var failure: SafeErrorSummary?
        if case .failed(let summary) = status { failure = summary }
        PrivacyLog.device(.glasses, .cameraPermissionRead,
                          state: PrivacyToken.caseName(of: status), error: failure)
        cameraPermission = status
        publish()
    }

    func connect() async {
        // Configure here rather than assuming a caller did. This is the path that used to kill the
        // app outright: an unconfigured `Wearables.shared` is a fatalError, not a throw.
        guard WearablesBootstrap.ensureConfigured() else {
            connectionStatus = "Meta SDK unavailable — \(WearablesBootstrap.failureReason ?? "not configured")"
            return
        }
        // The listener may never have been armed (SDK unconfigured at init); arm it now.
        startObserving()
        connectionStatus = "Registering..."
        let stateBefore = Wearables.shared.registrationState
        PrivacyLog.device(.glasses, .registrationStarted,
                          state: PrivacyToken(String(stateBefore.rawValue)))

        do {
            do {
                try await Wearables.shared.startRegistration()
            } catch RegistrationError.alreadyRegistered {
                // Not a failure — it is the precondition for success, and it is the *normal* state
                // on every connect after the first. Treating it as an error skipped the whole path
                // below, so a wearer whose glasses dropped mid-session could press Connect forever
                // and get "Connection failed: User is already registered" each time: the one state
                // from which reconnecting is guaranteed possible was the one state we refused to
                // reconnect from. Device-traced 2026-08-23, after a glasses disconnect mid-reply.
                PrivacyLog.device(.glasses, .alreadyRegistered)
            }

            // Poll registration state. `startRegistration()` returns before the user approves the
            // app in the Meta AI companion app, and that approval has been seen to take ~25s — so
            // wait that long (RegistrationFlow policy) and, throughout, show an actionable "approve
            // in Meta AI" status instead of giving up early with a cryptic internal state number.
            var stateAfter = Wearables.shared.registrationState
            let deadline = ContinuousClock.now + .seconds(RegistrationFlow.approvalDeadlineSeconds)
            while !RegistrationFlow.isRegistered(stateRaw: stateAfter.rawValue), ContinuousClock.now < deadline {
                connectionStatus = RegistrationFlow.status(stateRaw: stateAfter.rawValue)
                try? await Task.sleep(nanoseconds: 500_000_000)
                stateAfter = Wearables.shared.registrationState
            }

            PrivacyLog.device(.glasses, .registrationState,
                              state: PrivacyToken(String(stateAfter.rawValue)))
            // Registered says nothing about the link: a pair already connected keeps saying so,
            // and for one that is not, the diagnosis says what it is waiting on.
            if RegistrationFlow.isRegistered(stateRaw: stateAfter.rawValue) {
                if isObserving { registrationChanged(source.registration) }
                connectionStatus = reachability.diagnosis.statusLine(deviceName: deviceName)
            } else if phase.isConnected {
                connectionStatus = reachability.diagnosis.statusLine(deviceName: deviceName)
            } else {
                connectionStatus = RegistrationFlow.approvalTimedOutStatus()
            }
        } catch {
            // `startRegistration()` uses typed throws, so every error reaching this catch is a
            // `RegistrationError`; testing the type again is both redundant and a Swift 6 warning.
            PrivacyLog.device(.glasses, .registrationFailed, error: SafeErrorSummary(error))
            let message = RegistrationFlow.registrationErrorMessage(error)
            connectionStatus = message
            NoticeCenter.shared.post(message, severity: .error, source: .glasses)
        }
    }
}

// MARK: - Errors
enum GlassesError: LocalizedError {
    case connectionFailed(String)
    case notConnected
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .notConnected: return "Glasses not connected"
        case .streamingFailed(let msg): return "Streaming failed: \(msg)"
        }
    }
}
