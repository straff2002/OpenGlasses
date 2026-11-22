import Foundation

/// Whether a qualification run may measure the next case now (Plan MQ H4, P3). Pure: the device
/// app reads the phone (thermal state, Low Power Mode, battery level and charging) and this turns
/// the reading into one decision.
///
/// In another app's overnight runs every model fell to 5–11 tokens a second once the phone reached
/// `serious`, which took two to five long answers, and a cool-down wait that gave up after a few
/// minutes measured hot twice a night. So an unattended run waits for `nominal` and then a settle
/// period, refuses a draining battery and refuses Low Power Mode:
///
/// - `proceed`: measure now.
/// - `wait(reasons)`: not yet; the reasons are for the log. Ask again shortly.
/// - `flag(reasons)`: the wait ran out on heat alone, so the case is measured anyway and the
///   record says so. A flagged result can't grant a badge. While the heat lasts, later cases are
///   flagged at once rather than each waiting out the cap again; a settled `nominal` clears it.
/// - `stop(reasons)`: the power is still bad at the cap (Low Power Mode, a draining or unknown
///   battery), so no later case or model is measured.
///
/// The thermal trace of the whole run is kept either way (`LocalModelQualificationRecord`).
enum QualificationRunGate {

    /// `ProcessInfo.ThermalState`, mirrored so the rule needs no UIKit.
    enum Thermal: Int, Codable, Comparable, Sendable, CaseIterable {
        case nominal, fair, serious, critical
        static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    /// Whether the phone is on a charger. `unknown` is what the simulator reports.
    enum Power: String, Codable, Sendable {
        case charging, full, unplugged, unknown
    }

    struct Reading: Equatable, Sendable {
        /// Seconds since the run started.
        let time: TimeInterval
        let thermal: Thermal
        let lowPowerMode: Bool
        /// 0…1, or nil when unknown.
        let batteryLevel: Double?
        let power: Power
    }

    enum Reason: String, Codable, Sendable, CaseIterable {
        /// Warmer than `nominal`.
        case thermal
        /// `nominal`, but not yet for the settle period.
        case settling
        case lowPowerMode
        /// On battery: a run must not drain the phone, and a draining phone throttles.
        case batteryDraining
        /// The battery state can't be read.
        case batteryUnknown

        /// A power reason ends the run at the cap; a heat reason only flags it.
        var isPower: Bool { self == .lowPowerMode || self == .batteryDraining || self == .batteryUnknown }
    }

    enum Decision: Equatable, Sendable {
        case proceed
        case wait([Reason])
        case flag([Reason])
        case stop([Reason])
    }

    struct Policy: Equatable, Sendable {
        /// How long `nominal` must hold before measuring.
        var settleSeconds: TimeInterval = 120
        /// The longest one wait lasts before it flags (heat) or stops (power).
        var capSeconds: TimeInterval = 20 * 60
        /// False lets a run proceed on battery (an attended smoke run); Low Power Mode still waits.
        var requiresCharger = true

        static let unattended = Policy()
    }

    /// What the gate remembers between readings.
    struct State: Equatable, Sendable {
        /// When the current stretch of `nominal` began.
        var nominalSince: TimeInterval?
        /// When the current wait began.
        var waitingSince: TimeInterval?
        /// The wait ran out on heat; later cases are flagged until a settled `nominal`.
        var flagging = false

        init() {}
    }

    /// The reasons `reading` is not fit to measure on, updating when `nominal` began.
    static func reasons(_ reading: Reading, state: inout State, policy: Policy) -> [Reason] {
        var reasons: [Reason] = []
        if reading.thermal == .nominal {
            if state.nominalSince == nil { state.nominalSince = reading.time }
            if let since = state.nominalSince, reading.time - since < policy.settleSeconds { reasons.append(.settling) }
        } else {
            state.nominalSince = nil
            reasons.append(.thermal)
        }
        if reading.lowPowerMode { reasons.append(.lowPowerMode) }
        if policy.requiresCharger {
            switch reading.power {
            case .charging, .full: break
            case .unplugged: reasons.append(.batteryDraining)
            case .unknown: reasons.append(.batteryUnknown)
            }
        }
        return reasons
    }

    /// The decision for one reading.
    static func decide(_ reading: Reading, state: inout State, policy: Policy = .unattended) -> Decision {
        let found = reasons(reading, state: &state, policy: policy)
        guard !found.isEmpty else {
            state.waitingSince = nil
            state.flagging = false
            return .proceed
        }
        let power = found.filter(\.isPower)
        // Already flagging and only heat stands in the way: measure, flagged, without waiting again.
        if state.flagging, power.isEmpty { return .flag(found) }
        if state.waitingSince == nil { state.waitingSince = reading.time }
        let waited = reading.time - (state.waitingSince ?? reading.time)
        guard waited >= policy.capSeconds else { return .wait(found) }
        state.waitingSince = nil
        if !power.isEmpty { return .stop(found) }
        state.flagging = true
        return .flag(found)
    }
}
