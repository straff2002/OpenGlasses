import SwiftUI

/// What a saved-model row says, in words.
///
/// Vision used to be an `eye` glyph beside the provider name — meaning carried
/// by a symbol alone, which a monochrome or magnified reading loses. It is a
/// word now, in both the visible subtitle and the spoken label. Pure functions,
/// so the wording is covered headlessly rather than only in a running UI.
enum ModelRowSummary {
    /// The supporting line under the model's display name.
    static func subtitle(provider: String, modelId: String, visionEnabled: Bool) -> String {
        let base = "\(provider) · \(modelId)"
        return visionEnabled ? "\(base) · Vision" : base
    }

    /// The row's VoiceOver label — identity, then capability, then whether this
    /// is the model the session is currently using.
    static func spoken(name: String, provider: String, visionEnabled: Bool, isActive: Bool) -> String {
        var parts = [name, provider]
        if visionEnabled { parts.append("vision enabled") }
        if isActive { parts.append("active") }
        return parts.joined(separator: ", ")
    }
}

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
    }

    @State private var selectedTier: Config.ModelTier = Config.modelTier
    @State private var selectedMode: AppMode = Config.appMode

    /// Which modes are selectable, and why not when they aren't. Read at display time so adding a
    /// key in Settings and coming back here shows the mode unlocked.
    private var modeOptions: [ConversationModeAvailability.Option] {
        ConversationModeAvailability.options(for: ConversationModeAvailability.current)
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
                Section {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(modeOptions) { option in
                            Text(option.mode.displayName).tag(option.mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedMode) { previous, mode in
                        guard let option = modeOptions.first(where: { $0.mode == mode }) else { return }
                        guard option.isAvailable else {
                            // Bounce back rather than switching into a mode that cannot start —
                            // the reason is shown in the footer, so the refusal is explained.
                            selectedMode = previous
                            return
                        }
                        appState.switchMode(to: mode)
                    }
                } footer: {
                    if let blocked = modeOptions.first(where: { $0.mode == selectedMode && !$0.isAvailable }),
                       let reason = blocked.unavailableReason {
                        Text(reason)
                    } else if let unavailable = modeOptions.first(where: { !$0.isAvailable }),
                              let reason = unavailable.unavailableReason {
                        Text(reason)
                    }
                }

                Section {
                    Picker("Speed", selection: $selectedTier) {
                        ForEach(Config.ModelTier.allCases) { tier in
                            Label(tier.displayName, systemImage: tier.icon)
                                .tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTier) { _, newTier in
                        Config.setModelTier(newTier)
                        if let match = Config.modelForTier(newTier) {
                            selectModel(match)
                        }
                    }
                }

                Section {
                    modelRows(savedModels)
                } header: {
                    Text("Model")
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()
        }
    }

    private func modelRows(_ models: [ModelConfig]) -> some View {
        let activeId = Config.activeModelId
        return ForEach(Array(models), id: \.id) { (model: ModelConfig) in
            OGSelectionRow(
                title: model.name,
                subtitle: ModelRowSummary.subtitle(
                    provider: model.llmProvider.displayName,
                    modelId: model.model,
                    visionEnabled: model.visionEnabled
                ),
                isSelected: model.id == activeId,
                accessibilityText: ModelRowSummary.spoken(
                    name: model.name,
                    provider: model.llmProvider.displayName,
                    visionEnabled: model.visionEnabled,
                    isActive: model.id == activeId
                )
            ) {
                selectModel(model)
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
