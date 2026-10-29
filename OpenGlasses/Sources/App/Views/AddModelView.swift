import SwiftUI

struct AddModelView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var claudeOAuth = ClaudeOAuthService.shared
    @ObservedObject private var chatgptOAuth = ChatGPTOAuthService.shared
    @ObservedObject private var googleOAuth = GoogleOAuthService.shared
    @ObservedObject private var xaiOAuth = XAIOAuthService.shared

    @State private var name: String = ""
    @State private var selectedProvider: LLMProvider = .anthropic
    @State private var apiKey: String = ""
    @State private var model: String = LLMProvider.anthropic.defaultModel
    @State private var baseURL: String = LLMProvider.anthropic.defaultBaseURL
    @State private var supportsVision: Bool = true
    @State private var smallContext: Bool = false

    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String?
    @State private var keyValidated: Bool = false

    @State private var isRealtime = false
    @State private var realtimeModel = RealtimeProviderCatalog.templates[0].modelConfiguration()
    @State private var providerTemplateID: String?
    @State private var saveError: String?

    /// The saved model and the list its key returned, so the "this key can also…" card can read
    /// what the key reaches (Plan KA P1). The list is empty when none was loaded.
    let onAdd: (ModelConfig, [ModelFetcher.RemoteModel]) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Conversation", selection: $isRealtime) {
                        Text("Chat").tag(false)
                        Text("Realtime").tag(true)
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("model.conversationKind")
                }
                if isRealtime {
                    RealtimeModelForm(configuration: $realtimeModel)
                    if let saveError { OGStatusLabel(saveError, kind: .error) }
                } else {
                ModelFormView(
                    name: $name,
                    selectedProvider: $selectedProvider,
                    apiKey: $apiKey,
                    model: $model,
                    baseURL: $baseURL,
                    supportsVision: $supportsVision,
                    smallContext: $smallContext,
                    providerTemplateID: $providerTemplateID,
                    availableModels: $availableModels,
                    isFetchingModels: $isFetchingModels,
                    fetchError: $fetchError,
                    keyValidated: $keyValidated,
                    resetModelOnProviderChange: true
                )
                }
            }
            .ogFormStyle()
            .navigationTitle("Add Model")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                prefillIfExistingKey(for: selectedProvider)
            }
            .onChange(of: selectedProvider) { _, newProvider in
                prefillIfExistingKey(for: newProvider)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if isRealtime {
                            do {
                                _ = try realtimeModel.request()
                                var models = Config.savedRealtimeModels
                                models.append(realtimeModel)
                                guard Config.setSavedRealtimeModels(models) else { saveError = String(localized: "Couldn't save the model to Keychain."); return }
                                Config.setActiveRealtimeModelID(realtimeModel.id)
                                dismiss()
                            } catch { saveError = error.localizedDescription }
                            return
                        }
                        let config = ModelConfig(
                            id: UUID().uuidString,
                            name: name.isEmpty ? selectedProvider.displayName : name,
                            provider: selectedProvider.rawValue,
                            apiKey: apiKey,
                            model: model,
                            baseURL: baseURL,
                            supportsVision: supportsVision,
                            smallContext: smallContext,
                            providerTemplateID: providerTemplateID
                        )
                        onAdd(config, availableModels)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }

    private var canAdd: Bool {
        if isRealtime { return !realtimeModel.endpoint.isEmpty && !realtimeModel.apiKey.isEmpty && !realtimeModel.model.isEmpty }
        return ModelFormValidation.canAdd(
            provider: selectedProvider, model: model, baseURL: baseURL, apiKey: apiKey,
            claudeConnected: claudeOAuth.isConnected,
            chatgptConnected: chatgptOAuth.isConnected,
            googleConnected: googleOAuth.isConnected,
            xaiConnected: xaiOAuth.isConnected
        )
    }

    // MARK: - Pre-fill from existing saved model

    /// If the user already has a saved model for this provider, pre-fill the API key
    /// and auto-fetch the model list so they don't have to re-enter credentials.
    private func prefillIfExistingKey(for provider: LLMProvider) {
        guard providerTemplateID == nil, provider != .local, provider != .appleOnDevice,
              let existing = Config.savedModels.first(where: {
                  $0.llmProvider == provider && !$0.apiKey.isEmpty
              }) else { return }
        apiKey = existing.apiKey
        if provider.showBaseURL && !existing.baseURL.isEmpty {
            baseURL = existing.baseURL
        }
        // Run fetch after the current onChange cycle (model list was just reset by ModelFormView)
        Task { await fetchModels() }
    }

    // MARK: - Model Fetching

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
            fetchError = String(localized: "Couldn't find any models. Double-check your API key and try again.")
            keyValidated = false
        } else {
            availableModels = models
            keyValidated = true
            if !models.contains(where: { $0.id == model }) {
                model = ModelFetcher.initialChoice(in: models, preferring: [selectedProvider.defaultModel]) ?? model
            }
        }
    }
}
