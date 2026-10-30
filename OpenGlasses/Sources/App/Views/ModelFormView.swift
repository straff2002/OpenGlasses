import SwiftUI

/// Shared form content for adding and editing AI model configurations.
/// Used by both `AddModelView` and `ModelEditorView` to eliminate duplication.
struct ModelFormView: View {
    @Binding var name: String
    @Binding var selectedProvider: LLMProvider
    @Binding var apiKey: String
    @Binding var model: String
    @Binding var baseURL: String
    @Binding var supportsVision: Bool
    @Binding var smallContext: Bool
    var providerTemplateID: Binding<String?> = .constant(nil)

    // Model fetching state
    @Binding var availableModels: [ModelFetcher.RemoteModel]
    @Binding var isFetchingModels: Bool
    @Binding var fetchError: String?
    @Binding var keyValidated: Bool

    /// When true, changing provider also resets the model ID to the new provider's default.
    var resetModelOnProviderChange: Bool = true

    // Connection-test state (siri-and-local-server plan)
    @State private var isTestingConnection = false
    @State private var connectionStatus: String?
    @State private var connectionOK = false
    // LAN auto-detect (Plan AF #6, experimental)
    @State private var isScanning = false
    @State private var discoveredServers: [LocalServerScanner.DiscoveredServer] = []
    @State private var scanMessage: String?
    /// Per-region workspace URL and key while a Model Studio template is being edited.
    @State private var regionDrafts = ModelStudioRegionDrafts()

    // Account sign-in state (Anthropic, ChatGPT and xAI — rendered via the shared OAuthSignInRows)
    @ObservedObject private var claudeOAuth = ClaudeOAuthService.shared
    @ObservedObject private var chatgptOAuth = ChatGPTOAuthService.shared
    @ObservedObject private var googleOAuth = GoogleOAuthService.shared
    @ObservedObject private var xaiOAuth = XAIOAuthService.shared

    @Environment(\.appAccent) private var accent
    /// Row heights that have to grow with the type beside them, so every
    /// tappable row clears 44pt at any Dynamic Type size.
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 44

