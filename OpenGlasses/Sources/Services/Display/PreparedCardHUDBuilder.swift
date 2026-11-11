import Foundation

/// What a press on a card's lens screens asks for (Plan KT §6.3). The builder only reports the
/// press; `HUDRouter` decides what each one does.
enum PreparedCardLensAction: Equatable {
    /// One of the card's own actions that runs from the lens as it is: directions, an open, a
    /// reminder done. Never a hand-off: that opens the draft.
    case run(PreparedAction)
    /// Push the draft screen.
    case draft
    case nextCard
    case previousCard
    case close
    /// The draft's next page.
    case nextPage
    /// The draft's previous page, or from its first page back to the card.
    case back
    /// Stage the draft on the phone (§6.4).
    case sendOnPhone
    case readIt
    case later
    case dismiss
    case notUseful
    /// A pushed glance's **Open**: the stack, at that card.
    case open
}

/// A press, and the card it was made on, so a press on a card that has since expired or been
/// rebuilt is dropped.
struct PreparedCardLensPress: Equatable {
    let action: PreparedCardLensAction
    let cardID: PreparedCardID
}

/// Builds the lens screens of Plan KT §6.3 from the feed's cards. Pure: the same cards and
/// geometry always give the same screens, and every press is reported through `onPress`.
///
/// | Screen | Title | Lines | Buttons (at most three) |
/// |---|---|---|---|
/// | the stack, card *i* of *n* | the headline | the chips as one meta line, one or two facts, "i/n" | the primary · the draft action (or the first secondary) · **Next ›** (**Close** on the last card) |
/// | the draft | "To Ana · Messages" | a page of the draft, "1/3" when paged | **Send on phone** (**Next ›** until the last page) · **Read it** · **‹ Back** |
/// | a pushed glance (§6.2) | the headline | one fact | **Open** · **Close** |
///
/// **Sensitivity (§6.6).** A health chip shows on the lens as "Short night", never its numbers.
/// The web mirror gets the strictest column: a health card is hidden there, and a draft's text is
/// hidden on every draft screen (`HUDScreen.mirror`).
///
/// "Later", "Dismiss" and "Not useful" are not buttons: the three slots go to doing things, and
/// those are said ("later", "not useful") while the stack is on the lens.
enum PreparedCardHUDBuilder {
    /// §6.3: a screen holds at most three buttons, so focus moves in one short sweep.
    static let maxButtons = 3
    /// §6.3: a stack screen shows at most two facts.
    static let maxFacts = 2

    enum ItemID {
        static let primary = "kt.primary"
        static let second = "kt.second"
        static let nextCard = "kt.next"
        static let close = "kt.close"
        static let draftNext = "kt.draft.next"
        static let send = "kt.draft.send"
        static let read = "kt.draft.read"
        static let back = "kt.draft.back"
        static let open = "kt.glance.open"
        static let glanceClose = "kt.glance.close"
    }

    // MARK: Strings

    /// §6.6: what a health chip says on the lens.
    static var shortNightChip: String {
        String(localized: "Short night", comment: "Glasses: a sleep reason on a card, shown without the hours slept.")
    }
    /// §6.3: the flash after **Send on phone**.
    static var stagedLine: String {
        String(localized: "Ready on your phone — tap the notification to send.",
               comment: "Glasses: shown for three seconds after a drafted message was put on the phone to send.")
    }
    /// §6.3: the same, when the phone opened the message straight away.
    static var stagedOpenLine: String {
        String(localized: "Open on your phone — tap Send there.",
               comment: "Glasses: shown after a drafted message opened on the phone, which is in front and unlocked.")
    }
    /// After a press that needs the phone, made while the phone is away.
    static var openOnPhoneLine: String {
        String(localized: "On your phone when you unlock it", comment: "Glasses: a card's action will open on the phone once it is unlocked.")
    }
    /// The web mirror's line in place of a card with health content.
    static var mirrorHiddenLine: String {
        String(localized: "Shown on the glasses only", comment: "Web display mirror: a card it may not show.")
    }
    /// The web mirror's line in place of a draft's text.
    static var mirrorDraftHiddenLine: String {
        String(localized: "Message hidden here", comment: "Web display mirror: stands in for a drafted message's text.")
    }
    static var nextLabel: String { String(localized: "Next ›", comment: "Glasses: next card, or the draft's next page.") }
    static var closeLabel: String { String(localized: "Close", comment: "Glasses: closes the cards.") }
    static var sendLabel: String {
        String(localized: "Send on phone", comment: "Glasses: puts the drafted message on the phone, ready to send there.")
    }
    static var readLabel: String { String(localized: "Read it", comment: "Glasses: reads the drafted message aloud.") }
    static var backLabel: String { String(localized: "‹ Back", comment: "Glasses: back a page, or back to the card.") }
    static var openLabel: String { String(localized: "Open", comment: "Glasses: opens a card that was shown unasked.") }

