import Foundation

/// What the reading view shows (Plan MG §2): the turn at the top — the newest, or an earlier one
/// the wearer opened — and the earlier turns under it, newest first. Pure data.
struct HUDReadingViewState {
    struct Turn {
        let id: Int
        /// The question line as the card draws it ("You: …"); nil for a turn the app started.
        let question: String?
        let text: String
        let isComplete: Bool
        let followUps: [String]
        /// The turn staged a manual page the lens can show now: **Page** leads the buttons.
        let hasPage: Bool
    }

    var top: Turn
    /// False when the top is an earlier turn the wearer opened: its buttons then lead with
    /// **‹ Latest**.
    var topIsLatest: Bool = true
    /// The turns under the top one, newest first.
    var earlier: [LensConversationTurn] = []
}

/// Builds the reading view's screen (Plan MG §2): one view per answer on the Meta Display, a
/// column the band steps through and the lens scrolls. Pure: presses are reported through
/// `onAction`.
///
/// ```
/// You: what size breaker for the condenser      (meta line)
/// ┌ For a 3-ton unit on 230 V, the nameplate … ┐  a row: a paragraph, or ≤ 4 lines of one
/// ┌ Wire it with 10 AWG copper …              ┐  a row
/// [ Page ] [ follow-up ] [ Actions ] [ Close ]    the answer's buttons (≤ 4)
/// Earlier                                         (meta line)
/// ┌ You: refrigerant charge for the …         ┐  an earlier turn: its question and first
/// └ R-410A, 7 lb 4 oz factory charge …        ┘  two lines
/// ```
///
/// - **Rows** are cards (`HUDBlock.Style.card`, the only way the lens shows focus on a box). A
///   press on one says the answer again from that row to its end (decision 3).
/// - **Buttons.** The newest turn's: **Page** first when the turn staged one, then its follow-ups
///   (two, or one beside **Page**; the rest are on the Actions screen), **Actions** and **Close**.
///   An opened earlier turn's: **‹ Latest** and **Close**. Four at most (KV's rule).
/// - **Focus.** No button takes it (`HUDScreen.focusesFirstBlock`), so the first row does and the
///   lens opens at the top, where the wearer starts reading.
/// - **Earlier** turns are collapsed to their question and first two lines; a press opens one at
///   the top of the view, whole.
/// - **Caps** (provisional until the glasses time a send): `maxRows` blocks and `maxCharacters`
///   characters in one view. Past them the oldest earlier turns go first, then the top answer ends
///   in "… more on phone".
enum HUDReadingViewBuilder {
    static let maxRows = 40
    static let maxCharacters = 4000
    /// An earlier turn shows its first two lines.
    static let collapsedLines = 2
    static let maxButtons = 4

    enum ItemID {
        static let latest = "mg.latest"
        static func row(turn: Int, index: Int) -> String { "mg.row.\(turn).\(index)" }
        static func turn(_ id: Int) -> String { "mg.turn.\(id)" }
    }

    static var earlierHeading: String {
        String(localized: "Earlier", comment: "Glasses: heading over the conversation's earlier answers on the lens.")
    }

    static var latestLabel: String {
        String(localized: "‹ Latest", comment: "Glasses: go back to the newest answer from an earlier one.")
    }

