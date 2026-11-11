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
        return key
    }
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
