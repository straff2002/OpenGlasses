import CoreGraphics
import Foundation

/// Whether a row of buttons fits across the lens, by width rather than by count (Plan MU §3). Pure.
///
/// The Display draws a `ButtonGroup` as one row and cannot scroll sideways, so a row wider than
/// the 576 px column is centred and cut off at both ends (a tester's photo: two follow-up questions
/// pushed the first label off the left and **Close** off the right). Each button is estimated from
/// its label's characters at `advancePixels` a character (`wideAdvanceFactor` times that for a
/// full-width CJK character), plus `buttonPaddingPixels` for the button round it and `iconPixels`
/// for an icon, with `gapPixels` between buttons.
///
/// **When a row is too wide** (`fit`):
/// 1. labels with a short form take it (`shortLabelKey(for:)`: "Next page ›" → "Next ›",
///    "‹ Back" → "‹"), the least important first;
/// 2. a follow-up question, free text with no short form, is cut at a word to the room left, with
///    "…", but never below `minimumCutCharacters`;
/// 3. still too wide, the least important button leaves the row (`givingWay`, then any other but
///    the protected ones, from the end); the caller puts it where it is still reachable — the
///    Actions screen, a card in the column, or voice.
///
/// **Close is never dropped** (nor any other id in `protected`): Meta's Back gesture isn't passed to
/// apps (ios #349), so Close is the only way to put the lens away from the lens itself.
///
/// **The constants are provisional** (P5 measures them on the simulated Display). They come from
/// two readings: the lens body text's advance, 18 px a character (`LensPageFrame.readingCharAdvancePixels`,
/// 32 characters across the column), as an upper bound for a button label; and the tester's photo of
/// a zoomed page whose four buttons "Zoom in", "Whole page", "Move" and "Close" (26 characters) all
/// showed, which a 15 px advance with 32 px of padding a button and 8 px gaps puts at 542 px, inside
/// the column. The same numbers put the photo's cut-off row (two follow-ups, **Actions**, **Close**)
/// at well over 576 px.
enum LensButtonRowBudget {
    /// The column a row must fit: the lens less its side padding.
    static var columnPixels: CGFloat { LensPageFrame.contentWidthPixels }
    /// Provisional: a button label's advance, per character.
    static let advancePixels: CGFloat = 15
    /// A full-width character (CJK) takes this many times the advance.
    static let wideAdvanceFactor: CGFloat = 1.8
    /// Provisional: a button's own padding, both sides together.
    static let buttonPaddingPixels: CGFloat = 32
    /// Provisional: an icon and its spacing beside the label.
    static let iconPixels: CGFloat = 32
    /// Provisional: the gap between two buttons.
    static let gapPixels: CGFloat = 8
    /// A follow-up cut shorter than this says too little to press: it leaves the row instead.
    static let minimumCutCharacters = 12

    // MARK: - Widths

    static func labelWidth(_ label: String) -> CGFloat {
        label.reduce(0) { $0 + (isWide($1) ? advancePixels * wideAdvanceFactor : advancePixels) }
    }

    static func width(of item: HUDItem, label: String? = nil) -> CGFloat {
        let icon = LensButtonIconPolicy.icon(item.icon, style: item.style) != .none ? iconPixels : 0
        // As the backend sends it: cut to a heading's length.
        let drawn = HUDTextShaper.condense(label ?? item.label, max: HUDTextShaper.maxTitleLength)
        return labelWidth(drawn) + buttonPaddingPixels + icon
    }

    static func width(of items: [HUDItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + width(of: $1) } + gapPixels * CGFloat(items.count - 1)
    }

    static func fits(_ items: [HUDItem]) -> Bool { width(of: items) <= columnPixels }

    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
                 0xFFE0...0xFFE6, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Short forms

    /// The English source of an item's short form, by its id: the table P7 translates. Nil for an
    /// item with none.
    static func shortLabelKey(for id: String) -> String? {
        switch id {
        // "Next diagram ›" left the lens's buttons in P1; "Next page ›" is the long "next" now.
        case HUDPageScreenBuilder.ItemID.nextPage: return "Next ›"
        case HUDAnswerCardBuilder.ItemID.back, HUDAnswerCardBuilder.ItemID.answer,
             HUDReadingViewBuilder.ItemID.latest, HUDPageScreenBuilder.ItemID.back,
             HUDPageScreenBuilder.ItemID.previousText:
            return "‹"
        default: return nil
        }
    }

