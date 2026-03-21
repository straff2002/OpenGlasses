import SwiftUI

struct AddModelView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedProvider: LLMProvider = .anthropic
    @State private var apiKey: String = ""
    @State private var model: String = LLMProvider.anthropic.defaultModel
    @State private var baseURL: String = LLMProvider.anthropic.defaultBaseURL
    @State private var supportsVision: Bool = true

    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String?
    @State private var keyValidated: Bool = false

    let onAdd: (ModelConfig) -> Void

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
                    resetModelOnProviderChange: true
                )
            }
            .navigationTitle("Add Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let config = ModelConfig(
                            id: UUID().uuidString,
                            name: name.isEmpty ? selectedProvider.displayName : name,
                            provider: selectedProvider.rawValue,
                            apiKey: apiKey,
                            model: model,
                            baseURL: baseURL,
                            supportsVision: supportsVision
                        )
                        onAdd(config)
                        dismiss()
                    }
                    .disabled(selectedProvider == .local ? model.isEmpty : apiKey.isEmpty)
                }
            }
        }
    }
}
