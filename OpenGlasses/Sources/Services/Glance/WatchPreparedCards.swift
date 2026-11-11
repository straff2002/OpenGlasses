import Foundation

/// Plan KT §6.7 — the day's prepared cards on the wrist, built on the phone. Pure: the feed's
/// cards, the clock and the Medical Compliance reading are inputs.
///
/// - At most three cards, in the feed's order, none expired.
/// - **Health cards never go to the watch** (§6.6).
/// - Medical Compliance withholds what the Today glance withholds (`PreparedCardMedicalWithholding`):
///   no event title, and no draft text that names the meeting.
/// - A draft's text goes only when its sensitivity allows it on the wrist: `ordinary` and
///   `personal` do (§6.6's watch column), `health` never reaches here.
enum WatchPreparedCardBuilder {

    static func cards(from feed: [PreparedCard], now: Date, withholding: Bool) -> [WatchPreparedCard] {
        feed.filter { $0.sensitivity != .health && $0.validUntil > now }
            .prefix(WatchPreparedCard.maxCards)
            .map { card(for: $0, withholding: withholding) }
    }

    static func card(for card: PreparedCard, withholding: Bool) -> WatchPreparedCard {
        let shown = PreparedCardMedicalWithholding.shown(card, withholding: withholding)
        let facts = shown.facts.filter { !shown.headline.contains($0.value) }
        let chips = shown.signals.filter { $0.sensitivity != .health }
        let withheld = PreparedCardMedicalWithholding.withholdsDraftText(card, withholding: withholding)
        let draft = card.draft
        return WatchPreparedCard(
            id: card.id.rawValue,
            headline: shown.headline,
            chips: chips,
            facts: Array(facts.prefix(WatchPreparedCard.maxFacts)),
            primaryLabel: PreparedCardPresentation.button(card.primary, card: card).label,
            buttons: buttons(card),
            draftTo: draft.map { PreparedCardPresentation.draftModel($0).recipientLine },
            draftText: withheld ? nil : draft?.text,
            draftWithheld: withheld,
            validUntil: card.validUntil)
    }

    /// What the wrist can press, primary first: the hand-off (as **stage**) and directions, at most
    /// two. Opens, reports and parts orders stay on the phone.
    static func buttons(_ card: PreparedCard) -> [WatchPreparedCardButton] {
        var result: [WatchPreparedCardButton] = []
        for action in card.actions {
            let mapped: WatchPreparedCardAction?
            switch action {
            case .handOff: mapped = card.draft == nil ? nil : .stage
            case .directions: mapped = .directions
            default: mapped = nil
            }
            guard let mapped, !result.contains(where: { $0.action == mapped }) else { continue }
            result.append(WatchPreparedCardButton(action: mapped,
                                                  label: PreparedCardPresentation.button(action, card: card).label))
        }
        return Array(result.prefix(2))
    }
}

/// Plan KT §6.7 — a `preparedCardAction` from the watch: `card_id` and `action` (`stage`,
/// `directions`, `later`, `dismiss`). Pure resolution against the feed as it is now, and the reply
/// wording, so every reply is a test.
enum WatchPreparedCardCommand {

    enum Resolution: Equatable {
        case run(WatchPreparedCardAction, PreparedCard)
        case refuse(String)
    }

    enum Reply: Equatable {
        case done(String)
        case refused(String)
    }

    static var goneMessage: String {
        String(localized: "That card has gone. Your iPhone has the latest.",
               comment: "Watch: a card pressed on the wrist is no longer on the phone.")
    }
    static var nothingToDoMessage: String {
        String(localized: "That card can't do that.", comment: "Watch: a card was asked for an action it does not offer.")
    }
    static var directionsMessage: String {
        String(localized: "Directions are open on your iPhone.", comment: "Watch: directions started on the phone.")
    }
    static var laterMessage: String {
        String(localized: "Moved to later.", comment: "Watch: a card was put off until later.")
    }
    static var cannotWaitMessage: String {
        String(localized: "It's due before then, so it stays.", comment: "Watch: a card could not be put off; it is due too soon.")
    }
    static var dismissedMessage: String {
        String(localized: "Dismissed.", comment: "Watch: a card was dismissed.")
    }

