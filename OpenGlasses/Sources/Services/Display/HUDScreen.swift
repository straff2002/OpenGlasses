import Foundation
import UIKit

/// SDK-free description of one interactive HUD screen (Display Phase 3 / Plan X).
///
/// A screen is a heading + some non-interactive content lines + a list of
/// band-selectable items. The active `GlassesDisplayBackend` renders it (Meta: a
/// `MWDATDisplay` FlexBox/Button tree; EVEN G2: a monochrome text frame — Plan AH);
/// nothing here imports an SDK, so screens are pure data and unit-testable headlessly.

/// Semantic icon for HUD content. Lives with the DSL (Plan AH) so the DSL's owner isn't
/// an SDK-importing class; each backend maps it to its own representation (Meta:
/// `MWDATDisplay.IconName`; EVEN: a text glyph).
enum HUDIcon: Equatable {
    case none
    case info, success, warning, error
    case navigation, hazard
    case calendar, location, reminder, message
    /// Plan LC §4: the Today glance's weather row and its time-and-battery line.
    case weather, clock
    /// Plan LC §6: the caption screen's live-capture mark, the Now Playing card's track line, and a
    /// Field Assist step's **Watch** (its clip).
    case microphone, music, video
}

/// Shared HUD text shaping (Plan AH — extracted from `GlassesDisplayService` so every
/// backend condenses identically).
enum HUDTextShaper {
    /// Max characters for a body line — kept short for in-lens legibility.
    static let maxBodyLength = 120
    /// Max characters for a heading.
    static let maxTitleLength = 40

    /// Collapse whitespace and truncate to a HUD-legible length.
    static func condense(_ text: String, max: Int = maxBodyLength) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        let cut = collapsed.prefix(max)
        // Prefer to break on the last space so we don't slice a word in half.
        if let lastSpace = cut.lastIndex(of: " "), lastSpace > cut.index(cut.startIndex, offsetBy: max / 2) {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}

/// Text emphasis for a content line; each backend maps it to its own representation.
enum HUDEmphasis: Equatable {
    case primary    // body / primary colour
    case secondary  // body / secondary colour
    case meta       // small meta / secondary colour
}

/// Button prominence, mapped to the SDK's `ButtonStyle` inside `GlassesDisplayService`.
enum HUDButtonStyle: Equatable {
    case primary
    case secondary
    case outline
}

/// A non-interactive content line (optional leading icon + text).
struct HUDLine: Equatable {
    let text: String
    let icon: HUDIcon
    let emphasis: HUDEmphasis

    init(_ text: String, icon: HUDIcon = .none, emphasis: HUDEmphasis = .primary) {
        self.text = text
        self.icon = icon
        self.emphasis = emphasis
    }
}

/// A band-selectable action. `id` is stable and Sendable so the SDK `onClick`
/// callback can route back by id; `action` is invoked on the main actor by `HUDRouter`.
struct HUDItem: Identifiable {
    let id: String
    let label: String
    let icon: HUDIcon
    let style: HUDButtonStyle
    let action: () -> Void

    init(id: String,
         label: String,
         icon: HUDIcon = .none,
         style: HUDButtonStyle = .secondary,
         action: @escaping () -> Void) {
        self.id = id
        self.label = label
        self.icon = icon
        self.style = style
        self.action = action
    }
}

/// A picture a screen draws above its button row (Plan KV §6): a manual page's crop, drawn by the
/// phone for an additive lens. Only a backend that `drawsPictures` is ever handed one; the others
/// render the screen's text lines as before.
struct HUDPicture {
    let image: UIImage
    /// The image's size in pixels (the canvas it was drawn for).
    let pixelSize: CGSize
    /// What the picture shows — the page, the crop and how it was drawn — so the render queue's
    /// de-duplication skips an identical frame without comparing pixels. Never page text.
    let contentKey: String

    /// Where the backend draws it: under the screen's lines (a page crop, a vision thumbnail) or,
    /// Plan LC §6, above them (the turn arrow, which leads its guidance line).
    enum Placement: Equatable {
        case belowLines
        case aboveLines
    }
    var placement: Placement = .belowLines
}

/// Plan LC §6: a clip a Field Assist step points at, as the lens can play it — an HTTPS MP4 the
/// Display fetches itself (DAT's `VideoPlayer(provider: .uri(_:), codec: .mp4)`). SDK-free, so the
/// task card can offer **Watch** without knowing which backend is up; only a backend that
/// `playsVideo` is ever handed one. The phone never downloads the clip; Meta's limits for it
/// (at most 400 px a side and 70,000 px in all) are the clip author's to meet, and a clip the
/// glasses refuse ends as an error, which returns to the task card.
struct HUDVideo: Equatable {
    let url: URL

