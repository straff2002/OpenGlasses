import SwiftUI
import AVFoundation
import MWDATCore

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The locked-settings lock glyph is decorative and drawn well past body size — scale it
    /// with Dynamic Type rather than pinning it to a literal point size.
    @ScaledMetric(relativeTo: .largeTitle) private var lockGlyphSize: CGFloat = 44

    @State private var simpleModeEnabled = Config.simpleModeEnabled
    /// Plan CT 3b / HA C2: the Field Assist edition's lockdown, lifted by an administrator session.
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var orgProfile = OrgProfileManager.shared
    @AppStorage("appAppearance") private var appearance: String = "system"
    @AppStorage("wakePhrase") private var wakePhrase = Config.defaultWakePhrase
    @AppStorage("activeModelId") private var activeModelId = ""
    @AppStorage("glassesDisplayEnabled") private var glassesDisplayEnabled = false
    @AppStorage("fieldAssistEnabled") private var fieldAssistEnabled = false

    // Owner gate (BM P10): Simple-Mode exit always asks; Settings entry asks when the flag is on.
    @State private var settingsOwnerGateEnabled = Config.settingsOwnerGateEnabled
    @State private var settingsLocked = Config.settingsOwnerGateEnabled
    @State private var exitGate = OwnerGateMachine()
    @State private var entryGate = OwnerGateMachine()

    // The individual settings live in per-category screens (SettingsScreens.swift and
    // SettingsCategoryScreens.swift); this view is the hub (Plan HA): the hero device card,
    // every category in `SettingsCatalog` order, then Simple Mode and About.
    //
    // Every category is always a row. Simple Mode filters the owner-configuration rows out; an
    // organisation's lockdown (`SettingsLockPolicy`) never removes a row — it marks it read-only
    // with the organisation named, and an administrator session unlocks it.

    private var visibleCategories: [SettingsCategory] {
        SettingsCatalog.visible(simpleMode: simpleModeEnabled)
    }

    private var organization: String { ManagedLockReason.organization }

    private var heroDevice: SettingsHeroDevice {
        SettingsHeroDevice.resolve(phase: appState.glassesPhase, glassesAdded: appState.glassesAdded)
    }

    var body: some View {
        // The hub is an OGDesign page (Plan CL): hero device card, then one grouped card of
        // category rows, each with a live value summary.
        OGScrollPage {
            // The device in use (Plan HA C3): the glasses while they are attached — connected,
            // paused or connecting — and this iPhone otherwise. Glasses settings stay one row away
            // under Devices & Privacy › Glasses whichever card is showing.
            switch heroDevice {
            case .phone:
                OGHeroDeviceCard(
                    title: "This iPhone",
                    status: heroDevice.phoneStatus ?? "In use",
                    dot: OGTheme.ok,
                    chips: [("Voice", true), ("Chat", true), ("Camera", true)],
                    symbol: "iphone"
                )
            case .glasses:
                OGHeroDeviceCard(
                    title: appState.glassesService.deviceName ?? "Meta Glasses",
                    status: glassesStatus,
                    dot: appState.isConnected ? OGTheme.ok
                        : (appState.glassesPhase.isConnecting ? OGTheme.warn : Color.secondary),
                    batteryPercent: appState.glassesService.batteryLevel,
                    chips: [
                        ("Camera", appState.isConnected),
                        ("Display", appState.glassesDisplay.hasDisplayCapability),
                        ("HUD \(glassesDisplayEnabled ? "on" : "off")", glassesDisplayEnabled),
                    ]
                )
            }

            // Plan CT PR 2: a managed phone says so, always, with the way out beside it.
            ManagedByOrganisationSection(manager: OrgProfileManager.shared)
            OrgAdministratorSection(gate: adminGate, manager: orgProfile)

            OGSection {
                ForEach(Array(visibleCategories.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { OGDivider() }
                    categoryRow(category)
                }
            }

            // MARK: Simple Mode (the owner's hand-off switch, behind the owner gate). Under an
            // organisation's edition it is locked with everything else the owner configures.
            simpleModeSection

            OGSection(
                header: "About",
                // The tagline and the device line, in the owner's words (Plan FY P2.1).
                footer: "Your AI. Your terms. On your phone, from your wrist, or hands-free with glasses.\n\nAvenkin © 2026 Skunkworks NZ Ltd. Source-available under the Business Source License 1.1: free for personal, non-commercial use — commercial use requires a licence.\n\nJoin the Discord for help, ideas, and to share what you've built."
            ) {
                OGRow("Version", icon: "info.circle", mutedIcon: true, verbatimValue: Self.appVersion, showsChevron: false)
                OGDivider()
                OGRow("Build", icon: "hammer", mutedIcon: true, verbatimValue: Self.buildNumber, showsChevron: false)
                OGDivider()
                NavigationLink {
                    AttributionsView()
                } label: {
                    OGRow("Attributions", icon: "doc.text", mutedIcon: true,
                          subtitle: "Third-party models and libraries")
                }
                .buttonStyle(.plain)
                OGDivider()
                Button {
                    UIApplication.shared.open(PublicSite.privacy)
                } label: {
                    OGRow("Privacy Policy", icon: "hand.raised", mutedIcon: true, showsChevron: false) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                OGDivider()
                Button {
                    let webURL = URL(string: "https://discord.gg/8W2qaXJzz9")!
                    UIApplication.shared.open(webURL)
                } label: {
                    OGRow("Discord", icon: "bubble.left.and.bubble.right", showsChevron: false) {
                        HStack(spacing: 4) {
                            Text("Avenkin Discord")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Settings")
        .tint(accent)
        // Owner gate on Settings entry (BM P10, opt-in): an opaque cover — never a blur that
        // leaks decrypted key fields — until device-owner auth grants entry.
        .overlay {
            if settingsLocked { settingsLockCover }
        }
        .onAppear {
            if settingsLocked { authenticateSettingsEntry() }
        }
    }

    // MARK: - Simple Mode

    private var ownerControlsLocked: Bool { adminGate.isLocked(.ownerControls) }

    private var simpleModeSection: some View {
        OGSection(footer: "Simple Mode hides model, persona, behavior, tool, integration, Field Assist and advanced settings — for handing the device to someone who just needs it to work. Leaving it asks for Face ID or your passcode. Lock Settings asks every time Settings opens.") {
            OGRow(
                "Simple Mode",
                isOn: Binding(
                    get: { simpleModeEnabled },
                    set: { requestSimpleModeChange(to: $0) }
                ),
                icon: "dial.low"
            )
            .disabled(ownerControlsLocked)
            OGDivider()
            OGRow("Lock Settings", isOn: $settingsOwnerGateEnabled, icon: "faceid")
                .disabled(ownerControlsLocked)
                .onChange(of: settingsOwnerGateEnabled) { _, v in Config.settingsOwnerGateEnabled = v }
            if ownerControlsLocked {
                OGDivider()
                ManagedLockNote(organization: organization)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            if exitGate.lastFailed {
                OGDivider()
                OGStatusLabel("Couldn't verify it's you — Simple Mode stays on.", kind: .error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Category rendering

    /// One hub row. A category the organisation locked is still a row: its value says so, and its
    /// screen opens read-only (or with its locked rows read-only) under a "Managed by" banner.
    @ViewBuilder
    private func categoryRow(_ category: SettingsCategory) -> some View {
        let lock = adminGate.lock(category.id)
        categoryLink(destination: lockedDestination(for: category.id, lock: lock)) {
            OGRow(
                category.title,
                icon: category.icon,
                mutedIcon: category.mutedIcon,
                subtitle: category.subtitle,
                value: lock.isLocked ? "Managed" : summary(for: category.id),
                alwaysStacksValue: true
            )
        }
        .accessibilityHint(lock.isLocked ? Text("Managed by \(organization). Opens read only.") : Text(""))
    }

    @ViewBuilder
    private func lockedDestination(for id: SettingsCategoryID, lock: CategoryLock) -> some View {
        switch lock {
        case .open:
            destination(for: id)
        case .readOnly:
            destination(for: id).managedReadOnly(organization)
        case .partlyOpen:
            // The screen locks its own rows (it asks `AdminGate` per area); the banner says why.
            destination(for: id).managedPartlyLocked(organization)
        }
    }

    /// The hero card's glasses status, from the link's phase.
    private var glassesStatus: String {
        if appState.glassesPaused { return "Connected · paused" }
        switch appState.glassesPhase {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .noGlassesAdded, .addedDisconnected: return "Not connected"
        }
    }

    /// The live value summary beside a category row, where one is worth showing.
    private func summary(for id: SettingsCategoryID) -> String? {
        switch id {
        case .voice: return "“\(displayedWakePhrase)”"
        case .intelligence: return displayedActiveModelName
        case .devices:
            if appState.glassesPaused { return "Paused" }
            switch appState.glassesPhase {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .noGlassesAdded, .addedDisconnected: return nil
            }
        case .fieldAssist: return fieldAssistEnabled ? "On" : nil
        case .lookAndFeel: return appearance.capitalized
        case .accessibility: return Config.accessibilityModeEnabled ? "On" : nil
        case .display: return glassesDisplayEnabled ? "On" : nil
        case .advanced: return "Test panel"
        case .tools, .connections, .capture, .diagnostics: return nil
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
        case .devices:
            GlassesPrivacySettingsScreen(appState: appState)
        case .accessibility:
            AccessibilitySettingsView().environmentObject(appState)
        case .fieldAssist:
            FieldAssistSettingsView().environmentObject(appState)
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

    private var displayedWakePhrase: String {
        let phrase = wakePhrase.isEmpty ? Config.wakePhrase : wakePhrase
        return phrase.capitalized
    }

    private var displayedActiveModelName: String? {
        Config.savedModels.first { $0.id == activeModelId }?.name ?? Config.activeModel?.name
    }

    // MARK: - Category Row

    /// A hub row wrapped in a plain-styled NavigationLink — outside a List,
    /// the link adds no chrome of its own, so `OGRow` supplies the chevron.
    private func categoryLink<D: View, L: View>(
        destination: D, @ViewBuilder label: () -> L
    ) -> some View {
        NavigationLink { destination } label: { label() }
            .buttonStyle(.plain)
    }

    // MARK: - Owner gate (BM P10)

    private var settingsLockCover: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: lockGlyphSize))
                    .foregroundStyle(.secondary)
                Text("Settings are locked")
                    .font(.headline)
                if entryGate.lastFailed {
                    Text("Authentication failed. Try again.")
                        .font(.caption)
                        .foregroundStyle(OGTheme.errorLabel)
                }
                Button {
                    authenticateSettingsEntry()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func authenticateSettingsEntry() {
        guard entryGate.begin() else { return }
        OwnerGateAuth.authenticate(reason: "Unlock Avenkin Settings") { granted in
            entryGate.finish(success: granted)
            if entryGate.consume() {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { settingsLocked = false }
            }
        }
    }

    /// Simple-Mode toggle path: turning it ON is immediate; turning it OFF (re-exposing the owner
    /// surface, incl. decrypted API-key fields) needs a fresh device-owner grant every time.
    private func requestSimpleModeChange(to newValue: Bool) {
        guard OwnerGatePolicy.requiresGate(togglingSimpleModeTo: newValue, currentlyEnabled: simpleModeEnabled) else {
            simpleModeEnabled = newValue
            Config.simpleModeEnabled = newValue
            return
        }
        guard exitGate.begin() else { return }
        OwnerGateAuth.authenticate(reason: "Verify it's you to leave Simple Mode") { granted in
            exitGate.finish(success: granted)
            if exitGate.consume() {
                simpleModeEnabled = false
                Config.simpleModeEnabled = false
            }
        }
    }

    // MARK: - Voice Isolation

    /// Shows Apple's system Voice Isolation / Mic Modes picker.
    /// Enables noise cancellation for use in noisy environments.
    private func showVoiceIsolationPicker() {
        #if !targetEnvironment(simulator)
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        #endif
    }

    // MARK: - About

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}

// MARK: - Tier Model Picker

/// Lets the user assign a specific model to a complexity tier for smart routing.
struct TierModelPicker: View {
    let tier: Config.ModelTier
    let models: [ModelConfig]

    @State private var selectedModelId: String

    init(tier: Config.ModelTier, models: [ModelConfig]) {
        self.tier = tier
        self.models = models
        _selectedModelId = State(initialValue: Config.modelIdForTier(tier) ?? "")
    }

    private var selectedModelName: String {
        if selectedModelId.isEmpty { return "Auto" }
        guard let model = models.first(where: { $0.id == selectedModelId }) else { return "Auto" }
        return model.model.isEmpty ? model.name : model.model
    }

    var body: some View {
        NavigationLink {
            TierModelDetailPicker(
                tier: tier,
                models: models,
                selectedModelId: $selectedModelId
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tier.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.displayName)
                    Text(tier.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectedModelName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onChange(of: selectedModelId) { _, newValue in
            Config.setModelForTier(tier, modelId: newValue.isEmpty ? nil : newValue)
        }
    }
}

/// Detail picker for selecting a specific model for a routing tier.
/// Groups saved models by provider and fetches all available models from each provider's API.
struct TierModelDetailPicker: View {
    let tier: Config.ModelTier
    let models: [ModelConfig]
    @Binding var selectedModelId: String

    /// Unique providers from saved models (all providers, not just those with API keys).
    private var providers: [(config: ModelConfig, provider: LLMProvider)] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard seen.insert(model.provider).inserted else { return nil }
            return (config: model, provider: model.llmProvider)
        }.sorted { $0.provider.displayName < $1.provider.displayName }
    }

    /// The currently selected model ID — could be a saved ModelConfig.id or a "provider:modelId" composite.
    private var currentSelection: String {
        if selectedModelId.isEmpty { return "" }
        // Check if it's a saved model
        if let model = models.first(where: { $0.id == selectedModelId }) {
            return model.model
        }
        // It's a provider:modelId composite — extract the model part
        if let range = selectedModelId.range(of: "::") {
            return String(selectedModelId[range.upperBound...])
        }
        return selectedModelId
    }

    var body: some View {
        List {
            Section {
                selectionRow(label: "Auto-detect", isSelected: selectedModelId.isEmpty) {
                    selectedModelId = ""
                }
            } footer: {
                Text("Automatically selects the best available model for \(tier.displayName.lowercased()) requests.")
            }

            ForEach(providers, id: \.provider) { entry in
                TierProviderSection(
                    config: entry.config,
                    provider: entry.provider,
                    selectedModelId: $selectedModelId
                )
            }
        }
        .navigationTitle(tier.displayName)
    }

    private func selectionRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(OGTheme.okLabel)
                }
            }
        }
        .foregroundStyle(Color(.label))
    }
}

/// A section within the tier picker showing all available models for one provider.
private struct TierProviderSection: View {
    let config: ModelConfig
    let provider: LLMProvider
    @Binding var selectedModelId: String

    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var isFetching = false
    @State private var hasFetched = false

    /// Always read live from Config so newly created models are visible.
    private var allModels: [ModelConfig] { Config.savedModels }

    var body: some View {
        Section {
            if isFetching {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models…")
                        .foregroundStyle(.secondary)
                }
            } else if availableModels.isEmpty && hasFetched {
                // Fallback: show the saved model(s) for this provider
                ForEach(allModels.filter({ $0.provider == provider.rawValue })) { model in
                    modelRow(id: model.model, name: model.model, configId: model.id)
                }
            } else {
                ForEach(availableModels) { remote in
                    modelRow(id: remote.id, name: remote.name, configId: nil)
                }
            }
        } header: {
            Text(provider.displayName)
        }
        .task {
            guard !hasFetched else { return }
            isFetching = true
            availableModels = await ModelFetcher.fetchModels(
                provider: provider,
                apiKey: config.apiKey,
                baseURL: config.baseURL
            )
            hasFetched = true
            isFetching = false
        }
    }

    /// Check if a given model ID is currently selected for this provider.
    private func isSelected(_ modelId: String, configId: String?) -> Bool {
        // Direct match on saved model config ID
        if let cid = configId, selectedModelId == cid { return true }
        // Match on composite key
        if selectedModelId == "\(provider.rawValue)::\(modelId)" { return true }
        // Match if a saved model with this model ID is selected
        if let selected = allModels.first(where: { $0.id == selectedModelId }),
           selected.model == modelId { return true }
        return false
    }

    private func modelRow(id: String, name: String, configId: String?) -> some View {
        Button {
            // Prefer selecting via saved ModelConfig if one exists with this model ID
            if let existing = allModels.first(where: { $0.provider == provider.rawValue && $0.model == id }) {
                selectedModelId = existing.id
            } else {
                // Create or update a ModelConfig for this provider+model and select it
                selectRemoteModel(id: id, name: name)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .lineLimit(1)
                    if name != id {
                        Text(id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected(id, configId: configId) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(OGTheme.okLabel)
                }
            }
        }
        .foregroundStyle(Color(.label))
    }

    /// When user picks a model that doesn't have a saved ModelConfig, create one
    /// using the same API key and base URL from the existing config for this provider.
    private func selectRemoteModel(id: String, name: String) {
        let newConfig = ModelConfig(
            id: UUID().uuidString,
            name: "\(provider.displayName) — \(name)",
            provider: provider.rawValue,
            apiKey: config.apiKey,
            model: id,
            baseURL: config.baseURL
        )
        var saved = Config.savedModels
        saved.append(newConfig)
        Config.setSavedModels(saved)
        selectedModelId = newConfig.id
    }
}

// MARK: - Smart Routing Sub-View

struct SmartRoutingView: View {
    @Binding var autoModelRoutingEnabled: Bool
    let modelConfigs: [ModelConfig]

    var body: some View {
        Form {
            Section {
                InfoToggle(
                    title: "Auto Model Routing",
                    isOn: $autoModelRoutingEnabled,
                    info: "Automatically classifies each request by complexity and routes it to the right model. Simple queries like \"what time is it\" use a fast, cheap model. Complex reasoning uses your best model. Saves cost without sacrificing quality. Assign models to each tier below."
                )
                .onChange(of: autoModelRoutingEnabled) { _, newValue in
                    Config.setAutoModelRoutingEnabled(newValue)
                }
            } footer: {
                Text(autoModelRoutingEnabled
                     ? "Requests are classified by complexity and routed to the assigned model. Memory and conversation context are always preserved."
                     : "When enabled, simple requests use a faster model while complex questions use your best model."
                )
            }

            if autoModelRoutingEnabled {
                Section {
                    ForEach(Config.ModelTier.allCases) { tier in
                        TierModelPicker(tier: tier, models: modelConfigs)
                    }
                } header: {
                    Text("Tier Assignments")
                } footer: {
                    Text("Assign any model to each tier. Simple queries use Fast, most use Balanced, complex reasoning uses Best.")
                }
            }

            Section {
                InfoToggle(
                    title: "Model Fallback",
                    isOn: Binding(
                        get: { Config.modelCascadeEnabled },
                        set: { Config.setModelCascadeEnabled($0) }
                    ),
                    info: "If a model can't handle a request — the prompt is too long, it's rate-limited, or it returns nothing — the assistant automatically tries the next model instead of failing. It prefers your active (often on-device) model and only falls over to cloud when needed."
                )
                InfoToggle(
                    title: "Narrate Model Switches",
                    isOn: Binding(
                        get: { Config.narrateModelSwitchesEnabled },
                        set: { Config.setNarrateModelSwitchesEnabled($0) }
                    ),
                    info: "Speaks a short notice when the assistant changes models mid-request (for example, \"That's a bit much for the on-device model — switching to Claude\"), so you know the model — and its cost — changed. Turn off for silent switching."
                )
            } header: {
                Text("Fallback")
            } footer: {
                Text("Fallback keeps a turn alive across model limits; narration keeps you informed when it happens.")
            }
        }
        .navigationTitle("Smart Routing")
    }
}

// MARK: - Hardware & Privacy Sub-View

struct HardwarePrivacyView: View {
    @ObservedObject var appState: AppState
    @Binding var micRoute: MicRoute
    @Binding var privacyFilterEnabled: Bool
    @Binding var conversationEncryptionEnabled: Bool
    /// W03.3 — how long the wearer's own conversations and memories are kept. Zero means forever
    /// and is the default; see `Config.historyRetentionDays`.
    @State private var historyRetentionDays = Config.historyRetentionDays
    @Binding var isTogglingEncryption: Bool
    @State private var showEncryptionInfo = false
    @AppStorage("displayBackend") private var displayBackendRaw = DisplayBackendChoice.metaRayBan.rawValue
    @AppStorage("hudMirrorEnabled") private var hudMirrorEnabled = false

    private var displayedDisplayBackendName: String {
        DisplayBackendChoice(rawValue: displayBackendRaw)?.displayName ?? Config.displayBackend.displayName
    }

    var body: some View {
        Form {
            // Plan CL P3: unified capture route. Headset mode exists because the
            // glasses' hands-free mic link makes Display glasses put their call
            // screen over the lens HUD — earbuds carry mic + voice, lens stays free.
            Section {
                Picker("Microphone", selection: $micRoute) {
                    ForEach(MicRoute.allCases) { route in
                        Text(route.label).tag(route)
                    }
                }
            } footer: {
                Text("Where you are heard once the conversation starts, and where its replies play. Glasses Mic is truly hands-free; while it is open, other audio on the glasses drops to call quality, and on Display glasses the call screen covers the lens HUD. Headset Mic keeps voice in your earbuds while the lens keeps the HUD; it never falls back to the glasses mic. iPhone Mic never uses a Bluetooth mic. Where the app waits for the wake word is set separately, under Devices & Privacy › Glasses.")
            }

            Section {
                InfoToggle(
                    title: "Audio-Only Mode",
                    isOn: Binding(
                        get: { Config.audioOnlyMode },
                        set: { Config.setAudioOnlyMode($0) }
                    ),
                    info: "Disables camera video streaming from the glasses. Voice commands still work but vision features (photo capture, live video analysis) are unavailable. Significantly extends glasses battery life."
                )
                InfoToggle(
                    title: "Glasses Display (HUD)",
                    isOn: Binding(
                        get: { Config.glassesDisplayEnabled },
                        set: { newValue in
                            Config.setGlassesDisplayEnabled(newValue)
                            if !newValue {
                                Task { await appState.glassesDisplay.shutdown() }
                            }
                        }
                    ),
                    info: "Shows AI responses, live captions, notifications and turn-by-turn guidance on the in-lens display, and runs interactive task cards you complete hands-free with the Neural Band or voice (\"next\", \"done\", \"skip\", \"back\"). Ray-Ban Display glasses only — no effect on glasses without a built-in display."
                )
                InfoToggle(
                    title: "HUD Choice Buttons",
                    isOn: Binding(
                        get: { Config.hudChoiceButtonsEnabled },
                        set: { Config.setHudChoiceButtonsEnabled($0) }
                    ),
                    info: "When a reply lays out explicit options (\"A) the fast route, B) the scenic route\"), they appear as selectable buttons on the in-lens display — pick one with the Neural Band instead of re-speaking it. Detection is deliberately conservative: plain numbered steps never become buttons."
                )
                InfoToggle(
                    title: "Dwell Capture",
                    isOn: Binding(
                        get: { Config.dwellCaptureEnabled },
                        set: { newValue in
                            Config.setDwellCaptureEnabled(newValue)
                            if !newValue { appState.dwellCapture.stop() }
                            else {
                                appState.dwellCapture.start(cameraService: appState.cameraService,
                                                            privacyFilter: appState.privacyFilter)
                            }
                        }
                    ),
                    info: "Hold your gaze on an object for about two seconds and it's captured to Photos automatically — hands-free, no wake word. Uses on-device object detection while the camera streams; off by default because the detection loop uses extra battery."
                )
                NavigationLink {
                    TempleTapSettingsView(appState: appState)
                } label: {
                    HStack {
                        Label("Temple Taps", systemImage: "hand.tap")
                        Spacer()
                        Text(Config.mediaTriggerEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    HUDMirrorView(router: appState.hudRouter)
                } label: {
                    Label("HUD Mirror (phone preview)", systemImage: "eyeglasses")
                }
                NavigationLink {
                    EvenDisplaySettingsView()
                } label: {
                    HStack {
                        Label("Display Backend", systemImage: "display")
                        Spacer()
                        Text(displayedDisplayBackendName)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    WebHUDMirrorSettingsView()
                } label: {
                    HStack {
                        Label("Web HUD Mirror", systemImage: "globe.desk")
                        Spacer()
                        Text(LocalServiceExposurePolicy.current.permitsListener(for: .webHUDMirror)
                             ? (hudMirrorEnabled ? "On" : "Off") : "Unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    TeleprompterSettingsView(service: appState.teleprompterService,
                                             store: appState.teleprompterStore)
                } label: {
                    HStack {
                        Label("Teleprompter", systemImage: "text.alignleft")
                        Spacer()
                        if appState.teleprompterService.isActive {
                            Text("Running").foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    InsightsView().environmentObject(appState)
                } label: {
                    Label("Insights", systemImage: "chart.bar")
                }
                NavigationLink {
                    MemoryView(model: appState.memoryFacts.makeScreenModel())
                } label: {
                    Label("Memory", systemImage: "brain.head.profile")
                }
                InfoToggle(
                    title: "Use Phone Mic for Translation",
                    isOn: Binding(
                        get: { Config.usePhoneMicForTranslation },
                        set: { Config.setUsePhoneMicForTranslation($0) }
                    ),
                    info: "Uses the phone's microphone instead of the glasses mic for live translation. Useful when holding the phone near the person speaking a foreign language, or when the glasses mic has too much background noise."
                )
                InfoToggle(
                    title: "Glasses Only Audio",
                    isOn: Binding(
                        get: { Config.glassesOnlyAudio },
                        set: { Config.setGlassesOnlyAudio($0) }
                    ),
                    info: "When on, the agent and notification sounds are silent if your glasses aren't connected. When off (default), audio plays through the phone speaker even without glasses."
                )
                Button {
                    #if !targetEnvironment(simulator)
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                    #endif
                } label: {
                    Label("Voice Isolation Mode", systemImage: "waveform.badge.mic")
                }
            } header: {
                Text("Hardware")
            } footer: {
                Text("Where the mic listens and how audio is routed. Tap any \(Image(systemName: "info.circle")) for a full explanation. Glasses mic uses more battery but is truly hands-free.")
            }

            Section {
                NavigationLink {
                    RecordingsView(
                        store: appState.recordedSessionStore,
                        controller: appState.sessionRecorder,
                        audioRecorder: appState.audioRecorder
                    )
                } label: {
                    HStack {
                        Label("Recordings", systemImage: "waveform")
                        Spacer()
                        if appState.sessionRecorder.isRecording {
                            OGStatusLabel("Recording", kind: .error, systemImage: "record.circle")
                        }
                    }
                }
                NavigationLink {
                    MeetingRecordsView()
                } label: {
                    Label("Meeting Records", systemImage: "text.book.closed")
                }
            } header: {
                Text("Recordings")
            } footer: {
                Text("Preserved meeting recordings with playback and transcripts, and summaries saved by the Meeting Summary tool.")
            }

            Section {
                InfoToggle(
                    title: "Blur Bystander Faces",
                    isOn: $privacyFilterEnabled,
                    info: "Uses Apple's on-device Vision framework to detect faces in the camera feed and applies a Gaussian blur before a frame leaves your device — AI providers, video recordings, live broadcasts, browser streaming, and expert calls. Detection and blurring happen entirely on-device. On video, faces are found several times a second and the blur follows them in between, so someone stepping into shot can be briefly visible before the next detection catches them. Faces you have enrolled for recognition are matched on the unblurred frame, so recognition keeps working."
                )
                .disabled(PolicyEnvelope.isLocked(.privacyFilterEnabled))
                ManagedSettingNote(key: .privacyFilterEnabled)
                // Apple Health: what is read, whether the AI may see it (the share toggle lives
                // there now), and the summary kept for locked-phone answers.
                NavigationLink {
                    HealthSettingsView()
                } label: {
                    Label("Health", systemImage: "heart.text.square")
                }
                InfoStatusRow(
                    title: "Glasses Analytics",
                    status: MetaTelemetryBlock.disclosureState.summary,
                    info: "Avenkin has no analytics or crash-reporting service of its own: no developer backend, no account, so the app never sends us usage data or crash reports. Apple can, in TestFlight builds or if you turn on Share with App Developers in iOS. The glasses SDK does collect its own — connection sessions, camera streams, permission checks, crashes — and uploads them to Meta. This app opts out and additionally blocks those uploads from leaving your phone; there is nothing to turn on. This row says Off when nothing has ever had to be stopped, and Blocked if an upload was attempted anyway — the self-test in Diagnostics & Support shows how many. Pairing still contacts Meta once to verify the app is allowed to talk to your glasses, which is what makes the connection work and carries no usage data."
                )
            } header: {
                Text("Privacy")
            } footer: {
                Text("Bystander Face Blur runs entirely on-device: faces are found and blurred on your phone, and the blurred frame is what an AI provider, recording, broadcast or expert call receives. Share Health Data with AI (under Health) is off by default: Apple Health numbers are sent to your AI provider only when you turn it on. Avenkin has no analytics or crash reporting of its own (Apple may share crash reports with us from TestFlight, or if you allow it in iOS), and the glasses SDK's own analytics are opted out and blocked on this phone.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { conversationEncryptionEnabled },
                    set: { newValue in
                        guard !isTogglingEncryption else { return }
                        isTogglingEncryption = true
                        Task {
                            if newValue {
                                let success = await appState.conversationStore.enableEncryption()
                                await MainActor.run { conversationEncryptionEnabled = success }
                            } else {
                                let success = await appState.conversationStore.disableEncryption()
                                await MainActor.run { conversationEncryptionEnabled = !success }
                            }
                            await MainActor.run { isTogglingEncryption = false }
                        }
                    }
                )) {
                    HStack(spacing: 6) {
                        Text("Encrypt Conversations")
                        Button { showEncryptionInfo = true } label: {
                            Image(systemName: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        // Unlabelled, this read as "info circle" — the same three words on every
                        // one of these rows, which tells the user nothing about which explanation
                        // they are about to open.
                        .accessibilityLabel("About encrypting conversations")
                        if isTogglingEncryption {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(isTogglingEncryption)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks saved conversation transcripts behind Face ID / passcode. The key lives in the Secure Enclave and never leaves your device.")
            }
            .alert("Encrypt Conversations", isPresented: $showEncryptionInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Encrypts all saved conversation transcripts using ChaCha20-Poly1305 authenticated encryption. The encryption key is stored in the Secure Enclave via Keychain and requires Face ID, Touch ID, or your device passcode to unlock. Conversations are automatically locked when the app moves to the background.")
            }

            Section {
                Picker("Keep History For", selection: Binding(
                    get: { historyRetentionDays },
                    set: { newValue in
                        historyRetentionDays = newValue
                        Config.historyRetentionDays = newValue
                    }
                )) {
                    Text("Forever").tag(0)
                    Text("30 Days").tag(30)
                    Text("90 Days").tag(90)
                    Text("6 Months").tag(180)
                    Text("1 Year").tag(365)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Applies to saved conversations and the things you asked to be remembered. Kept forever unless you choose otherwise — this is your own record, and the app will not decide to delete it for you. Anything older than the period you pick is deleted for real, not hidden, next time the app opens or comes back to the foreground. Memories you gave an expiry to are removed when that expiry passes, whatever this is set to.")
            }
        }
        .navigationTitle("Hardware & Privacy")
    }
}

// MARK: - Glasses Sub-View

/// Devices & Privacy › Glasses (Plan HA C3): the settings that belong to the glasses themselves —
/// where the wake word waits, how replies play, sleep, and the glasses-side updates. Reachable
/// whether or not the glasses are attached, and open on an organisation's locked phone, where a
/// technician still has to get the glasses working.
struct GlassesSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var glassesUpdateError: String?
    // Plan GU — where the wake word waits, and how replies play.
    @State private var wakeListenMic = Config.wakeListenMic
    @State private var replyAudioMode = Config.replyAudioMode
    @State private var replySwitchTimeLimit = Config.replySwitchTimeLimit

    /// Deep-link to the glasses-side DAT app update flow. Failure is reported rather than
    /// swallowed: the whole point is that the user could not find this screen on their own, so a
    /// button that silently does nothing is worse than the copy it replaced.
    @MainActor
    private func openGlassesAppUpdate() async {
        glassesUpdateError = nil
        guard WearablesBootstrap.ensureConfigured() else {
            glassesUpdateError = "Meta SDK unavailable — connect the glasses first."
            return
        }
        do { try await Wearables.shared.openDATGlassesAppUpdate() }
        catch { glassesUpdateError = "Couldn't open the update screen: \(error.localizedDescription)" }
    }

    @MainActor
    private func openGlassesFirmwareUpdate() async {
        glassesUpdateError = nil
        guard WearablesBootstrap.ensureConfigured() else {
            glassesUpdateError = "Meta SDK unavailable — connect the glasses first."
            return
        }
        do { try await Wearables.shared.openFirmwareUpdate() }
        catch { glassesUpdateError = "Couldn't open the firmware screen: \(error.localizedDescription)" }
    }

    /// Plan CQ P0: what class of device is connected, resolved from the three things that
    /// actually determine it. Re-read on each render — this view is cheap and the answer
    /// changes when glasses connect or drop.
    private var connectedTier: GlassesTier? {
        GlassesTierPolicy.resolve(
            cameraCapabilities: appState.cameraService.activeCapabilities,
            displayBackendActive: appState.glassesDisplay.isDisplayActive,
            audioPortNames: (AVAudioSession.sharedInstance().availableInputs ?? []).map(\.portName)
        )
    }

    /// What the chosen "Reply audio" means, in the wearer's terms.
    private var replyAudioFootnote: String {
        switch replyAudioMode {
        case .callQuality:
            return "Replies play over the glasses' call link, so you can always interrupt by speaking or saying stop."
        case .fullQuality:
            return "Replies play in full quality. To interrupt one, speak towards your iPhone — the glasses' mic is off while it plays. Each follow-up waits a moment longer while the glasses switch back."
        case .automatic:
            return "Full quality when your glasses switch fast enough, measured on these glasses; otherwise call quality. Until the switch has been measured, replies use call quality."
        }
    }

    var body: some View {
        Form {
            // Plan CQ P0: "which glasses work with OpenGlasses?" stopped being a product name.
            // Any glasses that pair as a Bluetooth headset already run the whole voice loop, so
            // say what the connected pair CAN do rather than letting the user find the limits
            // one failed feature at a time.
            Section {
                // Plan GU: first in the glasses section, so it can be flipped per situation —
                // phone in a bag → the glasses.
                Picker("Listen for the wake word on", selection: $wakeListenMic) {
                    ForEach(WakeListenMic.allCases) { mic in
                        Text(mic.label).tag(mic)
                    }
                }
                .onChange(of: wakeListenMic) { _, newValue in
                    Config.setWakeListenMic(newValue)
                    appState.restartWakeWordIfDirect()
                }
                Text("iPhone keeps music and podcasts on your glasses in full quality and saves their battery. Choose Same as Microphone if your phone is usually in a bag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Reply audio", selection: $replyAudioMode) {
                    ForEach(ReplyAudioMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: replyAudioMode) { _, newValue in
                    Config.setReplyAudioMode(newValue)
                }
                if replyAudioMode == .automatic {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Switch time limit")
                            Spacer()
                            Text(String(format: "%.1f s", replySwitchTimeLimit))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $replySwitchTimeLimit,
                               in: ReplyRoutePolicy.thresholdRange, step: 0.1)
                            .accessibilityLabel("Switch time limit")
                            .accessibilityValue(String(format: "%.1f seconds", replySwitchTimeLimit))
                            .onChange(of: replySwitchTimeLimit) { _, newValue in
                                Config.setReplySwitchTimeLimit(newValue)
                            }
                    }
                }
                Text(replyAudioFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let tier = connectedTier {
                    LabeledContent("Device class", value: tier.label)
                    Text(tier.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent(
                        "Camera",
                        value: CameraFeatureGate.summary(given: appState.cameraService.capabilities)
                    )
                    let blocked = CameraFeatureGate.unavailableFeatures(
                        given: appState.cameraService.activeCapabilities ?? .unavailable
                    )
                    if !blocked.isEmpty {
                        Text("Unavailable on these glasses: "
                             + blocked.map(\.displayName).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No glasses detected. Pair them in iOS Settings — any glasses that "
                         + "connect as a Bluetooth headset can run the voice features.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Device-traced 2026-08-23: streaming was refused with
                // `datAppOnTheGlassesUpdateRequired`, and our copy said "install the pending
                // update" — but Meta AI's update screen showed none, because the glasses-side DAT
                // app is not the same artefact as the firmware or the phone app. The SDK has
                // deep links straight to both flows; we were telling people to go looking instead
                // of taking them there.
                InfoToggle(
                    title: "Sleep When Quiet, Even While Worn",
                    isOn: Binding(
                        get: { Config.sleepWhenQuietWhileWorn },
                        set: { Config.sleepWhenQuietWhileWorn = $0 }
                    ),
                    info: "Only while the wake word listens on the glasses' own mic (Listen for the wake word on: Same as Microphone, with Glasses Mic) — that is what keeps their mic open. Listening on the iPhone holds nothing open on the glasses, so they never sleep and the wake word keeps listening on the phone when you take them off. Glasses you take off sleep after 30 seconds and wake when you put them back on. Glasses you're wearing stay awake however quiet it gets, unless this is on: then they also sleep after \(Config.autoSleepMinutes) minutes of silence, and wake when you take them off and put them on again, or tap to talk. Glasses that can't tell whether they're worn always sleep after that much silence. With push-to-talk, or listening off, nothing is held open and the glasses never sleep."
                )
                Button("Update Glasses App") { Task { await openGlassesAppUpdate() } }
                Button("Update Glasses Firmware") { Task { await openGlassesFirmwareUpdate() } }
                if let glassesUpdateError {
                    Text(glassesUpdateError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connected Glasses")
            } footer: {
                Text("The glasses run their own companion app for developer access, updated separately from the firmware and from the Meta AI app on your phone. If streaming is refused as needing an update, this is usually the one to open.")
            }

        }
        .navigationTitle("Glasses")
    }
}

// MARK: - Info Status Row

/// A read-only counterpart to ``InfoToggle``: states a privacy fact and explains it, with
/// nothing for the user to switch. For guarantees that are compiled in rather than configured —
/// presenting one as a toggle would imply an "on" state the app does not offer.
struct InfoStatusRow: View {
    /// Title and info are written at the call site, so they are
    /// `LocalizedStringKey`s and reach the string catalog; the status is a
    /// runtime summary and stays a `String`.
    let title: LocalizedStringKey
    let status: String
    let info: LocalizedStringKey

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("About \(Text(title))"))
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
        }
        .alert(title, isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(info)
        }
    }
}

// MARK: - Info Toggle

/// A toggle with an info button that shows an explanation popover.
struct InfoToggle: View {
    let title: String
    @Binding var isOn: Bool
    let info: String

    @State private var showInfo = false

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title)
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(title)")
            }
        }
        .alert(title, isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(info)
        }
    }
}
