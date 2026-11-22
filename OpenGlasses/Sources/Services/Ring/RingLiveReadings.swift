import Foundation

/// The newest heart rate from the ring, in memory only (Plan MZ §5).
///
/// A workout and Live Coach read it; nothing persists it, and it reads as nil once 15 s pass
/// without a new reading, so a number the ring stopped sending is never handed on as current.
@MainActor
final class RingLiveReadings: ObservableObject {

    nonisolated static let freshness: TimeInterval = 15

    struct Reading: Equatable, Sendable {
        let beatsPerMinute: Int
        let at: Date
    }

    @Published private(set) var latest: Reading?

    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    func record(beatsPerMinute: Int, at date: Date) {
        guard RingHealthWriter.heartRateRange.contains(beatsPerMinute) else { return }
        if let latest, latest.at > date { return }
        latest = Reading(beatsPerMinute: beatsPerMinute, at: date)
    }

    /// The newest reading if it is no older than `freshness`.
    var fresh: Reading? { Self.fresh(latest, now: clock()) }

    var freshBeatsPerMinute: Int? { fresh?.beatsPerMinute }

    func clear() {
        latest = nil
    }

    nonisolated static func fresh(_ reading: Reading?, now: Date) -> Reading? {
        guard let reading else { return nil }
        let age = now.timeIntervalSince(reading.at)
        return age >= 0 && age <= freshness ? reading : nil
    }
}

/// What the Developer panel shows about the ring's traffic (Plan MZ P2): unknown opcodes and how
/// often each came, and the last twenty packets. On screen only: held in memory, never logged,
/// saved or put in a support report.
@MainActor
final class RingPacketLog: ObservableObject {

    nonisolated static let capacity = 20

    struct Entry: Identifiable, Equatable {
        enum Direction: String { case sent, received }
        let id: Int
        let direction: Direction
        let hex: String
    }

    @Published private(set) var unknownOpcodes: [UInt8: Int] = [:]
    @Published private(set) var malformedCount = 0
    @Published private(set) var recent: [Entry] = []
    private var nextID = 0

    func record(_ bytes: [UInt8], _ direction: Entry.Direction) {
        nextID += 1
        recent.append(Entry(id: nextID, direction: direction, hex: Self.hex(bytes)))
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }
    }

    func countUnknown(_ opcode: UInt8) {
        unknownOpcodes[opcode, default: 0] += 1
    }

    func countMalformed() {
        malformedCount += 1
    }

    func clear() {
        unknownOpcodes = [:]
        malformedCount = 0
        recent = []
    }

    nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// Where a workout's live heart rate comes from (Plan MZ §5). `RingService` conforms; the fitness
/// coach asks it for a session at `start_workout` and lets it go at `stop_workout`.
@MainActor
protocol WorkoutHeartRateSource: AnyObject {
    func beginWorkoutHeartRate()
    func endWorkoutHeartRate()
    /// The newest heart rate if fresh (`RingLiveReadings.freshness`), else nil.
    var freshHeartRate: Int? { get }
    /// The heart rate measured since the workout began, between `start` and `end`, as samples to
    /// attach to the saved workout (`RingHealthWriter.workoutHeartRateSamples`). Read before
    /// `endWorkoutHeartRate()`, which lets them go.
    func workoutHeartRateSamples(from start: Date, to end: Date) -> [RingHealthSample]
}

extension RingService: WorkoutHeartRateSource {}
