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

    private var wearableDevice: WearableDevice?

    init() {
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .wearableDeviceDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleDeviceConnected(notification)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .wearableDeviceDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDeviceDisconnected()
            }
        }
    }

    func connect() async throws {
        connectionStatus = "Connecting..."

        do {
            // Request connection through Meta View app
            try await Wearables.requestConnection()
            connectionStatus = "Waiting for device..."
        } catch {
            connectionStatus = "Connection failed"
            throw GlassesError.connectionFailed(error.localizedDescription)
        }
    }

    func disconnect() {
        wearableDevice = nil
        isConnected = false
        deviceName = nil
        batteryLevel = nil
        connectionStatus = "Disconnected"
    }

    private func handleDeviceConnected(_ notification: Notification) {
        guard let device = notification.object as? WearableDevice else { return }

        wearableDevice = device
        isConnected = true
        deviceName = device.name
        connectionStatus = "Connected to (device.name ?? "glasses")"

        // Start monitoring battery
        Task {
            await monitorBattery()
        }
    }

    private func handleDeviceDisconnected() {
        isConnected = false
        deviceName = nil
        batteryLevel = nil
        connectionStatus = "Disconnected"
    }

    private func monitorBattery() async {
        guard let device = wearableDevice else { return }

        do {
            let battery = try await device.getBatteryLevel()
            batteryLevel = battery
        } catch {
            print("Failed to get battery level: (error)")
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let wearableDeviceDidConnect = Notification.Name("WearableDeviceDidConnect")
    static let wearableDeviceDidDisconnect = Notification.Name("WearableDeviceDidDisconnect")
}

// MARK: - Errors
enum GlassesError: LocalizedError {
    case connectionFailed(String)
    case notConnected
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: (msg)"
        case .notConnected: return "Glasses not connected"
        case .streamingFailed(let msg): return "Streaming failed: (msg)"
        }
    }
}
