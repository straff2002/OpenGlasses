import Foundation

/// One addition to a subscriber's shelf, as the allowance remembers it (Plan JK §8).
///
/// Carries no title, no file name and nothing from the manual: `fingerprint` is an HMAC of the
/// original file's bytes under a per-subscription secret, so the history cannot say which manual a
/// person owns. Records are append-only; `refunded` and `read` only ever turn on.
struct ManualAdditionRecord: Codable, Hashable, Sendable {
    let fingerprint: String
    /// Whole milliseconds since 1970, so a record round-trips through JSON to the same key.
    let addedAtMillis: Int64
    /// True when the addition used the rolling allowance; false for one of the first free fills.
    let spent: Bool
    var refunded: Bool
    /// Something was read from this manual (an answer cited it, or one of its pages was opened)
    /// while it was still inside the undo window. A read addition is never given back.
    var read: Bool

    init(fingerprint: String, addedAt: Date, spent: Bool, refunded: Bool = false, read: Bool = false) {
        self.fingerprint = fingerprint
        self.addedAtMillis = Int64((addedAt.timeIntervalSince1970 * 1000).rounded(.down))
        self.spent = spent
        self.refunded = refunded
        self.read = read
    }

    var addedAt: Date { Date(timeIntervalSince1970: Double(addedAtMillis) / 1000) }

    struct Key: Hashable, Sendable {
        let fingerprint: String
        let addedAtMillis: Int64
    }
    var key: Key { Key(fingerprint: fingerprint, addedAtMillis: addedAtMillis) }

    enum CodingKeys: String, CodingKey {
        case fingerprint = "f", addedAtMillis = "t", spent = "s", refunded = "r", read = "u"
    }
}

/// The pure new-manual allowance: three new manuals in any rolling 30 days, the first five
/// distinct manuals of a subscription free, a returning manual free. Same fail-closed rule as
/// `ManualQuota`: an unreadable history (`nil`) refuses additions. Reading and removal never ask.
enum ManualAdditionAllowance {
    enum Decision: Equatable, Sendable {
        /// The records to append when the install commits. Empty when nothing new is added.
        case allowed(spending: [ManualAdditionRecord])
        /// `nextAvailable` is nil when the proposal could never fit (a set larger than the window).
        case wouldExceed(remaining: Int, nextAvailable: Date?)
        case unavailable

        var spending: [ManualAdditionRecord]? {
            if case .allowed(let records) = self { return records }
            return nil
        }
    }

    struct Status: Equatable, Sendable {
        /// Free fills left before the rolling allowance applies.
        let freeRemaining: Int
        /// New additions left in the rolling window right now.
        let remaining: Int
        /// When the earliest spent addition in the window comes back; nil when none is spent.
        let nextAvailable: Date?
    }

    /// Fingerprints held at some point under this subscription and not given back.
    static func known(_ history: [ManualAdditionRecord]) -> Set<String> {
        Set(history.filter { !$0.refunded }.map(\.fingerprint))
    }

    /// Spent, unrefunded additions inside the window. A record dated after `now` is inside it: a
    /// clock moved forward spends the future window instead of freeing this one.
    static func inWindow(_ allowance: ManualLimits.AdditionAllowance, history: [ManualAdditionRecord],
                         now: Date) -> [ManualAdditionRecord] {
        history.filter { $0.spent && !$0.refunded && now < $0.addedAt.addingTimeInterval(allowance.window) }
    }

    static func status(_ allowance: ManualLimits.AdditionAllowance, history: [ManualAdditionRecord], now: Date) -> Status {
        let spent = inWindow(allowance, history: history, now: now)
        return Status(freeRemaining: max(0, allowance.freeFirst - known(history).count),
                      remaining: max(0, allowance.newPerWindow - spent.count),
                      nextAvailable: spent.map { $0.addedAt.addingTimeInterval(allowance.window) }.min())
    }

    /// `proposed` are the fingerprints of documents new to this shelf (by identity); a reindex,
    /// retry or replacement of a held identity is never proposed. A set is decided whole.
    static func decide(limits: ManualLimits?, history: [ManualAdditionRecord]?, proposed: [String],
                       now: Date) -> Decision {
        guard let allowance = limits?.additions else { return .allowed(spending: []) }
        guard let history else { return .unavailable }
        guard proposed.allSatisfy({ !$0.isEmpty }) else { return .unavailable }
        let known = known(history)
        var seen = Set<String>()
        let fresh = proposed.filter { !known.contains($0) && seen.insert($0).inserted }
        guard !fresh.isEmpty else { return .allowed(spending: []) }

        let freeCount = min(max(0, allowance.freeFirst - known.count), fresh.count)
        let paid = fresh.dropFirst(freeCount)
        let spentNow = inWindow(allowance, history: history, now: now)
        let remaining = max(0, allowance.newPerWindow - spentNow.count)
        if paid.count > remaining {
            // The window must shed enough spent additions to leave room for the whole proposal;
            // an offline overspend (more in the window than the allowance) has to shed that too.
            let mustExpire = spentNow.count - (allowance.newPerWindow - paid.count)
            let expiries = spentNow.map { $0.addedAt.addingTimeInterval(allowance.window) }.sorted()
            let next = paid.count <= allowance.newPerWindow && mustExpire >= 1 && mustExpire <= expiries.count
                ? expiries[mustExpire - 1] : nil
            return .wouldExceed(remaining: remaining, nextAvailable: next)
        }
        return .allowed(spending: fresh.prefix(freeCount).map { .init(fingerprint: $0, addedAt: now, spent: false) }
                        + paid.map { .init(fingerprint: $0, addedAt: now, spent: true) })
    }

