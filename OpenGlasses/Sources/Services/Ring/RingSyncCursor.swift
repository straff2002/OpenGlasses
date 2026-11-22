import Foundation

/// How far each kind of reading has reached Apple Health: one date per kind, and no values.
///
/// The ring is the buffer. A cursor moves only after Health accepted the batch; when the phone is
/// locked and Health refuses, the batch is dropped from memory, the cursor stays, and the next sync
/// reads the same span from the ring again. Kept with the ring's pairing record (Plan MZ P2).
struct RingSyncCursor: Codable, Equatable, Sendable {
    var heartRate: Date?
    var oxygenSaturation: Date?
    var sleepAnalysis: Date?
    var stepCount: Date?

    init(heartRate: Date? = nil, oxygenSaturation: Date? = nil, sleepAnalysis: Date? = nil,
         stepCount: Date? = nil) {
        self.heartRate = heartRate
        self.oxygenSaturation = oxygenSaturation
        self.sleepAnalysis = sleepAnalysis
        self.stepCount = stepCount
    }

    subscript(kind: RingHealthKind) -> Date? {
        get {
            switch kind {
            case .heartRate: return heartRate
            case .oxygenSaturation: return oxygenSaturation
            case .sleepAnalysis: return sleepAnalysis
            case .stepCount: return stepCount
            }
        }
        set {
            switch kind {
            case .heartRate: heartRate = newValue
            case .oxygenSaturation: oxygenSaturation = newValue
            case .sleepAnalysis: sleepAnalysis = newValue
            case .stepCount: stepCount = newValue
            }
        }
    }

    /// Moves a kind forward, never back.
    mutating func advance(_ kind: RingHealthKind, to date: Date) {
        if let existing = self[kind], existing >= date { return }
        self[kind] = date
    }
}
