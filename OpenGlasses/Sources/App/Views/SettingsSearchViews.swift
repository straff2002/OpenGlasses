import SwiftUI

// Plan NE P1 — settings search and pins on the hub. `SettingsIndex`, `SettingsSearch` and
// `SettingsPins` decide everything; these only draw it. What they draw is always resolved through
// `SettingsIndex.visible(in:)`, so a result or a pin never reaches what the hub could not.

// MARK: - Who is looking, now

extension SettingsSearchConditions {
    /// This phone, now. `simpleMode` comes from the caller's `@AppStorage`, so the caller redraws
    /// when it changes.
    @MainActor static func current(simpleMode: Bool) -> SettingsSearchConditions {
        #if AVENKIN_PHONE_ONLY
        let phoneOnlyBuild = true
        #else
        let phoneOnlyBuild = false
        #endif
        return SettingsSearchConditions(
            simpleMode: simpleMode,
            context: AdminGate.shared.settingsContext,
            phone: .current,
            phoneOnlyBuild: phoneOnlyBuild,
            assistingPresent: AssistingPresenceFeed.shared.presence.isPresent,
            agentMode: Config.agentModeEnabled,
            fieldAssistUnlocked: Config.fieldAssistUnlocked,
            fieldAssistOn: Config.fieldAssistEnabled,
            watchInstalled: WatchConnectivityManager.shared.isWatchAppInstalled,
            myDayOn: Config.myDayEnabled)
    }
}

// MARK: - The search field

/// `.searchable` on the hub, only while the Lock Settings cover is not up.
struct SettingsSearchField: ViewModifier {
    @Binding var query: String
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: Text("Search Settings"))
        } else {
            content
        }
    }
}

// MARK: - Results

/// What the hub shows while there is something in the search field.
struct SettingsSearchResultsPage: View {
    let query: String
    let conditions: SettingsSearchConditions
    @Binding var pins: SettingsPins
    let open: (SettingsIndexEntry) -> Void

    var body: some View {
        let results = SettingsSearch.results(for: query, in: conditions)
        OGScrollPage {
            if results.isEmpty {
                Text("No settings match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else {
                OGSection {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        if index > 0 { OGDivider() }
                        SettingsSearchResultRow(
                            entry: result.entry,
                            breadcrumb: result.breadcrumb,
                            pinned: pins.contains(result.entry.id),
                            canPin: !pins.isFull,
                            open: { open(result.entry) },
                            togglePin: { pins.toggle(result.entry.id) })
                    }
                }
            }
        }
    }
}

/// One result: its name, its category's icon and where it lives, and a pin at the end.
struct SettingsSearchResultRow: View {
    let entry: SettingsIndexEntry
    let breadcrumb: String
    let pinned: Bool
    let canPin: Bool
    let open: () -> Void
    let togglePin: () -> Void
    @Environment(\.appAccent) private var accent

    var body: some View {
        let category = SettingsCatalog.category(entry.category)
        HStack(spacing: 0) {
            Button(action: open) {
                OGRow(entry.title, icon: category.icon, mutedIcon: category.mutedIcon, subtitle: breadcrumb,
                      showsChevron: false) { EmptyView() }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)

            Button(action: togglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.body)
                    .foregroundStyle(pinned ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .disabled(!pinned && !canPin)
            .accessibilityLabel(pinned ? Text("Unpin") : Text("Pin"))
            .accessibilityHint(!pinned && !canPin ? Text("Up to 8 settings can be pinned.") : Text(verbatim: ""))
        }
    }
}

// MARK: - Pinned

/// The hub's Pinned section, between the Organisation section and the category rows. Not drawn
/// while nothing pinned is visible to this person.
struct SettingsPinnedSection: View {
    @Binding var pins: SettingsPins
    let conditions: SettingsSearchConditions
    let open: (SettingsIndexEntry) -> Void

    var body: some View {
        let shown = pins.visible(in: conditions)
        if !shown.isEmpty {
            let order = shown.map(\.id)
            OGSection(header: "Pinned") {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { OGDivider() }
                    row(entry, order: order)
                }
            }
        }
    }

    private func row(_ entry: SettingsIndexEntry, order: [String]) -> some View {
        let category = SettingsCatalog.category(entry.category)
        let canMoveUp = pins.canMove(up: entry.id, among: order)
        let canMoveDown = pins.canMove(down: entry.id, among: order)
        return Button {
            open(entry)
        } label: {
            OGRow(entry.title, icon: category.icon, mutedIcon: category.mutedIcon,
                  subtitle: SettingsIndex.breadcrumb(for: entry, on: conditions.phone))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Unpin", systemImage: "pin.slash") { pins.unpin(entry.id) }
            if canMoveUp {
                Button("Move Up", systemImage: "arrow.up") { pins.move(up: entry.id, among: order) }
            }
            if canMoveDown {
                Button("Move Down", systemImage: "arrow.down") { pins.move(down: entry.id, among: order) }
            }
        }
        .accessibilityAction(named: Text("Unpin")) { pins.unpin(entry.id) }
        .accessibilityAction(named: Text("Move Up")) {
            if canMoveUp { pins.move(up: entry.id, among: order) }
        }
        .accessibilityAction(named: Text("Move Down")) {
            if canMoveDown { pins.move(down: entry.id, among: order) }
        }
    }
}

