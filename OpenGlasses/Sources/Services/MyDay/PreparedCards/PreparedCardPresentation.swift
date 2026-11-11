import Foundation

// Plan KT §5 — what the My Day page and the home cards draw for a card, decided without SwiftUI so
// the labels, the "Ready" mark, the hand-off note, "N more ready" and the VoiceOver reading are
// value tests. The views only lay these out.

/// One button on a card.
struct PreparedCardButtonModel: Equatable, Identifiable {
    let action: PreparedAction
    /// Names the effect and, for a message, the person: "Text Ana", "Email Tom", "Directions",
    /// "Send report". Never "Send" alone.
    let label: String
    let systemImage: String

    var id: String { label }
    var isHandOff: Bool { if case .handOff = action { true } else { false } }
}

struct PreparedCardDraftModel: Equatable {
    /// "To Ana Example · Messages".
    let recipientLine: String
    let text: String
    /// Where the text came from: "Simple draft", "Drafted on this iPhone", "Drafted by …".
    let footer: String
    let channel: DraftChannel
}

/// One card as the phone draws it.
struct PreparedCardModel: Equatable, Identifiable {
    let id: PreparedCardID
    let kind: PreparedCardKind
    let chips: [CardSignal]
    let headline: String
    let subject: String?
    let facts: [CardFact]
    let draft: PreparedCardDraftModel?
    let primary: PreparedCardButtonModel
    let secondary: [PreparedCardButtonModel]
    let laterOptions: [PreparedCardLaterOption]
    /// A hand-off with no result: "Opened in WhatsApp", with Done and Not sent.
    let handedOffNote: String?
    /// "Times changed — update draft?", with the new draft to update to.
    let changedDraft: String?
    /// §5.5: headline, then "because: …", then the facts, then the draft with its recipient.
    let accessibilityLabel: String

    static var readyLabel: String { String(localized: "Ready", comment: "My Day: the small label on a card that has something prepared.") }

    /// Every chip read as one element: "because: Slept 5h 10m; Free from 10".
    static func because(_ chips: [CardSignal]) -> String? {
        guard !chips.isEmpty else { return nil }
        let reasons = chips.map(\.text).joined(separator: "; ")
        return String(localized: "because: \(reasons)", comment: "VoiceOver: the reasons a My Day card exists, read after its headline.")
    }
}

enum PreparedCardPresentation {

    static func model(_ card: PreparedCard, memory: PreparedCardMemory?, changedDraft: String?,
                      now: Date, calendar: Calendar) -> PreparedCardModel {
        let draft = card.draft.map(draftModel)
        let primary = button(card.primary, card: card)
        let secondary = card.secondary.filter { $0 != .later && $0 != .dismiss }.map { button($0, card: card) }
        var note: String?
        if case .handedOff(_, .unknown)? = memory?.state, let channel = card.draft?.channel {
            note = String(localized: "Opened in \(appName(channel))", comment: "My Day card: the draft was handed to another app, which gives no result.")
        }
        var spoken = [card.headline]
        if let subject = card.subject { spoken.append(subject) }
        if let because = PreparedCardModel.because(card.signals) { spoken.append(because) }
        spoken += card.facts.map { "\($0.label) \($0.value)" }
        if let draft {
            spoken.append(String(localized: "Draft \(draft.recipientLine): \(draft.text)",
                                 comment: "VoiceOver: a My Day card's drafted message and who it is to."))
        }
        if let note { spoken.append(note) }
        return PreparedCardModel(
            id: card.id, kind: card.kind, chips: card.signals, headline: card.headline, subject: card.subject,
            facts: card.facts, draft: draft, primary: primary, secondary: secondary,
            laterOptions: PreparedCardLaterOption.available(validUntil: card.validUntil, now: now, calendar: calendar),
            handedOffNote: note, changedDraft: changedDraft,
            accessibilityLabel: spoken.joined(separator: ". "))
    }

    static func draftModel(_ draft: PreparedDraft) -> PreparedCardDraftModel {
        let footer: String
        switch draft.origin {
        case .template: footer = String(localized: "Simple draft", comment: "My Day card: the draft is the plain built-in wording.")
        case .onDevice: footer = String(localized: "Drafted on this iPhone", comment: "My Day card: the draft was written on the phone.")
        case .cloud(let provider): footer = String(localized: "Drafted by \(provider)", comment: "My Day card: the draft was written by the named AI provider.")
        }
        return PreparedCardDraftModel(
            recipientLine: String(localized: "To \(draft.recipient.name) · \(channelName(draft.channel))",
                                  comment: "My Day card: who a draft is to, and how it goes."),
            text: draft.text, footer: footer, channel: draft.channel)
    }

    static func channelName(_ channel: DraftChannel) -> String {
        switch channel {
        case .messages: String(localized: "Messages", comment: "A way a draft is sent.")
        case .email: String(localized: "Email", comment: "A way a draft is sent.")
        case .whatsapp: "WhatsApp"
        }
    }