    /// The short form in the app's language.
    static func localizedShortLabel(for id: String) -> String? {
        guard let key = shortLabelKey(for: id) else { return nil }
        switch key {
        case "Next ›": return String(localized: "Next ›")
        default: return key        // "‹" is a glyph, the same in every language
        }
    }

    /// Whether `id` is free text that may be cut to fit: a follow-up question.
    static func isCuttable(_ id: String) -> Bool { id.hasPrefix("kp.followup.") }

    /// Whether `id` closes the view, so it never leaves the row.
    static func isClose(_ id: String) -> Bool {
        id == "close" || id.hasSuffix(".close")
    }

    // MARK: - Fitting

    struct Fitted {
        /// The row, in its order, with any labels cut.
        var row: [HUDItem]
        /// The buttons that left it, in their order.
        var moved: [HUDItem]

        var ids: [String] { row.map(\.id) }
    }

    /// `items` made to fit the column (see the type's note). `givingWay` lists ids least important
    /// first; `protected` ids (and every Close) stay. `shortLabel` is the short form of an id (the
    /// app's language by default; a test passes another language's).
    static func fit(_ items: [HUDItem], givingWay: [String] = [], protected: Set<String> = [],
                    shortLabel: (String) -> String? = localizedShortLabel(for:)) -> Fitted {
        var row = items
        guard !fits(row) else { return Fitted(row: row, moved: []) }
        let keeps: (String) -> Bool = { isClose($0) || protected.contains($0) }
        let order = importanceOrder(row, givingWay: givingWay, keeps: { _ in false })

        // 1. Short forms, least important first.
        for id in order {
            guard !fits(row), let index = row.firstIndex(where: { $0.id == id }),
                  let short = shortLabel(id), short != row[index].label else { continue }
            row[index] = relabelled(row[index], short)
        }
        // 2. Follow-ups cut to the room left.
        for id in order where isCuttable(id) {
            guard !fits(row), let index = row.firstIndex(where: { $0.id == id }) else { continue }
            if let cut = cutLabel(of: row[index], toFit: columnPixels - (width(of: row) - width(of: row[index]))) {
                row[index] = relabelled(row[index], cut)
            }
        }
        // 3. The least important leave.
        var moved: [HUDItem] = []
        for id in importanceOrder(row, givingWay: givingWay, keeps: keeps) {
            guard !fits(row) else { break }
            guard let index = row.firstIndex(where: { $0.id == id }) else { continue }
            moved.append(items.first { $0.id == id } ?? row[index])
            row.remove(at: index)
        }
        let movedIDs = Set(moved.map(\.id))
        return Fitted(row: row, moved: items.filter { movedIDs.contains($0.id) })
    }

    /// The ids in the order they give way: `givingWay` first, then the rest from the end of the
    /// row, never one `keeps` holds.
    private static func importanceOrder(_ row: [HUDItem], givingWay: [String],
                                        keeps: (String) -> Bool) -> [String] {
        let ids = row.map(\.id)
        let named = givingWay.filter { ids.contains($0) && !keeps($0) }
        let rest = ids.reversed().filter { !named.contains($0) && !keeps($0) }
        return named + rest
    }

    /// A follow-up's label cut at a word, with "…", to fit `room`; nil when what is left would be
    /// shorter than `minimumCutCharacters`.
    private static func cutLabel(of item: HUDItem, toFit room: CGFloat) -> String? {
        var max = item.label.count - 1
        while max >= minimumCutCharacters {
            let cut = HUDTextShaper.condense(item.label, max: max)
            if width(of: item, label: cut) <= room { return cut }
            max -= 1
        }
        return nil
    }

    private static func relabelled(_ item: HUDItem, _ label: String) -> HUDItem {
        HUDItem(id: item.id, label: label, icon: item.icon, style: item.style, action: item.action)
    }
}
