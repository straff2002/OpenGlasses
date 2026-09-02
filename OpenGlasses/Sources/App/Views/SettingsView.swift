import SwiftUI
import AVFoundation
import MWDATCore

struct SettingsView: View {
    @ObservedObject var appState: AppState
    /// The journey state (Plan DE): which categories are unfolded, and which
    /// Discover card — if any — is currently being suggested. Visibility only:
    /// nothing here gates a capability or changes a setting.
    @ObservedObject private var journey = SettingsJourneyStore.shared
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The locked-settings lock glyph is decorative and drawn well past body size — scale it
    /// with Dynamic Type rather than pinning it to a literal point size.
    @ScaledMetric(relativeTo: .largeTitle) private var lockGlyphSize: CGFloat = 44

    @State private var simpleModeEnabled = Config.simpleModeEnabled
    @AppStorage("appAppearance") private var appearance: String = "system"
    @AppStorage("wakePhrase") private var wakePhrase = "openglasses"
    @AppStorage("activeModelId") private var activeModelId = ""
    @AppStorage("glassesDisplayEnabled") private var glassesDisplayEnabled = false

    // Owner gate (BM P10): Simple-Mode exit always asks; Settings entry asks when the flag is on.
    @State private var settingsOwnerGateEnabled = Config.settingsOwnerGateEnabled
    @State private var settingsLocked = Config.settingsOwnerGateEnabled
    @State private var exitGate = OwnerGateMachine()
    @State private var entryGate = OwnerGateMachine()

    // The individual settings sections live in per-category screens (SettingsScreens.swift
    // and SettingsJourneyScreens.swift); this view is the hub: the categories the user
    // has, the ones they haven't met yet, plus the always-visible Simple Mode and About
    // sections.
    //
    // Which categories are rows and which are Discover cards is decided entirely by
    // `CapabilityCatalog` + `SettingsJourneyState` (Plan DE) — folded is never locked,
    // there is no gate of any kind, and the accessibility surface is structurally
    // incapable of being folded away. Simple Mode is orthogonal and untouched: it hides
    // the owner-only configuration surface for handing the device to someone else, and
    // unfolding a card never changes what it hides.

    private var visibleCategories: [CapabilityCategory] {
        journey.state.visibleCategories(simpleMode: simpleModeEnabled)
    }

    private var discoverCards: [CapabilityCategory] {
        journey.state.discoverCards(simpleMode: simpleModeEnabled)
    }