    static func appName(_ channel: DraftChannel) -> String {
        switch channel {
        case .messages: String(localized: "Messages", comment: "The app a draft opened in.")
        case .email: String(localized: "your mail app", comment: "The app a draft opened in: the wearer's default mail app.")
        case .whatsapp: "WhatsApp"
        }
    }

    static func button(_ action: PreparedAction, card: PreparedCard) -> PreparedCardButtonModel {
        switch action {
        case .handOff(let ref):
            let first = card.draft.flatMap { PreparedCardRules.firstName($0.recipient.name) }
            let label: String
            if card.kind == .meetingFollowUp {
                label = String(localized: "Email recap", comment: "My Day card button: open the meeting recap in Mail.")
            } else if ref.channel == .email {
                label = first.map { String(localized: "Email \($0)", comment: "My Day card button: open the draft to this person in Mail.") }
                    ?? String(localized: "Open email", comment: "My Day card button: open the draft in Mail.")
            } else {
                label = first.map { String(localized: "Text \($0)", comment: "My Day card button: open the draft to this person in Messages.") }
                    ?? String(localized: "Open message", comment: "My Day card button: open the draft in Messages.")
            }
            return .init(action: action, label: label, systemImage: ref.channel == .email ? "envelope" : "message")
        case .directions:
            return .init(action: action, label: String(localized: "Directions", comment: "My Day card button."),
                         systemImage: "arrow.triangle.turn.up.right.diamond")
        case .openEvent:
            return .init(action: action, label: String(localized: "Open event", comment: "My Day card button."),
                         systemImage: "calendar")
        case .openJob:
            return .init(action: action, label: String(localized: "Open job", comment: "My Day card button."),
                         systemImage: "wrench.and.screwdriver")
        case .openReport:
            return .init(action: action, label: String(localized: "Send report", comment: "My Day card button: opens the job report's composer."),
                         systemImage: "doc.text")
        case .openPartsOrder:
            return .init(action: action, label: String(localized: "Send parts order", comment: "My Day card button: opens the parts order's composer."),
                         systemImage: "shippingbox")
        case .getSignOff:
            return .init(action: action, label: String(localized: "Get sign-off", comment: "My Day card button: opens the job for the customer's signature."),
                         systemImage: "signature")
        case .addToCalendar:
            return .init(action: action, label: String(localized: "Add to calendar", comment: "My Day card button."),
                         systemImage: "calendar.badge.plus")
        case .call(let contact):
            let first = PreparedCardRules.firstName(contact.name) ?? contact.name
            return .init(action: action, label: String(localized: "Call \(first)", comment: "My Day card button: phone this person."),
                         systemImage: "phone")
        case .complete:
            return .init(action: action, label: String(localized: "Done", comment: "My Day card button: complete the reminder."),
                         systemImage: "checkmark.circle")
        case .later:
            return .init(action: action, label: String(localized: "Later", comment: "My Day card button."), systemImage: "clock")
        case .dismiss:
            return .init(action: action, label: String(localized: "Dismiss", comment: "My Day card button."), systemImage: "xmark")
        }
    }

    /// The page's cards, in the feed's order.
    static func page(_ feed: PreparedCardFeed, memory: [PreparedCardID: PreparedCardMemory], now: Date,
                     calendar: Calendar) -> [PreparedCardModel] {
        feed.feed.cards.map { model($0, memory: memory[$0.id], changedDraft: feed.changedDrafts[$0.id],
                                    now: now, calendar: calendar) }
    }
}

/// The home card's share of the cards (§5.2): the top one in compact form, and "N more ready".
struct PreparedCardHomeModel: Equatable {
    let top: PreparedCardModel?
    let moreReadyCount: Int

    var moreReadyText: String? {
        moreReadyCount > 0
            ? String(localized: "\(moreReadyCount) more ready", comment: "My Day home card: how many more prepared cards wait on the My Day page.")
            : nil
    }

    /// `includes` scopes the cards: the job day's card shows job cards, and personal ones only
    /// when My Day's items are folded into it.
    static func make(_ feed: PreparedCardFeed, memory: [PreparedCardID: PreparedCardMemory], now: Date,
                     calendar: Calendar, includes: (PreparedCardKind) -> Bool = { _ in true }) -> PreparedCardHomeModel {
        let cards = feed.feed.cards.filter { includes($0.kind) }
        guard let first = cards.first else { return PreparedCardHomeModel(top: nil, moreReadyCount: 0) }
        return PreparedCardHomeModel(
            top: PreparedCardPresentation.model(first, memory: memory[first.id],
                                                changedDraft: feed.changedDrafts[first.id], now: now, calendar: calendar),
            moreReadyCount: cards.count - 1)
    }
}
