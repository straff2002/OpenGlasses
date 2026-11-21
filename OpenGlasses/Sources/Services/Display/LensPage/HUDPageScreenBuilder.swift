import CoreGraphics
import Foundation

/// What a press on the page view asks for (Plan KV §3, Plan MU §6). The builder only reports the
/// press; the session changes the view and renders the next frame.
enum HUDPageAction: Equatable {
    /// Plan MU §6: a press on the whole page's picture: the close-up of the highlighted part, or
    /// fit width when nothing is highlighted.
    case closeUp
    /// Plan MU §6: **Back**: from a close-up, fit width, a spoken zoom or the rows, to the whole page.
    case back
    /// Plan MU §6: **Rows**: the page's table, one row a card.
    case rows
    /// Plan MU §6: a press on a row card: say the row aloud.
    case speakRow(Int)
    case nextPage
    case close
    /// On the cue for a page the app put up by itself (§4): open the view.
    case showHere
    /// Reading mode (§1): the next page of the passage's words.
    case nextText
    /// …the page before.
    case previousText
    /// From reading mode to the picture (**Page**): the whole page, the passage highlighted.
    case showPicture
    /// From the picture back to reading mode (**Read it**).
    case readIt
    /// The spoken words only (MG's zoom words stay by voice, Plan MU §6): one rung in or out, the
    /// whole page, half a crop in a direction, the page's next drawing.
    case zoomIn
    case zoomOut
    case wholePage
    case step(LensPageViewport.Step)
    case nextDiagram
}

/// The page view's state, as far as its lines, its buttons and its pictures depend on it.
///
/// **Which view is up** (`view`), first that applies:
/// - **reading**: the cited passage's words as text (Plan KV §1), after **Read it**;
/// - **rows**: the page's table, one row a card (Plan MU §6, **Rows**);
/// - **close-up**: the highlighted part read closely, or the page at fit width (`closeUp`);
/// - **zoomed**: a spoken zoom ("zoom in", "zoom in on the bottom right"), drawn as a strip;
/// - **whole**: the whole page, one picture, the highlight outlined and the rest dimmed.
struct HUDPageViewState: Equatable {

    enum View: Equatable {
        case whole, closeUp, zoomed, rows, reading
    }

    var viewport: LensPageViewport
    var legibility: LensLegibility
    /// The view's first frame: the citation line shows on it and on no later one (§5).
    var isFirstFrame: Bool = true
    /// "Figure 12 · p. 30" — shown in the meta style on the first frame.
    var citation: String?
    /// There is a further cited page after this one ("show me the relevant pages").
    var hasNextPage: Bool = false
    /// How many drawings the page has (Plan KV P1b), and which one is highlighted (nil when the
    /// highlight is something else, or the page has none).
    var diagramCount: Int = 0
    var diagramIndex: Int?
    /// Reading mode (§1): the cited passage's words as lens text, paged; empty when the page has
    /// none to read (a drawing, a table, a photographed page, a page asked for by number).
    var readingPages: [HUDAnswerPage] = []
    /// The reading page shown, or last shown.
    var readingIndex: Int = 0
    /// Reading mode is up (rather than the picture).
    var isReading: Bool = false
    /// Plan MU §6: what the whole page highlights, why, and its words.
    var highlight: LensPageHighlight = .none()
    /// Plan MU §6: the close-up (or fit width) that is up, when one is.
    var closeUp: LensPageCloseUp?
    /// Plan MU §6: the page's table as rows, when the vault holds it.
    var rows: LensPageRows?
    /// Plan MU §6: the rows view is up.
    var showsRows: Bool = false

    var view: View {
        if isReading, !readingPages.isEmpty { return .reading }
        if showsRows, rows != nil { return .rows }
        if closeUp != nil { return .closeUp }
        return viewport.isWholePage ? .whole : .zoomed
    }

    /// A spoken zoom is drawn as a strip of the crop's column of the page (Plan MG §4).
    var showsStrip: Bool { view == .zoomed }

    /// **Next diagram** has somewhere to go: from a view on a drawing, the page has another; from
    /// a view on none, the page has any.
    var hasNextDiagram: Bool { diagramIndex == nil ? diagramCount >= 1 : diagramCount >= 2 }

    /// The page has words to read, so its picture offers **Read it**.
    var canRead: Bool { !readingPages.isEmpty }

    /// The reading page on the lens, while reading mode is up.
    var readingPage: HUDAnswerPage? {
        guard isReading, readingPages.indices.contains(readingIndex) else { return nil }
        return readingPages[readingIndex]
    }

