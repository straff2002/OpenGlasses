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
/// ┌ For a 3-ton unit on 230 V, the nameplate … ┐  a row: a paragraph, or ≤ 8 lines of one
/// ┌ Wire it with 10 AWG copper …              ┐  a row
/// ┌ Source: Invented Unit Guide, page 20      ┐  the source tile (meta, ≤ 3 lines)
/// [ Page ] [ Actions ] [ Close ]                  the answer's buttons (≤ 3, and within the width)
/// Earlier — press to open                         (meta line)
/// ┌ You: refrigerant charge for the …         ┐  an earlier turn: its question and first
/// └ R-410A, 7 lb 4 oz factory charge …        ┘  three lines
/// ```
///
/// - **Rows** are cards (`HUDBlock.Style.card`, the only way the lens shows focus on a box). A
///   press on one says the answer again from that row to its end (decision 3). They are cut from
///   the answer's prose (`LensSourceTile`): its `Source:` markers are taken out of it (Plan MU §2).
/// - **The source tile** (Plan MU §2) follows the rows, before the buttons: one card in the meta
///   style naming every source, at most three lines. A press on it opens the page, as **Page** does.
/// - **Buttons** (Plan MU §3, decision 4). The newest turn's: **Page** when the turn staged one,
///   else its first follow-up once the answer is final, then **Actions** and **Close**: three at
///   most. Every follow-up is on the Actions screen and by voice. An opened earlier turn's:
///   **‹ Latest** and **Close**. The row goes through `LensButtonRowBudget`: a follow-up is cut to
///   fit, and gives way (then **Page**, to the Actions screen) when the row still doesn't fit.
/// - **Focus.** No button takes it (`HUDScreen.focusesFirstBlock`), so the first row does and the
///   lens opens at the top, where the wearer starts reading.
/// - **Earlier** turns, under "Earlier — press to open", are collapsed to their question and first
///   three lines; a press opens one at the top of the view, whole.
/// - **Caps** (provisional until the glasses time a send): `maxRows` blocks and `maxCharacters`
///   characters in one view. Past them the oldest earlier turns go first, then the top answer ends
///   in "… more on phone".
enum HUDReadingViewBuilder {
    static let maxRows = 40
    static let maxCharacters = 4000
    /// Plan MU §5: an earlier turn shows its first three lines.
    static let collapsedLines = 3
    /// Plan MU §3: Page (or one follow-up), Actions, Close.
    static let maxButtons = 3
    /// The order the row's buttons give way in when it is too wide (`LensButtonRowBudget`).
    static let rowGivingWay = [HUDAnswerCardBuilder.ItemID.followUp(0), HUDAnswerCardBuilder.ItemID.page]

    enum ItemID {
        static let latest = "mg.latest"
        static func row(turn: Int, index: Int) -> String { "mg.row.\(turn).\(index)" }
        static func turn(_ id: Int) -> String { "mg.turn.\(id)" }
        /// Plan MU §2.
        static func sources(turn: Int) -> String { "mu.sources.\(turn)" }
    }

    static var earlierHeading: String {
        String(localized: "Earlier — press to open",
               comment: "Glasses: heading over the conversation's earlier answers on the lens; pressing one opens it.")
    }

    static var latestLabel: String {
        String(localized: "‹ Latest", comment: "Glasses: go back to the newest answer from an earlier one.")
    }

    static func screen(_ state: HUDReadingViewState,
                       geometry: TeleprompterPaginator.Geometry,
                       onAction: @escaping (HUDAnswerAction) -> Void) -> HUDScreen {
        let chars = HUDReadingRows.maxChars(for: geometry)
        let top = state.top
        let lensText = LensSourceTile.split(top.text)
        let allRows = HUDReadingRows.rows(for: lensText.prose, maxChars: chars)
        let sourceLines = lensText.lines(maxChars: chars)

        // The caps: the oldest earlier turns go first, then the top answer is cut short.
        var earlier = state.earlier
        let questionChars = top.question?.count ?? 0
        func earlierChars(_ turns: [LensConversationTurn]) -> Int {
            turns.reduce(0) { $0 + collapsedLines(for: $1, maxChars: chars).reduce(0) { $0 + $1.text.count } }
        }
        // The source tile is one block and its characters, kept whatever the caps cut.
        let sourceBlocks = sourceLines.isEmpty ? 0 : 1
        let sourceChars = sourceLines.reduce(0) { $0 + $1.count }
        let topChars = questionChars + sourceChars + allRows.reduce(0) { $0 + $1.text.count }
        while !earlier.isEmpty,
              allRows.count + sourceBlocks + earlier.count > maxRows
                || topChars + earlierChars(earlier) > maxCharacters {
            earlier.removeLast()
        }
        var rows = allRows
        var capped = false
        let moreLine = HUDAnswerPager.moreOnPhoneLine
        if rows.count + sourceBlocks + earlier.count > maxRows || topChars + earlierChars(earlier) > maxCharacters {
            capped = true
            let roomRows = max(1, maxRows - earlier.count - sourceBlocks)
            let roomChars = maxCharacters - questionChars - sourceChars - earlierChars(earlier) - moreLine.count
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
        if !sourceLines.isEmpty {
            // Plan MU §2: the citation's door, the same as **Page**, while the answer has one to open.
            let opensPage = state.topIsLatest && top.hasPage
            screen.flow.append(.blocks([HUDBlock(id: ItemID.sources(turn: top.id),
                                                 lines: sourceLines.map { HUDLine($0, emphasis: .meta) },
                                                 style: .card,
                                                 action: opensPage ? { onAction(.page) } : nil)]))
        }
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

    /// An earlier turn, collapsed: its question line, then its first three lines (of its prose,
    /// the sources taken out as on the top answer), the last ending in "…" when there is more.
    static func collapsedLines(for turn: LensConversationTurn, maxChars: Int) -> [HUDLine] {
        var lines: [HUDLine] = []
        if let question = turn.question, !question.isEmpty {
            lines.append(HUDLine(HUDTextShaper.condense(question, max: maxChars), emphasis: .meta))
        }
        let display = HUDAnswerPager.displayLines(for: LensSourceTile.split(turn.answer).prose, maxChars: maxChars)
        var shown = Array(display.prefix(collapsedLines))
        if display.count > collapsedLines, let last = shown.last {
            let room = max(1, maxChars - 1)
            shown[shown.count - 1] = (last.count > room ? String(last.prefix(room)) : last) + "…"
        }
        lines += shown.map { HUDLine($0, emphasis: .secondary) }
        return lines
    }

    /// The view's buttons (see the type's note), fitted to the lens's width.
    static func items(_ state: HUDReadingViewState,
                      _ onAction: @escaping (HUDAnswerAction) -> Void) -> [HUDItem] {
        LensButtonRowBudget.fit(rowItems(state, onAction), givingWay: rowGivingWay).row
    }

    /// The view's buttons before the width budget: the row it asks for.
    static func rowItems(_ state: HUDReadingViewState,
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
        } else if top.isComplete, let question = top.followUps.first {
            // Decision 4: with no page, one follow-up before Actions; every one is on Actions.
            items.append(item(HUDAnswerCardBuilder.ItemID.followUp(0), question, .outline,
                              .followUp(index: 0, text: question), onAction))
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
