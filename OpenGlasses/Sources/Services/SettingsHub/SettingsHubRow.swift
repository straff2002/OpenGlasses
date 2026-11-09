import Foundation

// The settings hub's rows (Plan KH P2): eight, and a ninth, Assisting, only on an expert's phone
// (Plan KW). A drawing layer on top of `SettingsCategoryID`, and
// nothing else: pure data and pure functions, like `SettingsCatalog`.
//
// **An organisation profile never sees this file.** `SettingsCategoryID`, its raw values, what a
// lockdown locks and what `SettingsVisibilityPolicy` decides are all still per category. A row only
// says which categories it draws together, so moving a row here cannot open or lock anything.
//
// The rules, each asserted headlessly in `SettingsHubRowTests`:
//
//   1. Every category belongs to exactly one row, whichever kind of phone this is.
//   2. A row is drawn when any of its categories is visible, and shows only those.
//   3. A row with one visible category goes straight to it, with that category's own subtitle.
//   4. A category still opens by itself (`SettingsHub.route`), so `AppState.openSettings(_:)` lands
//      on the same screen it always did.

/// One row of the hub. Not stored and not named by any profile, so these may change.
enum SettingsHubRowID: String, CaseIterable, Sendable {
    case assistant
    case everyday
    case devicesPrivacy
    case connections
    case accessibility
    case fieldAssist
    /// Plan KW: drawn only where Assisting is the owner's (`AssistingPresence`).
    case assisting
    case lookAndFeel
    case advancedSupport
}

/// What the row layout depends on, beyond who is looking.
struct SettingsHubPhone: Equatable, Sendable {
    /// This copy offers glasses (`GlassesSupportPolicy.isSupported`).
    var glassesSupported: Bool
}

struct SettingsHubRow: Identifiable, Equatable, Sendable {
    let id: SettingsHubRowID
    let title: String
    let icon: String
    let mutedIcon: Bool
    let subtitle: String
    /// In the order the row's screen shows them.
    let children: [SettingsCategoryID]
}

enum SettingsHub {

    // MARK: - The rows

    /// The hub's rows, in order, with the categories each one holds on this kind of phone.
    static func rows(on phone: SettingsHubPhone) -> [SettingsHubRow] {
        SettingsHubRowID.allCases.map { row($0, on: phone) }
    }

    static func row(_ id: SettingsHubRowID, on phone: SettingsHubPhone) -> SettingsHubRow {
        switch id {
        case .assistant:
            return SettingsHubRow(
                id: id, title: String(localized: "Assistant"), icon: "brain.head.profile", mutedIcon: false,
                subtitle: String(localized: "Models, personas, wake phrase, and voice"),
                children: [.intelligence, .voice])
        case .everyday:
            let everyday = SettingsCatalog.category(.everyday)
            return SettingsHubRow(
                id: id, title: everyday.title, icon: everyday.icon, mutedIcon: false, subtitle: everyday.subtitle,
                children: [.everyday, .myManuals])
        case .devicesPrivacy:
            let devices = SettingsCatalog.category(.devices)
            return SettingsHubRow(
                id: id, title: devices.title, icon: devices.icon, mutedIcon: false,
                subtitle: phone.glassesSupported
                    ? String(localized: "Glasses, privacy, recordings, and going live")
                    : String(localized: "Hardware, privacy, recordings, and going live"),
                children: [.devices, .capture, .display])
        case .connections:
            let connections = SettingsCatalog.category(.connections)
            return SettingsHubRow(
                id: id, title: connections.title, icon: connections.icon, mutedIcon: false,
                subtitle: String(localized: "Your apps, services, tools, and skills"),
                children: [.connections, .tools])
        case .accessibility:
            return single(id, .accessibility)
        case .fieldAssist:
            let fieldAssist = SettingsCatalog.category(.fieldAssist)
            return SettingsHubRow(
                id: id, title: fieldAssist.title, icon: fieldAssist.icon, mutedIcon: false,
                subtitle: fieldAssist.subtitle,
                children: [.fieldAssist])
        case .assisting:
            return single(id, .assisting)
        case .lookAndFeel:
            return single(id, .lookAndFeel)
        case .advancedSupport:
            return SettingsHubRow(
                id: id, title: String(localized: "Advanced & Support"), icon: "gearshape.2", mutedIcon: true,
                subtitle: String(localized: "Test your devices, report a problem, and power-user tools"),
                children: [.diagnostics, .advanced])
        }
    }

    private static func single(_ id: SettingsHubRowID, _ category: SettingsCategoryID) -> SettingsHubRow {
        let described = SettingsCatalog.category(category)
        return SettingsHubRow(id: id, title: described.title, icon: described.icon, mutedIcon: described.mutedIcon,
                              subtitle: described.subtitle, children: [category])
    }

    /// The row a category is drawn under on this kind of phone.
    static func home(of category: SettingsCategoryID, on phone: SettingsHubPhone) -> SettingsHubRowID {
        // Total by construction: `testEveryCategoryBelongsToExactlyOneRow` holds it to that.
        rows(on: phone).first { $0.children.contains(category) }?.id ?? .advancedSupport
    }

