import Foundation

/// What a ring said, in the app's own words. A driver decodes it.
///
/// Nothing here carries the ring's address, and an event the driver cannot read keeps only its
/// opcode: no payload is held, so no undecoded byte can travel further into the app.
enum RingEvent: Equatable, Sendable {
    /// The ring acknowledged a command (most commands are echoed back unchanged).
    case acknowledged(RingCommandKind)
    /// The ring's current activity counters.
    case activity(RingActivityReading)
    /// A second activity packet whose fields are only partly understood. Decoded, not used.
    case activitySummary(RingActivitySummary)
    /// The ring's battery level, in percent.
    case battery(percent: Int)
    /// One live heart-rate reading in beats per minute.
    case heartRate(bpm: Int)
    /// The ring ended a live heart-rate run on its own.
    case liveHeartRateEnded
    /// A blood-oxygen run is still measuring.
    case oxygenProgress
    /// A blood-oxygen result in percent.
    case oxygenResult(percent: Int)
    /// The ring ended a blood-oxygen run.
    case oxygenEnded
    /// A summary packet answering the sleep query. Its fields are not decoded.
    case sleepHistorySummary
    /// Fifteen minutes of the sleep timeline.
    case sleep(RingSleepPacket)
    /// The stored-measurement stream started.
    case storedHistoryHeader
    /// A stored-measurement metadata record. Not decoded.
    case storedHistoryMetadata
    /// A chunk of stored measurements. Not decoded until the device pass confirms the format.
    case storedHistoryChunk
    /// The stored-measurement stream ended.
    case storedHistoryEnd
    /// The wearer clenched or flicked the hand while the trigger mode was on.
    case clench
    /// A packet this driver does not read. Only the opcode is kept, so it can be counted.
    case unknown(opcode: UInt8)
    /// A packet of the wrong length, refused without reading it.
    case malformed(length: Int)
}

/// The ring's current activity counters, as it reports them.
struct RingActivityReading: Equatable, Sendable {
    /// The ring's local wall-clock seconds when it took the reading.
    let ringSeconds: UInt32
    /// Steps since the ring's day began.
    let steps: Int
    /// A distance-like counter, probably metres. Not written until the device pass (decision 2).
    let distanceUnits: Int
    /// The ring's own calorie estimate. Never written (decision 2).
    let calories: Int
}

/// The second activity packet. Field meanings are open (Plan MZ risk 5).
struct RingActivitySummary: Equatable, Sendable {
    let ringSeconds: UInt32
    let fieldA: Int
    let fieldB: Int
    let stepLike: Int
}

/// One minute of the sleep timeline.
enum RingSleepMinute: Equatable, Sendable {
    case light
    case deep
    /// No data for this minute (the ring's zero value; an awake value has never been seen).
    case none
    /// A value this driver does not know. Treated as a gap, never guessed at.
    case unrecognised
}

/// Fifteen consecutive minutes of the sleep timeline, starting at `ringSeconds`.
struct RingSleepPacket: Equatable, Sendable {
    let ringSeconds: UInt32
    let minutes: [RingSleepMinute]
}