    /// The citation line is over the picture: on the view's first frame only.
    var showsCitation: Bool { view == .whole && isFirstFrame && citation != nil }

    /// Plan MU §6: the highlighted part's words, under the whole page's picture.
    var wordsLine: String? { view == .whole ? highlight.words : nil }

    /// "Zoom in for labels" under the whole page: only with no highlighted words to give and the
    /// page's text too small to read there (a pinch on the picture is the zoom).
    var showsZoomHint: Bool {
        view == .whole && wordsLine == nil
            && Self.needsZoomHint(viewport, legibility: legibility, citation: showsCitation)
    }

    /// The body lines the whole page's frame gives the line under its picture.
    var lineUnderPicture: Int { wordsLine != nil ? highlight.wordsLineCount : (showsZoomHint ? 1 : 0) }

    /// The box the frame leaves the picture, from the lines round it (`LensPageFrame`).
    var pictureBox: CGSize {
        LensPageFrame.pictureBox(metaLines: showsCitation ? 1 : 0, bodyLines: lineUnderPicture)
    }

    /// The state with its viewport drawn into the box its own frame leaves the picture. Every
    /// state the session draws is framed, so two that show the same thing compare equal.
    func framed() -> HUDPageViewState {
        var copy = self
        copy.viewport.setBox(pictureBox)
        return copy
    }

    /// Whether `viewport`'s text needs the hint. Judged in the box the frame would have with the
    /// hint in it — the smaller box, so the decision can't flip once the hint takes its line.
    static func needsZoomHint(_ viewport: LensPageViewport, legibility: LensLegibility, citation: Bool) -> Bool {
        legibility.needsZoomHint(at: viewport.withBox(LensPageFrame.pictureBox(citation: citation, hint: true)))
    }
}

/// Builds the page view's lines, its blocks and its button row from its state (Plan KV §3, Plan MU
/// §6). Pure: presses are reported through the injected `onAction`. The pictures are the
/// session's; the builder lays out where they go.
///
/// | View | Over | Pictures | Buttons |
/// |---|---|---|---|
/// | whole | the citation (first frame) | the whole page, a card (focus opens on it); its words under it | Rows (a table) · Read it (words to read) · Next page › (another page) · Close |
/// | close-up, fit width, a spoken zoom | – | a strip under the row | Back · Close |
/// | rows | the table's name | a card a row, under the row | Back · Close |
/// | reading | the citation (first page), the page's lines, "1/2" | – | Next › · Page · ‹ Back · Next page › · Close |
///
/// **Three buttons at most** (`maxButtons`; Plan MU §3–§6: a row wider than the lens is cut off at
/// both ends, and the Display cannot scroll sideways). **Close** is always there and always last.
/// Over three, **Next page ›**, then **Rows**, give way on the whole page (still said as "next
/// page" and "rows"), and **‹ Back**, then **Next page ›**, in reading mode. **Zoom in**, **Zoom
/// out**, **Whole page**, **Move**, the arrows, **Done**, **Back to part** and **Next diagram ›**
/// are not on the lens: one press on the picture reads the part closely, and the zoom and diagram
/// words stay by voice.
enum HUDPageScreenBuilder {

    /// Stable item ids, so a band press routes back by id.
    enum ItemID {
        static let back = "kv.page.back"
        static let rows = "kv.page.rows"
        static let nextPage = "kv.page.next"
        static let close = "kv.page.close"
        static let showHere = "kv.page.show-here"
        /// Reading mode (§1).
        static let nextText = "kv.page.text-next"
        static let previousText = "kv.page.text-back"
        static let showPicture = "kv.page.picture"
        static let readIt = "kv.page.read"
        /// Plan MU §6: the whole page's picture, a slice of a close-up's strip, a row card.
        static let wholePicture = "mu.page.whole"
        static func slice(_ index: Int) -> String { "mg.page.slice.\(index)" }
        static func row(_ index: Int) -> String { "mu.page.row.\(index)" }
    }

    /// The most buttons a page-view row holds.
    static let maxButtons = 3