    static func resolve(_ message: [String: Any], cards: [PreparedCard]) -> Resolution {
        guard let raw = message[WatchPreparedCardWire.actionKey] as? String,
              let action = WatchPreparedCardAction(rawValue: raw) else { return .refuse(nothingToDoMessage) }
        guard let rawID = message[WatchPreparedCardWire.cardIDKey] as? String,
              let id = PreparedCardID(rawValue: rawID),
              let card = cards.first(where: { $0.id == id }),
              // A health card is never on the wrist, so a press for one is not the wearer's.
              card.sensitivity != .health else { return .refuse(goneMessage) }
        switch action {
        case .stage:
            guard card.draft != nil, card.actions.contains(where: PreparedCardHUDBuilder.isHandOff) else {
                return .refuse(nothingToDoMessage)
            }
        case .directions:
            guard directions(card) != nil else { return .refuse(nothingToDoMessage) }
        case .later, .dismiss:
            break
        }
        return .run(action, card)
    }

    /// The card's directions action, if it has one.
    static func directions(_ card: PreparedCard) -> PreparedAction? {
        card.actions.first { if case .directions = $0 { true } else { false } }
    }

    /// The reply as the watch reads it: `response` on success, `error` otherwise.
    static func dictionary(_ reply: Reply) -> [String: Any] {
        switch reply {
        case .done(let text): return ["status": "done", "response": text]
        case .refused(let reason): return ["status": "refused", "error": reason]
        }
    }
}

/// Runs a resolved watch command on the phone. `stage` is the very `PreparedCardStager.stage` the
/// Display's **Send on phone** calls; directions, later and dismiss are the card's own actions.
@MainActor
final class WatchPreparedCardHandler {
    var cards: () -> [PreparedCard] = { [] }
    var stage: (PreparedCard) async -> PreparedCardStager.Outcome = { _ in .nothingToStage }
    /// Runs one of the card's actions as a press away from the phone does
    /// (`AppState.performCardActionAway`). True when it ran now; false when it waits for the phone
    /// to be unlocked.
    var run: (PreparedAction, PreparedCard) -> Bool = { _, _ in false }
    var later: (PreparedCard) -> Void = { _ in }
    var dismiss: (PreparedCard) -> Void = { _ in }
    var now: () -> Date = Date.init
    var calendar: Calendar = .autoupdatingCurrent

    init() {}

    func handle(_ message: [String: Any]) async -> WatchPreparedCardCommand.Reply {
        switch WatchPreparedCardCommand.resolve(message, cards: cards()) {
        case .refuse(let reason):
            return .refused(reason)
        case .run(let action, let card):
            return await perform(action, on: card)
        }
    }

    private func perform(_ action: WatchPreparedCardAction, on card: PreparedCard) async -> WatchPreparedCardCommand.Reply {
        switch action {
        case .stage:
            switch await stage(card) {
            case .openedComposer: return .done(PreparedCardHUDBuilder.stagedOpenLine)
            case .notified: return .done(PreparedCardHUDBuilder.stagedLine)
            case .nothingToStage: return .refused(WatchPreparedCardCommand.nothingToDoMessage)
            }
        case .directions:
            guard let directions = WatchPreparedCardCommand.directions(card) else {
                return .refused(WatchPreparedCardCommand.nothingToDoMessage)
            }
            return .done(run(directions, card) ? WatchPreparedCardCommand.directionsMessage
                                               : PreparedCardHUDBuilder.openOnPhoneLine)
        case .later:
            let now = now()
            guard !PreparedCardLaterOption.available(validUntil: card.validUntil, now: now, calendar: calendar).isEmpty
            else { return .refused(WatchPreparedCardCommand.cannotWaitMessage) }
            later(card)
            return .done(WatchPreparedCardCommand.laterMessage)
        case .dismiss:
            dismiss(card)
            return .done(WatchPreparedCardCommand.dismissedMessage)
        }
    }
}
