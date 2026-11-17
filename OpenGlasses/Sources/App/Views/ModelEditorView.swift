import SwiftUI

struct ModelEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedProvider: LLMProvider
    @State private var apiKey: String
    @State private var model: String
    @State private var baseURL: String
    @State private var supportsVision: Bool
    @State private var providerTemplateID: String?
    @State private var smallContext: Bool
    @State private var reasoningEffort: String?

    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String?
    @State private var keyValidated: Bool = false

    let modelId: String
    let onSave: (ModelConfig) -> Void

    init(model config: ModelConfig, onSave: @escaping (ModelConfig) -> Void) {
        self.modelId = config.id
        self.onSave = onSave
        _name = State(initialValue: config.name)
        _selectedProvider = State(initialValue: config.llmProvider)
        _apiKey = State(initialValue: config.apiKey)
        _model = State(initialValue: config.model)
        _baseURL = State(initialValue: config.baseURL)
        _supportsVision = State(initialValue: config.visionEnabled)
        _providerTemplateID = State(initialValue: config.providerTemplateID)
        _smallContext = State(initialValue: config.smallContextEnabled)
        _reasoningEffort = State(initialValue: config.reasoningEffort)
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    resetModelOnProviderChange: false
                )
                ModelReasoningSection(provider: selectedProvider, model: model, baseURL: baseURL,
                                      reasoningEffort: $reasoningEffort)
            }
            .ogFormStyle()
            .navigationTitle("Edit Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = ModelConfig(
                            id: modelId,
                            name: name.isEmpty ? selectedProvider.displayName : name,
                            provider: selectedProvider.rawValue,
                            apiKey: apiKey,
                            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                            baseURL: baseURL,
                            supportsVision: ChatGPTVisionOverrideReset.storedOverride(
                                provider: selectedProvider, model: model.trimmingCharacters(in: .whitespacesAndNewlines), chosen: supportsVision),
                            smallContext: smallContext,
                            reasoningEffort: reasoningEffort
                        )
                        updated.providerTemplateID = providerTemplateID
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!ModelFormValidation.canSave(provider: selectedProvider, model: model,
                                                           baseURL: baseURL))
                }
            }
        }
    }
}
