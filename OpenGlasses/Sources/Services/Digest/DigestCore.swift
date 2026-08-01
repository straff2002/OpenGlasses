import Foundation

/// Plan BZ — the deterministic half of the notification digest: item model, ranking policy,
/// dedup, staleness, and composition. All pure; the live edge (`NotificationDigestService`)
/// feeds real sources in and renders the result.
///
/// Scope guard: sources are all **first-party** (calendar, geofence, proactive alerts, agent
/// queue, reminders, sync). iOS gives no third-party notification access and the glasses
/// firmware no ANCS hook — this is a permanent constraint, not a TODO.

// MARK: - Item model

enum DigestSource: String, Codable, CaseIterable {
    case calendar, geofence, proactive, agent, reminder, sync

    /// The deterministic fallback line's tag: `[Calendar] Standup in 8 min`.
    var displayTag: String {
        switch self {
        case .calendar: return "Calendar"
        case .geofence: return "Location"
        case .proactive: return "Heads-up"
        case .agent: return "Agent"
        case .reminder: return "Reminder"
        case .sync: return "Sync"
        }
    }
}

struct DigestItem: Codable, Identifiable, Equatable {
    let id: String
    let source: DigestSource
    let title: String
    let rawBody: String
    let createdAt: Date
    let priority: NotificationPriority
    /// Items sharing a key collapse to the latest (e.g. repeated geofence enter/exit).
    var threadKey: String?
    /// When the underlying event occurs (calendar start) — drives the time-sensitive tier
    /// and the "in N min" fallback phrasing.
    var eventDate: Date?
    /// Agent result awaiting a user reply — the actionable tier.
    var awaitingReply: Bool
    /// Times this item has appeared in a presented digest; retires at the seen cap.
    var seenCount: Int

    init(id: String = UUID().uuidString, source: DigestSource, title: String,
         rawBody: String = "", createdAt: Date, priority: NotificationPriority,
         threadKey: String? = nil, eventDate: Date? = nil, awaitingReply: Bool = false,
         seenCount: Int = 0) {
        self.id = id
        self.source = source
        self.title = title
        self.rawBody = rawBody
        self.createdAt = createdAt
        self.priority = priority
        self.threadKey = threadKey
        self.eventDate = eventDate
        self.awaitingReply = awaitingReply
        self.seenCount = seenCount
    }
}

// MARK: - Ranking

/// The explicit priority ladder. Lower raw value = shown first.
enum DigestTier: Int, Comparable, CaseIterable {
    /// User-directed / `high` priority.
    case urgent = 0
    /// Imminent calendar event or a location transition — matters *right now*.
    case timeSensitive
    /// An agent result waiting on a reply.
    case actionable
    /// Medium-priority information.
    case informational
    /// Everything else.
    case routine

    static func < (lhs: DigestTier, rhs: DigestTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum DigestRanker {

    /// An event further out than this isn't "time-sensitive" yet.
    static let imminentWindow: TimeInterval = 15 * 60

    static func tier(of item: DigestItem, now: Date) -> DigestTier {
        if item.priority == .high { return .urgent }
        if let event = item.eventDate, event.timeIntervalSince(now) <= imminentWindow {
            return .timeSensitive
        }
        if item.source == .geofence { return .timeSensitive }
        if item.awaitingReply { return .actionable }
        if item.priority == .medium { return .informational }
        return .routine
    }

    /// Tier order; ties broken by recency (newest first).
    static func ranked(_ items: [DigestItem], now: Date) -> [DigestItem] {
        items.sorted { a, b in
            let ta = tier(of: a, now: now)
            let tb = tier(of: b, now: now)
            if ta != tb { return ta < tb }
            return a.createdAt > b.createdAt
        }
    }
}

// MARK: - Dedup

enum DigestDeduper {

    /// Two same-source items with equal normalized bodies within this window are duplicates.
    static let nearDuplicateWindow: TimeInterval = 600

    /// Collapse threadKey groups to their latest item, then drop near-duplicate bodies.
    /// Output preserves input order of the surviving items (the ranker orders later).
    static func deduped(_ items: [DigestItem]) -> [DigestItem] {
        // Latest per threadKey.
        var latestByThread: [String: DigestItem] = [:]
        for item in items {
            guard let key = item.threadKey else { continue }
            if let existing = latestByThread[key], existing.createdAt >= item.createdAt { continue }
            latestByThread[key] = item
        }

        var out: [DigestItem] = []
        var seenNormalized: [(source: DigestSource, body: String, at: Date)] = []
        for item in items {
            if let key = item.threadKey, latestByThread[key]?.id != item.id { continue }
            let normalized = normalize(item.title + " " + item.rawBody)
            if seenNormalized.contains(where: { $0.source == item.source && $0.body == normalized
                && abs($0.at.timeIntervalSince(item.createdAt)) <= nearDuplicateWindow }) {
                continue
            }
            seenNormalized.append((item.source, normalized, item.createdAt))
            out.append(item)
        }
        return out
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Staleness

enum DigestStaleness {

    /// A calendar-style event that started this long ago is over as news.
    static let eventLapse: TimeInterval = 300

    /// Retired items never appear again: age-by-priority staleness (shared rule), the seen
    /// cap, or an event already underway for a while — "Standup in -20 min" is not a glance.
    static func isRetired(_ item: DigestItem, now: Date, seenCap: Int = 3) -> Bool {
        if item.priority.isStale(age: now.timeIntervalSince(item.createdAt)) { return true }
        if item.seenCount >= seenCap { return true }
        if let event = item.eventDate, now.timeIntervalSince(event) > eventLapse { return true }
        return false
    }
}

// MARK: - Composition

struct Digest: Equatable {
    let items: [DigestItem]
    /// Live-but-unshown items beyond top-N ("+2 more").
    let overflowCount: Int

    var isEmpty: Bool { items.isEmpty }
}

enum DigestComposer {

    /// Panel line budget default (HUD ~600 px → 3 item lines).
    static let defaultTopN = 3

    /// dedupe → drop retired → rank → top-N + overflow.
    static func compose(_ items: [DigestItem], now: Date,
                        topN: Int = defaultTopN, seenCap: Int = 3) -> Digest {
        let live = DigestDeduper.deduped(items)
            .filter { !DigestStaleness.isRetired($0, now: now, seenCap: seenCap) }
        let ranked = DigestRanker.ranked(live, now: now)
        let capped = max(0, topN)
        return Digest(items: Array(ranked.prefix(capped)),
                      overflowCount: max(0, ranked.count - capped))
    }
}