    /// Plan MU §6: a close-up's strip, under the button row: each column's slices top to bottom,
    /// and before the right half, its marker line. Slices take focus (so the lens steps and scrolls
    /// through them) and do nothing when pressed.
    static func stripSlices(_ columns: [(pictures: [HUDPicture], isRightHalf: Bool)]) -> [HUDFlowElement] {
        var flow: [HUDFlowElement] = []
        var index = 0
        for column in columns {
            if column.isRightHalf {
                flow.append(.line(HUDLine(String(localized: "Right half",
                                                 comment: "Glasses: marks where the right half of a wide part of a manual page starts, under its left half."),
                                          emphasis: .meta)))
            }
            for picture in column.pictures {
                flow.append(.blocks([HUDBlock(id: ItemID.slice(index), picture: picture, style: .plain)]))
                index += 1
            }
        }
        return flow
    }

    /// Plan MU §6: the whole page's picture as one tappable card, alone in its row, and under it
    /// the highlighted part's words (or the hint).
    static func wholePageFlow(_ state: HUDPageViewState, picture: HUDPicture,
                              onAction: @escaping (HUDPageAction) -> Void) -> [HUDFlowElement] {
        var flow: [HUDFlowElement] = [
            .blocks([HUDBlock(id: ItemID.wholePicture, picture: picture, style: .card,
                              action: { onAction(.closeUp) })]),
        ]
        if let words = state.wordsLine {
            flow.append(.line(HUDLine(words, emphasis: .secondary)))
        } else if state.showsZoomHint {
            flow.append(.line(HUDLine(String(localized: "Zoom in for labels"), emphasis: .secondary)))
        }
        return flow
    }

    /// Plan MU §6: the rows view's cards, the highlighted row first: the row's values, and under
    /// them the names of their columns. A press says the row.
    static func rowCards(_ rows: LensPageRows, onAction: @escaping (HUDPageAction) -> Void) -> [HUDFlowElement] {
        rows.order.map { index in
            let row = rows.rows[index]
            return .blocks([HUDBlock(id: ItemID.row(index),
                                     lines: [HUDLine(row.text, emphasis: .primary),
                                             HUDLine(row.headings, emphasis: .meta)],
                                     style: .card, action: { onAction(.speakRow(index)) })])
        }
    }

    /// Plan KV §4: the cue for a page the app put up by itself — where the page is, and one
    /// button, **Show here**, that opens the view. It never shows the page unasked.
    static func cue(_ line: String, onAction: @escaping (HUDPageAction) -> Void) -> HUDScreen {
        let text = HUDTextShaper.condense(line)
        return HUDScreen(title: nil,
                         lines: text.isEmpty ? [] : [HUDLine(text, icon: .info, emphasis: .secondary)],
                         items: [item(ItemID.showHere,
                                      String(localized: "Show here", comment: "Glasses: open the manual page on the lens."),
                                      .primary, .showHere, onAction)])
    }

    /// The screen's lines and buttons, and for the rows view its cards. The session adds the
    /// pictures (`wholePageFlow`, `stripSlices`).
    static func screen(_ state: HUDPageViewState,
                       onAction: @escaping (HUDPageAction) -> Void) -> HUDScreen {
        var screen = HUDScreen(title: nil, lines: lines(state), items: items(state, onAction))
        if state.view == .rows, let rows = state.rows {
            screen.trailingFlow = rowCards(rows, onAction: onAction)
        }
        return screen
    }

    static func lines(_ state: HUDPageViewState) -> [HUDLine] {
        switch state.view {
        case .reading:
            guard let page = state.readingPage else { return [] }
            var lines: [HUDLine] = []
            if page.index == 0, let citation = citationLine(state) { lines.append(citation) }
            lines += page.lines.enumerated().map { offset, text in
                let isMoreLine = page.isCapped && offset == page.lines.count - 1
                return HUDLine(text, emphasis: isMoreLine ? .secondary : .primary)
            }
            if let footer = page.footer { lines.append(HUDLine(footer, emphasis: .meta)) }
            return lines
        case .rows:
            let title = HUDTextShaper.condense(state.rows?.title ?? "", max: HUDTextShaper.maxTitleLength)
            return title.isEmpty ? [] : [HUDLine(title, emphasis: .meta)]
        case .whole:
            return state.showsCitation ? citationLine(state).map { [$0] } ?? [] : []
        case .closeUp, .zoomed:
            return []
        }
    }

    private static func citationLine(_ state: HUDPageViewState) -> HUDLine? {
        guard let citation = state.citation else { return nil }
        let text = HUDTextShaper.condense(citation, max: HUDTextShaper.maxTitleLength)
        return text.isEmpty ? nil : HUDLine(text, emphasis: .meta)
    }

