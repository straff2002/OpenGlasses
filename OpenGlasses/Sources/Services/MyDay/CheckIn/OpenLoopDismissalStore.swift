import Foundation

/// Where the Evening Check-in keeps what it knows about tonight (Plan LE §9, P1): the loops the
/// wearer cleared from it, and the loops it has already said today. Two records of one shape
/// (`OpenLoopDismissals`), each pinned to the day and to each loop's fingerprint, so both lapse at
/// midnight and both let a changed loop back in.
///
/// What is kept is loop ids — the trail entry's, the reminder's, the queued send's, the session's —
/// and a one-way digest of each loop's content (`OpenLoop.fingerprint`). No title and no name.
/// `UserDefaults` + JSON in the house style of `MyDayDismissalStore`: one small day-scoped record,
/// read on every check-in, and losing it costs the wearer one re-clear. Registered in
/// `DataStoreRegistry` as `checkInDismissals`; `deleteAll()` is what clears it.
final class OpenLoopDismissalStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let calendar: @Sendable () -> Calendar
    static let dismissedKey = "checkInDismissedLoops"
    static let saidKey = "checkInSaidLoops"

    init(defaults: UserDefaults = .standard,
         calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent }) {
        self.defaults = defaults
        self.calendar = calendar
    }

    // MARK: Dismissed tonight

    /// What the check-in filters against right now: loop id → fingerprint when cleared.
    func dismissed(on date: Date) -> [String: String] {
        record(Self.dismissedKey).active(on: date, calendar: calendar())
    }

    /// Clear one loop from tonight's check-in. Never resolves anything: the reminder is still
    /// open, the approval still held, the report still unsent.
    func dismiss(_ loop: OpenLoop, on date: Date) {
        write(record(Self.dismissedKey).adding(loop, on: date, calendar: calendar()), to: Self.dismissedKey)
    }

    // MARK: Said today

    /// The loops already said today, by the scheduled check-in or asked for after its time.
    func said(on date: Date) -> [String: String] {
        record(Self.saidKey).active(on: date, calendar: calendar())
    }

    /// Mark loops said today — the once-a-day rule. A loop that changes is new news again.
    func markSaid(_ loops: [OpenLoop], on date: Date) {
        guard !loops.isEmpty else { return }
        let cal = calendar()
        let next = loops.reduce(record(Self.saidKey)) { $0.adding($1, on: date, calendar: cal) }
        write(next, to: Self.saidKey)
    }

    // MARK: Erasure

    /// Both records — the registry's "delete all".
    func deleteAll() {
        defaults.removeObject(forKey: Self.dismissedKey)
        defaults.removeObject(forKey: Self.saidKey)
    }

    // MARK: Storage

    private func record(_ key: String) -> OpenLoopDismissals {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(OpenLoopDismissals.self, from: data) else {
            return .empty
        }
        return stored
    }

    private func write(_ record: OpenLoopDismissals, to key: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}
