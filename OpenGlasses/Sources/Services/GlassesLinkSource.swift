import Foundation
import MWDATCore

/// Where `GlassesConnectionService` hears about registration, the device list and each device's
/// state. The production source is the Meta SDK (`WearablesGlassesLinkSource`); tests inject a
/// fake, because `Wearables` fatals in the test process.
///
/// Callbacks arrive on the main actor, in the order the source produced them.
@MainActor
protocol GlassesLinkSource: AnyObject {
    /// Make the source usable (configures the SDK on demand). `false` when it cannot be.
    func activate() -> Bool
    var registration: GlassesRegistration { get }
    var devices: [String] { get }
    func deviceName(for id: String) -> String?
    func observeRegistration(_ onChange: @escaping @MainActor @Sendable (GlassesRegistration) -> Void) -> GlassesLinkObservation
    func observeDevices(_ onChange: @escaping @MainActor @Sendable ([String]) -> Void) -> GlassesLinkObservation
    /// Observe one device's state: delivered once promptly, then on every change. `nil` when the
    /// source does not know the device.
    func observeDeviceState(for id: String,
                            _ onChange: @escaping @MainActor @Sendable (GlassesDeviceState) -> Void) -> GlassesLinkObservation?
}

/// A subscription that can be ended.
@MainActor
protocol GlassesLinkObservation: AnyObject {
    func cancel()
}

// MARK: - Meta SDK

/// The Meta DAT SDK as a `GlassesLinkSource`. The only place the SDK's `LinkState`,
/// `ChargingState`, `DonState`, `ThermalLevel`, `Compatibility` and `RegistrationState` are mapped
/// onto the app's own enums.
///
/// Uses `Device.addDeviceStateListener(_:)` (MWDATCore 1.0.0, stable API): one listener per device
/// delivers the full `DeviceState` — link, battery, charging, worn, thermal level, compatibility —
/// immediately and on every change.
@MainActor
final class WearablesGlassesLinkSource: GlassesLinkSource {
    func activate() -> Bool { WearablesBootstrap.ensureConfigured() }

    var registration: GlassesRegistration {
        GlassesRegistration(stateRaw: Wearables.shared.registrationState.rawValue)
    }

    var devices: [String] { Wearables.shared.devices }

    func deviceName(for id: String) -> String? {
        Wearables.shared.deviceForIdentifier(id)?.name
    }

    func observeRegistration(_ onChange: @escaping @MainActor @Sendable (GlassesRegistration) -> Void) -> GlassesLinkObservation {
        let token = Wearables.shared.addRegistrationStateListener { state in
            let mapped = GlassesRegistration(stateRaw: state.rawValue)
            Self.deliver { onChange(mapped) }
        }
        return SDKListenerObservation(token)
    }

    func observeDevices(_ onChange: @escaping @MainActor @Sendable ([String]) -> Void) -> GlassesLinkObservation {
        let token = Wearables.shared.addDevicesListener { ids in
            Self.deliver { onChange(ids) }
        }
        return SDKListenerObservation(token)
    }

    func observeDeviceState(for id: String,
                            _ onChange: @escaping @MainActor @Sendable (GlassesDeviceState) -> Void) -> GlassesLinkObservation? {
        guard let device = Wearables.shared.deviceForIdentifier(id) else { return nil }
        // Seed from the accessors first, so the phase is right even before the listener's own
        // first delivery lands. Both go through the same FIFO hop, so the seed cannot overtake it.
        let seed = GlassesDeviceState(link: Self.map(device.linkState),
                                      batteryLevel: device.batteryLevel,
                                      charging: Self.map(device.chargingState),
                                      worn: Self.map(device.donState),
                                      thermal: Self.map(device.thermalLevel),
                                      compatibility: Self.map(device.compatibility()))
        Self.deliver { onChange(seed) }
        let token = device.addDeviceStateListener { state in
            let mapped = GlassesDeviceState(link: Self.map(state.linkState),
                                            batteryLevel: state.batteryLevel,
                                            charging: Self.map(state.chargingState),
                                            worn: Self.map(state.donState),
                                            thermal: Self.map(state.thermalLevel),
                                            compatibility: Self.map(state.compatibility))
            Self.deliver { onChange(mapped) }
        }
        return SDKListenerObservation(token)
    }

    /// SDK listeners fire on SDK threads. `DispatchQueue.main` keeps their order — two quick
    /// link changes (connecting → connected) must not land the wrong way round, which separate
    /// `Task`s would not promise.
    nonisolated private static func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    nonisolated static func map(_ link: LinkState) -> GlassesLinkState {
        switch link {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        }
    }

    /// `DonState` (MWDATCore 1.0.0, stable): donned → worn, doffed → not, unknown → nil.
    nonisolated static func map(_ don: DonState) -> Bool? {
        switch don {
        case .donned: return true
        case .doffed: return false
        case .unknown: return nil
        }
    }

    nonisolated static func map(_ charging: ChargingState) -> GlassesChargingState {
        switch charging {
        case .unknown: return .unknown
        case .charging: return .charging
        case .notCharging: return .notCharging
        }
    }

    /// `ThermalLevel` (MWDATCore 1.0.0, stable, frozen): case for case, with unknown → nil.
    nonisolated static func map(_ thermal: ThermalLevel) -> GlassesThermal? {
        switch thermal {
        case .unknown: return nil
        case .none: return .normal
        case .light: return .light
        case .moderate: return .moderate
        case .severe: return .severe
        case .critical: return .critical
        case .emergency: return .emergency
        case .shutdown: return .shutdown
        }
    }

    /// `Compatibility` (MWDATCore 1.0.0, stable). Not frozen: a case a later SDK adds reads as
    /// the glasses not having said, which asks nothing of the wearer.
    nonisolated static func map(_ compatibility: Compatibility) -> GlassesCompatibility {
        switch compatibility {
        case .undefined: return .undefined
        case .compatible: return .compatible
        case .deviceUpdateRequired: return .deviceUpdateRequired
        case .sdkUpdateRequired: return .sdkUpdateRequired
        @unknown default: return .undefined
        }
    }
}

/// One SDK listener token. `AnyListenerToken.cancel()` is async; ending a subscription is not
/// something a caller should have to wait for, and the service ignores anything a cancelled
/// listener still delivers.
@MainActor
private final class SDKListenerObservation: GlassesLinkObservation {
    private var token: (any AnyListenerToken)?

    init(_ token: any AnyListenerToken) { self.token = token }

    func cancel() {
        guard let token else { return }
        self.token = nil
        Task { await token.cancel() }
    }
}
