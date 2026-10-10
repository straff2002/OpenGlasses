import Foundation

/// Normalised thermal pressure, shared by the phone (`ProcessInfo.ThermalState`) and the glasses
/// (DAT `ThermalLevel`) so the fusion table reasons over one scale (docs/plans/BV-power-policy.md).
///
/// Four bands, ordered least→most severe. The phone mapping lives here (Foundation-only, so the
/// core stays headless and testable); the glasses mapping lives beside the P2 wiring in
/// `PowerPolicyService.swift` and takes the app's own `GlassesThermal`, not the SDK's type.
enum ThermalPressure: Int, Comparable, CaseIterable, Equatable {
    case nominal = 0
    case fair
    case serious
    case critical

    static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Map the OS thermal state. `ProcessInfo.ThermalState` is a 1:1 fit by design.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .fair   // an unrecognised state is treated as mild pressure, not ignored
        }
    }
}

/// The power posture the app should operate at. Mirrors the shape of Plan W's `ThrottleDecision`:
/// a small ordered enum the whole app reads, each consumer applying it in its own terms. Presence
/// (Plan W) decides *whether* a loop runs; this decides *how expensively* — they compose.
///
/// Ordered by severity so the fusion can take the worst-case across signals with `max`.
enum PowerPosture: Int, Comparable, CaseIterable, Equatable {
    /// No constraint — full sensing/compute/networking.
    case normal = 0
    /// Battery low on either device, or elevated thermals: snapshot-before-stream, longer idle
    /// teardowns, raised frame-rate floors, prefer the smaller local-model tier.
    case conserve
    /// Critical battery or serious thermals: voice-first — camera only on explicit request, no
    /// continuous streams without confirmation, heartbeats stretched.
    case reserve

    static func < (lhs: PowerPosture, rhs: PowerPosture) -> Bool { lhs.rawValue < rhs.rawValue }

    // MARK: Shared consumer contract
    //
    // The semantic questions consumers ask, so a feature reads intent rather than switching on the
    // enum itself (and the meaning of a posture lives in one place).

    /// Try `latestFrame`/photo before opening a continuous stream.
    var prefersSnapshotOverStream: Bool { self >= .conserve }
    /// Prefer the smaller local-model tier for opportunistic / non-critical work.
    var prefersSmallerLocalModel: Bool { self >= .conserve }
    /// A continuous stream (or live-session start) needs explicit user confirmation first.
    var requiresConfirmationBeforeStream: Bool { self == .reserve }
    /// Plan GU §6 — the wake-word speech gate uses its stricter thresholds (a higher onset over the
    /// noise floor, a shorter recognition tail), so less speech-shaped noise wakes the recognizer.
    var prefersStrictWakeGate: Bool { self >= .conserve }
    /// Plan GU §6 — a *glasses* idle-listening choice is overridden to the phone mic, saving the
    /// glasses' radio. Never applies to a conversation, only to waiting.
    var prefersPhoneWakeMic: Bool { self == .reserve }

    /// Plan HE — a large transfer that nobody is waiting for (a recorded job going to the office)
    /// waits for power. Small traffic — job reports, receipts — is not held by this.
    var defersBulkTransfer: Bool { self >= .conserve }

    /// Multiplier on a live-mode frame-forwarding interval — the posture's lever on the biggest
    /// continuous spender. `1.0` = full rate; higher = fewer frames. Mirrors the shape of Plan W's
    /// `ThrottleDecision.intervalMultiplier`, applied to frame cadence rather than loop cadence.
    var frameIntervalMultiplier: Double {
        switch self {
        case .normal:   return 1.0
        case .conserve: return 2.0
        case .reserve:  return 4.0
        }
    }

    var label: String {
        switch self {
        case .normal:   return "normal"
        case .conserve: return "conserving"
        case .reserve:  return "power reserve"
        }
    }
}

/// The fused power signals at an instant (docs/plans/BV-power-policy.md P1). Every glasses/battery
/// input is optional with an honest default, so a phone-only posture is fully useful on its own
/// and missing firmware signals never force a downgrade.
struct PowerState: Equatable {
    /// Phone battery, 0…1. `nil` when unknown (battery monitoring off / simulator).
    var phoneBatteryFraction: Double?
    /// Phone is charging or full — relieves *battery* pressure (thermals still apply).
    var phoneCharging: Bool
    /// Phone thermal state (always available via `ProcessInfo`).
    var phoneThermal: ThermalPressure
    /// Glasses battery percentage 0…100, `nil` when no glasses / not yet reported.
    var glassesBatteryPercent: Int?
    /// Glasses thermal state, `nil` when absent or the firmware doesn't report it.
    var glassesThermal: ThermalPressure?
    /// iOS Low Power Mode — a direct user signal to economise; floors the posture at `conserve`.
    var lowPowerMode: Bool

    init(phoneBatteryFraction: Double? = nil,
         phoneCharging: Bool = false,
         phoneThermal: ThermalPressure = .nominal,
         glassesBatteryPercent: Int? = nil,
         glassesThermal: ThermalPressure? = nil,
         lowPowerMode: Bool = false) {
        self.phoneBatteryFraction = phoneBatteryFraction
        self.phoneCharging = phoneCharging
        self.phoneThermal = phoneThermal
        self.glassesBatteryPercent = glassesBatteryPercent
        self.glassesThermal = glassesThermal
        self.lowPowerMode = lowPowerMode
    }
}

