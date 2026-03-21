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
                    Label("No models downloaded yet", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
                SecureField("API Key", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: apiKey) { _, _ in resetModelList() }

                if selectedProvider.showBaseURL {
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: baseURL) { _, _ in resetModelList() }
                }

                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack {
                        if isFetchingModels {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Validating…")
                        } else if keyValidated {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key valid — \(availableModels.count) models")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Validate key & fetch models")
                        }
                    }
                }
                .disabled(apiKey.isEmpty || isFetchingModels)

                if let error = fetchError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text(providerHelpText)
            }

            Section {
                if !availableModels.isEmpty {
                    Picker("Select Model", selection: $model) {
                        ForEach(availableModels) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("Model ID", text: $model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

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

    // MARK: - Private

    private func resetModelList() {
        availableModels = []
        keyValidated = false
        fetchError = nil
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
        case .gemini: return "Get your API key at aistudio.google.com"
        case .groq: return "Get your API key at console.groq.com"
        case .zai: return "Z.ai subscription — OpenAI-compatible API"
        case .qwen: return "Coding Plan subscription — coding-intl.dashscope.aliyuncs.com"
        case .minimax: return "MiniMax subscription — platform.minimaxi.com"
        case .custom: return "Any OpenAI-compatible API endpoint"
        case .local: return "On-device inference — no internet needed"
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
