import Foundation

/// Which notice to show when several are live, and when to stop showing it.
///
/// Pure: notices and a timestamp in, one notice out. Each rule is a way the surface could go quiet
/// again, which is the failure it exists to prevent.
enum NoticePolicy {

    /// How long an advisory stays up: long enough to read, short enough that a condition the wearer
    /// has already fixed does not linger and train them to ignore the surface.
    static let advisoryLifetime: TimeInterval = 8

    /// Errors never expire on their own. The thing the wearer asked for did not happen, and a
    /// timeout would hide exactly that.
    static func isExpired(_ notice: AppNotice, now: TimeInterval) -> Bool {
        guard notice.severity == .advisory else { return false }
        return now - notice.postedAt >= advisoryLifetime
    }

    /// The one to show. Highest severity wins; ties go to the most recent, so a fresh instance of
    /// an ongoing condition replaces a stale one instead of pinning the first.
    static func current(from notices: [AppNotice], now: TimeInterval) -> AppNotice? {
        notices
            .filter { !isExpired($0, now: now) }
            .max { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
                return lhs.postedAt < rhs.postedAt
            }
    }

    /// One notice per source, newest wins.
    ///
    /// Keyed by source rather than appended, because a queue is something a chatty subsystem fills:
    /// a camera reporting every dropped frame would bury a failed session behind a hundred
    /// advisories.
    static func merge(_ existing: [AppNotice], with notice: AppNotice) -> [AppNotice] {
        existing.filter { $0.source != notice.source } + [notice]
    }

    /// Drop everything from a source — its condition has cleared.
    static func clearing(_ existing: [AppNotice], source: AppNotice.Source) -> [AppNotice] {
        existing.filter { $0.source != source }
    }
}
