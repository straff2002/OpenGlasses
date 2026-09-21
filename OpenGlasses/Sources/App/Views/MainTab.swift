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
    /// Field Assist's job dashboard. Conditional — see `JobTabPresence`.
    case job
    case settings

    var id: String { rawValue }

    /// Left-to-right order in the tab bar, with every tab the app has. `MainView` builds its bar
    /// from `visibleOrder(showingJob:)`, which is this filtered by what is actually on.
    ///
    /// The Job tab sits between Chat and Settings. Voice is the primary capture surface and stays
    /// first; Settings is the drawer everything else is kept out of and stays last; the job is
    /// content, so it belongs with the content tabs. Inserting it there moves only Settings, and
    /// Settings is reached by its label — the UI tests address every tab by name
    /// (`AccessibilityAudit.openTab(_:in:)`), and nothing in the app addresses one by position.
    static let displayOrder: [MainTab] = [.voice, .modes, .chat, .job, .settings]

    /// The bar as it is actually built. Without Field Assist this is exactly the four tabs that
    /// shipped, in the order they shipped in.
    static func visibleOrder(showingJob: Bool) -> [MainTab] {
        showingJob ? displayOrder : displayOrder.filter { $0 != .job }
    }

    /// The tab's spoken name. Also its accessibility label, because a tab bar button's label is
    /// the word the wearer hears.
    var title: String {
        switch self {
        case .voice: return "Voice"
        case .modes: return "Modes"
        case .chat: return "Chat"
        case .job: return "Job"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .voice: return "waveform"
        case .modes: return "person.2.fill"
        case .chat: return "bubble.left.and.bubble.right"
        // A clipboard with a tick: the job is a list of work that gets signed off, and it reads
        // differently from the waveform, the people and the gear beside it.
        case .job: return "checklist"
        case .settings: return "gearshape.fill"
        }
    }

    // No `accessibilityIdentifier` here, deliberately: nothing in this app sets one. Every tab —
    // and every row the UI tests reach — is addressed by its spoken label
    // (`AccessibilityAudit.openTab(_:in:)`, `tapRow(startingWith:)`), which is also what makes a
    // VoiceOver user and a UI test walk the same tree. `title` is that label.

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
        // Added after the identifier was typed, and deliberately never given a number: `.job` sits
        // between Chat and Settings, so numbering it would have to renumber Settings, which is the
        // exact rewrite freezing the table prevents.
        case .job: return nil
        }
    }
}
