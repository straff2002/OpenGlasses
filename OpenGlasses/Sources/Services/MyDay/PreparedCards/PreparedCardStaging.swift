import Foundation
import UserNotifications

// Plan KT §6.4 — why the Display stages instead of sending. iOS lets no app send a text or an
// email without the wearer tapping Send on the phone, so "Send on phone" (from the lens, and later
// the wrist and the voice) does three things:
//
// 1. marks the card `staged` with its current draft;
// 2. when the phone is not already showing the app, posts a time-sensitive local notification,
//    "Message to Ana ready — tap to send", which names the recipient (the wearer just asked for
//    it) but never carries the draft's text, and only when notifications are already allowed;
// 3. when the app is in front and the phone unlocked, opens the composer straight away instead.
//
// Tapping the notification opens the composer with the draft. Staged lasts until the card's
// `validUntil`, when the card leaves the feed and its notification is taken down.

enum PreparedCardStagingPolicy {
    /// The key a tap reads to open the composer rather than only the page.
    static let stagedKey = "og_prepared_card_staged"
    static let identifierPrefix = "my-day.staged."

    static func identifier(for id: PreparedCardID) -> String { identifierPrefix + id.rawValue }

    /// What the notification says, or nil for a card with no draft. The recipient's name, never
    /// the draft's text, never a chip or a fact.
    static func content(for card: PreparedCard) -> PreparedCardNotificationContent? {
        guard let draft = card.draft else { return nil }
        let name = draft.recipient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = name.isEmpty
            ? String(localized: "Message ready — tap to send",
                     comment: "Notification: a drafted message was put on the phone from the glasses, to send there.")
            : String(localized: "Message to \(name) ready — tap to send",
                     comment: "Notification: a drafted message to this person was put on the phone from the glasses, to send there.")
        return PreparedCardNotificationContent(identifier: identifier(for: card.id), cardID: card.id,
                                               title: PreparedCardNotificationPolicy.genericTitle, body: body)
    }

    /// The user info the notification carries: the card id, and that it is staged.
    static func userInfo(for id: PreparedCardID) -> [AnyHashable: Any] {
        [PreparedCardNotificationPolicy.cardKey: id.rawValue, stagedKey: true]
    }

    /// Whether a tapped notification is a staged card's, so the tap opens its composer.
    static func isStaged(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[stagedKey] as? Bool) == true
    }

    /// Opens straight away only when the wearer could tap Send now.
    static func opensComposerNow(appInFront: Bool, unlocked: Bool) -> Bool {
        appInFront && unlocked
    }
}

@MainActor
final class PreparedCardStager {

    enum Outcome: Equatable {
        /// The app was in front and unlocked: the composer opened.
        case openedComposer
        /// The notification was handed to the system (it shows only if allowed).
        case notified
        /// No draft: nothing to stage.
        case nothingToStage
    }

    /// Records the staged state (`PreparedCardFeedBuilder.stage`, through `MyDayService`).
    var record: (PreparedCard) -> Void = { _ in }
    /// Opens the card's composer on the phone.
    var openComposer: (PreparedCard) -> Void = { _ in }
    /// The app is in front (`.active`).
    var appInFront: () -> Bool = { false }
    /// Protected data is available: the phone is unlocked.
    var unlocked: () -> Bool = { false }
    /// Posts the notification if notifications are already allowed; never asks. A seam: the
    /// default goes to the notification centre.
    var post: (PreparedCardNotificationContent) async -> Void = PreparedCardStager.postIfAllowed
    /// Takes delivered notifications down.
    var remove: ([String]) -> Void = { ids in
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Cards staged in this process whose notification may be up.
    private(set) var stagedIDs: Set<PreparedCardID> = []

    init() {}

    @discardableResult
    func stage(_ card: PreparedCard) async -> Outcome {
        guard let content = PreparedCardStagingPolicy.content(for: card) else { return .nothingToStage }
        record(card)
        if PreparedCardStagingPolicy.opensComposerNow(appInFront: appInFront(), unlocked: unlocked()) {
            openComposer(card)
            return .openedComposer
        }
        stagedIDs.insert(card.id)
        await post(content)
        return .notified
    }

    /// The feed changed: a staged card that has left it (sent, expired, gone) takes its
    /// notification with it.
    func feedChanged(_ feed: TodayFeed) {
        let live = Set(feed.cards.map(\.id))
        let gone = stagedIDs.subtracting(live)
        guard !gone.isEmpty else { return }
        stagedIDs.subtract(gone)
        remove(gone.map(PreparedCardStagingPolicy.identifier(for:)).sorted())
    }

    /// The composer opened for a card: its notification is no longer needed.
    func composerOpened(_ id: PreparedCardID) {
        guard stagedIDs.remove(id) != nil else { return }
        remove([PreparedCardStagingPolicy.identifier(for: id)])
    }

    static func postIfAllowed(_ item: PreparedCardNotificationContent) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = PreparedCardStagingPolicy.userInfo(for: item.cardID)
        try? await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: nil))
    }
}
