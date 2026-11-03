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
        return visionEnabled ? String(localized: "\(base) · Vision") : base
    }

    /// The row's VoiceOver label — identity, then capability, then whether this
    /// is the model the session is currently using.
    static func spoken(name: String, provider: String, visionEnabled: Bool, isActive: Bool) -> String {
        var parts = [name, provider]
        if visionEnabled { parts.append(String(localized: "vision enabled")) }
        if isActive { parts.append(String(localized: "active")) }
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
        .onAppear {
            Config.migrateRealtimeModelsIfNeeded()
            Config.postPendingRealtimeModelNotice()
            realtimeModels = Config.savedRealtimeModels
        }
    }

    @State private var selectedTier: Config.ModelTier = Config.modelTier
    @State private var selectedMode: AppMode = Config.appMode.isRealtime ? .openaiCompatibleRealtime : .direct
    @State private var realtimeModels = Config.savedRealtimeModels
    @State private var modeSelectionError: String?

    /// Which modes are selectable, and why not when they aren't. Read at display time so adding a
    /// key in Settings and coming back here shows the mode unlocked.
    private var modeOptions: [ConversationModeAvailability.Option] {
        ConversationModeAvailability.options(for: ConversationModeAvailability.current)
    }

    @ViewBuilder
    private var modelContent: some View {
        let savedModels = Config.savedModels
        // Live servers have their own credentials and do not require a saved text model.
        Group {
            List {
                Section {
                    Picker("Mode", selection: $selectedMode) {
                        Text("Direct").tag(AppMode.direct)
                        Text("Realtime").tag(AppMode.openaiCompatibleRealtime)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedMode) { previous, mode in
                        guard let option = modeOptions.first(where: { $0.mode == mode }) else { return }
                        guard option.isAvailable else {
                            // Bounce back rather than switching into a mode that cannot start —
                            // the reason is shown in the footer, so the refusal is explained.
                            modeSelectionError = option.unavailableReason
                            selectedMode = previous
                            return
                        }
                        guard mode != appState.currentMode else { return }
                        modeSelectionError = nil
                        appState.switchMode(to: mode)
                    }
                    NavigationLink("Manage Realtime Models") {
                        RealtimeModelsView()
                    }
                } footer: {
                    if let modeSelectionError {
                        Text(modeSelectionError)
                    } else if let blocked = modeOptions.first(where: { $0.mode == selectedMode && !$0.isAvailable }),
                       let reason = blocked.unavailableReason {
                        Text(reason)
                    }
                }

                if selectedMode == .openaiCompatibleRealtime {
                    Section {
                        if realtimeModels.isEmpty {
                            Text("Add a realtime model in Settings, or open Manage Realtime Models above.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(realtimeModels), id: \.id) { (model: RealtimeModelConfig) in
                            realtimeModelRow(model)
                        }
                    } header: { Text("Realtime Model") }
                } else {
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
                        if savedModels.isEmpty {
                            Text("Add a text model in Settings to use Direct Mode.")
                                .foregroundStyle(.secondary)
                        } else {
                            modelRows(savedModels)
                        }
                    } header: {
                        Text("Model")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()
            .onAppear { realtimeModels = Config.savedRealtimeModels }
        }
    }

    private func realtimeModelRow(_ model: RealtimeModelConfig) -> some View {
        let protocolTitle = model.profile?.title ?? String(localized: "Unsupported protocol version")
        return OGSelectionRow(title: model.name, subtitle: protocolTitle,
                              isSelected: selectedRealtimeID == model.id,
                              accessibilityText: model.name + ", " + protocolTitle) {
            appState.selectRealtimeModel(model.id)
            dismiss()
        }
    }

    private var selectedRealtimeID: String {
        if appState.currentMode == .geminiLive { return "legacy-gemini" }
        if appState.currentMode == .openaiRealtime { return "legacy-openai" }
        return Config.activeRealtimeModel?.id ?? ""
    }

    private func modelRows(_ models: [ModelConfig]) -> some View {
        let activeId = Config.activeModelId
        return ForEach(Array(models), id: \.id) { (model: ModelConfig) in
            OGSelectionRow(
                title: model.name,
                subtitle: ModelRowSummary.subtitle(
                    provider: model.providerDisplayName,
                    modelId: model.model,
                    visionEnabled: model.visionEnabled
                ),
                isSelected: model.id == activeId,
                accessibilityText: ModelRowSummary.spoken(
                    name: model.name,
                    provider: model.providerDisplayName,
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
        CloudSharingReview.shared.run(pickedModelId: model.id)
        appState.llmService.clearHistory()
        appState.llmService.refreshActiveModel()

        // Picking a text model must not replace the independently configured live server.
        if appState.currentMode == .openaiCompatibleRealtime {
            dismiss()
            return
        }

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
