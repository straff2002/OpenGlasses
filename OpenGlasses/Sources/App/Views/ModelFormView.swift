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

    // Account sign-in state (Anthropic + ChatGPT — rendered via the shared OAuthSignInRows)
    @ObservedObject private var claudeOAuth = ClaudeOAuthService.shared
    @ObservedObject private var chatgptOAuth = ChatGPTOAuthService.shared

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
            Picker("Provider", selection: $selectedProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .onChange(of: selectedProvider) { _, newProvider in
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
                    Text("Select a downloaded model. Runs entirely on-device — no internet needed.")
                }
            }
        } else {
            // MARK: Cloud API key section
            Section {
                if selectedProvider == .anthropic {
                    OAuthSignInRows(
                        service: claudeOAuth,
                        signInLabel: "Sign in with Claude",
                        connectedLabel: "Claude account connected",
                        connectedCaption: "Requests use your Claude subscription unless an API key is set below.",
                        pasteInstructions: "Sign in in the browser, copy the code shown on the callback page, then paste it here.",
                        onChange: resetModelList
                    )
                }
                if selectedProvider == .chatgpt {
                    OAuthSignInRows(
                        service: chatgptOAuth,
                        signInLabel: "Sign in with ChatGPT",
                        connectedLabel: "ChatGPT account connected",
                        connectedCaption: "Requests use your ChatGPT subscription (codex models). Realtime voice still needs an OpenAI API key model.",
                        pasteInstructions: "Sign in in the browser. When it ends on a localhost page that can't connect, copy the full URL from the address bar and paste it here.",
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

                if let url = selectedProvider.consoleURL {
                    Link(destination: url) {
                        HStack {
                            Label("Get API Key", systemImage: "arrow.up.right.square")
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
                Text("API Key")
            } footer: {
                Text(providerHelpText)
            }

            // The list a validated credential unlocks — a native grouped
            // selection list, the same shape the credentials step offers.
            if !availableModels.isEmpty {
                Section {
                    ForEach(availableModels) { candidate in
                        OGSelectionRow(
                            title: candidate.name,
                            subtitle: candidate.id == candidate.name ? nil : candidate.id,
                            isSelected: model == candidate.id,
                            accessibilityText: modelRowLabel(candidate)
                        ) {
                            model = candidate.id
                        }
                    }
                } header: {
                    Text("Select Model")
                }
            }

            Section {
                TextField("Model ID", text: $model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: rowMinHeight)

                Toggle("Vision (Image Input)", isOn: $supportsVision)
            } header: {
                Text("Model")
            } footer: {
                if !availableModels.isEmpty {
                    Text("Pick from the list or type a model ID. Turn on Vision to send photos from your glasses to the AI.")
                } else {
                    Text("Turn on Vision to send photos from your glasses to the AI. Leave it off for text-only models.")
                }
            }
        }
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
                    Text("Key valid · \(availableModels.count) models")
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                    Text(selectedProvider == .custom ? "Fetch models" : "Validate key & fetch models")
                }
            }
            .frame(minHeight: rowMinHeight)
        }
        .disabled((apiKey.isEmpty && selectedProvider != .custom && !accountOAuthReady) || isFetchingModels)
        .accessibilityLabel(
            keyValidated
                ? "Key valid, \(availableModels.count) models. Check again"
                : (selectedProvider == .custom ? "Fetch models" : "Validate key and fetch models")
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
        candidate.id == candidate.name ? candidate.name : "\(candidate.name), \(candidate.id)"
    }

    // MARK: - Private

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
            connectionStatus = "Reachable — \(latencyMs) ms, \(count) model\(count == 1 ? "" : "s")"
        case .httpError(let code):
            connectionStatus = "Server returned HTTP \(code)"
        case .insecure:
            connectionStatus = "Blocked by App Transport Security — use https, or allow this host in Info.plist"
        case .unreachable(let why):
            connectionStatus = "Unreachable — \(why)"
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
            ? "No servers found. Many local servers don't advertise on the network — enter the Base URL manually or pick a preset above."
            : "Found \(servers.count) server\(servers.count == 1 ? "" : "s"). Tap one to use it."
    }

    private func fetchModels() async {
        isFetchingModels = true
        fetchError = nil
        let models = await ModelFetcher.fetchModels(
            provider: selectedProvider,
            apiKey: apiKey,
            baseURL: baseURL
        )
        isFetchingModels = false
        if models.isEmpty {
            fetchError = "Couldn't find any models. Double-check your API key and try again."
            keyValidated = false
        } else {
            availableModels = models
            keyValidated = true
            if !models.contains(where: { $0.id == model }) {
                model = models.first(where: { $0.id == selectedProvider.defaultModel })?.id
                    ?? models.first?.id ?? model
            }
        }
    }

    private var providerHelpText: String {
        switch selectedProvider {
        case .anthropic: return "Get your API key at console.anthropic.com"
        case .openai: return "Get your API key at platform.openai.com"
        case .chatgpt: return "Sign in with your ChatGPT account — uses your subscription, no API key. Serves the codex model family."
        case .gemini: return "Get your API key at aistudio.google.com"
        case .geminiVertex: return "Sign in with your Google account — Gemini on your own GCP project via Vertex AI, no API key. Needs a GCP iOS OAuth client ID and project ID (console.cloud.google.com). Gemini Live mode still uses the AI Studio key provider."
        case .groq: return "Get your API key at console.groq.com"
        case .zai: return "Z.ai subscription — OpenAI-compatible API"
        case .qwen: return "Coding Plan subscription — coding-intl.dashscope.aliyuncs.com"
        case .minimax: return "MiniMax subscription — platform.minimaxi.com"
        case .xai: return "Get your API key at console.x.ai"
        case .openrouter: return "500+ models with one API key — openrouter.ai/keys"
        case .custom: return "Any OpenAI-compatible endpoint — a cloud API or a self-hosted Ollama / llama.cpp / LM Studio / vLLM / LocalAI server. For a local server, set the Base URL to e.g. http://your-mac.local:11434/v1 and leave the API Key blank. Use the host's .local name or a Tailscale address — a raw 192.168.x.x IP over http may be blocked by App Transport Security."
        case .local: return "On-device inference — no internet needed"
        case .appleOnDevice: return "Apple Intelligence — built-in, no download, no API key"
        }
    }

    // MARK: - Account sign-in (OAuth)

    /// True when the selected provider can authenticate without a pasted key.
    private var accountOAuthReady: Bool {
        (selectedProvider == .anthropic && claudeOAuth.isConnected)
            || (selectedProvider == .chatgpt && chatgptOAuth.isConnected)
            || (selectedProvider == .geminiVertex && GoogleOAuthService.shared.isConnected)
    }

    private var anthropicKeyPlaceholder: String {
        switch selectedProvider {
        case .custom: return "API Key (optional for local servers)"
        case .anthropic: return claudeOAuth.isConnected ? "API Key (optional — account connected)" : "API Key"
        default: return "API Key"
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
