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
    case close
    /// On the cue for a page the app put up by itself (§4): open the view.
    case showHere
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
}

/// Builds the page view's lines and button row from its state (Plan KV §3). Pure: presses are
/// reported through the injected `onAction`. The picture itself is not here — `HUDScreen` gains it
/// in P1 — so the screen holds the lines over the picture and the row under it.
///
/// | View | Buttons |
/// |---|---|
/// | zoomed (the opening view, or any step short of the deepest) | Zoom in · Whole page · Move · Close |
/// | the whole page | Zoom in · Back to part (when the view opened on one) · Close |
/// | the deepest zoom | Zoom out · Move · Close |
/// | Move (pushed) | ↑ · ↓ · ← · → · Done |
///
/// **Next page ›** goes in before Close on the opening view, while another cited page follows.
/// The arrow row is always all four arrows, so a press always does the same thing; one against the
/// page's edge does nothing.
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
        static let close = "kv.page.close"
        static let showHere = "kv.page.show-here"
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
        if state.isFirstFrame, let citation = state.citation {
            let text = HUDTextShaper.condense(citation, max: HUDTextShaper.maxTitleLength)
            if !text.isEmpty { lines.append(HUDLine(text, emphasis: .meta)) }
        }
        if !state.isMoving, state.legibility.needsZoomHint(at: state.viewport) {
            lines.append(HUDLine(String(localized: "Zoom in for labels"), emphasis: .secondary))
        }
        return lines
    }

    static func items(_ state: HUDPageViewState,
                      _ onAction: @escaping (HUDPageAction) -> Void) -> [HUDItem] {
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
        if state.hasNextPage, viewport.isAtOpening {
            items.append(item(ItemID.nextPage, String(localized: "Next page ›"), .secondary, .nextPage, onAction))
        }
        items.append(item(ItemID.close, String(localized: "Close"), .outline, .close, onAction))
        return items
    }

    private static func item(_ id: String, _ label: String, _ style: HUDButtonStyle,
                             _ action: HUDPageAction,
                             _ onAction: @escaping (HUDPageAction) -> Void) -> HUDItem {
        HUDItem(id: id, label: label, style: style) { onAction(action) }
    }
}
