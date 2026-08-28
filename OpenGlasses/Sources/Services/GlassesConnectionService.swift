import Foundation
import MWDATCore

/// Service for connecting to Ray-Ban Meta smart glasses
/// Uses Meta Wearables Device Access Toolkit (MWDAT)
@MainActor
class GlassesConnectionService: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var connectionStatus: String = "Not connected"
    @Published var deviceName: String?
    @Published var batteryLevel: Int?

    private var devicesListenerToken: (any AnyListenerToken)?
    private var connectedDeviceId: DeviceIdentifier?

    init() {
        // Only observe when the user is past onboarding, so the SDK's Bluetooth prompt still waits
        // until they've reached for the glasses. `isPastOnboarding` rather than
        // `hasCompletedOnboarding`: the narrower flag left anyone who saved an API key without
        // finishing onboarding with this listener permanently unarmed, so even a registration that
        // completed would never surface as connected.
        if Config.isPastOnboarding {
            observeDevices()
        }
    }

    /// Begin observing connected devices. Configures the SDK on demand — callers are not required
    /// to have done it first.
    func startObserving() {
        guard devicesListenerToken == nil else { return }
        observeDevices()
    }

    private func observeDevices() {
        guard WearablesBootstrap.ensureConfigured() else {
            connectionStatus = "Meta SDK unavailable"
            return
        }
        devicesListenerToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
            Task { @MainActor in
                self?.handleDevicesChanged(deviceIds)
            }
        }
    }

    private func handleDevicesChanged(_ deviceIds: [DeviceIdentifier]) {
        if let firstId = deviceIds.first {
            let device = Wearables.shared.deviceForIdentifier(firstId)
            connectedDeviceId = firstId
            isConnected = true
            deviceName = device?.name
            connectionStatus = "Connected to \(device?.nameOrId() ?? "glasses")"
        } else {
            connectedDeviceId = nil
            isConnected = false
            deviceName = nil
            batteryLevel = nil
            connectionStatus = "Disconnected"
        }
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
        print("📋 Registration state before: \(stateBefore)")

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
                print("📋 Already registered — continuing to connect")
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

            print("✅ startRegistration() succeeded, state: \(stateAfter)")
            connectionStatus = RegistrationFlow.status(stateRaw: stateAfter.rawValue)
        } catch {
            // `startRegistration()` uses typed throws, so every error reaching this catch is a
            // `RegistrationError`; testing the type again is both redundant and a Swift 6 warning.
            print("❌ startRegistration() failed: \(error)")
            let message = RegistrationFlow.registrationErrorMessage(error)
            connectionStatus = message
            NoticeCenter.shared.post(message, severity: .error, source: .glasses)
        }
    }

    func disconnect() {
        connectedDeviceId = nil
        isConnected = false
        deviceName = nil
        batteryLevel = nil
        connectionStatus = "Disconnected"
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
