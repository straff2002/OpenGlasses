import Foundation

// Plan GI: read-only summaries of heart rate, sleep and steps from Apple Health.
//
// This file holds the value types every stage shares and the reader seam. The live reader is
// `HealthKitSampleReader`; tests hand the tool a fake. Nothing here imports HealthKit, so the pure
// core (aggregator, baseline, heart-rate summary, phraser, delivery policy, cache) builds and
// tests without it.

/// One heart-rate reading in beats per minute, at the time it was measured.
struct HeartRateReading: Codable, Equatable, Sendable {
    let beatsPerMinute: Double
    let date: Date
}

/// A sleep-analysis category, mirroring Apple Health's values without importing HealthKit.
enum SleepStage: String, Codable, Equatable, Sendable, CaseIterable {
    case inBed
    case asleepUnspecified
    case awake
    case asleepCore
    case asleepDeep
    case asleepREM

    /// Any of the asleep values, staged or not.
    var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: return true
        case .inBed, .awake: return false
        }
    }

    /// A value only a stage-tracking source (a watch, a ring) records.
    var isStaged: Bool {
        switch self {
        case .asleepCore, .asleepDeep, .asleepREM: return true
        default: return false
        }
    }
}

/// One sleep-analysis sample. `sourceID` tells overlapping recorders apart — a phone's in-bed
/// schedule and a watch's staged night cover the same hours and must not be added together.
struct SleepSample: Equatable, Sendable {
    let start: Date
    let end: Date
    let stage: SleepStage
    let sourceID: String
}

/// One earlier day's steps: the count by the same clock time as now, and the whole day's total.
struct DayStepSample: Equatable, Sendable {
    let byNow: Double
    let dayTotal: Double
}

/// What can be said about read access. HealthKit never reveals whether *read* access was granted —
/// a denied type simply returns no samples — so the most it can tell us is whether we have asked.
enum HealthAuthorizationState: Equatable, Sendable {
    /// No Health store on this device (iPad without Health, a restricted device).
    case unavailable
    /// The wearer has not been asked yet.
    case notDetermined
    /// The wearer has been asked; whatever they chose, reads now return what they allowed.
    case requested
}

/// Why a read could not happen at all.
enum HealthReadError: Error, Equatable {
    /// The phone is locked and Health's store is encrypted until it is unlocked.
    case protectedDataUnavailable
    /// Health is not available, or the read failed for a reason the wearer cannot act on.
    case unavailable
}

/// The Health types this feature reads. Nothing is written.
enum HealthSummaryReadType: String, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case sleepAnalysis
    case stepCount

    /// How the settings screen and the usage string name it.
    var displayName: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .sleepAnalysis: return "Sleep"
        case .stepCount: return "Steps"
        }
    }
}

/// The reader seam. Main-actor isolated like the tools that use it.
@MainActor
protocol HealthSampleReading: AnyObject {
    func authorizationState() async -> HealthAuthorizationState
    /// Ask for read access to `HealthSummaryReadType.allCases`. Returns false when the request
    /// could not be shown (no Health store, the app is not on screen) or failed.
    func requestAuthorization() async -> Bool
    /// The most recent heart-rate sample ending at or after `since`.
    func latestHeartRate(since: Date) async throws -> HeartRateReading?
    /// Resting heart-rate samples in the range, any order.
    func restingHeartRates(from: Date, to: Date) async throws -> [HeartRateReading]
    /// Sleep-analysis samples overlapping the range, any order.
    func sleepSamples(from: Date, to: Date) async throws -> [SleepSample]
    /// The cumulative step count in the range, de-duplicated across sources.
    func cumulativeSteps(from: Date, to: Date) async throws -> Double
}
