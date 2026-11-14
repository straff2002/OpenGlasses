import Foundation

/// The open loops the wearer cleared from tonight's check-in (Plan LE §9), in the style of
/// `MyDayDismissals`: pinned to the day and to a fingerprint of the loop.
///
/// **This never resolves anything.** A dismissed reminder is still open, a dismissed approval is
/// still held, a dismissed report is still unsent; only the check-in stops naming it tonight. It
/// comes back tomorrow (the record lapses with the day), or tonight if the loop changes — a
/// reminder moved to another time, a send that has since failed.
///
/// The only data the check-in keeps beyond what its sources already hold. Pure: the store that
/// persists it is P1's wiring.
struct OpenLoopDismissals: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` in the wearer's calendar — the same shape the delivery markers use.
    var dayKey: String
    /// Loop id → the fingerprint the loop had when it was cleared.
    var fingerprints: [String: String]

    init(dayKey: String = "", fingerprints: [String: String] = [:]) {
        self.dayKey = dayKey
        self.fingerprints = fingerprints
    }

    static let empty = OpenLoopDismissals()

    /// The dismissals that still apply on `date`. A record from another day is not carried.
    func active(on date: Date, calendar: Calendar) -> [String: String] {
        dayKey == MyDayDismissalPolicy.dayKey(for: date, calendar: calendar) ? fingerprints : [:]
    }

    /// The record with `loop` added, rolled over first if it belongs to a previous day.
    func adding(_ loop: OpenLoop, on date: Date, calendar: Calendar) -> OpenLoopDismissals {
        let today = MyDayDismissalPolicy.dayKey(for: date, calendar: calendar)
        var next = dayKey == today ? fingerprints : [:]
        next[loop.id] = loop.fingerprint
        return OpenLoopDismissals(dayKey: today, fingerprints: next)
    }

    /// Whether a loop is one the wearer cleared: the same loop, with the same content.
    static func isDismissed(_ loop: OpenLoop, in active: [String: String]) -> Bool {
        active[loop.id] == loop.fingerprint
    }
}
