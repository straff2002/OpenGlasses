import Foundation

/// Which device the settings hub's hero card shows (Plan HA C3). Pure, over the glasses' truthful
/// link phase (`GlassesConnectionPhase`) — never over "were glasses ever added".
///
/// The rule: **the glasses card only while the glasses are attached** — the link is up (including
/// "Connected · paused", where the wearer stood the app down but the glasses are still there) or
/// coming up (`connecting`, the moment after a tap on Connect). Otherwise this iPhone is the device
/// in use, and the card says so. A pair in its case is not the device anyone is using; showing it
/// as "Not connected" at the top of Settings read as a fault.
///
/// Glasses settings stay reachable either way: Devices & Privacy › Glasses is a row whatever the
/// link is doing, and the iPhone card says the glasses are not connected when glasses are part of
/// this person's setup, so the absence is stated rather than implied.
enum SettingsHeroDevice: Equatable, Sendable {
    /// This iPhone. `glassesAway` is true when glasses are added but not attached.
    case phone(glassesAway: Bool)
    case glasses

    static func resolve(phase: GlassesConnectionPhase, glassesAdded: Bool) -> SettingsHeroDevice {
        switch phase {
        case .connected, .connecting:
            return .glasses
        case .noGlassesAdded, .addedDisconnected:
            return .phone(glassesAway: glassesAdded)
        }
    }

    /// The iPhone card's status line.
    var phoneStatus: String? {
        guard case .phone(let away) = self else { return nil }
        return away ? "In use · Glasses not connected" : "In use"
    }
}
