import CoreGraphics
import Foundation

/// What a press on the page view asks for (Plan KV §3). The builder only reports the press; the
/// caller (P1) changes the viewport and renders the next frame.
enum HUDPageAction: Equatable {
    case zoomIn
    case zoomOut
    case wholePage
    /// From the whole page back to the part the view opened on.
    case backToPart
    /// Push the arrow row.
    case move
    case step(LensPageViewport.Step)
    /// Pop the arrow row.
    case doneMoving
    case nextPage
    /// Plan KV P1b: the page's next drawing, in reading order, round to the first.
    case nextDiagram
    case close
    /// On the cue for a page the app put up by itself (§4): open the view.
    case showHere
    /// Reading mode (§1): the next page of the passage's words.
    case nextText
    /// …the page before.
    case previousText
    /// From reading mode to the picture, opened on the passage's mark (**Page**).
    case showPicture
    /// From the picture back to reading mode (**Read it**).
    case readIt
}

/// The page view's state, as far as its lines and buttons depend on it.
struct HUDPageViewState: Equatable {
    var viewport: LensPageViewport
    var legibility: LensLegibility
    /// The arrow row is pushed.
    var isMoving: Bool = false
    /// The view's first frame: the citation line shows on it and on no later one (§5).
    var isFirstFrame: Bool = true
    /// "Figure 12 · p. 30" — shown in the meta style on the first frame.
    var citation: String?
    /// There is a further cited page after this one ("show me the relevant pages").
    var hasNextPage: Bool = false
    /// How many drawings the page has (Plan KV P1b), and which one the view is on (nil when it
    /// opened on something else: a cited passage, a table's area, the whole page).
    var diagramCount: Int = 0
    var diagramIndex: Int?
    /// Reading mode (§1): the cited passage's words as lens text, paged; empty when the page has
    /// none to read (it opened on a drawing, a table, a photographed page, the whole page).
    var readingPages: [HUDAnswerPage] = []
    /// The reading page shown, or last shown.
    var readingIndex: Int = 0
    /// Reading mode is up (rather than the picture).
    var isReading: Bool = false

    /// **Next diagram ›** has somewhere to go: from a view on a drawing, the page has another;
    /// from a view on no drawing (the whole page "show me page 7" opened on, a cited passage),
    /// the page has any.
    var hasNextDiagram: Bool { diagramIndex == nil ? diagramCount >= 1 : diagramCount >= 2 }

    /// The page has words to read, so its picture offers **Read it**.
    var canRead: Bool { !readingPages.isEmpty }

    /// The reading page on the lens, while reading mode is up.
    var readingPage: HUDAnswerPage? {
        guard isReading, readingPages.indices.contains(readingIndex) else { return nil }
        return readingPages[readingIndex]
    }

    /// The citation line is over the picture: on the view's first frame only.
    var showsCitation: Bool { !isReading && isFirstFrame && citation != nil }

    /// "Zoom in for labels" is over the picture (not while moving).
    var showsZoomHint: Bool {
        !isReading && !isMoving && Self.needsZoomHint(viewport, legibility: legibility, citation: showsCitation)
    }

    /// The box the frame leaves the picture, from the lines over it (`LensPageFrame`).
    var pictureBox: CGSize { LensPageFrame.pictureBox(citation: showsCitation, hint: showsZoomHint) }

    /// The state with its viewport drawn into the box its own frame leaves the picture. Every
    /// state the session draws is framed, so two that show the same thing compare equal.
    func framed() -> HUDPageViewState {
        var copy = self
        copy.viewport.setBox(pictureBox)
        return copy
    }

    /// Whether `viewport`'s text needs the hint. Judged in the box the frame would have with the
    /// hint in it — the smaller box, so the decision can't flip once the hint takes its line: at
    /// the whole page a smaller box only draws the text smaller, and zoomed in the box doesn't
    /// change the magnification.
    static func needsZoomHint(_ viewport: LensPageViewport, legibility: LensLegibility, citation: Bool) -> Bool {
        legibility.needsZoomHint(at: viewport.withBox(LensPageFrame.pictureBox(citation: citation, hint: true)))
    }
}