    /// The addition a removal gives back, if any: the newest unrefunded record of `fingerprint`
    /// made within the undo window and never read. Removal itself never consults this.
    static func refund(limits: ManualLimits?, history: [ManualAdditionRecord], fingerprint: String,
                       now: Date) -> ManualAdditionRecord.Key? {
        guard let allowance = limits?.additions else { return nil }
        let candidates = history.filter { $0.fingerprint == fingerprint && !$0.refunded }
        guard let newest = candidates.max(by: { $0.addedAtMillis < $1.addedAtMillis }),
              !newest.read, now.timeIntervalSince(newest.addedAt) < allowance.undoWindow else { return nil }
        // An older, already-read holding of the same manual means it was not the wrong file.
        guard !candidates.contains(where: { $0.read }) else { return nil }
        return newest.key
    }

    /// Records a read of `fingerprint` turns on: those still inside the undo window, unread.
    static func readMarks(limits: ManualLimits?, history: [ManualAdditionRecord], fingerprint: String,
                          now: Date) -> [ManualAdditionRecord.Key] {
        guard let allowance = limits?.additions else { return [] }
        return history.filter {
            $0.fingerprint == fingerprint && !$0.refunded && !$0.read
                && now.timeIntervalSince($0.addedAt) < allowance.undoWindow
        }.map(\.key)
    }

    /// Union by `(fingerprint, addedAt)`. Flags only turn on, so a smaller or older copy never
    /// takes back a refund, a read or a spend another device recorded.
    static func merge(_ lists: [ManualAdditionRecord]...) -> [ManualAdditionRecord] {
        var merged: [ManualAdditionRecord.Key: ManualAdditionRecord] = [:]
        for record in lists.joined() {
            if let existing = merged[record.key] {
                merged[record.key] = ManualAdditionRecord(fingerprint: record.fingerprint, addedAt: record.addedAt,
                    spent: existing.spent || record.spent, refunded: existing.refunded || record.refunded,
                    read: existing.read || record.read)
            } else { merged[record.key] = record }
        }
        return merged.values.sorted { ($0.addedAtMillis, $0.fingerprint) < ($1.addedAtMillis, $1.fingerprint) }
    }

    // MARK: - Copy

    /// Day and month in the reader's locale ("12 November", "November 12").
    static func dayMonth(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale).day().month(.wide))
    }

    static func refusal(_ decision: Decision, limits: ManualLimits?, locale: Locale = .current) -> String? {
        switch decision {
        case .allowed: return nil
        case .unavailable:
            return String(localized: "Your manual history could not be checked. Unlock the phone and try again. You can still read and remove your manuals.")
        case .wouldExceed(let remaining, let next):
            let allowed = limits?.additions?.newPerWindow ?? 0
            let days = Int(((limits?.additions?.window ?? 0) / 86_400).rounded())
            let returning = String(localized: " Manuals you've had before can come back any time.")
            guard let next else {
                return String(localized: "This set has more new manuals than can be added in \(days) days, so nothing was added.") + returning
            }
            let lead = remaining == 0
                ? String(localized: "You've added \(allowed) new manuals in the last \(days) days.")
                : String(localized: "This set has more new manuals than the \(remaining) you can add now, so nothing was added.")
            return lead + String(localized: " Your next new manual can be added on \(dayMonth(next, locale: locale)).") + returning
        }
    }

    /// The upload sheet's line: only once the free fills are used and one or no addition is left.
    static func uploadNotice(_ status: Status?, locale: Locale = .current) -> String? {
        guard let status, status.freeRemaining == 0, status.remaining <= 1 else { return nil }
        if status.remaining == 1 { return String(localized: "1 new manual left for now. Manuals you've had before don't count.") }
        guard let next = status.nextAvailable else { return nil }
        return String(localized: "No new manuals left until \(dayMonth(next, locale: locale)). Manuals you've had before can still come back.")
    }
}
