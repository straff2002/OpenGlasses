import Foundation

/// The ring keeps local wall-clock seconds: UTC plus the offset it was given at its last time sync.
///
/// `RingClock` is that offset, latched when the app sets the ring's clock, and the conversion both
/// ways. The offset is the full one in seconds: the time-sync packet's offset field holds whole
/// hours only and truncates a half-hour zone, but the seconds it carries are already shifted by the
/// full offset, so decoding uses the latched seconds and never the hour field (Plan MZ §3).
///
/// The latched clock is kept per ring (with the sync cursors) because a night recorded before a
/// time zone change was stamped under the old offset; `RingSyncMachine` decodes what it fetches
/// with the clock that was in force while it was recorded.
struct RingClock: Codable, Equatable, Hashable, Sendable {

    /// Seconds east of UTC.
    let offsetSeconds: Int

    init(offsetSeconds: Int) {
        self.offsetSeconds = offsetSeconds
    }

    /// The clock for `timeZone` at `date` (daylight saving included).
    static func latching(_ timeZone: TimeZone, at date: Date) -> RingClock {
        RingClock(offsetSeconds: timeZone.secondsFromGMT(for: date))
    }

    /// The ring's seconds for a moment.
    func ringSeconds(for date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(offsetSeconds))
    }

    /// The moment a ring timestamp stands for.
    func date(fromRingSeconds seconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(seconds) - Int64(offsetSeconds)))
    }

    /// What the time-sync command carries at `date`.
    func timeSync(at date: Date) -> RingTimeSync {
        RingTimeSync(ringSeconds: ringSeconds(for: date), offsetSeconds: offsetSeconds)
    }
}
