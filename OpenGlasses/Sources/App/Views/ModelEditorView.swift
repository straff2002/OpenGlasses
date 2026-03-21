import SwiftUI

struct ModelEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedProvider: LLMProvider
    @State private var apiKey: String
    @State private var model: String
    @State private var baseURL: String
    @State private var supportsVision: Bool

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
                    availableModels: $availableModels,
                    isFetchingModels: $isFetchingModels,
                    fetchError: $fetchError,
                    keyValidated: $keyValidated,
                    resetModelOnProviderChange: false
                )
            }
            .navigationTitle("Edit Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = ModelConfig(
                            id: modelId,
                            name: name.isEmpty ? selectedProvider.displayName : name,
                            provider: selectedProvider.rawValue,
                            apiKey: apiKey,
                            model: model,
                            baseURL: baseURL,
                            supportsVision: supportsVision
                        )
                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}
