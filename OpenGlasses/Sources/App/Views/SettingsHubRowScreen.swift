import SwiftUI

// What the settings hub's rows open (Plan KH P2). `SettingsHub` decides; these only draw it.

// MARK: - One category

/// One category's screen, behind its lock. A hub row, a merged page's link row and a request from
/// elsewhere (`AppState.openSettings(_:)`) all come through here.
struct SettingsCategoryScreen: View {
    @ObservedObject var appState: AppState
    let id: SettingsCategoryID
    @ObservedObject private var adminGate = AdminGate.shared

    var body: some View {
        switch adminGate.lock(id) {
        case .open, .partlyOpen:
            // A partly open screen asks `AdminGate` per row and leaves the locked ones out.
            destination(for: id)
        case .locked:
            // Reached only when the lock changed under an open screen (an administrator session
            // ending); the screen's own controls are never built.
            ManagedHiddenScreen(organization: ManagedLockReason.organization)
        }
    }

    /// Every category's screen. Exhaustive on purpose: a category added to `SettingsCategoryID`
    /// does not compile until it has somewhere to go.
    @ViewBuilder
    private func destination(for id: SettingsCategoryID) -> some View {
        switch id {
        case .intelligence:
            AIPersonalitySettingsScreen(appState: appState)
        case .voice:
            VoiceTriggersSettingsScreen(appState: appState)
        case .everyday:
            EverydaySettingsScreen(appState: appState)
        case .devices:
            GlassesPrivacySettingsScreen(appState: appState)
        case .accessibility:
            AccessibilitySettingsView().environmentObject(appState)
        case .fieldAssist:
            FieldAssistSettingsView().environmentObject(appState)
        case .myManuals:
            MyManualsView().environmentObject(appState)
        case .lookAndFeel:
            LookFeelSettingsScreen()
        case .tools:
            ToolsActionsSettingsScreen(appState: appState)
        case .connections:
            ConnectionsSettingsScreen(appState: appState)
        case .capture:
            CaptureStreamingSettingsScreen(appState: appState)
        case .display:
            DisplayHUDSettingsScreen(appState: appState)
        case .advanced:
            AdvancedSettingsScreen(appState: appState)
        case .diagnostics:
            DiagnosticsSupportView(appState: appState)
        }
    }
}

// MARK: - One hub row

/// What a hub row opens. It reads what is visible each time it draws, so an administrator session
/// ending under an open page takes the locked categories with it.
struct SettingsHubRowScreen: View {
    @ObservedObject var appState: AppState
    let row: SettingsHubRowID
    @ObservedObject private var adminGate = AdminGate.shared

    private var children: [SettingsCategoryID] {
        SettingsHub.visibleRows(simpleMode: Config.simpleModeEnabled, in: adminGate.settingsContext,
                                on: .current)
            .first { $0.id == row }?.children.map(\.id) ?? []
    }

    var body: some View {
        let page = SettingsHub.page(for: row, showing: children)
        switch page {
        case .category(let id):
            SettingsCategoryScreen(appState: appState, id: id)
        case .merged(let children):
            if children.isEmpty {
                ManagedHiddenScreen(organization: ManagedLockReason.organization)
            } else {
                merged(children)
            }
        }
    }

    /// The pages that hold more than one category. A short category's sections are drawn here, so
    /// nothing costs another tap. A long one is one link row at the top of its neighbour.
    @ViewBuilder
    private func merged(_ children: [SettingsCategoryID]) -> some View {
        switch row {
        case .assistant:
            AIPersonalitySettingsScreen(appState: appState, showsVoiceLink: true)
        case .advancedSupport:
            DiagnosticsSupportView(appState: appState, showsAdvancedLink: true)
        case .devicesPrivacy where children.first == .devices:
            GlassesPrivacySettingsScreen(appState: appState, alsoShows: Array(children.dropFirst()))
        case .devicesPrivacy, .connections:
            Form {
                ForEach(children, id: \.self) { category in
                    SettingsInlineSections(appState: appState, category: category)
                }
            }
            .navigationTitle(SettingsHub.row(row, on: .current).title)
            .ogFormStyle()
        case .everyday, .fieldAssist, .accessibility, .lookAndFeel:
            // `SettingsHub.page(for:showing:)` never merges these.
            SettingsCategoryScreen(appState: appState, id: children[0])
        }
    }
}

/// A category's sections, for a page that draws several. Only the categories with a sections view
/// can be here: `SettingsHub.page(for:showing:)` keeps the others apart.
struct SettingsInlineSections: View {
    @ObservedObject var appState: AppState
    let category: SettingsCategoryID

    var body: some View {
        switch category {
        case .capture: CaptureStreamingSections(appState: appState)
        case .display: DisplayHUDSections(appState: appState)
        case .connections: ConnectionsSections(appState: appState)
        case .tools: ToolsActionsSections(appState: appState)
        default: EmptyView()
        }
    }
}

// MARK: - A link row inside a Form

/// A category as one row in a Form, where `NavigationLink` draws the chevron: its title, and the
/// subtitle that says what is behind it.
struct SettingsLinkLabel: View {
    private let title: String
    private let subtitle: String
    private let icon: String

    init(title: String, subtitle: String, icon: String) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }

    init(_ category: SettingsCategoryID) {
        let described = SettingsCatalog.category(category)
        self.init(title: described.title, subtitle: described.subtitle, icon: described.icon)
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - This phone

extension SettingsHubPhone {
    /// This phone, now.
    @MainActor static var current: SettingsHubPhone {
        SettingsHubPhone(fieldAssistOn: Config.fieldAssistActive,
                         glassesSupported: GlassesSupportPolicy.isSupported)
    }
}

extension SettingsHub {
    /// Whether this phone's `host` screen draws the My Manuals row.
    @MainActor static func showsMyManuals(on host: SettingsHubRowID) -> Bool {
        let phone = SettingsHubPhone.current
        return showsMyManuals(on: host,
                              visible: visibleCategories(simpleMode: Config.simpleModeEnabled,
                                                         in: AdminGate.shared.settingsContext, on: phone),
                              phone: phone)
    }
}
