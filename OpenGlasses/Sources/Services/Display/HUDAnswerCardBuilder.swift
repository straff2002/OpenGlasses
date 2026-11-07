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
}

/// Builds the answer card's `HUDScreen`s from the pager's pages and the answer's follow-ups
/// (Plan KP §3, decision 3). Pure: actions are reported through the injected `onAction`.
///
/// | Page | Lines | Buttons |
/// |---|---|---|
/// | the first of several | the page, footer "1/3" | Next › · Actions |
/// | a middle page | the page, footer "2/3" | Next › · Actions · ‹ Back |
/// | the last (or only) | the page, footer when paged | up to two follow-ups · Actions · ‹ Back (paged only) |
/// | Actions (pushed) | the answer's first line | third follow-up (if any) · Page (when the turn staged a page the lens can show) · More · Repeat · Save · Send · ‹ Answer · Close |
///
/// P1 put ‹ Back on middle pages too (P0 had it on the paged last page only): with the band
/// alone, a wearer two pages in had no way back but to read on to the end.
enum HUDAnswerCardBuilder {
    /// Follow-ups shown beside Actions on the last page; a third goes on the Actions screen.
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

    /// The card for one page. `index` is clamped into the pages; nil when there are no pages.
    static func page(_ pages: [HUDAnswerPage],
                     index: Int,
                     followUps: [String],
                     onAction: @escaping (HUDAnswerAction) -> Void) -> HUDScreen? {
        guard !pages.isEmpty else { return nil }
        let page = pages[min(max(index, 0), pages.count - 1)]

        var lines: [HUDLine]
        if page.isPaged {
            lines = page.lines.enumerated().map { offset, text in
                let isMoreLine = page.isCapped && offset == page.lines.count - 1
                return HUDLine(text, emphasis: isMoreLine ? .secondary : .primary)
            }
            if let footer = page.footer { lines.append(HUDLine(footer, emphasis: .meta)) }
        } else {
            lines = [HUDLine(page.body)]
        }

        var items: [HUDItem] = []
        if page.isLast {
            for (offset, question) in followUps.prefix(followUpsOnLastPage).enumerated() {
                items.append(followUpItem(offset, question, onAction))
            }
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
        return HUDScreen(title: nil, lines: lines, items: items)
    }

    /// The pushed Actions screen: the answer's first line as a reminder, the third follow-up if
    /// there is one, **Page** when the turn staged a page the lens can show (Plan KV §4), then
    /// More, Repeat, Save, Send, ‹ Answer (back to the page) and Close.
    static func actions(_ pages: [HUDAnswerPage],
                        followUps: [String],
                        hasPage: Bool = false,
                        onAction: @escaping (HUDAnswerAction) -> Void) -> HUDScreen {
        var lines: [HUDLine] = []
        if let first = pages.first?.lines.first, !first.isEmpty {
            lines.append(HUDLine(first, emphasis: .secondary))
        }
        var items: [HUDItem] = []
        let extra = Array(followUps.prefix(maxFollowUps).dropFirst(followUpsOnLastPage))
        for (offset, question) in extra.enumerated() {
            items.append(followUpItem(followUpsOnLastPage + offset, question, onAction))
        }
        if hasPage {
            items.append(item(ItemID.page, String(localized: "Page", comment: "Answer card action: show the cited manual page on the glasses."),
                              .secondary, .page, onAction))
        }
        items.append(item(ItemID.more, String(localized: "More"), .primary, .more, onAction))
        items.append(item(ItemID.repeatAnswer, String(localized: "Repeat"), .secondary, .repeatAnswer, onAction))
        items.append(item(ItemID.save, String(localized: "Save"), .secondary, .save, onAction))
        items.append(item(ItemID.send, String(localized: "Send"), .secondary, .send, onAction))
        items.append(item(ItemID.answer, String(localized: "‹ Answer"), .outline, .answer, onAction))
        items.append(item(ItemID.close, String(localized: "Close"), .outline, .close, onAction))
        return HUDScreen(title: nil, lines: lines, items: items)
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
