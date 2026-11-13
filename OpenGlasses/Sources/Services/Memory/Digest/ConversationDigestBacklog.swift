import Foundation

/// Plan LQ §2 — the conversations that qualified for a note and did not get one (no network, the
/// phone locked, an on-device model while backgrounded, a spend cap), picked up when the app comes
/// to the foreground. Pure.
///
/// A thread is picked when it is eligible, not the active one, quiet for at least the idle gap,
/// and was last touched after the feature first ran on this phone (decision 7: no first-run spend
/// over two hundred old threads). Newest first, at most what is left of today's allowance.
enum ConversationDigestBacklog {

    /// The most notes the backlog writes in a day.
    static let dailyCap = 20

    static func select(threads: [ConversationThread], activeThreadID: String?,
                       jobThreadIDs: Set<String>, since: Date?, now: Date,
                       quietFor gap: TimeInterval = JobThreadPolicy.conversationIdleGap,
                       remaining: Int) -> [String] {
        guard remaining > 0, let since else { return [] }
        return threads
            .filter { thread in
                thread.id != activeThreadID
                    && thread.updatedAt >= since
                    && now.timeIntervalSince(thread.updatedAt) >= gap
                    && ConversationDigestEligibility.check(thread, jobThreadIDs: jobThreadIDs).isEligible
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(remaining)
            .map(\.id)
    }
}

/// How many backlog notes were written today, and when the feature first ran. Plain values in
/// `UserDefaults` — two numbers and a day, never any text.
struct ConversationDigestBacklogLedger {
    static let dayKey = "conversationDigestBacklogDay"
    static let countKey = "conversationDigestBacklogCount"
    static let sinceKey = "conversationDigestsSince"

    let defaults: UserDefaults
    var calendar: Calendar = .current

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// When notes were first possible on this phone. Recorded the first time it is asked for, so
    /// only conversations left after the feature shipped are ever picked up.
    func since(now: Date = Date()) -> Date {
        if let stored = defaults.object(forKey: Self.sinceKey) as? Double {
            return Date(timeIntervalSince1970: stored)
        }
        defaults.set(now.timeIntervalSince1970, forKey: Self.sinceKey)
        return now
    }

    func remaining(now: Date = Date()) -> Int {
        max(0, ConversationDigestBacklog.dailyCap - used(now: now))
    }

    func used(now: Date = Date()) -> Int {
        defaults.string(forKey: Self.dayKey) == day(now) ? defaults.integer(forKey: Self.countKey) : 0
    }

    func recordWrite(now: Date = Date()) {
        let today = day(now)
        let count = defaults.string(forKey: Self.dayKey) == today ? defaults.integer(forKey: Self.countKey) : 0
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(count + 1, forKey: Self.countKey)
    }

    private func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
