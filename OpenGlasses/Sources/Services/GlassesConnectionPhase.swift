import Foundation

// The glasses' connection, as facts the SDK reports rather than as a flag the app latches.
//
// Pure and SDK-free on purpose: `WearablesGlassesLinkSource` maps the Meta SDK's enums onto the
// ones below at the edge, so every rule here is decided — and tested — without `Wearables`.
//
// The bug this replaces: the app said "connected" whenever registration was complete or the SDK's
// device list was non-empty. Both describe a pair that has been *added* (registered with Meta AI,
// camera permission granted), not one that is reachable — a pair left in its case for days stayed
// "connected" the whole time. Only a device's own link state says the link is up.

/// Registration with Meta AI, reduced to what the connection phase needs.
enum GlassesRegistration: Equatable, Sendable {
    /// Unavailable or available — not registered (raw 0 or 1).
    case notRegistered
    /// A registration is in flight (raw 2).
    case registering
    /// Registered (raw 3 and up).
    case registered

    /// From `RegistrationState.rawValue` — the same raw numbering the rest of the app logs and
    /// compares (`RegistrationFlow.isRegistered`).
    init(stateRaw: Int) {
        switch stateRaw {
        case 3...: self = .registered
        case 2: self = .registering
        default: self = .notRegistered
        }
    }
}

/// One device's link to the phone — the SDK's `LinkState`.
enum GlassesLinkState: Equatable, Sendable {
    case disconnected, connecting, connected
}

/// The SDK's `ChargingState`.
enum GlassesChargingState: Equatable, Sendable {
    case unknown, charging, notCharging
}

/// What the SDK last reported about one device (`DeviceState`), as far as the app reads it.
struct GlassesDeviceState: Equatable, Sendable {
    var link: GlassesLinkState = .disconnected
    /// Percent, when the device reports one.
    var batteryLevel: Int?
    var charging: GlassesChargingState = .unknown
}

/// The app's one answer to "are the glasses connected?".
enum GlassesConnectionPhase: Equatable, Sendable {
    /// Not registered and no device listed: this person has not added glasses (or removed them).
    case noGlassesAdded
    /// Glasses are added — registered, or listed by the SDK — but no link is up: in the case,
    /// switched off, out of range.
    case addedDisconnected
    /// A link is coming up. Not connected: nothing that needs the glasses can run yet.
    case connecting
    /// A device's link is up.
    case connected

    /// The only phase in which the glasses can be used.
    var isConnected: Bool { self == .connected }

    var isConnecting: Bool { self == .connecting }

    /// Whether glasses are part of this person's setup at all, reachable or not.
    var glassesAdded: Bool { self != .noGlassesAdded }

    /// The short status line `GlassesConnectionService.connectionStatus` carries when the phase
    /// changes. "Not connected" is the wording the session card maps to its own headline.
    func statusText(deviceName: String?) -> String {
        switch self {
        case .noGlassesAdded, .addedDisconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected to \(deviceName ?? "glasses")"
        }
    }
}

/// Everything the SDK has told the app about the glasses, and the phase that follows from it.
///
/// A value type driven by events, so the whole mapping is a deterministic fold:
/// registration × device list × per-device state → phase, active device, live battery.
///
/// **Multi-device rule.** Connected when *any* listed device's link is connected; connecting when
/// none is connected and any is connecting. The device the app describes (name, battery) is the
/// first connected device in the SDK's list order, else the first connecting one, else the first
/// listed. The camera session picks its device with `AutoDeviceSelector`, which also chooses among
/// the SDK's devices, so "connected" here does not name a pair the camera could not reach.
///
/// **Registration.** Registration (or a listed device) makes glasses *added*; it never makes them
/// connected. With devices listed, the phase follows their links even if the registration flag
/// reads below registered: unregistering is what empties the SDK's device list, so a revoked
/// registration reaches the phase through that list, while registration has been seen bouncing
/// through lower states during a healthy session — gating the link on it would flap the
/// connection and tear down audio for nothing.
struct GlassesConnectionSnapshot: Equatable, Sendable {
    var registration: GlassesRegistration = .notRegistered
    /// The SDK's device list, in its order.
    private(set) var deviceIds: [String] = []
    /// Last reported state per listed device. A device listed but not yet reported is disconnected.
    private(set) var deviceStates: [String: GlassesDeviceState] = [:]
    private(set) var deviceNames: [String: String] = [:]

    enum Event: Equatable, Sendable {
        case registration(GlassesRegistration)
        case devices([String])
        case deviceState(id: String, GlassesDeviceState)
        case deviceName(id: String, String?)
    }

    init(registration: GlassesRegistration = .notRegistered) {
        self.registration = registration
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .registration(let registration):
            self.registration = registration
        case .devices(let ids):
            // De-duplicated, order kept. A device that left the list takes its state and name with
            // it, so a pair removed while connected cannot keep the link up from memory.
            var seen = Set<String>()
            deviceIds = ids.filter { seen.insert($0).inserted }
            deviceStates = deviceStates.filter { seen.contains($0.key) }
            deviceNames = deviceNames.filter { seen.contains($0.key) }
        case .deviceState(let id, let state):
            // A late report for a device no longer listed (its listener was cancelled but had
            // already fired) must not resurrect it.
            guard deviceIds.contains(id) else { return }
            deviceStates[id] = state
        case .deviceName(let id, let name):
            guard deviceIds.contains(id) else { return }
            deviceNames[id] = name
        }
    }

    func state(of id: String) -> GlassesDeviceState {
        deviceStates[id] ?? GlassesDeviceState()
    }

    var phase: GlassesConnectionPhase {
        if deviceIds.isEmpty {
            return registration == .registered ? .addedDisconnected : .noGlassesAdded
        }
        let links = deviceIds.map { state(of: $0).link }
        if links.contains(.connected) { return .connected }
        if links.contains(.connecting) { return .connecting }
        return .addedDisconnected
    }

    /// The device the app describes. See the multi-device rule above.
    var activeDeviceId: String? {
        deviceIds.first { state(of: $0).link == .connected }
            ?? deviceIds.first { state(of: $0).link == .connecting }
            ?? deviceIds.first
    }

    var activeDeviceName: String? {
        activeDeviceId.flatMap { deviceNames[$0] }
    }

    /// Battery shown as live only while the link is up. A pair in its case reports nothing new,
    /// and a percentage from days ago presented beside the device is the same lie as "connected" —
    /// so it is hidden, not shown as last known.
    var liveBatteryLevel: Int? {
        guard phase == .connected, let id = activeDeviceId else { return nil }
        return state(of: id).batteryLevel
    }

    /// Charging, under the same rule as the battery: only while connected, else unknown.
    var liveCharging: GlassesChargingState {
        guard phase == .connected, let id = activeDeviceId else { return .unknown }
        return state(of: id).charging
    }
}