// MARK: - What a result opens

/// What opening a result or a pin shows. It re-reads visibility each time it draws, as
/// `SettingsHubRowScreen` does, so a profile arriving or Simple Mode going on under an open screen
/// takes it away; a category goes through its own lock wrapper. Each screen is built exactly as the
/// screen that links to it builds it.
struct SettingsIndexDestinationScreen: View {
    @ObservedObject var appState: AppState
    let entry: SettingsIndexEntry
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var assisting = AssistingPresenceFeed.shared
    @ObservedObject private var watch = WatchConnectivityManager.shared
    @AppStorage("simpleModeEnabled") private var simpleModeEnabled = false

    // The values the parents of Smart Routing and Hardware & Privacy hold for them, seeded as
    // those parents seed them.
    @State private var autoModelRoutingEnabled = Config.autoModelRoutingEnabled
    @State private var micRoute = Config.micRoute
    @State private var conversationEncryptionEnabled = Config.conversationEncryptionEnabled
    @State private var isTogglingEncryption = false

    var body: some View {
        if SettingsIndex.opens(entry.destination, in: .current(simpleMode: simpleModeEnabled)) {
            destination
                .environmentObject(appState)
        } else {
            ManagedHiddenScreen(organization: ManagedLockReason.organization)
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch entry.destination {
        case .category(let id):
            SettingsCategoryScreen(appState: appState, id: id)
        case .screen(let id):
            screen(id)
        }
    }

    /// Every screen. Exhaustive on purpose: a screen added to `SettingsScreenID` does not compile
    /// until it has somewhere to go.
    private func screen(_ id: SettingsScreenID) -> AnyView {
        switch id {
        // AI & Personality
        case .realtimeModels:
            return AnyView(RealtimeModelsView())
        case .personas:
            return AnyView(PersonasView())
        case .systemPrompt:
            return AnyView(PromptPresetsView(appState: appState))
        case .smartRouting:
            return AnyView(SmartRoutingView(autoModelRoutingEnabled: $autoModelRoutingEnabled,
                                            modelConfigs: Config.savedModels))
        case .visionImages:
            return AnyView(LLMImageSettingsView())
        case .agenticFeatures:
            return AnyView(AgenticFeaturesView(agentDocs: appState.agentDocs, localLLM: appState.localLLMService)
                .environmentObject(appState))
        // Voice & Triggers
        case .templeTaps:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(TempleTapSettingsView(appState: appState))
            #endif
        // Everyday
        case .memory:
            return AnyView(MemoryView(model: appState.memoryFacts.makeScreenModel()))
        case .goals:
            return AnyView(GoalsView())
        case .activity:
            return AnyView(ActivityView(model: ActivityScreenModel.live(conversations: appState.conversationStore)))
        case .myDayContents:
            return AnyView(MyDayContentsSettingsView())
        case .preparedCards:
            return AnyView(PreparedCardSettingsView(service: appState.myDayService))
        case .myDayDelivery:
            return AnyView(MyDayDeliverySettingsView())
        case .scheduledTasks:
            return AnyView(ScheduledTasksView()
                .environmentObject(appState))
        case .navigation:
            return AnyView(NavigationSettingsView(glassesDisplay: appState.glassesDisplay))
        case .parking:
            return AnyView(ParkingSettingsView(appState: appState))
        case .music:
            return AnyView(MusicSettingsView())
        case .homeAssistant:
            return AnyView(HomeAssistantSettingsView())
        case .translation:
            return AnyView(TranslationSettingsView())
        case .health:
            return AnyView(HealthSettingsView())
        // Devices & Privacy
        case .glasses:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(GlassesSettingsView(appState: appState))
            #endif
        case .displayBackend:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(EvenDisplaySettingsView())
            #endif
        case .appleWatch:
            return AnyView(AppleWatchSettingsView())
        case .smartRing:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(RingSettingsView(ring: appState.ringService))
            #endif
        case .hardwarePrivacy:
            // Devices & Privacy writes the microphone choice back when its page goes, so this does.
            return AnyView(HardwarePrivacyView(
                appState: appState,
                micRoute: $micRoute,
                conversationEncryptionEnabled: $conversationEncryptionEnabled,
                isTogglingEncryption: $isTogglingEncryption
            )
            .onDisappear {
                Config.setMicRoute(micRoute)
                appState.restartWakeWordIfDirect()
            })
        case .insights:
            return AnyView(InsightsView().environmentObject(appState))
        case .teleprompterOnPhone:
            return AnyView(TeleprompterSettingsView(service: appState.teleprompterService,
                                                    store: appState.teleprompterStore))
        case .healthFitness:
            return AnyView(EverydaySettingsScreen(appState: appState, only: .healthFitness))
        case .medicalCompliance:
            return AnyView(MedicalCompliancePaywallView(
                hipaaService: appState.hipaaService,
                exportService: appState.medicalExportService
            ))
        case .cloudAISharing:
            return AnyView(CloudProcessingSettingsView())
        case .processingSummary:
            return AnyView(ProcessingSummaryView())
        // Accessibility
        case .readinessCheck:
            return AnyView(ReadinessWalkthroughView())
        case .scanAssist:
            return AnyView(ScanAssistSettingsView())
        case .fingerspelling:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(FingerspellingSettingsView())
            #endif
        // Look & Feel
        case .languages:
            return AnyView(LanguageSettingsView())
        // Tools & Actions
        case .quickActions:
            return AnyView(QuickActionsSettingsView()
                .environmentObject(appState))
        case .tools:
            return AnyView(ToolsSettingsView(appState: appState))
        case .customVaults:
            return AnyView(VaultManagerView())
        case .personalNotes:
            return AnyView(VaultFilesEditorView(vaultId: "notes", title: String(localized: "Personal Notes")))
        case .studyMode:
            return AnyView(DeckListView())
        case .reading:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(ReadingStatsView())
            #endif
        case .healthVault:
            return AnyView(HealthVaultEditorView())
        case .customTools:
            return AnyView(CustomToolsView()
                .environmentObject(appState))
        case .skillPacks:
            return AnyView(SkillPacksSettingsView()
                .environmentObject(appState))
        case .addOns:
            return AnyView(AddOnsSettingsView(store: appState.addOnStore)
                .environmentObject(appState))
        case .siriSearch:
            return AnyView(SiriExposureView())
        case .mcpServer:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(MCPServerSettingsView()
                .environmentObject(appState))
            #endif
        case .playbooks:
            return AnyView(PlaybooksSettingsView(store: appState.playbookStore))
        case .skillStore:
            return AnyView(ClawHubBrowserView())
        case .voiceSkills:
            return AnyView(VoiceSkillsManagerView())
        case .suggestedSkills:
            return AnyView(SuggestedSkillsView()
                .environmentObject(appState))
        // Connections
        case .appleIntegrations:
            return AnyView(AppleIntegrationsSettingsScreen())
        case .weatherData:
            return AnyView(WeatherDataAboutView())
        case .services:
            return AnyView(ServicesSettingsView(appState: appState))
        case .gateways:
            return AnyView(GatewaySettingsView(appState: appState))
        case .mcpServers:
            return AnyView(MCPServersView()
                .environmentObject(appState))
        // Capture & Streaming
        case .recordings:
            return AnyView(RecordingsView(
                store: appState.recordedSessionStore,
                controller: appState.sessionRecorder,
                audioRecorder: appState.audioRecorder
            ))
        case .meetingRecords:
            return AnyView(MeetingRecordsView())
        case .captionSessions:
            return AnyView(CaptionSessionsView())
        // Display & HUD
        case .bandPractice:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(BandPracticeView(session: appState.bandPractice))
            #endif
        case .lensFitCheck:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(LensFitCheckView(session: appState.lensFitCheck))
            #endif
        case .hudMirror:
            #if AVENKIN_PHONE_ONLY
            return hidden
            #else
            return AnyView(HUDMirrorView(router: appState.hudRouter))
            #endif
        case .teleprompter:
            return AnyView(TeleprompterSettingsView(service: appState.teleprompterService,
                                                    store: appState.teleprompterStore))
        // Advanced
        case .developer:
            return AnyView(DeveloperPanelView(appState: appState))
        case .promptInspector:
            return AnyView(PromptInspectorView(appState: appState))
        case .networkActivity:
            return AnyView(NetworkMonitorView())
        case .liveVision:
            return AnyView(LiveVisionSettingsView())
        case .documents:
            return AnyView(DocumentsView())
        case .captureFlow:
            return AnyView(CaptureFlowAuthorView())
        // Diagnostics & Support
        case .diagnosticExport:
            return AnyView(DiagnosticExportView())
        }
    }

    #if AVENKIN_PHONE_ONLY
    /// A glasses screen on the phone-only build: its entry is never offered there.
    private var hidden: AnyView {
        AnyView(ManagedHiddenScreen(organization: ManagedLockReason.organization))
    }
    #endif
}
