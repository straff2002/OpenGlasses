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
        // Don't call observeDevices() here — Wearables.configure() may not
        // have been called yet (deferred until after onboarding).
        // Call startObserving() explicitly after Wearables is configured.
        if Config.hasCompletedOnboarding {
            observeDevices()
        }
    }

    /// Begin observing connected devices. Call after Wearables.configure().
    func startObserving() {
        guard devicesListenerToken == nil else { return }
        observeDevices()
    }

    private func observeDevices() {
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
        connectionStatus = "Registering..."
        let stateBefore = Wearables.shared.registrationState
        print("📋 Registration state before: \(stateBefore)")

        do {
            try await Wearables.shared.startRegistration()

            // Poll registration state — can take up to ~10s on fresh install
            var stateAfter = Wearables.shared.registrationState
            let deadline = ContinuousClock.now + .seconds(10)
            while stateAfter.rawValue < 3, ContinuousClock.now < deadline {
                connectionStatus = "Registering… (state \(stateAfter.rawValue))"
                try? await Task.sleep(nanoseconds: 500_000_000)
                stateAfter = Wearables.shared.registrationState
            }

            print("✅ startRegistration() succeeded, state: \(stateAfter)")
            connectionStatus = stateAfter.rawValue >= 3
                ? "Waiting for device..."
                : "Complete authorization in Meta AI app"
        } catch {
            print("❌ startRegistration() failed: \(error)")
            connectionStatus = "Connection failed: \(error.localizedDescription)"
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