/// Builds the page view's lines and button row from its state (Plan KV §3). Pure: presses are
/// reported through the injected `onAction`. The picture itself is not here — the session sets it
/// on the screen — so the screen holds the lines over the picture and the row under it.
///
/// | View | Buttons |
/// |---|---|
/// | zoomed (the opening view, or any magnification short of the cap) | Zoom in · Whole page · Move · Close |
/// | the whole page | Zoom in · Back to part (when the view opened on one) · Close |
/// | at the zoom cap | Zoom out · Move · Close |
/// | Move (pushed) | ↑ · ↓ · ← · → · Done |
/// | Reading mode | Next › (while pages remain) · Page · ‹ Back (after the first page) · Close |
///
/// **Next page ›** goes in before Close on the opening view, while another cited page follows (in
/// reading mode, on its last page). **Read it** goes in second on every picture row of a page with
/// words to read (reading mode, §1). **Next diagram ›** goes in after them, on the opening view and
/// on the whole page, while it has somewhere to go (`hasNextDiagram`: another drawing, or any
/// drawing from a view on none; Plan KV P1b).
/// A row holds at most four buttons (`maxButtons`, P4): over that, **Move**, then **Next
/// diagram ›**, then **Whole page** give way (`capped`); each is still said by voice.
/// The arrow row is always all four arrows, so a press always does the same thing; one against the
/// page's edge does nothing.
///
/// Reading mode's lines are the citation (over the first reading page only), the page's lines and
/// its "1/2" footer, as on the answer card.
enum HUDPageScreenBuilder {

    /// Stable item ids, so a band press routes back by id.
    enum ItemID {
        static let zoomIn = "kv.page.zoom-in"
        static let zoomOut = "kv.page.zoom-out"
        static let wholePage = "kv.page.whole"
        static let backToPart = "kv.page.part"
        static let move = "kv.page.move"
        static let up = "kv.page.up"
        static let down = "kv.page.down"
        static let left = "kv.page.left"
        static let right = "kv.page.right"
        static let done = "kv.page.done"
        static let nextPage = "kv.page.next"
        static let nextDiagram = "kv.page.next-diagram"
        static let close = "kv.page.close"
        static let showHere = "kv.page.show-here"
        /// Reading mode (§1).
        static let nextText = "kv.page.text-next"
        static let previousText = "kv.page.text-back"
        static let showPicture = "kv.page.picture"
        static let readIt = "kv.page.read"
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

    static func screen(_ state: HUDPageViewState,
                       onAction: @escaping (HUDPageAction) -> Void) -> HUDScreen {
        HUDScreen(title: nil, lines: lines(state), items: items(state, onAction))
    }

    static func lines(_ state: HUDPageViewState) -> [HUDLine] {
        var lines: [HUDLine] = []
        if let page = state.readingPage {
            if page.index == 0, let citation = citationLine(state) { lines.append(citation) }
            lines += page.lines.enumerated().map { offset, text in
                let isMoreLine = page.isCapped && offset == page.lines.count - 1
                return HUDLine(text, emphasis: isMoreLine ? .secondary : .primary)
            }
            if let footer = page.footer { lines.append(HUDLine(footer, emphasis: .meta)) }
            return lines
        }
        if state.showsCitation, let citation = citationLine(state) { lines.append(citation) }
        if state.showsZoomHint {
            lines.append(HUDLine(String(localized: "Zoom in for labels"), emphasis: .secondary))
        }
        return lines
    }

    private static func citationLine(_ state: HUDPageViewState) -> HUDLine? {
        guard let citation = state.citation else { return nil }
        let text = HUDTextShaper.condense(citation, max: HUDTextShaper.maxTitleLength)
        return text.isEmpty ? nil : HUDLine(text, emphasis: .meta)
    }