    var body: some View {
        // The hub is an OGDesign page (Plan CL): hero device card, then one
        // grouped card of category rows, each with a live value summary, then the
        // Discover section for everything still folded.
        OGScrollPage {
            OGHeroDeviceCard(
                title: appState.glassesService.deviceName ?? "Meta Glasses",
                status: appState.isConnected ? "Connected" : "Not connected",
                dot: appState.isConnected ? OGTheme.ok : Color.secondary,
                batteryPercent: appState.glassesService.batteryLevel,
                chips: [
                    ("Camera", appState.isConnected),
                    ("Display", appState.glassesDisplay.hasDisplayCapability),
                    ("HUD \(glassesDisplayEnabled ? "on" : "off")", glassesDisplayEnabled),
                ]
            )

            OGSection {
                ForEach(Array(visibleCategories.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { OGDivider() }
                    categoryLink(destination: destination(for: category)) {
                        OGRow(
                            category.title,
                            icon: category.icon,
                            mutedIcon: category.mutedIcon,
                            subtitle: category.subtitle,
                            value: summary(for: category),
                            alwaysStacksValue: true
                        )
                    }
                }
            }

            discoverSection

            // MARK: Simple Mode (always visible so the owner can leave it — behind the owner gate)
            OGSection(footer: "Simple Mode hides model, persona, behavior, tool, integration, and advanced settings — for handing the device to someone who just needs it to work. Leaving it asks for Face ID or your passcode. Lock Settings asks every time Settings opens.") {
                OGRow(
                    "Simple Mode",
                    isOn: Binding(
                        get: { simpleModeEnabled },
                        set: { requestSimpleModeChange(to: $0) }
                    ),
                    icon: "dial.low"
                )
                OGDivider()
                OGRow("Lock Settings", isOn: $settingsOwnerGateEnabled, icon: "faceid")
                    .onChange(of: settingsOwnerGateEnabled) { _, v in Config.settingsOwnerGateEnabled = v }
                if exitGate.lastFailed {
                    OGDivider()
                    OGStatusLabel("Couldn't verify it's you — Simple Mode stays on.", kind: .error)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }

            OGSection(
                header: "About",
                footer: "OpenGlasses © 2026 Skunkworks NZ Ltd. All rights reserved. Free for personal, non-commercial use — commercial use requires a licence.\n\nJoin the Discord for help, ideas, and to share what you've built."
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
                    let webURL = URL(string: "https://discord.gg/8W2qaXJzz9")!
                    UIApplication.shared.open(webURL)
                } label: {
                    OGRow("Discord", icon: "bubble.left.and.bubble.right", showsChevron: false) {
                        HStack(spacing: 4) {
                            Text("OpenGlasses Discord")
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
            // One of the four unlock moments is answerable from the hub itself:
            // whether the connected glasses have a display. No service needs to
            // report it, and the policy still spends the moment exactly once.
            if appState.glassesDisplay.hasDisplayCapability {
                journey.record(.displayGlassesConnected)
            }
        }
        // The unlock moment is a highlight that *arrives* — a card further down the page grows a
        // coral border and a sentence, sometimes while the user is already reading elsewhere on
        // this screen. Unfolding it was announced from the start; the moment it appeared was not,
        // which made the one thing the whole mechanism exists for the one thing a VoiceOver user
        // could only find by accident. Keyed off the pending set, so it says its piece exactly
        // once per moment — the store's `deliveredMoments` guard means a moment cannot re-enter.
        .onChange(of: journey.state.pendingMoments) { old, new in
            announceNewSuggestions(added: new.subtracting(old))
        }
    }

    /// Say what just lit up in Discover, and that it can be waved away.
    private func announceNewSuggestions(added: Set<String>) {
        guard !added.isEmpty else { return }
        let lines = discoverCards.compactMap { category -> String? in
            guard let suggestion = journey.pendingSuggestion(forCategory: category.id),
                  added.contains(suggestion.moment.rawValue) else { return nil }
            // The notes are written as display copy and don't all end in a full stop — spoken,
            // that runs the pitch straight into the next sentence.
            let note = suggestion.note.hasSuffix(".") ? suggestion.note : suggestion.note + "."
            return "\(category.title). \(note)"
        }
        guard let first = lines.first else { return }
        SessionAnnouncer.say("New in Discover: \(first) Dismiss it from the card.")
    }

    // MARK: - Discover (Plan DE)

    /// Folded capabilities, pitched rather than listed, plus the one switch that
    /// opens the lot. Absent entirely once there is nothing left to discover.
    @ViewBuilder
    private var discoverSection: some View {
        if !discoverCards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("DISCOVER")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .accessibilityLabel("Discover")
                    .accessibilityAddTraits(.isHeader)

                ForEach(discoverCards) { category in
                    let suggestion = journey.pendingSuggestion(forCategory: category.id)
                    OGDiscoverCard(
                        title: category.title,
                        pitch: category.pitch,
                        icon: category.icon,
                        suggestion: suggestion?.note,
                        unfold: { unfold(category) },
                        dismissSuggestion: suggestion.map { s in { journey.dismiss(s.moment) } }
                    )
                }

                Text("Tap one to add it to Settings for good. Nothing here is locked — this only decides what the list shows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }
        }

        if !discoverCards.isEmpty || journey.state.showsEverything {
            OGSection(
                footer: "Shows every category at once, including the ones you haven't opened yet."
            ) {
                OGRow(
                    "Show everything",
                    isOn: Binding(
                        get: { journey.state.showsEverything },
                        set: { on in
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                journey.setShowsEverything(on)
                            }
                        }
                    ),
                    icon: "square.grid.2x2"
                )
            }
        }
    }

    /// One tap, permanent, no gate. The announcement matters because the change
    /// is a card *becoming* a row further up the page — a sighted user sees the
    /// list grow, and VoiceOver otherwise would not.
    ///
    /// It says *where*, not just *what*: the card the user was standing on disappears in the
    /// same beat, so "added to Settings" left them holding a focus that no longer exists with no
    /// idea which direction the row went.
    private func unfold(_ category: CapabilityCategory) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            journey.unfold(category.id)
        }
        AccessibilityNotification
            .Announcement("\(category.title) added to the Settings list above.")
            .post()
    }

    // MARK: - Category rendering

    /// The live value summary beside a category row, where one is worth showing.
    private func summary(for category: CapabilityCategory) -> String? {
        switch category.id {
        case CapabilityCatalog.voice: return "“\(displayedWakePhrase)”"
        case CapabilityCatalog.intelligence: return displayedActiveModelName
        case CapabilityCatalog.glasses: return appState.isConnected ? "Connected" : nil
        case CapabilityCatalog.lookAndFeel: return appearance.capitalized
        case CapabilityCatalog.accessibility: return Config.accessibilityModeEnabled ? "On" : nil
        case CapabilityCatalog.display: return glassesDisplayEnabled ? "On" : nil
        case CapabilityCatalog.advanced: return "Test panel"
        default: return nil
        }
    }

    @ViewBuilder
    private func destination(for category: CapabilityCategory) -> some View {
        switch category.id {
        case CapabilityCatalog.voice:
            VoiceTriggersSettingsScreen(appState: appState)
        case CapabilityCatalog.appleIntegrations:
            AppleIntegrationsSettingsScreen()
        case CapabilityCatalog.accessibility:
            AccessibilitySettingsView().environmentObject(appState)
        case CapabilityCatalog.glasses:
            GlassesPrivacySettingsScreen(appState: appState)
        case CapabilityCatalog.lookAndFeel:
            LookFeelSettingsScreen()
        case CapabilityCatalog.diagnostics:
            DiagnosticsSupportView(appState: appState)
        case CapabilityCatalog.capture:
            CaptureStreamingSettingsScreen(appState: appState)
        case CapabilityCatalog.display:
            DisplayHUDSettingsScreen(appState: appState)
        case CapabilityCatalog.intelligence:
            AIPersonalitySettingsScreen(appState: appState)
        case CapabilityCatalog.tools:
            ToolsActionsSettingsScreen(appState: appState)
        case CapabilityCatalog.advanced:
            AdvancedSettingsScreen(appState: appState)
        case CapabilityCatalog.connections:
            ConnectionsSettingsScreen(appState: appState)
        default:
            EmptyView()
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
        OwnerGateAuth.authenticate(reason: "Unlock OpenGlasses Settings") { granted in
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
    @Binding var isTogglingEncryption: Bool
    @State private var showEncryptionInfo = false
    @State private var glassesUpdateError: String?
    @AppStorage("displayBackend") private var displayBackendRaw = DisplayBackendChoice.metaRayBan.rawValue
    @AppStorage("hudMirrorEnabled") private var hudMirrorEnabled = false

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

    private var displayedDisplayBackendName: String {
        DisplayBackendChoice(rawValue: displayBackendRaw)?.displayName ?? Config.displayBackend.displayName
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

    var body: some View {
        Form {
            // Plan CQ P0: "which glasses work with OpenGlasses?" stopped being a product name.
            // Any glasses that pair as a Bluetooth headset already run the whole voice loop, so
            // say what the connected pair CAN do rather than letting the user find the limits
            // one failed feature at a time.
            Section {
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
                Text("Where the wake-word listener captures voice. Glasses Mic enables true hands-free use but streams Bluetooth audio continuously (more battery) — and on Display glasses the active hands-free link covers the lens HUD with the call screen. Headset Mic keeps voice in your earbuds while the lens keeps the HUD; it never falls back to the glasses mic. iPhone Mic never re-routes to Bluetooth.")
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
                            else { appState.dwellCapture.start(cameraService: appState.cameraService) }
                        }
                    ),
                    info: "Hold your gaze on an object for about two seconds and it's captured to Photos automatically — hands-free, no wake word. Uses on-device object detection while the camera streams; off by default because the detection loop uses extra battery."
                )
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
                        Text(hudMirrorEnabled ? "On" : "Off")
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
                    info: "Uses Apple's on-device Vision framework to detect faces in the glasses camera feed and applies a Gaussian blur before a frame leaves your device — AI providers, video recordings, live broadcasts, browser streaming, and expert calls. Detection and blurring happen entirely on-device. On video, faces are found several times a second and the blur follows them in between, so someone stepping into shot can be briefly visible before the next detection catches them. Faces you have enrolled for recognition are matched on the unblurred frame, so recognition keeps working."
                )
                InfoToggle(
                    title: "Share Health Data with AI",
                    isOn: Binding(
                        get: { Config.shareHealthDataWithAI },
                        set: { Config.setShareHealthDataWithAI($0) }
                    ),
                    info: "Off by default. When on, the fitness coach may read your Apple Health workout history and send it to your configured AI provider (Anthropic, OpenAI, Google, etc.) so it can discuss your progress. Your Health data leaves the device only while this is enabled. On-device workout tracking, form analysis, and saving workouts to Apple Health work either way."
                )
                InfoStatusRow(
                    title: "Glasses Analytics",
                    status: MetaTelemetryBlock.disclosureState.summary,
                    info: "OpenGlasses collects nothing of its own: no developer backend, no account, so no usage analytics and no crash reports ever reach us, in any build. The glasses SDK does collect its own — connection sessions, camera streams, permission checks, crashes — and uploads them to Meta. This app opts out and additionally blocks those uploads from leaving your phone; there is nothing to turn on. This row says Off when nothing has ever had to be stopped, and Blocked if an upload was attempted anyway — the self-test in Diagnostics & Support shows how many. Pairing still contacts Meta once to verify the app is allowed to talk to your glasses, which is what makes the connection work and carries no usage data."
                )
            } header: {
                Text("Privacy")
            } footer: {
                Text("Bystander Face Blur runs entirely on-device — no images leave your phone. Share Health Data with AI is off by default: Apple Health data is sent to your AI provider only when you turn it on. OpenGlasses sends no analytics and no crash reports to its developer, and the glasses SDK's own analytics are opted out and blocked on this phone.")
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
        }
        .navigationTitle("Hardware & Privacy")
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