    var body: some View {
        Section {
            TextField("e.g. Claude Sonnet, GPT-4o", text: $name)
                .autocorrectionDisabled()
        } header: {
            Text("Display Name")
        }

        Section {
            Picker("Provider", selection: providerSelection) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag("provider:" + provider.rawValue)
                }
                ForEach(RealtimeProviderCatalog.chatTemplates) { template in
                    Text(LocalizedStringKey(template.name)).tag("template:" + template.id)
                }
            }
            .accessibilityIdentifier("chat.provider")
            .onChange(of: selectedProvider) { _, newProvider in
                guard providerTemplateID.wrappedValue == nil else { resetModelList(); return }
                baseURL = newProvider.defaultBaseURL
                if resetModelOnProviderChange {
                    model = newProvider.defaultModel
                } else if model.isEmpty || LLMProvider.allCases.contains(where: { $0.defaultModel == model }) {
                    model = newProvider.defaultModel
                }
                supportsVision = ModelConfig.inferredSupportsVision(
                    provider: newProvider,
                    model: model,
                    baseURL: baseURL
                )
                if name.isEmpty {
                    name = newProvider.displayName
                }
                resetModelList()
            }
            if let template = RealtimeProviderCatalog.chatTemplates.first(where: { $0.id == providerTemplateID.wrappedValue }),
               ModelStudioRegion.region(of: template.endpoint) != nil,
               let region = ModelStudioRegion.region(of: baseURL) {
                Picker("Region", selection: Binding(get: { region }, set: { switchRegion(from: region, to: $0) })) {
                    ForEach(ModelStudioRegion.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("chat.region")
            }
        } header: {
            Text("Provider")
        }

        if selectedProvider == .local {
            // MARK: Local model section
            Section {
                let downloaded = localDownloadedModels

                if downloaded.isEmpty {
                    OGStatusLabel("No models downloaded yet", kind: .warn)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(downloaded, id: \.self) { modelId in
                            Text(localDisplayName(modelId))
                                .tag(modelId)
                        }
                    }
                }

                NavigationLink {
                    LocalModelManagerView()
                } label: {
                    Label("Download & Manage Models", systemImage: "arrow.down.circle")
                        .frame(minHeight: rowMinHeight)
                }

                Toggle("Vision (Image Input)", isOn: $supportsVision)
            } header: {
                Text("Local Model")
            } footer: {
                if localDownloadedModels.isEmpty {
                    Text("Download a model first, then select it here. No internet needed after download.")
                } else {
                    // The numbers come from the same budget the truncation logic enforces, so
                    // what this caption promises is what the model actually receives.
                    Text("Select a downloaded model. Runs entirely on-device — no internet needed. \(Self.localContextCaption(modelId: model))")
                }
            }
        } else {
            // MARK: Cloud API key section
            Section {
                if selectedProvider == .anthropic {
                    OAuthSignInRows(
                        service: claudeOAuth,
                        signInLabel: "Sign in with Claude",
                        connectedLabel: String(localized: "Claude account connected"),
                        connectedCaption: "Requests use your Claude subscription unless an API key is set below.",
                        pasteInstructions: "Sign in in the browser, copy the code shown on the callback page, then paste it here.",
                        onChange: resetModelList
                    )
                }
                if selectedProvider == .chatgpt {
                    OAuthSignInRows(
                        service: chatgptOAuth,
                        signInLabel: "Sign in with ChatGPT",
                        connectedLabel: String(localized: "ChatGPT account connected"),
                        connectedCaption: "Conversation uses your ChatGPT plan. Live voice mode is a separate OpenAI product and still needs an OpenAI API key model — a sign-in can't reach it.",
                        pasteInstructions: "Sign in in the browser. When it ends on a localhost page that can't connect, copy the full URL from the address bar and paste it here.",
                        onChange: resetModelList
                    )
                    if !chatgptOAuth.isConnected {
                        ChatGPTDeviceCodeSignInRows(
                            service: chatgptOAuth,
                            onConnected: resetModelList
                        )
                    }
                }

                if selectedProvider == .xai {
                    OAuthSignInRows(
                        service: xaiOAuth,
                        signInLabel: "Sign in with xAI",
                        connectedLabel: xaiOAuth.accountLabel.map { String(localized: "Signed in as \($0)") } ?? String(localized: "Signed in"),
                        connectedCaption: "Requests use your xAI subscription (SuperGrok) unless an API key is set below.",
                        pasteInstructions: "Sign in in the browser. When it ends on a 127.0.0.1 page that can't connect, copy the full URL from the address bar and paste it here.",
                        onChange: resetModelList
                    )
                }

                if selectedProvider == .geminiVertex {
                    GoogleSignInRows(onChange: resetModelList)
                }

                // Account-sign-in providers have no key to paste.
                if selectedProvider != .chatgpt && selectedProvider != .geminiVertex {
                    SecretInputField(placeholder: anthropicKeyPlaceholder, text: $apiKey)
                        .frame(minHeight: rowMinHeight)
                        .onChange(of: apiKey) { _, _ in resetModelList() }
                }

                if let url = OnboardingProviderPolicy.keyPageURL(provider: selectedProvider,
                                                                 templateID: providerTemplateID.wrappedValue,
                                                                 baseURL: baseURL) {
                    Link(destination: url) {
                        HStack {
                            Label("Get API Key", systemImage: "arrow.up.forward.square")
                                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                            Spacer()
                            Text(url.host ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: rowMinHeight)
                    }
                    .accessibilityLabel("Get API Key from \(url.host ?? selectedProvider.displayName)")
                }

                if selectedProvider.showBaseURL {
                    localServerRows
                }

                validateButton

                if let error = fetchError {
                    OGStatusLabel(error, kind: .error)
                }

                if selectedProvider.showBaseURL {
                    connectionRows
                }
            } header: {
                Text(selectedProvider == .chatgpt ? "ChatGPT Account" : "API Key")
            } footer: {
                if providerTemplateID.wrappedValue == "qwen" {
                    Text("Replace {workspace} in the URL with your Model Studio workspace ID, and use an API key from that workspace. Beijing and Singapore workspaces have separate IDs and keys. This is separate from the Qwen Coding Plan subscription.")
                } else if providerTemplateID.wrappedValue == "doubao" {
                    Text("Use a Beijing Ark API key and a model ID or endpoint ID enabled for your account. Doubao speech has separate credentials.")
                } else if providerTemplateID.wrappedValue == "siliconflow" {
                    Text("Use a SiliconFlow API key. One key reaches Qwen, DeepSeek, GLM and more. Pick a vision model, such as Qwen3-VL, to send camera images.")
                } else {
                    Text(providerHelpText)
                }
            }

            // The list a validated credential unlocks — a native grouped
            // selection list, the same shape the credentials step offers.
            if !availableModels.isEmpty {
                Section {
                    ForEach(availableModels.filter { $0.assistantStatus(provider: selectedProvider).isChoosable }) { candidate in
                        OGSelectionRow(
                            title: candidate.name,
                            subtitle: modelRowSubtitle(candidate),
                            isSelected: model == candidate.id,
                            accessibilityText: modelRowLabel(candidate)
                        ) {
                            model = candidate.id
                        }
                    }
                } header: {
                    Text("Select Model")
                }
                NotAnAssistantModelsSection(
                    models: availableModels.filter { !$0.assistantStatus(provider: selectedProvider).isChoosable },
                    provider: selectedProvider)
            }

            Section {
                TextField("Model ID", text: $model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: rowMinHeight)
                // A speech, image or embedding id typed or saved here can't answer: say what it
                // is for. A warning, not a refusal — the classifier can't know every server's names.
                if let warning = ModelKindClassifier.kind(provider: selectedProvider, typedID: model,
                                                          listed: availableModels)?.assistantWarning {
                    OGStatusLabel(warning, kind: .warn)
                }
                // A model its provider has retired, or retires soon (the list's own date, else
                // the provider's published one).
                if let warning = shutdownWarning {
                    OGStatusLabel(warning, kind: .warn)
                }

                Toggle("Vision (Image Input)", isOn: $supportsVision)
            } header: {
                Text("Model")
            } footer: {
                if !availableModels.isEmpty {
                    Text("Pick from the list or type a model ID. Turn on Vision to send photos to the AI.")
                } else {
                    Text("Turn on Vision to send photos to the AI. Leave it off for text-only models.")
                }
            }

            Section {
                Toggle("Small context", isOn: $smallContext)
            } footer: {
                Text("Each turn sends a short prompt and recent lines only — no tool list or full system prompt. Turn on for tight providers like Groq (8k token cap); leave off for roomier models so tools keep working.")
            }
        }
    }