    // MARK: - The stack

    /// Card `index` of `cards` (clamped), or nil with no cards.
    static func stack(_ cards: [PreparedCard], index: Int, geometry: TeleprompterPaginator.Geometry,
                      onPress: @escaping (PreparedCardLensPress) -> Void) -> HUDScreen? {
        guard !cards.isEmpty else { return nil }
        let position = min(max(index, 0), cards.count - 1)
        let card = cards[position]
        let width = max(1, geometry.maxChars)
        let paged = cards.count > 1

        var lines: [HUDLine] = []
        if let meta = metaLine(card, maxChars: width) { lines.append(meta) }
        let room = max(0, geometry.maxLines - lines.count - (paged ? 1 : 0))
        lines += factLines(card, limit: min(maxFacts, room), maxChars: width)
        if paged { lines.append(HUDLine("\(position + 1)/\(cards.count)", emphasis: .meta)) }

        var items: [HUDItem] = []
        let press: (PreparedCardLensAction) -> () -> Void = { action in
            { onPress(PreparedCardLensPress(action: action, cardID: card.id)) }
        }
        items.append(HUDItem(id: ItemID.primary, label: label(card.primary, card: card),
                             icon: icon(card.primary), style: .primary,
                             action: press(lensAction(card.primary))))
        if let second = secondAction(card) {
            items.append(HUDItem(id: ItemID.second, label: label(second, card: card), icon: icon(second),
                                 style: .secondary, action: press(lensAction(second))))
        }
        if position + 1 < cards.count {
            items.append(HUDItem(id: ItemID.nextCard, label: nextLabel, style: .outline, action: press(.nextCard)))
        } else {
            items.append(HUDItem(id: ItemID.close, label: closeLabel, style: .outline, action: press(.close)))
        }

        var screen = HUDScreen(title: card.headline, lines: lines, items: items, focusItemID: ItemID.primary)
        if card.sensitivity == .health { screen.mirror = .hidden(placeholder: mirrorHiddenLine) }
        return screen
    }

    /// The second slot: the draft action when the primary is not already it, else the first
    /// secondary that does something. Never Later or Dismiss.
    static func secondAction(_ card: PreparedCard) -> PreparedAction? {
        let doing = card.secondary.filter { $0 != .later && $0 != .dismiss }
        if !isHandOff(card.primary), card.draft != nil, let handOff = doing.first(where: isHandOff) {
            return handOff
        }
        return doing.first { !isHandOff($0) }
    }

    /// The chips as one meta line ("19:00 · 34 min · rain"), the first chip's icon leading, as many
    /// whole chips as fit the line. A health chip reads "Short night" (§6.6). Nil with no chips.
    static func metaLine(_ card: PreparedCard, maxChars: Int) -> HUDLine? {
        let texts = lensChips(card)
        guard let first = card.signals.first, let lead = texts.first else { return nil }
        // Whole chips while they fit; the first is cut only when it alone is too long.
        var line = PreparedCardText.clipped(lead, to: maxChars)
        for text in texts.dropFirst() {
            let longer = line + " · " + text
            guard longer.count <= maxChars else { break }
            line = longer
        }
        return HUDLine(line, icon: icon(first.source), emphasis: .meta)
    }

    /// The chips' texts as the lens shows them, health ones replaced, repeats dropped.
    static func lensChips(_ card: PreparedCard) -> [String] {
        var texts: [String] = []
        for signal in card.signals {
            let text = signal.sensitivity == .health ? shortNightChip : signal.text
            if !text.isEmpty, !texts.contains(text) { texts.append(text) }
        }
        return texts
    }

    /// Up to `limit` facts as "Label value" lines, skipping one the headline already says ("Leave
    /// by 18:15" under the headline "Leave by 18:15"). With no fact to show, the subject.
    static func factLines(_ card: PreparedCard, limit: Int, maxChars: Int) -> [HUDLine] {
        guard limit > 0 else { return [] }
        let facts = card.facts.filter { !card.headline.contains($0.value) }
        let shown = facts.prefix(limit).map { fact in
            HUDLine(PreparedCardText.clipped("\(fact.label) \(fact.value)", to: maxChars), emphasis: .secondary)
        }
        if shown.isEmpty, let subject = card.subject, !subject.isEmpty {
            return [HUDLine(PreparedCardText.clipped(subject, to: maxChars), emphasis: .secondary)]
        }
        return Array(shown)
    }

    // MARK: - The draft

