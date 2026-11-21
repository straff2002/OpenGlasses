import Foundation

/// What a press on an answer card asks for (Plan KP §3). The builder only reports the press;
/// the caller (P1) decides what each one does.
enum HUDAnswerAction: Equatable {
    case next
    case back
    case actions
    /// From the Actions screen, back to the page the wearer was reading.
    case answer
    case more
    case repeatAnswer
    case save
    case send
    case close
    /// A suggested follow-up, by its position in the answer's follow-up list, with its text.
    case followUp(index: Int, text: String)
    /// Plan KV §4: open the page the turn staged, on the lens.
    case page
    /// Plan MG §2: a press on a reading-view row — say the answer again from that row (decision 3).
    case repeatFrom(row: Int, text: String)
    /// Plan MG §2: open an earlier turn at the top of the reading view.
    case openTurn(id: Int)
    /// Plan MG §2: back from an earlier turn to the newest (**‹ Latest**).
    case latest
}

/// Builds the answer card's `HUDScreen`s from the pager's pages and the answer's follow-ups
/// (Plan KP §3, decision 3). Pure: actions are reported through the injected `onAction`.
///
/// | Page | Lines | Buttons |
/// |---|---|---|
/// | the first of several | the question (Plan KV §7), the page, footer "1/3" | Next › · Actions |
/// | a middle page | the page, footer "2/3" | Next › · Actions · ‹ Back |
/// | the last (or only) | the page, footer when paged | up to two follow-ups · Actions · ‹ Back (paged only) |
/// | …with a page to show | the page, footer when paged | first follow-up (if any) · Page · Actions · ‹ Back (paged only) |
/// | Actions (pushed) | the answer's first line | third follow-up (if any) · More · Repeat · Save · Send · ‹ Answer · Close |
/// | …with a page to show | the answer's first line | second and third follow-ups (if any) · More · Repeat · Save · Send · ‹ Answer · Close |
///
/// "A page to show" is a turn that staged a manual page the lens can show now (Plan KV §4,
/// `hasPage`). **Page** then sits on the last page, where the wearer finishes reading (Plan MG §5),
/// in the second follow-up's place; that follow-up moves to the Actions screen ahead of the third,
/// and the Actions screen no longer offers Page. The last page never has more than four buttons.
///
/// Page sizes are the caller's geometry: on the Meta Display, `LensPageFrame.answerGeometry` (10 ×
/// 32), so 9 lines of text and the footer, 8 under the question.
///
/// **On the Meta Display (Plan MU §3, `fitsLensRow`)** each row goes through `LensButtonRowBudget`:
/// a follow-up is cut to fit, and a row still too wide sends its follow-ups, then **Page**, to the
/// Actions screen (and ‹ Back, last, to voice). The Actions screen then lists every follow-up the
/// row doesn't carry, and **Page** when the row lost it. Its own row can't move anything to Actions,
/// so there the follow-ups, and the buttons that don't fit, are cards in the column over the row,
/// pressed as the buttons would be. Even keeps its rows as they are (`fitsLensRow` false).
///
/// The question line ("You: what size breaker", `questionLine(for:maxChars:)`) is in the meta
/// style, on the first page only, cut to one display line so it never wraps; the pager budgets
/// that page one line shorter for it (`HUDAnswerPager.pages(firstPageReservedLines:)`).
///
/// P1 put ‹ Back on middle pages too (P0 had it on the paged last page only): with the band
/// alone, a wearer two pages in had no way back but to read on to the end.
///
/// **The picture (Plan LC §5).** A vision answer's first page carries the analysed frame's
/// thumbnail (`HUDAnswerThumbnail`) as its `HUDScreen.picture`, under the text and over the
/// buttons, when `HUDAnswerThumbnail.fits` says the page and the picture fit the lens together;
/// otherwise the page is drawn without it. Later pages and the Actions screen never carry it.
enum HUDAnswerCardBuilder {
    /// Follow-ups shown beside Actions on the last page; a third goes on the Actions screen. One
    /// fewer beside **Page** (`followUpsOnLastPage(hasPage:)`).
    static let followUpsOnLastPage = 2
    /// All follow-ups the card shows (two on the last page, one on the Actions screen).
    static let maxFollowUps = 3

