import Foundation
import Combine
import MWDATCore

/// Maps the DAT glasses thermal level onto the neutral `ThermalPressure` scale
/// (docs/plans/BV-power-policy.md P2). Lives here rather than in the pure P1 core so that file
/// stays `MWDATCore`-free and headless; the mapping itself is still pure and table-tested.
///
/// DAT's `ThermalLevel` is finer-grained than the phone's four states, so several DAT levels fold
/// into one band. `.unknown` maps to `.nominal` — an unknown glasses reading must never *raise*
/// posture (every glasses input is optional and a missing signal can't force a downgrade).
extension ThermalPressure {
    init(_ level: MWDATCore.ThermalLevel) {
        switch level {
        case .unknown, .none, .light:
            self = .nominal
        case .moderate:
            self = .fair
        case .severe:
            self = .serious
        case .critical, .emergency, .shutdown:
            self = .critical
        @unknown default:
            self = .nominal
        }
    }
}

/// The one power API the rest of the app reads (docs/plans/BV-power-policy.md P2). Fuses the live
/// battery/thermal signals into a `PowerPosture` and publishes it, exactly mirroring `PresenceMonitor`
/// (Plan W): signal *sources* are injected closures with neutral defaults so the service is
/// constructible and testable without the app or a device, and `update()` is a deterministic step.
///
/// Consumers subscribe to `$posture` (or read `posture` / `explanation`) and apply it in their own
/// terms — the service never reaches into features. It holds the previous posture so
/// `PowerPolicy.decide` gets its hysteresis input across successive samples.
///
/// **Glasses signals are optional and currently phone-led.** Glasses battery is fed from
/// `GlassesConnectionService` (nil until firmware reports it); glasses thermal (DAT 1.0
/// `Device.thermalLevel`, observed via `Device.addDeviceStateListener`) is not yet observed, so it
/// defaults absent — a phone-only posture, which the plan requires to be useful on its own. When
/// the device-state listener is wired, point `glassesThermal` at it via `ThermalPressure(_ level:)`.
@MainActor
final class PowerPolicyService: ObservableObject {
    static let shared = PowerPolicyService()

    @Published private(set) var posture: PowerPosture = .normal
    /// One-line reason for the current posture, or `nil` in `normal`. For status/tool answers.
    @Published private(set) var explanation: String?

    // Injected signal providers. Defaults describe a healthy, glasses-less phone so the service has
    // sane behaviour before AppState wires the real sources.
    /// Phone battery 0…1, or `nil` when unknown (monitoring off / simulator).
    var phoneBatteryFraction: () -> Double? = { nil }
    var phoneCharging: () -> Bool = { false }
    var phoneThermal: () -> ThermalPressure = { .nominal }
    var glassesBatteryPercent: () -> Int? = { nil }
    var glassesThermal: () -> ThermalPressure? = { nil }
    var lowPowerMode: () -> Bool = { false }

    /// Threshold source; defaults to the Config-backed knobs (overridable in tests).
    var thresholds: () -> PowerPolicy.Thresholds = { Config.powerThresholds }

    init() {}

    /// Sample the current signals and recompute the posture. Idempotent; safe to call often. The
    /// previous posture feeds `PowerPolicy`'s battery hysteresis, so postures don't flap when a
    /// percentage hovers at a threshold.
    func update() {
        let state = PowerState(
            phoneBatteryFraction: phoneBatteryFraction(),
            phoneCharging: phoneCharging(),
            phoneThermal: phoneThermal(),
            glassesBatteryPercent: glassesBatteryPercent(),
            glassesThermal: glassesThermal(),
            lowPowerMode: lowPowerMode()
        )
        let next = PowerPolicy.decide(state, previous: posture, thresholds: thresholds())
        if next != posture { posture = next }
        let reason = PowerPolicy.explanation(state, posture: next)
        if reason != explanation { explanation = reason }
    }
}
