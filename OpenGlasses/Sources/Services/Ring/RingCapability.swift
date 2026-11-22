import Foundation

// Plan MZ: a smart ring talks to the phone over Bluetooth and its readings go to Apple Health.
//
// Everything in this folder except `HealthKitRingStore` is pure: no CoreBluetooth, no HealthKit,
// no logging. The driver turns the app's own vocabulary (`RingCommand`, `RingEvent`) into one ring
// family's packets and back, so nothing above it ever sees an opcode.

/// What a ring family can do. A driver declares its set; the app offers only what is in it.
enum RingCapability: String, CaseIterable, Codable, Sendable {
    /// A heart-rate session the app starts and stops, readings streamed while it runs.
    case liveHeartRate
    /// Heart rate the ring measured on its own schedule and keeps until asked for.
    case storedHeartRate
    /// A one-off blood-oxygen reading the app starts.
    case spotOxygen
    /// The ring's day step counter.
    case steps
    /// Sleep recorded as stages (light and deep).
    case sleepStages
    /// The ring's battery level.
    case battery
    /// The ring lights up so it can be found.
    case findRing
    /// The ring reports a clench of the hand while its trigger mode is on.
    case clenchEvent
    /// The ring measures heart rate on a schedule the app sets.
    case heartRateSchedule
    /// The ring holds a daily step goal the app sets.
    case stepGoal
}