    static func items(_ state: HUDPageViewState,
                      _ onAction: @escaping (HUDPageAction) -> Void) -> [HUDItem] {
        if let page = state.readingPage {
            return readingItems(state, page: page, onAction)
        }
        if state.isMoving {
            // The arrows are symbols, not words, so they are not localized.
            return [
                item(ItemID.up, "↑", .secondary, .step(.up), onAction),
                item(ItemID.down, "↓", .secondary, .step(.down), onAction),
                item(ItemID.left, "←", .secondary, .step(.left), onAction),
                item(ItemID.right, "→", .secondary, .step(.right), onAction),
                item(ItemID.done, String(localized: "Done"), .outline, .doneMoving, onAction),
            ]
        }

        let viewport = state.viewport
        var items: [HUDItem] = []
        if viewport.isWholePage {
            items.append(item(ItemID.zoomIn, String(localized: "Zoom in"), .primary, .zoomIn, onAction))
            if viewport.opensOnPart {
                items.append(item(ItemID.backToPart, String(localized: "Back to part"), .secondary,
                                  .backToPart, onAction))
            }
        } else if viewport.isDeepest {
            items.append(item(ItemID.zoomOut, String(localized: "Zoom out"), .primary, .zoomOut, onAction))
            items.append(item(ItemID.move, String(localized: "Move"), .secondary, .move, onAction))
        } else {
            items.append(item(ItemID.zoomIn, String(localized: "Zoom in"), .primary, .zoomIn, onAction))
            items.append(item(ItemID.wholePage, String(localized: "Whole page"), .secondary, .wholePage, onAction))
            items.append(item(ItemID.move, String(localized: "Move"), .secondary, .move, onAction))
        }
        var after = 1
        if state.canRead, !items.isEmpty {
            items.insert(item(ItemID.readIt, String(localized: "Read it",
                                                    comment: "Glasses: show the cited passage on the manual page as text."),
                              .secondary, .readIt, onAction), at: after)
            after += 1
        }
        if state.hasNextDiagram, viewport.isAtOpening || viewport.isWholePage, !items.isEmpty {
            items.insert(item(ItemID.nextDiagram, String(localized: "Next diagram ›",
                                                         comment: "Glasses: show the page's next drawing."),
                              .secondary, .nextDiagram, onAction), at: after)
        }
        if state.hasNextPage, viewport.isAtOpening {
            items.append(item(ItemID.nextPage, String(localized: "Next page ›"), .secondary, .nextPage, onAction))
        }
        items.append(item(ItemID.close, String(localized: "Close"), .outline, .close, onAction))
        return capped(items)
    }

    /// Reading mode's row: **Next ›** while pages remain, **Page** (the picture, on the passage's
    /// mark), **‹ Back** after the first page, **Next page ›** on the last while another cited page
    /// follows, and **Close**. Four at most.
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
        items.append(item(ItemID.close, String(localized: "Close"), .outline, .close, onAction))
        return capped(items)
    }

    /// The most buttons a page-view row holds. Measured on the simulated Display (P4): five buttons,
    /// two of them **Next diagram ›** and **Whole page**, came to more than the lens is wide, and DAT
    /// cut both labels short.
    static let maxButtons = 4

    /// A row over `maxButtons` loses **Move** first (one **Zoom in** brings it back, and an arrow
    /// row on the opening view is rarely what's wanted), then **Next diagram ›** (still said as
    /// "next diagram"), then **Whole page** (still said as "whole page"; it gives way only on a
    /// page with words to read, whose **Read it** has the place). **Close** always stays.
    static func capped(_ items: [HUDItem]) -> [HUDItem] {
        var items = items
        for id in [ItemID.move, ItemID.nextDiagram, ItemID.wholePage, ItemID.previousText]
        where items.count > maxButtons {
            items.removeAll { $0.id == id }
        }
        return items
    }

    private static func item(_ id: String, _ label: String, _ style: HUDButtonStyle,
                             _ action: HUDPageAction,
                             _ onAction: @escaping (HUDPageAction) -> Void) -> HUDItem {
        HUDItem(id: id, label: label, style: style) { onAction(action) }
    }
}
