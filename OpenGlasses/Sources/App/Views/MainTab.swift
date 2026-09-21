import Foundation

/// Identifies one tab of the root tab bar (`MainView`).
///
/// The tab bar used to be selected by bare `Int` — Voice 0 / Modes 1 / Chat 2 / Settings 3 — which
/// ties a tab's identity to its position. That is fine until a tab is inserted: every number after
/// it shifts, and anything holding a number (a restored scene, a launch argument, a link) silently
/// lands on the wrong screen. The raw value here is the identity instead, so position and identity
/// can move independently.
///
/// Two rules keep that property:
/// - **Raw values are frozen.** They are what a persisted or transmitted selection would carry, and
///   they are also the tokens the privacy log records, so changing one rewrites history.
/// - **Order lives in `displayOrder`**, not in the declaration order and not in the raw values, so a
///   tab can be added in the middle of the bar without touching either.
enum MainTab: String, Hashable, CaseIterable, Identifiable {
    case voice
    case modes
    case chat
    case settings

    var id: String { rawValue }

    /// Left-to-right order in the tab bar. `MainView` builds its tabs in this order.
    static let displayOrder: [MainTab] = [.voice, .modes, .chat, .settings]

    /// The tab a legacy `Int` selection refers to, or `nil` if the number never named a tab.
    ///
    /// Nothing in the app persists or transmits a tab selection today — the selection is scene
    /// state and dies with the scene — so this has no caller yet. It exists because the numbers
    /// *were* the API for as long as the bare-`Int` tab bar shipped, and a value can still reach a
    /// future reader from outside the app's lifetime (a restored scene, a shortcut recorded against
    /// an older build). Freezing the mapping now means inserting a tab cannot re-point one.
    ///
    /// The table is closed: a tab added after the typed identifier has no legacy number, and must
    /// not be given one.
    static func legacy(_ value: Int) -> MainTab? {
        switch value {
        case 0: return .voice
        case 1: return .modes
        case 2: return .chat
        case 3: return .settings
        default: return nil
        }
    }

    /// The `Int` this tab was selected by before the identifier was typed, or `nil` for a tab that
    /// never had one. Inverse of `legacy(_:)` over the tabs that shipped with numbers.
    var legacyValue: Int? {
        switch self {
        case .voice: return 0
        case .modes: return 1
        case .chat: return 2
        case .settings: return 3
        }
    }
}