    /// A clip the lens can play, or nil: an absolute `https` URL with a host whose path ends in
    /// `.mp4` (any case). Anything else (http, a file URL, a page, another container) is not
    /// offered, because the glasses would only report an error.
    static func playable(_ string: String?) -> HUDVideo? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.pathExtension.lowercased() == "mp4" else { return nil }
        return HUDVideo(url: url)
    }
}

/// Plan LC §6: how a clip on the lens ended, mapped from DAT's `VideoPlaybackEventType`. Every
/// ending returns the lens to the task card the clip was started from.
enum HUDVideoEnding: String, Equatable {
    case ended, stopped, failed
}

/// Plan MG §2: a tappable block on the lens — a few lines of text (a reading-view row, a collapsed
/// earlier turn) or a picture (a page tile, a slice of a zoomed strip) — with an id a press routes
/// back by, as a button's does. On the Meta Display it is a `FlexBox` with `.onTap`; with `.card`
/// it is drawn on a card, which is the only way the lens shows focus on a box (measured on the
/// simulated Display). `.plain` draws no card, so a stack of picture slices stays seamless and the
/// lens still steps focus (and so its scroll) from one to the next. Text backends draw its lines.
struct HUDBlock: Identifiable {
    enum Style: Equatable {
        case card
        case plain
    }

    let id: String
    var lines: [HUDLine]
    var picture: HUDPicture?
    var style: Style
    /// What a press on it does; nil for a block that only takes focus.
    var action: (() -> Void)?

    init(id: String, lines: [HUDLine] = [], picture: HUDPicture? = nil, style: Style = .card,
         action: (() -> Void)? = nil) {
        self.id = id
        self.lines = lines
        self.picture = picture
        self.style = style
        self.action = action
    }

    var renderKey: String {
        var key = "\(id)#\(style == .card ? "c" : "p")#"
            + lines.map { "\($0.emphasis):\($0.icon):\($0.text)" }.joined(separator: "¦")
        if let picture { key += "#pic:\(picture.contentKey)" }
        return key
    }
}

/// Plan MG §2: one element of a screen's column beyond its own lines: a line, or a row of blocks
/// (one block takes the column's width; several sit side by side, as a page's tiles do).
enum HUDFlowElement {
    case line(HUDLine)
    case blocks([HUDBlock])

    var renderKey: String {
        switch self {
        case .line(let line): return "L:\(line.emphasis):\(line.icon):\(line.text)"
        case .blocks(let blocks): return "B[" + blocks.map(\.renderKey).joined(separator: ",") + "]"
        }
    }

    /// The element's text lines, in order (a block's lines after one another).
    var lines: [HUDLine] {
        switch self {
        case .line(let line): return [line]
        case .blocks(let blocks): return blocks.flatMap(\.lines)
        }
    }

    var blocks: [HUDBlock] {
        if case .blocks(let blocks) = self { return blocks }
        return []
    }
}

/// One renderable interactive screen.
struct HUDScreen {
    let title: String?
    let lines: [HUDLine]
    let items: [HUDItem]

    /// Plan KV: the page view's picture, drawn above the button row by a backend that draws
    /// pictures. Part of `renderKey` by its content key only.
    var picture: HUDPicture?

    /// Plan KP P1: on an answer card's page, every page the card can show, each as its own
    /// screen, so a surface that turns pages by itself (the web mirror, which is read-only and
    /// cannot send a press back) has them all. Nil on every other screen. Not part of
    /// `renderKey`: the key is what this frame shows.
    var pageSet: HUDPageSet?

    /// Plan LC §2.1: the item that takes focus when the screen first renders (DAT 1.0's
    /// `.actionRole(.primary)`: "the first primary action receives focus"). Nil lets
    /// `resolvedFocusItemID` choose. Set by a builder where the likeliest next press is not the
    /// first prominent button. Part of `renderKey` only when set, so default screens keep their keys.
    var focusItemID: String?

    /// Plan KT §6.6: what the web mirror (Plan BP), a LAN page someone else could open, may show of
    /// this screen. Nil shows all of it. The lens and the phone's own preview are unaffected. Not
    /// part of `renderKey`: the key is what the lens shows.
    var mirror: HUDMirrorRedaction?

    /// Plan MG §2: the column after the screen's lines and before its picture and button row: the
    /// reading view's rows, a page's tiles.
    var flow: [HUDFlowElement] = []
    /// Plan MG §2: the column after the button row: the reading view's earlier turns, a zoomed
    /// page's strip of slices.
    var trailingFlow: [HUDFlowElement] = []
    /// Plan MG §2: no button takes focus when the screen renders, so the first tappable block does
    /// and the lens opens at the top (measured on the simulated Display: a primary button anywhere
    /// in a tall column opens the lens scrolled to it). Part of `renderKey` only when set.
    var focusesFirstBlock = false

    init(title: String? = nil, lines: [HUDLine] = [], items: [HUDItem] = [], focusItemID: String? = nil) {
        self.title = title
        self.lines = lines
        self.items = items
        self.focusItemID = focusItemID
    }