    /// "To Ana · Messages": the draft screen's title, inside a title's length.
    static func draftTitle(_ draft: PreparedDraft) -> String {
        PreparedCardText.clipped(PreparedCardPresentation.draftModel(draft).recipientLine, to: HUDTextShaper.maxTitleLength)
    }

    /// The draft cut into pages with KP's pager and geometry.
    static func draftPages(_ card: PreparedCard, geometry: TeleprompterPaginator.Geometry) -> [HUDAnswerPage] {
        guard let draft = card.draft else { return [] }
        return HUDAnswerPager.pages(for: draft.text, geometry: geometry)
    }

    /// Page `page` (clamped) of the card's draft, or nil without a draft. **Send on phone** shows
    /// only on the last page, so the wearer has seen the whole message before they can stage it.
    static func draft(_ card: PreparedCard, page: Int, geometry: TeleprompterPaginator.Geometry,
                      onPress: @escaping (PreparedCardLensPress) -> Void) -> HUDScreen? {
        guard let draft = card.draft else { return nil }
        let pages = draftPages(card, geometry: geometry)
        guard !pages.isEmpty else { return nil }
        let shown = pages[min(max(page, 0), pages.count - 1)]

        // The pager's wrapped lines, one HUD line each, so a page is exactly the geometry's shape.
        var lines = shown.lines.map { HUDLine($0) }
        if let footer = shown.footer { lines.append(HUDLine(footer, emphasis: .meta)) }

        let press: (PreparedCardLensAction) -> () -> Void = { action in
            { onPress(PreparedCardLensPress(action: action, cardID: card.id)) }
        }
        var items: [HUDItem] = []
        if shown.isLast {
            items.append(HUDItem(id: ItemID.send, label: sendLabel, icon: .message, style: .primary,
                                 action: press(.sendOnPhone)))
        } else {
            items.append(HUDItem(id: ItemID.draftNext, label: nextLabel, style: .primary, action: press(.nextPage)))
        }
        items.append(HUDItem(id: ItemID.read, label: readLabel, style: .secondary, action: press(.readIt)))
        items.append(HUDItem(id: ItemID.back, label: backLabel, style: .outline, action: press(.back)))

        var screen = HUDScreen(title: draftTitle(draft), lines: lines, items: items)
        // §6.6: a draft's text is personal, so the mirror never shows it; a health card not at all.
        screen.mirror = card.sensitivity == .health
            ? .hidden(placeholder: mirrorHiddenLine)
            : .lines([HUDLine(mirrorDraftHiddenLine, icon: .message, emphasis: .meta)])
        return screen
    }

    // MARK: - A pushed glance (§6.2)

    /// The headline and one fact, with **Open** · **Close**.
    static func glance(_ card: PreparedCard, geometry: TeleprompterPaginator.Geometry,
                       onPress: @escaping (PreparedCardLensPress) -> Void) -> HUDScreen {
        let lines = factLines(card, limit: 1, maxChars: max(1, geometry.maxChars))
        let items = [
            HUDItem(id: ItemID.open, label: openLabel, style: .primary) {
                onPress(PreparedCardLensPress(action: .open, cardID: card.id))
            },
            HUDItem(id: ItemID.glanceClose, label: closeLabel, style: .outline) {
                onPress(PreparedCardLensPress(action: .close, cardID: card.id))
            },
        ]
        var screen = HUDScreen(title: card.headline, lines: lines, items: items, focusItemID: ItemID.open)
        if card.sensitivity == .health { screen.mirror = .hidden(placeholder: mirrorHiddenLine) }
        return screen
    }

    // MARK: - Actions

    static func isHandOff(_ action: PreparedAction) -> Bool {
        if case .handOff = action { return true }
        return false
    }

    /// What a card's action does from the lens: a hand-off opens the draft; the rest run.
    static func lensAction(_ action: PreparedAction) -> PreparedCardLensAction {
        switch action {
        case .handOff: return .draft
        case .later: return .later
        case .dismiss: return .dismiss
        default: return .run(action)
        }
    }

    /// The phone's own label for the action ("Text Ana", "Directions"), so the lens and the page
    /// name it the same.
    static func label(_ action: PreparedAction, card: PreparedCard) -> String {
        PreparedCardPresentation.button(action, card: card).label
    }

    static func icon(_ action: PreparedAction) -> HUDIcon {
        switch action {
        case .handOff: return .message
        case .directions: return .navigation
        case .openEvent, .addToCalendar: return .calendar
        case .complete: return .success
        case .call: return .message
        default: return .none
        }
    }

    static func icon(_ source: CardSource) -> HUDIcon {
        switch source {
        case .calendar: return .calendar
        case .reminders: return .reminder
        case .travel: return .navigation
        case .weather: return .weather
        case .sleep: return .clock
        case .location: return .location
        case .meeting: return .microphone
        case .job: return .info
        }
    }
}
