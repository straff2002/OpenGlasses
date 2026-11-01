import Foundation

// The settings hub's categories, in the order the hub draws them (Plan HA C1). Pure data and pure
// functions — no `Config`, no `UserDefaults`, no views — so the order, the Simple Mode subset and
// the guarantees below are asserted headlessly.
//
// There is no folding, no Discover shelf and no "Show everything": the hub lists the whole surface,
// in one fixed order. Only two things leave a row out — Simple Mode (below), and on a managed phone
// an organisation's lock on the whole category, which `SettingsVisibilityPolicy` applies (Plan HA C4).
//
// Two guarantees the types carry rather than a comment:
//
//   1. **The order is the enum's declaration order.** `SettingsCategoryID.allCases` *is* the hub,
//      so a category cannot exist without a place in it, and the view's `destination(for:)` switch
//      is exhaustive — a new case does not compile until it has a screen.
//   2. **The assistive surface is built by `SettingsCategory.pinnedAssistive`**, which takes no
//      Simple Mode parameter. Accessibility is free forever, and a blind or low-vision wearer is a
//      first-class day-one user: no Simple Mode, organisation profile or edition may withhold it
//      (an organisation's lockdown keeps it pinned open too — `ManagedLockdown.pinnedOpen`).

/// One category of the hub. The raw value is stable: it is the id an organisation profile names
/// when it opens or locks a category (`ConfigProfile.lockdown`), so **never change one**.
enum SettingsCategoryID: String, CaseIterable, Codable, Sendable {
    case intelligence
    case voice
    /// Plan KH P2: settings by what you want done. Locked on a managed phone unless a profile opens
    /// it, because `ManagedLockdown` locks whatever is not listed as open.
    case everyday
    case devices
    case accessibility
    case fieldAssist = "field-assist"
    case myManuals = "my-manuals"
    case lookAndFeel = "look-and-feel"
    case tools
    case connections
    case capture
    case display
    case advanced
    case diagnostics
}

/// One row of the settings hub. `title` and `subtitle` are localized where they are written
/// (`describe(_:)`): the hub hands them to its rows as runtime `String`s, which SwiftUI shows
/// verbatim, so a bare literal here would never reach the string catalog.
struct SettingsCategory: Identifiable, Equatable, Hashable, Sendable {
    let id: SettingsCategoryID
    let title: String
    /// SF Symbol for the row's icon tile.
    let icon: String
    /// Draw the icon tile in the muted (neutral) treatment — for power-user surfaces that
    /// shouldn't pull the eye down the list.
    let mutedIcon: Bool
    /// The row's supporting line.
    let subtitle: String
    /// Simple Mode (the caretaker switch, BM P10) hides the owner-configuration surface for
    /// handing the device to someone who just needs it to work. It is orthogonal to an
    /// organisation's lockdown: Simple Mode filters rows here; a lockdown's filter is
    /// `SettingsVisibilityPolicy.hubCategories`, applied on top.
    let shownInSimpleMode: Bool

    static func category(
        _ id: SettingsCategoryID,
        title: String,
        icon: String,
        mutedIcon: Bool = false,
        subtitle: String,
        shownInSimpleMode: Bool
    ) -> SettingsCategory {
        SettingsCategory(id: id, title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
                         shownInSimpleMode: shownInSimpleMode)
    }

    /// The assistive surface. No Simple Mode parameter: there is nowhere else to put it.
    static func pinnedAssistive(
        _ id: SettingsCategoryID,
        title: String,
        icon: String,
        subtitle: String
    ) -> SettingsCategory {
        SettingsCategory(id: id, title: title, icon: icon, mutedIcon: false, subtitle: subtitle,
                         shownInSimpleMode: true)
    }
}

/// The shipped hub: every category, its copy, and what Simple Mode keeps.
enum SettingsCatalog {

    /// The hub's rows, in `SettingsCategoryID` order.
    static let all: [SettingsCategory] = SettingsCategoryID.allCases.map(describe)

