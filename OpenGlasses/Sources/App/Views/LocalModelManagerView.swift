import SwiftUI

/// Download, manage, and select local LLM models for on-device inference.
struct LocalModelManagerView: View {
    @EnvironmentObject var appState: AppState
    @State private var downloadedIds: [String] = []
    @State private var selectedModelId: String = ""
    @State private var textModelId: String = Config.localTextModelId
    @State private var visionModelId: String = Config.localVisionModelId
    @State private var customModelId = ""
    @State private var downloadingModelId: String?
    @State private var downloadError: String?
    @State private var loadingModelId: String?
    @State private var loadedLocalModelId: String?   // mirrors the in-memory loaded model for the UI
    @State private var loadError: String?

    private var localService: LocalLLMService? {
        appState.llmService.localLLMService
    }


    var body: some View {
        List {
            // MARK: Device Info
            Section {
                let totalRAM = ProcessInfo.processInfo.physicalMemory
                let ramGB = Double(totalRAM) / 1_073_741_824
                LabeledContent("Device RAM", value: String(format: "%.1f GB", ramGB))
                if ramGB < 4 {
                    Label("Limited RAM — use models under 1 GB", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Device")
            }

            // MARK: Downloaded Models
            Section {
                if downloadedIds.isEmpty {
                    Text("No models downloaded yet. Pick one below to get started.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloadedIds, id: \.self) { modelId in
                        HStack(spacing: 10) {
                            Button {
                                selectModel(modelId)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(modelDisplayName(modelId))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(formatBytes(localService?.modelSizeOnDisk(modelId) ?? 0))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if selectedModelId == modelId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color(.label))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 0)

                            loadControl(for: modelId)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteModel(modelId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Downloaded Models")
            } footer: {
                Text("Tap a model to select it. Tap Load to bring it into memory now (so the first reply is instant) — or Unload to free memory. Swipe left to delete.")
            }

            // MARK: Recommended Models
            Section {
                ForEach(LocalLLMService.recommendedModels) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(model.estimatedSize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if model.hasVision {
                                        Label("Vision", systemImage: "eye")
                                            .font(.caption2)
                                            .foregroundStyle(Color(.label))
                                    }
                                    if model.hasToolCalling {
                                        Label("Tools", systemImage: "wrench")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            Spacer()

                            if downloadedIds.contains(model.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if downloadingModelId == model.id {
                                ProgressView(value: localService?.downloadProgress ?? 0)
                                    .frame(width: 60)
                            } else if !model.isCompatibleWithDevice {
                                Label("Needs 8 GB", systemImage: "memorychip")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Button("Download") {
                                    downloadModel(model.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.primary)
                            }
                        }

                        Text(model.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Recommended")
            } footer: {
                Text("These models are tested on iPhone and optimized for size. Larger models need more RAM.")
            }

            // MARK: Custom Model
            Section {
                HStack {
                    TextField("HuggingFace model ID", text: $customModelId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Download") {
                        let id = customModelId.trimmingCharacters(in: .whitespaces)
                        guard !id.isEmpty else { return }
                        downloadModel(id)
                    }
                    .disabled(customModelId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Custom Model")
            } footer: {
                Text("Paste any HuggingFace MLX model ID, e.g. \"mlx-community/phi-3-mini-4k-instruct-4bit\"")
            }

            // MARK: Error
            if let error = downloadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Local Models")
        .onAppear {
            refreshDownloaded()
            // Set initial selection from active model config
            if let activeModel = Config.activeModel, activeModel.llmProvider == .local {
                selectedModelId = activeModel.model
            }
        }
    }

    private func selectModel(_ modelId: String) {
        selectedModelId = modelId
        // Update the active model config if one exists for local provider
        var models = Config.savedModels
        if let idx = models.firstIndex(where: { $0.llmProvider == .local }) {
            models[idx].model = modelId
            Config.setSavedModels(models)
            appState.llmService.refreshActiveModel()
        }
    }

    private func downloadModel(_ modelId: String) {
        downloadingModelId = modelId
        downloadError = nil
        Task {
            do {
                try await localService?.downloadModel(modelId)
                refreshDownloaded()
                downloadingModelId = nil
            } catch {
                downloadError = error.localizedDescription
                downloadingModelId = nil
            }
        }
    }

    private func deleteModel(_ modelId: String) {
        try? localService?.deleteModel(modelId)
        refreshDownloaded()
    }

    private func refreshDownloaded() {
        downloadedIds = localService?.downloadedModelIds() ?? []
        loadedLocalModelId = (localService?.isModelLoaded == true) ? localService?.loadedModelId : nil
    }

    // MARK: - Manual load / unload

    /// Load/Unload control for a downloaded model — lets the user choose when the
    /// (heavy) model is brought into memory, instead of it loading lazily on first use.
    @ViewBuilder
    private func loadControl(for modelId: String) -> some View {
        if loadingModelId == modelId {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if loadedLocalModelId == modelId {
            Button { unloadLocalModel() } label: {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Model loaded — tap to unload")
        } else {
            Button { loadLocalModel(modelId) } label: {
                Text("Load")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.borderless)
            .disabled(loadingModelId != nil)
        }
    }

    private func loadLocalModel(_ modelId: String) {
        loadingModelId = modelId
        loadError = nil
        Task {
            do {
                try await localService?.loadModel(modelId)
                loadedLocalModelId = modelId
            } catch {
                loadError = error.localizedDescription
            }
            loadingModelId = nil
        }
    }

    private func unloadLocalModel() {
        localService?.unloadModel()
        loadedLocalModelId = nil
    }

    private func modelDisplayName(_ modelId: String) -> String {
        // "mlx-community/gemma-2-2b-it-4bit" → "gemma-2-2b-it-4bit"
        if let name = modelId.split(separator: "/").last {
            return String(name)
        }
        return modelId
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