/// Pure fusion of `PowerState` → `PowerPosture` (docs/plans/BV-power-policy.md P1). No clock, no
/// I/O — a function of the state, the previous posture (for hysteresis), and the thresholds, so
/// it's fully table-testable and identical across runs.
///
/// The worst signal wins: each of battery (phone + glasses), thermals (phone + glasses) and Low
/// Power Mode independently proposes a posture, and the result is their `max`. Battery uses
/// **hysteresis** — the enter and exit thresholds differ, keyed on the previous overall posture —
/// so a percentage hovering at a boundary can't flap the posture every tick. Thermals are already
/// discrete bands and map directly.
enum PowerPolicy {

    /// Battery/thermal thresholds. Defaults are deliberately conservative; the device pass tunes
    /// them via `Config` (see `Config.powerThresholds`).
    struct Thresholds: Equatable {
        /// At/below this battery fraction, `normal` → `conserve`.
        var conserveBatteryEnter: Double
        /// At/above this fraction, climb back out of `conserve` → `normal`.
        var conserveBatteryExit: Double
        /// At/below this fraction, drop to `reserve`.
        var reserveBatteryEnter: Double
        /// At/above this fraction, climb out of `reserve` → `conserve`.
        var reserveBatteryExit: Double
        /// Thermal band at/above which posture is at least `conserve`.
        var conserveThermal: ThermalPressure
        /// Thermal band at/above which posture is `reserve`.
        var reserveThermal: ThermalPressure

        static let `default` = Thresholds(
            conserveBatteryEnter: 0.30,
            conserveBatteryExit: 0.35,
            reserveBatteryEnter: 0.15,
            reserveBatteryExit: 0.20,
            conserveThermal: .serious,
            reserveThermal: .critical
        )
    }

    /// Fuse the signals into a posture.
    ///
    /// - Parameters:
    ///   - state: the current fused signals.
    ///   - previous: the last emitted posture, for battery hysteresis (default `.normal`).
    ///   - thresholds: tuning knobs (default `.default`; the service passes `Config.powerThresholds`).
    static func decide(_ state: PowerState,
                       previous: PowerPosture = .normal,
                       thresholds: Thresholds = .default) -> PowerPosture {
        var posture: PowerPosture = .normal

        // Battery. Charging relieves the *phone's* battery pressure (it's on mains); the glasses
        // battery always counts since we can't tell whether they're on a charger.
        if !state.phoneCharging {
            posture = max(posture, batteryPosture(fraction: state.phoneBatteryFraction,
                                                  previous: previous, thresholds: thresholds))
        }
        let glassesFraction = state.glassesBatteryPercent.map { Double($0) / 100.0 }
        posture = max(posture, batteryPosture(fraction: glassesFraction,
                                              previous: previous, thresholds: thresholds))

        // Thermals — discrete, no hysteresis needed.
        posture = max(posture, thermalPosture(state.phoneThermal, thresholds: thresholds))
        if let glassesThermal = state.glassesThermal {
            posture = max(posture, thermalPosture(glassesThermal, thresholds: thresholds))
        }

        // Low Power Mode is a direct ask to economise.
        if state.lowPowerMode { posture = max(posture, .conserve) }

        return posture
    }

    /// Battery → posture with hysteresis. An unknown battery drives no downgrade (returns
    /// `.normal`) — a missing reading must never be read as "empty".
    ///
    /// Hysteresis keys on the previous *overall* posture: once in a band you stay there until the
    /// signal clears the wider exit threshold. So between `conserveBatteryEnter` (0.30) and
    /// `conserveBatteryExit` (0.35) the posture is sticky rather than flapping.
    private static func batteryPosture(fraction: Double?,
                                       previous: PowerPosture,
                                       thresholds t: Thresholds) -> PowerPosture {
        guard let f = fraction else { return .normal }

        switch previous {
        case .reserve:
            if f < t.reserveBatteryExit { return .reserve }
            if f < t.conserveBatteryExit { return .conserve }
            return .normal
        case .conserve:
            if f <= t.reserveBatteryEnter { return .reserve }
            if f < t.conserveBatteryExit { return .conserve }
            return .normal
        case .normal:
            if f <= t.reserveBatteryEnter { return .reserve }
            if f <= t.conserveBatteryEnter { return .conserve }
            return .normal
        }
    }

    private static func thermalPosture(_ pressure: ThermalPressure, thresholds t: Thresholds) -> PowerPosture {
        if pressure >= t.reserveThermal { return .reserve }
        if pressure >= t.conserveThermal { return .conserve }
        return .normal
    }

    /// A one-line, user-facing reason for the current posture — the dominant signal that put us
    /// here. `nil` in `normal`. Feeds status-line/tool answers ("conserving — glasses battery 18%").
    static func explanation(_ state: PowerState, posture: PowerPosture) -> String? {
        guard posture != .normal else { return nil }
        // Report the signal that most plausibly drove the posture, thermals first (they escalate
        // fastest and matter most for hardware), then the lower battery of the two devices.
        let hottest = max(state.phoneThermal, state.glassesThermal ?? .nominal)
        if hottest >= .serious {
            let where_ = (state.glassesThermal ?? .nominal) >= state.phoneThermal ? "glasses" : "phone"
            return "\(posture.label) — \(where_) running warm"
        }
        if let g = state.glassesBatteryPercent, Double(g) / 100.0 <= 0.30 {
            return "\(posture.label) — glasses battery \(g)%"
        }
        if let f = state.phoneBatteryFraction, !state.phoneCharging, f <= 0.30 {
            return "\(posture.label) — phone battery \(Int((f * 100).rounded()))%"
        }
        if state.lowPowerMode {
            return "\(posture.label) — Low Power Mode"
        }
        return posture.label
    }
}