    static func category(_ id: SettingsCategoryID) -> SettingsCategory {
        describe(id)
    }

    /// The rows the hub draws. Simple Mode keeps the everyday surface — Voice & Triggers, Devices &
    /// Privacy, Accessibility, Look & Feel, Diagnostics & Support — and hides the owner's
    /// configuration. An organisation's lockdown is applied on top, by `SettingsVisibilityPolicy`.
    static func visible(simpleMode: Bool) -> [SettingsCategory] {
        all.filter { !simpleMode || $0.shownInSimpleMode }
    }

    private static func describe(_ id: SettingsCategoryID) -> SettingsCategory {
        switch id {
        case .intelligence:
            return .category(id, title: String(localized: "AI & Personality"), icon: "brain.head.profile",
                             subtitle: String(localized: "Models, personas, prompt, and behaviour"),
                             shownInSimpleMode: false)
        case .voice:
            return .category(id, title: String(localized: "Voice & Triggers"), icon: "waveform",
                             subtitle: String(localized: "Wake phrase, push-to-talk, hands-free triggers"),
                             shownInSimpleMode: true)
        case .everyday:
            return .category(id, title: String(localized: "Everyday"), icon: "sun.max",
                             subtitle: String(localized: "Memory, your day, getting around, home, translation, and health"),
                             shownInSimpleMode: false)
        case .devices:
            // Glasses settings live here, under Glasses — never in a general category.
            return .category(id, title: String(localized: "Devices & Privacy"), icon: "lock.shield",
                             subtitle: String(localized: "Glasses, hardware, privacy, and medical compliance"),
                             shownInSimpleMode: true)
        case .accessibility:
            return .pinnedAssistive(id, title: String(localized: "Accessibility"), icon: "accessibility",
                                    subtitle: String(localized: "Assistive narration, guidance, and reading help"))
        case .fieldAssist:
            return .category(id, title: String(localized: "Field Assist"), icon: "wrench.adjustable",
                             subtitle: String(localized: "Jobs, vaults, reports, and expert help"),
                             shownInSimpleMode: false)
        case .myManuals:
            return .category(id, title: String(localized: "My Manuals"), icon: "books.vertical",
                             subtitle: String(localized: "Your manuals, asked by voice with the page cited"),
                             shownInSimpleMode: true)
        case .lookAndFeel:
            return .category(id, title: String(localized: "Look & Feel"), icon: "paintbrush",
                             subtitle: String(localized: "Theme, accent colour, and languages"),
                             shownInSimpleMode: true)
        case .tools:
            return .category(id, title: String(localized: "Tools & Actions"), icon: "wrench.and.screwdriver",
                             subtitle: String(localized: "Quick actions, tools, skills, and playbooks"),
                             shownInSimpleMode: false)
        case .connections:
            return .category(id, title: String(localized: "Connections"), icon: "point.3.connected.trianglepath.dotted",
                             subtitle: String(localized: "Your iPhone's apps, services, gateways, and MCP servers"),
                             shownInSimpleMode: false)
        case .capture:
            return .category(id, title: String(localized: "Capture & Streaming"), icon: "video",
                             subtitle: String(localized: "Recordings, meetings, and going live"),
                             shownInSimpleMode: false)
        case .display:
            return .category(id, title: String(localized: "Display & HUD"), icon: "eyeglasses",
                             subtitle: String(localized: "The in-lens display and everything that draws on it"),
                             shownInSimpleMode: false)
        case .advanced:
            return .category(id, title: String(localized: "Advanced"), icon: "gearshape.2", mutedIcon: true,
                             subtitle: String(localized: "Developer and power-user tools"),
                             shownInSimpleMode: false)
        case .diagnostics:
            // Visible in Simple Mode on purpose: the wearers who most need a self-test and a way
            // to report a problem are the ones who never see Advanced.
            return .category(id, title: String(localized: "Diagnostics & Support"), icon: "stethoscope",
                             subtitle: String(localized: "Test your devices and AI — or report a problem"),
                             shownInSimpleMode: true)
        }
    }
}