    /// How a category is named in a path after "Settings": its row, then the category itself where
    /// it is a link row of its own rather than content on the row's page. For the words a person
    /// reads, and the model repeats, so a path cannot name a row the hub does not draw.
    static func path(to category: SettingsCategoryID,
                     on phone: SettingsHubPhone = SettingsHubPhone(glassesSupported: true)) -> String {
        let row = row(home(of: category, on: phone), on: phone).title
        switch category {
        case .voice, .advanced, .myManuals:
            return "\(row) > \(SettingsCatalog.category(category).title)"
        default:
            return row
        }
    }

    // MARK: - What is visible

    /// The categories this person can reach. `SettingsVisibilityPolicy` decides, per category; this
    /// adds only what the hub has always added: no My Manuals in the technician's view, and no
    /// display settings on a copy that does not offer glasses. Plan KW: Assisting only where it is
    /// the owner's — a card, a handover, ledger time or an open invite (`AssistingPresence`).
    static func visibleCategories(simpleMode: Bool, in context: ManagedSettingsContext,
                                  on phone: SettingsHubPhone, assistingPresent: Bool = false) -> [SettingsCategory] {
        SettingsVisibilityPolicy.hubCategories(simpleMode: simpleMode, in: context)
            .filter { $0.id != .myManuals || !context.restricted }
            .filter { phone.glassesSupported || $0.id != .display }
            .filter { assistingPresent || $0.id != .assisting }
    }

    /// A row as this person sees it.
    struct VisibleRow: Identifiable, Equatable, Sendable {
        let row: SettingsHubRow
        /// Never empty: a row with nothing visible is not drawn.
        let children: [SettingsCategory]

        var id: SettingsHubRowID { row.id }
        var title: String { row.title }

        /// With one category showing, the row says what is behind it, in that category's own words.
        var subtitle: String { children.count == 1 ? children[0].subtitle : row.subtitle }
        /// The category whose live value the row carries.
        var summaryCategory: SettingsCategoryID { children[0].id }
        var page: Page { SettingsHub.page(for: row.id, showing: children.map(\.id)) }
    }

    static func visibleRows(simpleMode: Bool, in context: ManagedSettingsContext,
                            on phone: SettingsHubPhone, assistingPresent: Bool = false) -> [VisibleRow] {
        let visible = visibleCategories(simpleMode: simpleMode, in: context, on: phone,
                                        assistingPresent: assistingPresent)
        return rows(on: phone).compactMap { row in
            let children = row.children.compactMap { id in visible.first { $0.id == id } }
            return children.isEmpty ? nil : VisibleRow(row: row, children: children)
        }
    }

    // MARK: - What a row opens

    /// What tapping a row shows.
    enum Page: Equatable, Sendable {
        /// Straight to one category's screen. Everyday and Field Assist always open this way: My
        /// Manuals is a row on Everyday's own screen, wherever it is opened from.
        case category(SettingsCategoryID)
        /// One page for these categories, in this order.
        case merged([SettingsCategoryID])
    }

    static func page(for row: SettingsHubRowID, showing children: [SettingsCategoryID]) -> Page {
        guard let first = children.first else { return .merged([]) }
        guard children.count > 1 else { return .category(first) }
        switch row {
        case .everyday, .fieldAssist, .assisting, .accessibility, .lookAndFeel: return .category(first)
        case .assistant, .devicesPrivacy, .connections, .advancedSupport: return .merged(children)
        }
    }

    // MARK: - Opening a category from elsewhere

    /// Where a request to open a category lands (`AppState.openSettings(_:)`). A category opens as
    /// itself, never as a row, so the person arrives at the setting rather than on a longer page
    /// with it further down. Simple Mode and a lockdown are not to be got round by a shortcut, so a
    /// category that is not visible leaves them on the hub.
    enum Route: Equatable, Sendable {
        case category(SettingsCategoryID)
        case hub
    }

    static func route(_ requested: SettingsCategoryID, visible: [SettingsCategory]) -> Route {
        visible.contains { $0.id == requested } ? .category(requested) : .hub
    }

    // MARK: - Things to Try

    enum ThingsToTryPlace: Equatable, Sendable {
        /// The first row of Everyday.
        case everyday
        /// Its own row beside About, because Everyday's screen cannot be reached here.
        case besideAbout
    }

    /// Keyed on the category, not the row. In Simple Mode the Everyday row can be on the hub with
    /// only My Manuals behind it, and Everyday's screen is still out of reach.
    static func thingsToTryPlace(visible: [SettingsCategory]) -> ThingsToTryPlace {
        visible.contains { $0.id == .everyday } ? .everyday : .besideAbout
    }

    // MARK: - My Manuals

    /// Whether the My Manuals row belongs on the screen of `host`. Always Everyday: My Manuals is the
    /// person's own library, never part of Field Assist, even on a phone that has both.
    static func showsMyManuals(on host: SettingsHubRowID, visible: [SettingsCategory],
                               phone: SettingsHubPhone) -> Bool {
        visible.contains { $0.id == .myManuals } && home(of: .myManuals, on: phone) == host
    }
}