    static func screen(_ state: HUDReadingViewState,
                       geometry: TeleprompterPaginator.Geometry,
                       onAction: @escaping (HUDAnswerAction) -> Void) -> HUDScreen {
        let chars = HUDReadingRows.maxChars(for: geometry)
        let top = state.top
        let allRows = HUDReadingRows.rows(for: top.text, maxChars: chars)

        // The caps: the oldest earlier turns go first, then the top answer is cut short.
        var earlier = state.earlier
        let questionChars = top.question?.count ?? 0
        func earlierChars(_ turns: [LensConversationTurn]) -> Int {
            turns.reduce(0) { $0 + collapsedLines(for: $1, maxChars: chars).reduce(0) { $0 + $1.text.count } }
        }
        let topChars = questionChars + allRows.reduce(0) { $0 + $1.text.count }
        while !earlier.isEmpty,
              allRows.count + earlier.count > maxRows || topChars + earlierChars(earlier) > maxCharacters {
            earlier.removeLast()
        }
        var rows = allRows
        var capped = false
        let moreLine = HUDAnswerPager.moreOnPhoneLine
        if rows.count + earlier.count > maxRows || topChars + earlierChars(earlier) > maxCharacters {
            capped = true
            let roomRows = max(1, maxRows - earlier.count)
            let roomChars = maxCharacters - questionChars - earlierChars(earlier) - moreLine.count
            var kept: [HUDReadingRow] = []
            var used = 0
            for row in rows where kept.count < roomRows {
                guard used + row.text.count <= roomChars || kept.isEmpty else { break }
                kept.append(row)
                used += row.text.count
            }
            rows = kept
        }

        var screen = HUDScreen(title: nil,
                               lines: top.question.map { [HUDLine($0, emphasis: .meta)] } ?? [],
                               items: items(state, onAction))
        screen.flow = rows.enumerated().map { index, row in
            let spoken = HUDReadingRows.spokenText(from: index, in: allRows)
            return .blocks([HUDBlock(id: ItemID.row(turn: top.id, index: index),
                                     lines: row.lines.map { HUDLine($0) }, style: .card,
                                     action: { onAction(.repeatFrom(row: index, text: spoken)) })])
        }
        if capped { screen.flow.append(.line(HUDLine(moreLine, emphasis: .secondary))) }
        if !earlier.isEmpty {
            screen.trailingFlow = [.line(HUDLine(earlierHeading, emphasis: .meta))]
            for turn in earlier {
                let id = turn.id
                screen.trailingFlow.append(.blocks([HUDBlock(id: ItemID.turn(id),
                                                             lines: collapsedLines(for: turn, maxChars: chars),
                                                             style: .card,
                                                             action: { onAction(.openTurn(id: id)) })]))
            }
        }
        screen.focusesFirstBlock = true
        return screen
    }

    /// An earlier turn, collapsed: its question line, then its first two lines, the second ending
    /// in "…" when there is more.
    static func collapsedLines(for turn: LensConversationTurn, maxChars: Int) -> [HUDLine] {
        var lines: [HUDLine] = []
        if let question = turn.question, !question.isEmpty {
            lines.append(HUDLine(HUDTextShaper.condense(question, max: maxChars), emphasis: .meta))
        }
        let display = HUDAnswerPager.displayLines(for: turn.answer, maxChars: maxChars)
        var shown = Array(display.prefix(collapsedLines))
        if display.count > collapsedLines, let last = shown.last {
            let room = max(1, maxChars - 1)
            shown[shown.count - 1] = (last.count > room ? String(last.prefix(room)) : last) + "…"
        }
        lines += shown.map { HUDLine($0, emphasis: .secondary) }
        return lines
    }

    /// The view's buttons (see the type's note).
    static func items(_ state: HUDReadingViewState,
                      _ onAction: @escaping (HUDAnswerAction) -> Void) -> [HUDItem] {
        var items: [HUDItem] = []
        guard state.topIsLatest else {
            items.append(item(ItemID.latest, latestLabel, .secondary, .latest, onAction))
            items.append(item(HUDAnswerCardBuilder.ItemID.close, String(localized: "Close"), .outline, .close, onAction))
            return items
        }
        let top = state.top
        if top.hasPage {
            items.append(item(HUDAnswerCardBuilder.ItemID.page,
                              String(localized: "Page", comment: "Answer card action: show the cited manual page on the glasses."),
                              .secondary, .page, onAction))
        }
        if top.isComplete {
            let room = HUDAnswerCardBuilder.followUpsOnLastPage(hasPage: top.hasPage)
            for (offset, question) in top.followUps.prefix(room).enumerated() {
                items.append(item(HUDAnswerCardBuilder.ItemID.followUp(offset), question, .outline,
                                  .followUp(index: offset, text: question), onAction))
            }
        }
        items.append(item(HUDAnswerCardBuilder.ItemID.actions, String(localized: "Actions"), .secondary, .actions, onAction))
        items.append(item(HUDAnswerCardBuilder.ItemID.close, String(localized: "Close"), .outline, .close, onAction))
        return items
    }

    /// Characters of text a screen carries, for the caps and the support report.
    static func characters(in screen: HUDScreen) -> Int {
        (screen.linesBeforeItems + screen.linesAfterItems).reduce(0) { $0 + $1.text.count }
    }

    private static func item(_ id: String, _ label: String, _ style: HUDButtonStyle,
                             _ action: HUDAnswerAction,
                             _ onAction: @escaping (HUDAnswerAction) -> Void) -> HUDItem {
        HUDItem(id: id, label: label, style: style) { onAction(action) }
    }
}
