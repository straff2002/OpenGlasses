import Foundation

/// Rows the wearer has cleared from today's card.
///
/// **This never destroys anything.** Clearing a row hides it from My Day and touches nothing else:
/// the calendar event still exists, the reminder is still open and unstarted, and both are still in
/// the next compose's inputs. The only thing that changes is which rows the card ranks. That is the
/// whole point — "I know it's this bloke's birthday, I don't need to know it all day" is a request
/// about a card, not about a calendar.
///
/// A dismissal is pinned to two things, and the second is what stops it becoming a black hole:
///
///   - **The day.** The card recomposes every time the app comes forward or the calendar changes,
///     and a dismissal has to survive all of that or it is not a dismissal. It lapses when the day
///     rolls over, because "not today" is what the wearer meant.
///   - **A fingerprint of the row.** The ids come from EventKit and are stable across recomposes for
///     the same event — which is what makes the dismissal stick, and also what would keep a
///     *rescheduled* event hidden. If the title or the time changes, the row is genuinely new news
///     and comes back.
struct MyDayDismissals: Codable, Equatable {
    /// `yyyy-MM-dd` in the wearer's calendar — the same shape the delivery markers use.
    var dayKey: String
    /// Storage key → the fingerprint the row had when it was cleared.
    var fingerprints: [String: String]

    init(dayKey: String = "", fingerprints: [String: String] = [:]) {
        self.dayKey = dayKey
        self.fingerprints = fingerprints
    }

    static let empty = MyDayDismissals()
}

extension MyDayItemID {
    /// Flat key for the dismissal record. The source is part of it because raw ids are only unique
    /// within their source.
    var dismissalKey: String { "\(source.rawValue):\(rawValue)" }
}

extension MyDayItem {
    /// What a dismissal is pinned to besides the id: enough of the row's content that a genuinely
    /// changed event comes back instead of staying cleared.
    var dismissalFingerprint: String {
        let due = dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(title)|\(due)"
    }
}

/// The day-key and lapse arithmetic, pure so the one property that matters — a dismissal survives
/// every refresh in a day and no refresh after it — can be proven without waiting a day.
enum MyDayDismissalPolicy {
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The dismissals that still apply on `date`. A record from another day is not carried: the
    /// wearer cleared the row for today, and tomorrow's card is a new question.
    static func active(_ stored: MyDayDismissals, on date: Date,
                       calendar: Calendar) -> [String: String] {
        stored.dayKey == dayKey(for: date, calendar: calendar) ? stored.fingerprints : [:]
    }

    /// Add a row to the record, rolling the record over first if it belongs to a previous day.
    static func adding(_ item: MyDayItem, to stored: MyDayDismissals, on date: Date,
                       calendar: Calendar) -> MyDayDismissals {
        let today = dayKey(for: date, calendar: calendar)
        var fingerprints = stored.dayKey == today ? stored.fingerprints : [:]
        fingerprints[item.id.dismissalKey] = item.dismissalFingerprint
        return MyDayDismissals(dayKey: today, fingerprints: fingerprints)
    }

    /// Whether a composed row is one the wearer cleared. Both halves must match: the same row, and
    /// the same row *content*. A rescheduled meeting is new news and is shown again.
    static func isDismissed(_ item: MyDayItem, in active: [String: String]) -> Bool {
        active[item.id.dismissalKey] == item.dismissalFingerprint
    }
}

/// The dismissal record's home. `UserDefaults` rather than a JSON store: it is one small
/// day-scoped dictionary, it is read on every compose, and losing it costs the wearer one
/// re-clear — the same reasoning the My Day delivery markers are stored this way.
/// Deliberately not actor-isolated: it is a read and a write on `UserDefaults`, which is its own
/// synchronisation, and `MyDayService` takes one as a default argument — a `@MainActor` default
/// cannot be constructed where that argument is evaluated.
final class MyDayDismissalStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let calendar: @Sendable () -> Calendar
    private let key = "myDayDismissals"

    init(defaults: UserDefaults = .standard,
         calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent }) {
        self.defaults = defaults
        self.calendar = calendar
    }

    private var stored: MyDayDismissals {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(MyDayDismissals.self, from: data) else {
            return .empty
        }
        return record
    }

    /// What compose should filter against right now.
    func active(on date: Date) -> [String: String] {
        MyDayDismissalPolicy.active(stored, on: date, calendar: calendar())
    }

    func dismiss(_ item: MyDayItem, on date: Date) {
        let next = MyDayDismissalPolicy.adding(item, to: stored, on: date, calendar: calendar())
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: key)
    }

    func clearAll() {
        defaults.removeObject(forKey: key)
    }
}
