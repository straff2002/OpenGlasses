import Foundation

/// The Apple Health types the ring writes (Plan MZ §1). Distance waits for the device pass to
/// confirm its unit (decision 2); calories are never written.
enum RingHealthKind: String, CaseIterable, Codable, Sendable {
    case heartRate
    case oxygenSaturation
    case sleepAnalysis
    case stepCount
}

/// A random value made when a ring is paired. It names the ring inside sync identifiers and is
/// never the ring's address or its CoreBluetooth identifier.
struct RingPairingID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func make() -> RingPairingID {
        RingPairingID(rawValue: UUID().uuidString.lowercased())
    }
}

/// What a ring reading becomes in Health.
enum RingHealthValue: Equatable, Sendable {
    case heartRate(beatsPerMinute: Double)
    /// A fraction, 0.70 … 1.00, as Health stores oxygen saturation.
    case oxygenSaturation(fraction: Double)
    case sleep(SleepStage)
    case steps(Double)

    var kind: RingHealthKind {
        switch self {
        case .heartRate: return .heartRate
        case .oxygenSaturation: return .oxygenSaturation
        case .sleep: return .sleepAnalysis
        case .steps: return .stepCount
        }
    }
}

/// One sample to write, with the sync identifier that makes a re-sync replace it rather than add
/// a second copy, and the version that decides which copy wins.
struct RingHealthSample: Equatable, Sendable {
    let start: Date
    let end: Date
    let value: RingHealthValue
    let syncIdentifier: String
    let syncVersion: Int

    var kind: RingHealthKind { value.kind }
}

/// A reading as the ring service hands it to the writer.
enum RingReading: Equatable, Sendable {
    case heartRate(bpm: Int, at: Date)
    case oxygen(percent: Int, at: Date)
    case sleep([RingSleepRun])
    /// The ring's day step counter as read at `at`.
    case steps(counter: Int, at: Date)
}

/// The last step-counter reading, held in memory only, so the next one can be turned into a
/// difference. It is a value, so it is never written to the app's own storage.
struct RingStepBaseline: Equatable, Sendable {
    let counter: Int
    let date: Date
}

/// What one write attempt holds: the samples, and where the cursor and the step baseline move to
/// once Health has accepted them. Nothing moves when Health refuses.
struct RingHealthBatch: Equatable, Sendable {
    let samples: [RingHealthSample]
    let cursorAfter: RingSyncCursor
    let stepBaselineAfter: RingStepBaseline?

    var isEmpty: Bool { samples.isEmpty }
}