    /// The view's buttons, three at most and fitted to the lens's width (`LensButtonRowBudget`,
    /// Plan MU §3): a label with a short form takes it ("Next page ›" → "Next ›", "Back" → "‹"),
    /// then the buttons in `givingWay(for:)` leave (still said by voice). **Close** stays.
    static func items(_ state: HUDPageViewState,
                      _ onAction: @escaping (HUDPageAction) -> Void) -> [HUDItem] {
        LensButtonRowBudget.fit(rowItems(state, onAction), givingWay: givingWay(for: state)).row
    }

    /// The order a view's buttons give way in, least important first.
    static func givingWay(for state: HUDPageViewState) -> [String] {
        switch state.view {
        case .reading: return [ItemID.previousText, ItemID.nextPage, ItemID.showPicture]
        case .whole: return [ItemID.nextPage, ItemID.rows, ItemID.readIt]
        case .closeUp, .zoomed, .rows: return [ItemID.back]
        }
    }

    /// The view's buttons, three at most, before the width budget.
    static func rowItems(_ state: HUDPageViewState,
                         _ onAction: @escaping (HUDPageAction) -> Void) -> [HUDItem] {
        switch state.view {
        case .reading:
            guard let page = state.readingPage else { return [closeItem(onAction)] }
            return readingItems(state, page: page, onAction)
        case .closeUp, .zoomed, .rows:
            // Back where focus opens, at the top of the column (the pictures and cards are under
            // the row).
            return [item(ItemID.back, String(localized: "Back", comment: "Glasses: from a close look at a manual page back to the whole page."),
                         .primary, .back, onAction),
                    closeItem(onAction)]
        case .whole:
            var items: [HUDItem] = []
            if state.rows != nil {
                items.append(item(ItemID.rows, String(localized: "Rows", comment: "Glasses: show the manual page's table as text, one row at a time."),
                                  .secondary, .rows, onAction))
            }
            if state.canRead {
                items.append(item(ItemID.readIt, String(localized: "Read it",
                                                        comment: "Glasses: show the cited passage on the manual page as text."),
                                  .secondary, .readIt, onAction))
            }
            if state.hasNextPage {
                items.append(item(ItemID.nextPage, String(localized: "Next page ›"), .secondary, .nextPage, onAction))
            }
            items.append(closeItem(onAction))
            return capped(items, givingWay: [ItemID.nextPage, ItemID.rows])
        }
    }

    /// Reading mode's row: **Next ›** while pages remain, **Page** (the whole page, the passage
    /// highlighted), **‹ Back** after the first page, **Next page ›** on the last while another
    /// cited page follows, and **Close**: three at most, **‹ Back** giving way first (still said
    /// as "back").
    private static func readingItems(_ state: HUDPageViewState, page: HUDAnswerPage,
                                     _ onAction: @escaping (HUDPageAction) -> Void) -> [HUDItem] {
        var items: [HUDItem] = []
        if !page.isLast {
            items.append(item(ItemID.nextText, String(localized: "Next ›"), .primary, .nextText, onAction))
        }
        items.append(item(ItemID.showPicture,
                          String(localized: "Page", comment: "Glasses: show the manual page itself, as a picture, instead of its words."),
                          page.isLast ? .primary : .secondary, .showPicture, onAction))
        if page.index > 0 {
            items.append(item(ItemID.previousText, String(localized: "‹ Back"), .outline, .previousText, onAction))
        }
        if page.isLast, state.hasNextPage {
            items.append(item(ItemID.nextPage, String(localized: "Next page ›"), .secondary, .nextPage, onAction))
        }
        items.append(closeItem(onAction))
        return capped(items, givingWay: [ItemID.previousText, ItemID.nextPage])
    }

    /// `items` cut to `maxButtons`, the ids in `givingWay` going first, in order. **Close** stays.
    static func capped(_ items: [HUDItem], givingWay: [String]) -> [HUDItem] {
        var items = items
        for id in givingWay where items.count > maxButtons {
            items.removeAll { $0.id == id }
        }
        return items
    }

    private static func closeItem(_ onAction: @escaping (HUDPageAction) -> Void) -> HUDItem {
        item(ItemID.close, String(localized: "Close"), .outline, .close, onAction)
    }

    private static func item(_ id: String, _ label: String, _ style: HUDButtonStyle,
                             _ action: HUDPageAction,
                             _ onAction: @escaping (HUDPageAction) -> Void) -> HUDItem {
        HUDItem(id: id, label: label, style: style) { onAction(action) }
    }
}
