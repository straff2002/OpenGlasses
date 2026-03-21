import SwiftUI

struct ModelPickerSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            modelContent
                .navigationTitle("Select Model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var modelContent: some View {
        let savedModels = Config.savedModels
        if savedModels.isEmpty {
            ContentUnavailableView(
                "No Models",
                systemImage: "brain",
                description: Text("Add a model in Settings to get started.")
            )
        } else {
            List {
                modelRows(savedModels)
            }
        }
    }

    private func modelRows(_ models: [ModelConfig]) -> some View {
        let activeId = Config.activeModelId
        return ForEach(Array(models), id: \.id) { (model: ModelConfig) in
            Button {
                selectModel(model)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(model.llmProvider.displayName) · \(model.model)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if model.visionEnabled {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                    .accessibilityLabel("Vision enabled")
                            }
                        }
                    }
                    Spacer()
                    if model.id == activeId {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Active model")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(model.name), \(model.llmProvider.displayName)\(model.id == activeId ? ", active" : "")")
            }
        }
    }

    private func selectModel(_ model: ModelConfig) {
        Config.setActiveModelId(model.id)
        appState.llmService.clearHistory()
        appState.llmService.refreshActiveModel()

        let isRealtimeModel = model.llmProvider == .openai
            && model.model.lowercased().contains("realtime")

        if isRealtimeModel && appState.currentMode != .openaiRealtime {
            appState.switchMode(to: .openaiRealtime)
        } else if appState.currentMode == .geminiLive && model.llmProvider != .gemini {
            appState.switchMode(to: .direct)
        } else if appState.currentMode == .openaiRealtime && !isRealtimeModel {
            appState.switchMode(to: .direct)
        }

        dismiss()
    }
}
