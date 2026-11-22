import Foundation

/// What the app asks a ring to do, in the app's own words. A driver encodes it.
///
/// Deliberately absent: the body-profile command (it would set someone else's height, weight, age
/// and sex on the wearer's ring; Plan MZ risk 1 and decision 10) and factory reset (not offered).
enum RingCommand: Equatable, Sendable {
    /// Ask for the ring's status. Its reply is used as a sign of life only.
    case status
    /// Set the ring's clock (`RingClock`).
    case timeSync(RingTimeSync)
    /// Set the ring's locale, an ASCII identifier such as `en-US`.
    case locale(String)
    /// Turn the automatic heart-rate schedule on or off.
    case heartRateSchedule(RingHeartRateSchedule)
    /// Set the daily step goal.
    case stepGoal(Int)
    /// Ask for the sleep timeline the ring holds.
    case sleepHistoryQuery
    /// Ask for the measurements the ring stored on its own.
    case storedHistoryQuery
    /// Start a live heart-rate run.
    case liveHeartRateStart
    /// Stop a live heart-rate run.
    case liveHeartRateStop
    /// Start a blood-oxygen run.
    case oxygenStart
    /// Stop a blood-oxygen run.
    case oxygenStop
    /// Light the ring up so it can be found.
    case findRing
    /// Turn the ring's clench trigger mode on or off.
    case selfieMode(on: Bool)

    var kind: RingCommandKind {
        switch self {
        case .status: return .status
        case .timeSync: return .timeSync
        case .locale: return .locale
        case .heartRateSchedule: return .heartRateSchedule
        case .stepGoal: return .stepGoal
        case .sleepHistoryQuery: return .sleepHistoryQuery
        case .storedHistoryQuery: return .storedHistoryQuery
        case .liveHeartRateStart: return .liveHeartRateStart
        case .liveHeartRateStop: return .liveHeartRateStop
        case .oxygenStart: return .oxygenStart
        case .oxygenStop: return .oxygenStop
        case .findRing: return .findRing
        case .selfieMode(let on): return on ? .selfieModeOn : .selfieModeOff
        }
    }
}

/// A command without its arguments: what an acknowledgement names.
enum RingCommandKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case status
    case timeSync
    case locale
    case heartRateSchedule
    case stepGoal
    case sleepHistoryQuery
    case storedHistoryQuery
    case liveHeartRateStart
    case liveHeartRateStop
    case oxygenStart
    case oxygenStop
    case findRing
    case selfieModeOn
    case selfieModeOff
}

/// The automatic heart-rate schedule. Only every 30 and every 10 minutes have been seen working.
enum RingHeartRateSchedule: Equatable, Sendable {
    case off
    case every(minutes: Int)

    /// Plan MZ decision 4: on, every 30 minutes.
    static let recommended = RingHeartRateSchedule.every(minutes: 30)
}

/// The two halves of a clock set: the ring's local wall-clock seconds and the offset they carry.
struct RingTimeSync: Equatable, Sendable {
    /// UTC seconds plus `offsetSeconds`: what the ring will count from.
    let ringSeconds: UInt32
    /// The full offset from UTC, half-hour zones included.
    let offsetSeconds: Int

    /// The offset in whole hours, truncated toward zero (a +5:30 zone is 5, −3:30 is −3). This is
    /// all the ring's offset field can hold; decoding never uses it (`RingClock`).
    var wholeHourOffset: Int8 {
        Int8(clamping: offsetSeconds / 3600)
    }
}