    /// Stable item ids, so a band press routes back by id.
    enum ItemID {
        static let next = "kp.next"
        static let back = "kp.back"
        static let actions = "kp.actions"
        static let answer = "kp.answer"
        static let more = "kp.more"
        static let repeatAnswer = "kp.repeat"
        static let save = "kp.save"
        static let send = "kp.send"
        static let close = "kp.close"
        /// Plan KV §4.
        static let page = "kv.answer.page"
        static func followUp(_ index: Int) -> String { "kp.followup.\(index)" }
    }

    /// The question line over the first page (Plan KV §7): "You:" and what the app heard,
    /// condensed to `maxChars` (one display line, so it never wraps). Nil for no question: a turn
    /// the app started.
    static func questionLine(for question: String?, maxChars: Int) -> String? {
        guard let question else { return nil }
        let heard = HUDTextShaper.condense(question, max: Int.max)
        guard !heard.isEmpty else { return nil }
        let prefix = String(localized: "You:",
                            comment: "Glasses: starts the line showing what the app heard the wearer ask, e.g. 'You: what size breaker'.")
        // `condense` adds "…" after the cut, so cut one short to keep the line inside `maxChars`.
        let line = HUDTextShaper.condense(prefix + " " + heard, max: max(1, maxChars - 1))
        return line.count <= maxChars ? line : String(line.prefix(maxChars))
    }

    /// The card for one page. `index` is clamped into the pages; nil when there are no pages.
    /// `question` is the shaped question line (`questionLine(for:maxChars:)`), shown over the
    /// first page only. `picture` is the frame a vision answer analysed (Plan LC §5): the first
    /// page carries it when the two fit the lens together. `hasPage` puts **Page** on the last page in
    /// the second follow-up's place.
    static func page(_ pages: [HUDAnswerPage],
                     index: Int,
                     followUps: [String],
                     question: String? = nil,
                     picture: HUDPicture? = nil,
                     hasPage: Bool = false,
                     fitsLensRow: Bool = false,
                     onAction: @escaping (HUDAnswerAction) -> Void) -> HUDScreen? {
        guard !pages.isEmpty else { return nil }
        let page = pages[min(max(index, 0), pages.count - 1)]

        var lines: [HUDLine] = []
        if page.index == 0, let question, !question.isEmpty {
            lines.append(HUDLine(question, emphasis: .meta))
        }
        // A page longer than one shaped body line (a backend cuts a line at
        // `HUDTextShaper.maxBodyLength`) goes line by line, as a paged page does.
        if page.isPaged || page.body.count > HUDTextShaper.maxBodyLength {
            lines += page.lines.enumerated().map { offset, text in
                let isMoreLine = page.isCapped && offset == page.lines.count - 1
                return HUDLine(text, emphasis: isMoreLine ? .secondary : .primary)
            }
            if let footer = page.footer { lines.append(HUDLine(footer, emphasis: .meta)) }
        } else {
            lines.append(HUDLine(page.body))
        }

        let row = rowItems(page, followUps: followUps, hasPage: hasPage, onAction: onAction)
        let items = fitsLensRow ? LensButtonRowBudget.fit(row, givingWay: rowGivingWay).row : row
        var screen = HUDScreen(title: nil, lines: lines, items: items)
        if page.index == 0, let picture, HUDAnswerThumbnail.fits(screen, picture: picture) {
            screen.picture = picture
        }
        return screen
    }

    /// The order a page's row gives way in on the Meta Display: the follow-ups (the second first),
    /// then **Page** (both to the Actions screen), then ‹ Back (still said as "back").
    static let rowGivingWay = [ItemID.followUp(1), ItemID.followUp(0), ItemID.page, ItemID.back]
    /// The order the Actions screen's buttons leave its row for the column on the Meta Display.
    static let actionsGivingWay = [ItemID.followUp(2), ItemID.followUp(1), ItemID.followUp(0),
                                   ItemID.send, ItemID.save, ItemID.repeatAnswer, ItemID.page, ItemID.more]

    /// A page's buttons before any width budget (see the type's table).
    static func rowItems(_ page: HUDAnswerPage, followUps: [String], hasPage: Bool,
                         onAction: @escaping (HUDAnswerAction) -> Void) -> [HUDItem] {
        var items: [HUDItem] = []
        if page.isLast {
            for (offset, question) in followUps.prefix(followUpsOnLastPage(hasPage: hasPage)).enumerated() {
                items.append(followUpItem(offset, question, onAction))
            }
            if hasPage { items.append(pageItem(onAction)) }
            items.append(item(ItemID.actions, String(localized: "Actions"), .secondary, .actions, onAction))
            if page.isPaged {
                items.append(item(ItemID.back, String(localized: "‹ Back"), .outline, .back, onAction))
            }
        } else {
            items.append(item(ItemID.next, String(localized: "Next ›"), .primary, .next, onAction))
            items.append(item(ItemID.actions, String(localized: "Actions"), .secondary, .actions, onAction))
            if page.index > 0 {
                items.append(item(ItemID.back, String(localized: "‹ Back"), .outline, .back, onAction))
            }
        }
        return items
    }