    /// Plan LC §2.1: the one item a backend marks as the focused default. The explicit
    /// `focusItemID` when it names an item on this screen, else the first `.primary` item, else the
    /// first `.secondary`, else the first item. Nil for a screen with no items. Exactly one button
    /// is ever marked, so focus never depends on which of several "primary" buttons the firmware
    /// happens to take.
    var resolvedFocusItemID: String? {
        if focusesFirstBlock, !allBlocks.isEmpty { return nil }
        if let focusItemID, items.contains(where: { $0.id == focusItemID }) { return focusItemID }
        return items.first(where: { $0.style == .primary })?.id
            ?? items.first(where: { $0.style == .secondary })?.id
            ?? items.first?.id
    }

    /// Stable key over the *visible* content, used to skip redundant re-renders
    /// (the render queue collapses identical screens). Excludes closures.
    var renderKey: String {
        let head = title ?? ""
        let body = lines.map { "\($0.emphasis):\($0.icon):\($0.text)" }.joined(separator: "¦")
        let acts = items.map { "\($0.id):\($0.style):\($0.icon):\($0.label)" }.joined(separator: "¦")
        var key = "\(head)|\(body)|\(acts)"
        if let picture {
            key += "|pic:\(picture.contentKey)"
            if picture.placement == .aboveLines { key += "^" }
        }
        if let focusItemID { key += "|focus:\(focusItemID)" }
        if !flow.isEmpty { key += "|flow:" + flow.map(\.renderKey).joined(separator: "¦") }
        if !trailingFlow.isEmpty { key += "|after:" + trailingFlow.map(\.renderKey).joined(separator: "¦") }
        if focusesFirstBlock { key += "|focus:first-block" }
        return key
    }

    /// Every block on the screen, in column order.
    var allBlocks: [HUDBlock] { (flow + trailingFlow).flatMap(\.blocks) }

    /// The block `id` names, if the screen has one.
    func block(id: String) -> HUDBlock? { allBlocks.first { $0.id == id } }

    /// Every text line in column order — the screen's own, then the flow's, then (after the
    /// buttons) the trailing flow's — for a backend that draws text only (Even, the web mirror).
    var linesBeforeItems: [HUDLine] { lines + flow.flatMap(\.lines) }
    var linesAfterItems: [HUDLine] { trailingFlow.flatMap(\.lines) }

    /// Whether anything on the screen is a picture: its own, or a block's.
    var hasPictures: Bool { picture != nil || allBlocks.contains { $0.picture != nil } }

    /// The screen with no pictures at all: the one a backend that draws none gets, and the one a
    /// picture frame that failed is sent again as. Blocks keep their lines; a block that was only a
    /// picture goes.
    func withoutPictures() -> HUDScreen {
        var copy = self
        copy.picture = nil
        func strip(_ elements: [HUDFlowElement]) -> [HUDFlowElement] {
            elements.compactMap { element in
                switch element {
                case .line: return element
                case .blocks(let blocks):
                    let kept = blocks.compactMap { block -> HUDBlock? in
                        var plain = block
                        plain.picture = nil
                        return plain.lines.isEmpty ? nil : plain
                    }
                    return kept.isEmpty ? nil : .blocks(kept)
                }
            }
        }
        copy.flow = strip(flow)
        copy.trailingFlow = strip(trailingFlow)
        return copy
    }
}

/// Plan KT §6.6: how the web mirror redacts a screen. The mirror is the strictest surface.
enum HUDMirrorRedaction: Equatable {
    /// The screen's title and buttons, with these lines in place of its own (a draft's text).
    case lines([HUDLine])
    /// Nothing of the screen but this one line (a card with health content).
    case hidden(placeholder: String)
}

/// Plan LC §2.3: the ids and labels that let the wearer leave a screen from the screen itself.
/// The band's Back gesture ends the whole display session on hardware (iOS #349), so every
/// interactive screen below the launcher's root carries one of these.
enum HUDExit {
    /// Item ids that leave or step back from a screen.
    static let ids: Set<String> = [
        "close", "back", "done", "dismiss", "stop",
        "kp.close", "kp.back", "kp.answer",
    ]

    /// Whether `screen` has an item that leaves it.
    static func hasExit(_ screen: HUDScreen) -> Bool {
        screen.items.contains { item in
            ids.contains(item.id) || item.id.hasSuffix(".close") || item.id.hasSuffix(".back")
                || item.id.hasSuffix(".stop") || item.id.hasSuffix(".done") || item.id.hasSuffix(".deny")
        }
    }
}

/// The pages of an answer card (Plan KP P1), carried on the page being shown.
struct HUDPageSet {
    /// One screen per page the card can show, in order.
    let pages: [HUDScreen]
    /// The page being shown.
    let index: Int
    /// Which card this is: the same number while one answer grows, a new one for a new answer,
    /// so a surface turning pages by itself keeps its place on the same card.
    var card: Int = 0
}