    private var providerSelection: Binding<String> {
        Binding(get: {
            providerTemplateID.wrappedValue.map { "template:" + $0 } ?? "provider:" + selectedProvider.rawValue
        }, set: { value in
            if value.hasPrefix("template:"), let template = RealtimeProviderCatalog.chatTemplates.first(where: { "template:" + $0.id == value }) {
                let previousName = RealtimeProviderCatalog.chatTemplates.first { $0.id == providerTemplateID.wrappedValue }?.name ?? selectedProvider.displayName
                providerTemplateID.wrappedValue = template.id
                selectedProvider = .custom
                baseURL = template.endpoint
                model = template.model
                supportsVision = template.vision
                apiKey = ""
                regionDrafts = ModelStudioRegionDrafts()
                if name.isEmpty || name == previousName { name = template.name }
                resetModelList()
            } else if let provider = LLMProvider(rawValue: String(value.dropFirst("provider:".count))) {
                providerTemplateID.wrappedValue = nil
                selectedProvider = provider
            }
        })
    }

    // MARK: - Key section rows

    /// Validate-and-fetch. Once a key has checked out the row becomes its own
    /// result plus a refresh affordance, so the outcome sits where the action
    /// was rather than in a separate banner.
    private var validateButton: some View {
        Button {
            Task { await fetchModels() }
        } label: {
            HStack(spacing: 8) {
                if isFetchingModels {
                    ProgressView().controlSize(.small)
                    Text("Validating…")
                } else if keyValidated {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OGTheme.okLabel)
                        .accessibilityHidden(true)
                    Text(selectedProvider == .chatgpt || listsModelsWithXAIAccount
                         ? "\(availableModels.count) models available"
                         : "Key valid · \(availableModels.count) models")
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                    Text(validateButtonTitle)
                }
            }
            .frame(minHeight: rowMinHeight)
        }
        .disabled(!credentialsReady || isFetchingModels)
        .accessibilityLabel(
            keyValidated
                ? String(localized: "\(availableModels.count) models available. Check again")
                : validateButtonTitle
        )
    }

    /// Preset menu + base URL, for the providers that point at a server the user
    /// runs themselves.
    @ViewBuilder
    private var localServerRows: some View {
        Menu {
            ForEach(LocalServerPreset.allCases) { preset in
                Button(preset.displayName) {
                    baseURL = preset.baseURL
                    resetModelList()
                    connectionStatus = nil
                }
            }
        } label: {
            Label("Local server preset", systemImage: "server.rack")
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .frame(minHeight: rowMinHeight)
        }

        TextField("Base URL", text: $baseURL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minHeight: rowMinHeight)
            .onChange(of: baseURL) { _, _ in resetModelList(); connectionStatus = nil }
    }

    /// Reachability test and the experimental LAN sweep (Plan AF #6).
    @ViewBuilder
    private var connectionRows: some View {
        Button {
            Task { await testConnection() }
        } label: {
            HStack(spacing: 8) {
                if isTestingConnection {
                    ProgressView().controlSize(.small)
                    Text("Testing…")
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                        .accessibilityHidden(true)
                    Text("Test Connection")
                }
            }
            .frame(minHeight: rowMinHeight)
        }
        .disabled(baseURL.isEmpty || isTestingConnection)

        if let connectionStatus {
            OGStatusLabel(connectionStatus, kind: connectionOK ? .ok : .error)
        }

        Button {
            Task { await scanLAN() }
        } label: {
            HStack(spacing: 8) {
                if isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .accessibilityHidden(true)
                    Text("Scan local network")
                }
                Spacer()
                Text("Experimental")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: rowMinHeight)
        }
        .disabled(isScanning)

        if let scanMessage {
            Text(scanMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(discoveredServers) { server in
            Button {
                baseURL = server.baseURL
                resetModelList()
                connectionStatus = nil
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(server.preset.displayName) · \(server.host)")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(server.baseURL) — \(server.modelCount) models, \(server.latencyMs) ms")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double-tap to use this server")
        }
    }

    /// What VoiceOver reads for a fetched-model row. The id is only worth
    /// speaking when it differs from the display name.
    private func modelRowLabel(_ candidate: ModelFetcher.RemoteModel) -> String {
        [candidate.name, candidate.id == candidate.name ? nil : candidate.id,
         candidate.assistantStatus(provider: selectedProvider).note]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func modelRowSubtitle(_ candidate: ModelFetcher.RemoteModel) -> String? {
        let parts = [candidate.id == candidate.name ? nil : candidate.id,
                     candidate.assistantStatus(provider: selectedProvider).note].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The typed or chosen id's shutdown warning, where its provider has dated it: the loaded
    /// list's own date, else the one the provider published.
    private var shutdownWarning: String? {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let listed = availableModels.first(where: { $0.id == id })?.shutdown
        return ModelShutdownCalendar.warning(
            for: ModelShutdownCalendar.shutdown(provider: selectedProvider, id: id, listed: listed))
    }

    // MARK: - Private

    private func switchRegion(from: ModelStudioRegion, to: ModelStudioRegion) {
        guard from != to, let template = RealtimeProviderCatalog.chatTemplates.first(where: { $0.id == providerTemplateID.wrappedValue }) else { return }
        let draft = regionDrafts.switchRegion(from: from, to: to, current: .init(endpoint: baseURL, apiKey: apiKey),
                                              templateEndpoint: template.endpoint)
        baseURL = draft.endpoint
        apiKey = draft.apiKey
    }

    private func resetModelList() {
        availableModels = []
        keyValidated = false
        fetchError = nil
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionStatus = nil
        defer { isTestingConnection = false }
        let result = await ModelFetcher.testConnection(provider: selectedProvider, apiKey: apiKey, baseURL: baseURL)
        connectionOK = result.isSuccess
        switch result {
        case .ok(let latencyMs, let count):
            let models = count == 1 ? String(localized: "1 model") : String(localized: "\(count) models")
            connectionStatus = String(localized: "Reachable — \(latencyMs) ms, \(models)")
        case .httpError(let code):
            connectionStatus = String(localized: "Server returned HTTP \(code)")
        case .insecure:
            connectionStatus = String(localized: "Blocked by App Transport Security — use https, or allow this host in Info.plist")
        case .unreachable(let why):
            connectionStatus = String(localized: "Unreachable — \(why)")
        }
    }

    /// Experimental LAN auto-detect (Plan AF #6): browse Bonjour + probe preset
    /// candidates. Best-effort — many local servers don't advertise, so an empty
    /// result is expected; the manual preset/Base-URL path remains primary.
    private func scanLAN() async {
        isScanning = true
        scanMessage = nil
        discoveredServers = []
        defer { isScanning = false }
        let servers = await LocalServerScanner().scan()
        discoveredServers = servers
        scanMessage = servers.isEmpty
            ? String(localized: "No servers found. Many local servers don't advertise on the network — enter the Base URL manually or pick a preset above.")
            : (servers.count == 1
                ? String(localized: "Found 1 server. Tap it to use it.")
                : String(localized: "Found \(servers.count) servers. Tap one to use it."))
    }

    private func fetchModels() async {
        isFetchingModels = true
        fetchError = nil
        let models: [ModelFetcher.RemoteModel]
        if selectedProvider == .chatgpt {
            // The account catalog is a drifting private surface; the distinguishable failure
            // reasons are the only way to tell "sign in again" from "the backend moved".
            switch await ModelFetcher.fetchChatGPTCatalog() {
            case .models(let fetched):
                models = fetched
            case .tokenUnavailable(let signedIn):
                models = []
                fetchError = signedIn
                    ? String(localized: "Signed in, but the session couldn't be refreshed. Sign out and sign in again.")
                    : String(localized: "No ChatGPT account is connected. Sign in first.")
            case .httpError(let code):
                models = []
                fetchError = code == 401 || code == 403
                    ? String(localized: "ChatGPT rejected the sign-in (HTTP \(code)). Sign out and sign in again — if it persists, the backend contract may have changed.")
                    : String(localized: "ChatGPT's model service returned HTTP \(code). Try again shortly.")
            case .networkError(let why):
                models = []
                fetchError = String(localized: "Couldn't reach ChatGPT — \(why)")
            case .emptyCatalog:
                models = []
                fetchError = String(localized: "ChatGPT answered, but reported no models enabled for this account.")
            }
        } else {
            models = await ModelFetcher.fetchModels(
                provider: selectedProvider,
                apiKey: apiKey,
                baseURL: baseURL
            )
        }
        isFetchingModels = false
        if models.isEmpty {
            if fetchError == nil {
                fetchError = listsModelsWithXAIAccount
                    ? String(localized: "Couldn't load the models for your xAI account. Sign out and sign in again, or type a model ID below.")
                    : String(localized: "Couldn't find any models. Double-check your API key and try again.")
            }
            keyValidated = false
        } else {
            availableModels = models
            keyValidated = true
            if !models.contains(where: { $0.id == model }) {
                model = ModelFetcher.initialChoice(in: models, preferring: [selectedProvider.defaultModel]) ?? model
            }
        }
    }

    /// Pure. Describes the prompt room a local model actually has, from the same tables the
    /// truncation logic uses. Local models always run the lean prompt, so there is no toggle —
    /// only the truth about the window.
    static func localContextCaption(modelId: String) -> String {
        let window = LocalModelBudget.contextWindow(for: modelId)
        let prompt = LocalModelBudget.promptBudget(for: modelId)
        let windowK = window / 1024
        let promptK = prompt / 1024
        return String(localized: "Always uses a compact prompt; ~\(windowK)k-token context (~\(promptK)k for the prompt).")
    }

    /// An xAI model with no key lists the signed-in account's models instead of validating a key.
    private var listsModelsWithXAIAccount: Bool {
        selectedProvider == .xai && xaiOAuth.isConnected
            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validateButtonTitle: String {
        if selectedProvider == .chatgpt || listsModelsWithXAIAccount { return String(localized: "Fetch available models") }
        if selectedProvider == .custom { return String(localized: "Fetch models") }
        return String(localized: "Validate key & fetch models")
    }

    private var providerHelpText: String {
        switch selectedProvider {
        case .anthropic: return String(localized: "Get your API key at console.anthropic.com")
        case .openai: return String(localized: "Get your API key at platform.openai.com")
        case .chatgpt: return String(localized: "Sign in with your ChatGPT account — uses your subscription, no API key. The model list comes from the models enabled for your account.")
        case .gemini: return String(localized: "Get your API key at aistudio.google.com")
        case .geminiVertex: return String(localized: "Sign in with your Google account — Gemini on your own GCP project via Vertex AI, no API key. Needs a GCP iOS OAuth client ID and project ID (console.cloud.google.com). Gemini Live mode still uses the AI Studio key provider.")
        case .groq: return String(localized: "Get your API key at console.groq.com")
        case .deepseek: return String(localized: "Get your API key at platform.deepseek.com — default model deepseek-flash (V4.1 Flash, multimodal vision)")
        case .mistral: return String(localized: "Get your API key at admin.mistral.ai — default model mistral-medium-latest (Mistral Medium, multimodal vision)")
        case .zai: return String(localized: "Z.ai subscription — OpenAI-compatible API")
        case .qwen: return String(localized: "Coding Plan subscription — coding-intl.dashscope.aliyuncs.com")
        case .minimax: return String(localized: "MiniMax subscription — platform.minimaxi.com")
        case .xai: return String(localized: "Sign in with your xAI account (SuperGrok) — no API key needed — or get an API key at console.x.ai. A key set here is used instead of the sign-in.")
        case .openrouter: return String(localized: "500+ models with one API key — openrouter.ai/keys")
        case .custom: return String(localized: "Any OpenAI-compatible endpoint — a cloud API or a self-hosted Ollama / llama.cpp / LM Studio / vLLM / LocalAI server. For a local server, set the Base URL to e.g. http://your-mac.local:11434/v1 and leave the API Key blank. Use the host's .local name or a Tailscale address — a raw 192.168.x.x IP over http may be blocked by App Transport Security.")
        case .local: return String(localized: "On-device inference — no internet needed")
        case .appleOnDevice: return String(localized: "Apple Intelligence — built-in, no download, no API key")
        }
    }

    // MARK: - Account sign-in (OAuth)

    private var credentialsReady: Bool {
        ModelFormValidation.credentialsReady(
            provider: selectedProvider, apiKey: apiKey,
            claudeConnected: claudeOAuth.isConnected,
            chatgptConnected: chatgptOAuth.isConnected,
            googleConnected: googleOAuth.isConnected,
            xaiConnected: xaiOAuth.isConnected
        )
    }

    private var anthropicKeyPlaceholder: String {
        switch selectedProvider {
        case .custom: return String(localized: "API Key (optional for local servers)")
        case .anthropic: return claudeOAuth.isConnected ? String(localized: "API Key (optional — account connected)") : String(localized: "API Key")
        case .xai: return xaiOAuth.isConnected ? String(localized: "API Key (optional — account connected)") : String(localized: "API Key")
        default: return String(localized: "API Key")
        }
    }

    // MARK: - Local Model Helpers

    /// List of downloaded local model IDs.
    private var localDownloadedModels: [String] {
        LocalLLMService().downloadedModelIds()
    }

    /// Convert "mlx-community/Qwen2.5-3B-Instruct-4bit" → "Qwen2.5 3B Instruct 4bit"
    private func localDisplayName(_ modelId: String) -> String {
        guard let name = modelId.split(separator: "/").last else { return modelId }
        return String(name)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
