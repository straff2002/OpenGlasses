import Foundation

enum MyDayDigestPolicy {
    static let limit = 2

    static func select(
        _ items: [DigestItem],
        now: Date,
        limit: Int = MyDayDigestPolicy.limit
    ) -> [MyDayDigestUpdate] {
        let live = DigestComposer.compose(
            items,
            now: now,
            topN: items.count
        ).items

        return live
            .filter(isEligible)
            .prefix(max(0, limit))
            .map { item in
                MyDayDigestUpdate(
                    id: item.id,
                    title: bounded(item.title, limit: 80),
                    detail: bounded(
                        item.rawBody.isEmpty ? item.source.displayTag : item.rawBody,
                        limit: 160
                    ),
                    createdAt: item.createdAt,
                    urgency: urgency(for: item, now: now)
                )
            }
    }

    /// Calendar, reminder, and proactive items already have authoritative My Day rows. Mirroring
    /// them through the digest would duplicate the same commitment or leave-by warning. P3 only
    /// admits first-party updates that still call for attention.
    private static func isEligible(_ item: DigestItem) -> Bool {
        switch item.source {
        case .geofence:
            true
        case .agent:
            item.awaitingReply || item.priority == .high
        case .sync:
            item.priority == .high
        case .calendar, .proactive, .reminder:
            false
        }
    }

    private static func urgency(for item: DigestItem, now: Date) -> MyDayUrgency {
        switch DigestRanker.tier(of: item, now: now) {
        case .urgent: .immediate
        case .timeSensitive, .actionable: .important
        case .informational: .upcoming
        case .routine: .routine
        }
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

@MainActor
final class NotificationDigestDaySource: DigestDaySource {
    private let service: NotificationDigestService

    init(service: NotificationDigestService) {
        self.service = service
    }

    func loadDigest(now: Date) async -> MyDaySourceLoad<[MyDayDigestUpdate]> {
        guard Config.digestEnabled else {
            return .init(
                value: [],
                state: .unavailable(.digest, message: "Actionable updates are off.")
            )
        }
        return .init(
            value: MyDayDigestPolicy.select(service.items, now: now),
            state: .available(.digest)
        )
    }

    func dismissDigestItem(id: String) {
        service.dismissItem(id: id)
    }
}
