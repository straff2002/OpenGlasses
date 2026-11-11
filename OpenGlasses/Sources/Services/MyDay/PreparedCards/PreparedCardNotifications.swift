import Foundation
import UserNotifications

// Plan KT §5.3 — a card may post one local notification when it reaches `immediate` (leave by
// within 10 min, running late, on my way to a job). The lock-screen text is generic by default, as
// My Day's scheduled notifications are; a setting shows the headline, and only for an ordinary
// card. The notification never carries a draft, a recipient, a chip or a fact. Quiet hours hold
// it back. A tap opens My Day.

/// What one card's notification says.
struct PreparedCardNotificationContent: Equatable, Sendable {
    let identifier: String
    let cardID: PreparedCardID
    let title: String
    let body: String
}

enum PreparedCardNotificationPolicy {

    /// The key a tap reads to open the card's page.
    static let cardKey = "og_prepared_card"
    static let identifierPrefix = "my-day.card."

    static var genericTitle: String { String(localized: "My Day", comment: "Notification title for a ready My Day card.") }
    static var genericBody: String {
        String(localized: "Something's ready in My Day", comment: "Notification body for a ready My Day card, with nothing about the card in it.")
    }

    /// The kinds that may notify at all.
    static let notifyingKinds: Set<PreparedCardKind> = [.leaveBy, .runningLate, .jobOnMyWay, .jobRunningLate]

    /// The cards that should notify now: immediate, of a notifying kind, not notified before, and
    /// not in quiet hours.
    static func due(cards: [PreparedCard], alreadyPosted: Set<String>, showsHeadline: Bool,
                    quiet: Bool) -> [PreparedCardNotificationContent] {
        guard !quiet else { return [] }
        return cards
            .filter { $0.urgency == .immediate && notifyingKinds.contains($0.kind) }
            .filter { !alreadyPosted.contains($0.id.rawValue) }
            .map { content(for: $0, showsHeadline: showsHeadline) }
    }

    /// Generic unless the wearer asked for the headline, and generic regardless for anything more
    /// sensitive than an ordinary card (§6.6: personal and health never reach the lock screen).
    static func content(for card: PreparedCard, showsHeadline: Bool) -> PreparedCardNotificationContent {
        let body = showsHeadline && card.sensitivity == .ordinary ? card.headline : genericBody
        return PreparedCardNotificationContent(identifier: identifierPrefix + card.id.rawValue, cardID: card.id,
                                               title: genericTitle, body: body)
    }

    /// The card a tapped notification names, if it names one.
    static func cardID(from userInfo: [AnyHashable: Any]) -> PreparedCardID? {
        (userInfo[cardKey] as? String).flatMap(PreparedCardID.init(rawValue:))
    }
}

/// Posts the policy's notifications, once per card. Never asks for permission: a phone that has
/// not allowed notifications still has every card on the page.
@MainActor
final class PreparedCardNotifier {

    private static let postedKey = "preparedCardNotifiedIDs"
    private let defaults: UserDefaults
    private let center: () -> UNUserNotificationCenter?

    init(defaults: UserDefaults = .standard,
         center: @escaping () -> UNUserNotificationCenter? = { .current() }) {
        self.defaults = defaults
        self.center = center
    }

    /// How many notified ids are remembered. A card id carries its day, so an old one never
    /// matches a new card; the cap only stops the list growing.
    static let rememberedLimit = 100

    /// Ids already notified. Not pruned by the feed: a locked refresh shows no cards, and the same
    /// card after the unlock must not notify twice.
    var posted: Set<String> { Set(defaults.stringArray(forKey: Self.postedKey) ?? []) }

    func notify(feed: TodayFeed, now: Date, calendar: Calendar = .autoupdatingCurrent,
                delivery: MyDayDeliverySettings = .current,
                showsHeadline: Bool = Config.preparedCardLockScreenText) {
        let quiet = MyDayDeliveryPolicy.isQuiet(at: now, calendar: calendar, settings: delivery)
        let due = PreparedCardNotificationPolicy.due(cards: feed.cards, alreadyPosted: posted,
                                                     showsHeadline: showsHeadline, quiet: quiet)
        guard !due.isEmpty else { return }
        let remembered = (defaults.stringArray(forKey: Self.postedKey) ?? []) + due.map(\.cardID.rawValue)
        defaults.set(Array(remembered.suffix(Self.rememberedLimit)), forKey: Self.postedKey)
        guard let center = center() else { return }
        Task { @MainActor in
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }
            for item in due {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                content.userInfo = [PreparedCardNotificationPolicy.cardKey: item.cardID.rawValue]
                try? await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: nil))
            }
        }
    }
}
