import Foundation

/// The first press on a page as it opens reads the page closely (build 770 field report).
///
/// The view opens on the whole page with focus on its picture (`HUDScreen.focusesFirstBlock`), so
/// one pinch reads the highlighted part closely (Plan MU §6). That focus was measured only on the
/// simulated Display, and the DAT Display API neither sets nor reports focus. On a Ray-Ban Display,
/// "show me the page" was reported opening on the passage's words, and on a page with a table on
/// its rows: the first pinch had pressed **Read it** or **Rows**, as if the lens had put focus on
/// the button row. So on a page's opening frame, a press from the lens on either of them opens the
/// close-up, as a press on the picture does, unless the wearer moved focus on that frame first (a
/// band input, heard in flagged builds only). A press on the phone preview is always the one the
/// wearer meant. Once the view has moved on from its opening frame, every button does its own
/// thing, and the spoken "read it" and "rows" always do.
enum LensOpeningPress {
    /// The buttons a stray first press is taken off.
    static let redirected: Set<String> = [HUDPageScreenBuilder.ItemID.rows, HUDPageScreenBuilder.ItemID.readIt]

    /// The item a press on `itemID` runs: the whole page's picture for a stray first press on
    /// **Rows** or **Read it**, else `itemID` itself.
    static func target(of itemID: String, on state: HUDPageViewState, screen: HUDScreen,
                       fromLens: Bool, focusMoved: Bool) -> String {
        guard fromLens, !focusMoved, state.view == .whole, state.isFirstFrame,
              redirected.contains(itemID),
              screen.block(id: HUDPageScreenBuilder.ItemID.wholePicture) != nil else { return itemID }
        return HUDPageScreenBuilder.ItemID.wholePicture
    }

    /// A pressed item as a log token: the button's own name, a row's or a slice's index dropped
    /// ("kv.page.read" → "read", "mu.page.row.3" → "row"). Never a label or the page's text.
    static func token(for itemID: String) -> String {
        for prefix in ["kv.page.", "mu.page.", "mg.page."] where itemID.hasPrefix(prefix) {
            let name = itemID.dropFirst(prefix.count)
            return String(name.split(separator: ".").first ?? "")
        }
        return "other"
    }
}

extension HUDPageViewState.View {
    /// The view's name for the app's log.
    var token: String {
        switch self {
        case .whole: return "whole"
        case .closeUp: return "closeUp"
        case .zoomed: return "zoomed"
        case .rows: return "rows"
        case .reading: return "reading"
        }
    }
}
