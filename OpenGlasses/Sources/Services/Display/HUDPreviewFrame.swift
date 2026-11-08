import UIKit

/// What the phone preview draws, and whether its buttons work there (Plan KV P3). SDK-free, so
/// tests read it without a view.
///
/// The preview (`HUDMirrorView` → `HUDPreviewView`) draws the router's current screen at the
/// lens's shape, picture included: the page view's crop is the same `HUDPicture` the lens got.
/// While the page view or its **Show here** cue is pushed, the preview's buttons press it: each
/// press goes, by the button's id, to the item of the frame `LensPageSession` last drew, so it
/// runs the same handler a band press does, against the same frame revision. Every other screen
/// stays view-only on the phone, as the mirror always was.
struct HUDPreviewFrame {
    let screen: HUDScreen
    /// The preview's buttons press the page view (or its cue).
    let isPressable: Bool

    /// The picture the lens was sent, when the screen has one.
    var picture: UIImage? { screen.picture?.image }
    /// The buttons, by id, in the order the lens shows them.
    var itemIDs: [String] { screen.items.map(\.id) }
    var itemLabels: [String] { screen.items.map(\.label) }
}

extension HUDRouter {
    /// What the phone preview draws now; nil while the HUD is idle.
    var previewFrame: HUDPreviewFrame? {
        currentScreen.map { HUDPreviewFrame(screen: $0, isPressable: isPresentingPage && pageView != nil) }
    }

    /// A press on the phone preview's button `id` (Plan KV P3). Reaches the page view's session as
    /// a band press would; false, and nothing happens, for any other screen or an unknown id.
    @discardableResult
    func pressFromPreview(_ id: String) -> Bool {
        guard isPresentingPage, let pageView else { return false }
        return pageView.press(itemID: id)
    }
}
