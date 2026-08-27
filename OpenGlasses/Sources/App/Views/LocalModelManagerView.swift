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
    @State private var failedLoadModelId: String?    // enables Try again after e.g. a headroom refusal
    @ScaledMetric(relativeTo: .body) private var loadTapTarget: CGFloat = 44

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
                    OGStatusLabel("Limited RAM — use models under 1 GB", kind: .warn)
                }
                // Live memory readout: refreshes while visible so the user can watch a
                // model load/unload. Sandboxing limits this to the app's own numbers —
                // other apps' memory isn't visible from inside an iOS app.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    LabeledContent("App memory", value: formatBytes(MemoryHeadroom.appFootprintBytes()))
                }
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let available = MemoryHeadroom.availableBytes()
                    LabeledContent("Headroom", value: available > 0 ? formatBytes(available) : "—")
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Headroom is how much more memory the app can use before iOS terminates it. A model won't load unless it fits in the current headroom with room to generate.")
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
                                    OGSelectionCheck(selectedModelId == modelId)
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
                    VStack(alignment: .leading, spacing: 8) {
                        OGStatusLabel(loadError, kind: .error, systemImage: "exclamationmark.triangle")
                        if let failedLoadModelId {
                            // Retry seam for the headroom gate: the user swipes other apps
                            // away, watches headroom recover, and retries without leaving
                            // the screen.
                            HStack(spacing: 12) {
                                Button("Try again") { loadLocalModel(failedLoadModelId) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(loadingModelId != nil)
                                TimelineView(.periodic(from: .now, by: 2)) { _ in
                                    let available = MemoryHeadroom.availableBytes()
                                    if available > 0 {
                                        Text("Headroom now: \(formatBytes(available))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
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
                                            .foregroundStyle(OGTheme.okLabel)
                                    }
                                }
                            }
                            Spacer()

                            if downloadedIds.contains(model.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(OGTheme.okLabel)
                            } else if downloadingModelId == model.id, let service = localService {
                                // Own subview so the service's @Published progress actually
                                // re-renders it — read through the computed optional above,
                                // nothing observed the service and the bar never moved.
                                DownloadProgressRow(service: service) {
                                    service.cancelDownload()
                                    downloadingModelId = nil
                                }
                            } else if !model.isCompatibleWithDevice {
                                // The model's OWN requirement — this badge was hardcoded
                                // "Needs 8 GB" and misreported every other tier.
                                Label("Needs \(Int(model.minimumRAMGB)) GB", systemImage: "memorychip")
                                    .font(.caption)
                                    .foregroundStyle(OGTheme.warnLabel)
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
                Text("These models are tested on iPhone and optimized for size. Larger models need more RAM. Keep the app open while downloading — the screen stays awake automatically.")
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
                    OGStatusLabel(error, kind: .error, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .navigationTitle("Local Models")
        .ogFormStyle()
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
            } catch is CancellationError {
                downloadingModelId = nil   // BK P5: user cancelled — not an error to surface
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
                    .foregroundStyle(OGTheme.okLabel)
                    .frame(minWidth: loadTapTarget, minHeight: loadTapTarget)
                    .contentShape(Rectangle())
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
                    .frame(minWidth: loadTapTarget, minHeight: loadTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(loadingModelId != nil)
        }
    }

    private func loadLocalModel(_ modelId: String) {
        loadingModelId = modelId
        loadError = nil
        failedLoadModelId = nil
        Task {
            do {
                try await localService?.loadModel(modelId)
                loadedLocalModelId = modelId
            } catch {
                loadError = error.localizedDescription
                failedLoadModelId = modelId
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

/// Shared with the first-run offline-model offer (Plan DH P2), which drives the same service call
/// — one download path in the app, so cancel, resume and the progress reading cannot diverge.
///
/// Observes the service so the download progress actually updates — with a live percentage,
/// because a multi-GB pull with no numbers reads as a hang. A compact spinner + percent, not a
/// linear bar: the bar-plus-Cancel cluster was wide enough to crush the model name and its
/// Vision/Tools badges in the same row.
struct DownloadProgressRow: View {
    @ObservedObject var service: LocalLLMService
    let onCancel: () -> Void
    @ScaledMetric(relativeTo: .body) private var cancelTapTarget: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            if service.downloadProgress > 0 {
                Text("\(Int(service.downloadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // BK P5: a real Cancel — routes through the service so the in-flight
            // download is actually stopped, not just hidden.
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: cancelTapTarget, minHeight: cancelTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel download")
        }
    }
}