    /// The pushed Actions screen: the answer's first line as a reminder, the follow-ups the last
    /// page has no room for (the third; and the second too when `hasPage`, the turn having staged a
    /// page the lens can show, whose **Page** is on the last page), then More, Repeat, Save, Send,
    /// ‹ Answer (back to the page) and Close.
    ///
    /// Plan MU §3: `followUpsOnRow` is how many follow-ups the row the wearer came from carries (nil:
    /// the last page's usual count), and `offersPage` puts **Page** here when that row lost it. With
    /// `fitsLensRow` (the Meta Display), the follow-ups, and any button that doesn't fit the row, are
    /// cards in the column over it.
    static func actions(_ pages: [HUDAnswerPage],
                        followUps: [String],
                        hasPage: Bool = false,
                        followUpsOnRow: Int? = nil,
                        offersPage: Bool = false,
                        fitsLensRow: Bool = false,
                        onAction: @escaping (HUDAnswerAction) -> Void) -> HUDScreen {
        var lines: [HUDLine] = []
        if let first = pages.first?.lines.first, !first.isEmpty {
            lines.append(HUDLine(first, emphasis: .secondary))
        }
        var items: [HUDItem] = []
        let onRow = max(0, followUpsOnRow ?? followUpsOnLastPage(hasPage: hasPage))
        let extra = Array(followUps.prefix(maxFollowUps).dropFirst(onRow))
        for (offset, question) in extra.enumerated() {
            items.append(followUpItem(onRow + offset, question, onAction))
        }
        if offersPage { items.append(pageItem(onAction)) }
        items.append(item(ItemID.more, String(localized: "More"), .primary, .more, onAction))
        items.append(item(ItemID.repeatAnswer, String(localized: "Repeat"), .secondary, .repeatAnswer, onAction))
        items.append(item(ItemID.save, String(localized: "Save"), .secondary, .save, onAction))
        items.append(item(ItemID.send, String(localized: "Send"), .secondary, .send, onAction))
        items.append(item(ItemID.answer, String(localized: "‹ Answer"), .outline, .answer, onAction))
        items.append(item(ItemID.close, String(localized: "Close"), .outline, .close, onAction))
        guard fitsLensRow else { return HUDScreen(title: nil, lines: lines, items: items) }

        // The Meta Display: follow-ups are questions, never a button's width; they and whatever
        // else doesn't fit go in the column over the row, as cards pressed like the buttons.
        let questions = items.filter { LensButtonRowBudget.isCuttable($0.id) }
        let fitted = LensButtonRowBudget.fit(items.filter { !LensButtonRowBudget.isCuttable($0.id) },
                                             givingWay: actionsGivingWay, protected: [ItemID.answer])
        var screen = HUDScreen(title: nil, lines: lines, items: fitted.row)
        screen.flow = (questions + fitted.moved).map { moved in
            .blocks([HUDBlock(id: moved.id, lines: [HUDLine(moved.label)], style: .card, action: moved.action)])
        }
        return screen
    }

    /// Follow-ups on the last page: two, or one beside **Page**.
    static func followUpsOnLastPage(hasPage: Bool) -> Int {
        hasPage ? followUpsOnLastPage - 1 : followUpsOnLastPage
    }

    private static func pageItem(_ onAction: @escaping (HUDAnswerAction) -> Void) -> HUDItem {
        item(ItemID.page, String(localized: "Page", comment: "Answer card action: show the cited manual page on the glasses."),
             .secondary, .page, onAction)
    }

    private static func item(_ id: String, _ label: String, _ style: HUDButtonStyle,
                             _ action: HUDAnswerAction,
                             _ onAction: @escaping (HUDAnswerAction) -> Void) -> HUDItem {
        HUDItem(id: id, label: label, style: style) { onAction(action) }
    }

    private static func followUpItem(_ index: Int, _ question: String,
                                     _ onAction: @escaping (HUDAnswerAction) -> Void) -> HUDItem {
        item(ItemID.followUp(index), question, .outline, .followUp(index: index, text: question), onAction)
    }
}
