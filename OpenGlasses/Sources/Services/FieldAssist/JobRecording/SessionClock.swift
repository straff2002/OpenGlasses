import Foundation

/// A moment on a recorded job's own clock, or a length of time on it: whole milliseconds from the
/// session's zero (Contracts/recorded-session.md §4).
///
/// The contract writes times as seconds to millisecond precision. They are held here as integers so
/// the phone and the office compare, sort and subtract the same numbers. A time is written as a
/// decimal with at most three places; one read with more is rounded to the nearest millisecond,
/// halves away from zero.
struct SessionTime: Hashable, Comparable, Sendable {
    let milliseconds: Int64

    static let zero = SessionTime(milliseconds: 0)
    /// The furthest a time may be from zero: the largest whole number of milliseconds every JSON
    /// reader keeps exactly.
    static let limit: Int64 = 9_007_199_254_740_991

    init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    /// A reading in seconds, rounded to the millisecond. A reading that is not a number is zero and
    /// one past the limit stops at it: a clock gives neither, and a time read from a file is
    /// checked before it gets here.
    init(seconds: Double) {
        guard seconds.isFinite else {
            self.milliseconds = 0
            return
        }
        let scaled = (seconds * 1000).rounded(.toNearestOrAwayFromZero)
        self.milliseconds = Int64(max(-Double(Self.limit), min(Double(Self.limit), scaled)))
    }

    var seconds: Double { Double(milliseconds) / 1000 }

    static func < (lhs: SessionTime, rhs: SessionTime) -> Bool { lhs.milliseconds < rhs.milliseconds }
    static func + (lhs: SessionTime, rhs: SessionTime) -> SessionTime {
        SessionTime(milliseconds: lhs.milliseconds + rhs.milliseconds)
    }
    static func - (lhs: SessionTime, rhs: SessionTime) -> SessionTime {
        SessionTime(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }
}

extension SessionTime: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let seconds = try container.decode(Double.self)
        guard seconds.isFinite, abs(seconds * 1000) <= Double(Self.limit) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "time out of range")
        }
        self.init(seconds: seconds)
    }

    /// Written as an exact decimal — `12.345`, `12.5`, `12` — never as a binary fraction's digits.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Decimal(milliseconds) / 1000)
    }
}

/// The zero of a recorded job: a wall-clock time and a monotonic reading taken together when the
/// recording starts (Plan HE §2).
///
/// Session time is counted on the monotonic clock, which does not jump when the phone's clock is
/// corrected. The wall time is kept so that things stamped only with a date — the job log's lines —
/// can be placed on the same clock. That placing is only as good as the wall clock was steady, which
/// is why a logged turn says whether it was aligned to the audio or left at its log time.
struct SessionClock: Equatable, Sendable {
    let wallStart: Date
    /// The monotonic clock's reading, in seconds, at `wallStart`.
    let monotonicStart: TimeInterval

    init(wallStart: Date, monotonicStart: TimeInterval) {
        self.wallStart = wallStart
        self.monotonicStart = monotonicStart
    }

    /// `wallStart` as the timeline writes it: Unix milliseconds.
    var wallStartMilliseconds: Int64 {
        Int64((wallStart.timeIntervalSince1970 * 1000).rounded(.toNearestOrAwayFromZero))
    }

    /// Where a monotonic reading falls. A reading from before the start is negative.
    func time(monotonic reading: TimeInterval) -> SessionTime {
        SessionTime(seconds: reading - monotonicStart)
    }

    /// Where a wall-stamped moment falls, taking the wall clock to have run steadily since the start.
    func time(wall date: Date) -> SessionTime {
        SessionTime(seconds: date.timeIntervalSince(wallStart))
    }

    /// The wall time of a session time, under the same assumption.
    func wallDate(at time: SessionTime) -> Date {
        wallStart.addingTimeInterval(time.seconds)
    }
}
