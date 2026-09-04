import SwiftUI

/// Download, manage, and select local LLM models for on-device inference.
///
/// The screen covers two runtimes now (MLX and GGUF) and two acquisition paths, so the parts that
/// used to be inline `if`s are values: `LocalModelRowState` decides what a row is about,
/// `LocalModelPresentation` writes what it says, `LocalModelAcquisition` owns the download
/// pipeline, and `LocalRuntimeDiagnostics` holds what the last on-device run measured. What is left
/// here is layout and the actions.
///
/// The two acquisition paths are deliberately **not** merged. MLX models are hub snapshots with no
/// pinned revision and no published digests — the verified pipeline refuses them by construction,
/// and it is right to. They keep the fetch they have always had; GGUF models, whose bytes are
/// pinned and checksummed, go through the download manager.
struct LocalModelManagerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var acquisition = LocalModelAcquisition.shared

    @State private var legacyDownloadedIds: [String] = []
    @State private var selectedModelId: String = ""
    @State private var customModelId = ""
    @State private var downloadingModelId: String?
    @State private var downloadError: String?

    @State private var loadingModelId: LocalModelID?
    @State private var residentModelId: LocalModelID?
    @State private var loadError: String?
    @State private var failedLoadModelId: LocalModelID?
    /// Reasons recorded by a failed load this session. In memory: a model that was refused because
    /// its runtime was switched off must get a fresh chance the moment it is switched back on.
    @State private var incompatibilities: [LocalModelID: LocalModelIncompatibility] = [:]

    @State private var runtimeFilter: LocalModelPresentation.RuntimeFilter = .all
    @State private var capabilityFilter: LocalModelPresentation.CapabilityFilter = .all

    @State private var pendingRemoval: PendingRemoval?
    @State private var reasonOnScreen: LocalModelIncompatibility?
    @State private var showImportSheet = false

    @ScaledMetric(relativeTo: .body) private var loadTapTarget: CGFloat = 44

    /// How often the staged rows re-read the pipeline while the screen is up. Fast enough for a
    /// progress bar, slow enough that a plan read is not a per-frame disk hit.
    private static let progressRefreshInterval: Duration = .milliseconds(1200)

    private struct PendingRemoval: Identifiable {
        let id: LocalModelID
        let displayName: String
        let message: String
    }

    private var localService: LocalLLMService? {
        appState.llmService.localLLMService
    }

    private var ggufEnabled: Bool { Config.ggufModelsEnabled }

    var body: some View {
        List {
            deviceSection
            filterSection
            installedSection
            recommendedSection
            if ggufEnabled { ggufCatalogSection }
            customSection
            diagnosticsSection
            if let error = downloadError ?? acquisition.errorMessage {
                Section {
                    OGStatusLabel(error, kind: .error, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .navigationTitle("Local Models")
        .ogFormStyle()
        .task { await refreshEverything() }
        .task(id: acquisition.staging.isEmpty) {
            // Only polls while something is staged; an idle screen does no disk work.
            guard !acquisition.staging.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressRefreshInterval)
                if Task.isCancelled { return }
                await acquisition.refreshPlans()
            }
        }
        .onDisappear(perform: announceBackgroundContinuation)
        .sheet(isPresented: $showImportSheet) {
            LocalModelImportSheet(acquisition: acquisition)
        }
        .confirmationDialog("Remove model",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRemoval) { removal in
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                Task { await remove(removal.id) }
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        } message: { removal in
            Text(removal.message)
        }
        .alert("Why this model can't run",
               isPresented: Binding(get: { reasonOnScreen != nil },
                                    set: { if !$0 { reasonOnScreen = nil } }),
               presenting: reasonOnScreen) { _ in
            Button("OK", role: .cancel) { reasonOnScreen = nil }
        } message: { reason in
            Text(reason.explanation)
        }
    }

    // MARK: - Device

    private var deviceSection: some View {
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
                LabeledContent("App memory",
                               value: LocalModelPresentation.formatBytes(
                                   MemoryHeadroom.appFootprintBytes()))
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let available = MemoryHeadroom.availableBytes()
                LabeledContent("Headroom",
                               value: available > 0
                                   ? LocalModelPresentation.formatBytes(available) : "—")
            }
        } header: {
            Text("Device")
        } footer: {
            Text("Headroom is how much more memory the app can use before iOS terminates it. A model won't load unless it fits in the current headroom with room to generate.")
        }
    }

    // MARK: - Filters

    private var filterSection: some View {
        Section {
            Picker("Runtime", selection: $runtimeFilter) {
                ForEach(LocalModelPresentation.RuntimeFilter.allCases, id: \.self) { filter in
                    Text(filter.title)
                        .accessibilityLabel(filter.spokenLabel)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Filter by runtime")

            Picker("Capability", selection: $capabilityFilter) {
                ForEach(LocalModelPresentation.CapabilityFilter.allCases, id: \.self) { filter in
                    Text(filter.title)
                        .accessibilityLabel(filter.spokenLabel)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Filter by capability")
        } header: {
            Text("Show")
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        Section {
            let rows = filtered(installedRows)
            if rows.isEmpty {
                Text(installedRows.isEmpty
                         ? "No models downloaded yet. Pick one below to get started."
                         : "No downloaded models match this filter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    installedRow(row)
                }
            }
            if let loadError {
                loadFailureNotice(loadError)
            }
            if let notice = acquisition.backgroundContinuationNotice() {
                // The plan requires this said explicitly, and it has to be *visible* as well as
                // spoken: the announcement on leaving reaches VoiceOver only, and a sighted person
                // backing out of a half-finished download deserves the same reassurance.
                OGStatusLabel(notice, kind: .ok, systemImage: "arrow.down.circle")
            }
        } header: {
            Text("On this iPhone")
        } footer: {
            Text("Tap a model to select it. Load brings it into memory now, so the first reply is instant; Unload frees that memory. Swipe left to remove it.")
        }
    }

    @ViewBuilder
    private func installedRow(_ row: ManagedModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    select(row.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.descriptor.displayName)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            badgeStrip(row)
                        }
                        OGSelectionCheck(selectedModelId == row.id.rawValue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.isIncompatible)

                Spacer(minLength: 0)

                loadControl(for: row)
            }

            sizeFactsStrip(row)

            if case .staged(let staging) = row.state {
                stagingControls(row, staging: staging)
            }
            if case .incompatible(let reason) = row.state {
                Button("Why can't this run?") { reasonOnScreen = reason }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(reason.spokenLabel)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmRemoval(row)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// Badges never carry meaning in colour alone: each one supplies its own spoken sentence, and
    /// the row groups them into a single element so VoiceOver reads them as one description rather
    /// than as six stops.
    private func badgeStrip(_ row: ManagedModel) -> some View {
        let badges = LocalModelPresentation.rowBadges(state: row.state, descriptor: row.descriptor)
        return HStack(spacing: 6) {
            ForEach(badges) { badge in
                Label {
                    Text(badge.text)
                } icon: {
                    if let glyph = badge.systemImage { Image(systemName: glyph) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint(for: badge.emphasis))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.quaternarySystemFill),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badges.map(\.spokenLabel).joined(separator: ". "))
    }

    private func tint(for emphasis: LocalModelBadge.Emphasis) -> Color {
        switch emphasis {
        case .neutral: return .secondary
        case .positive: return OGTheme.okLabel
        case .caution: return OGTheme.warnLabel
        case .critical: return OGTheme.errorLabel
        }
    }

    private func sizeFactsStrip(_ row: ManagedModel) -> some View {
        let facts = LocalModelPresentation.sizeFacts(descriptor: row.descriptor,
                                                     onDiskBytes: row.onDiskBytes)
        return Text(facts.map { "\($0.label) \($0.value)" }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(facts.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
    }

    @ViewBuilder
    private func stagingControls(_ row: ManagedModel, staging: LocalModelStagingSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if staging.isRetryable {
                if case .retryable(let reason) = staging.phase {
                    OGStatusLabel(LocalModelRowState.retryExplanation(reason), kind: .warn)
                }
                Button("Try again") { Task { await acquisition.retry(row.id) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                ProgressView(value: staging.fractionCompleted)
                    .accessibilityLabel(row.state.spokenLabel)
                    .accessibilityValue("\(Int(staging.fractionCompleted * 100)) percent")
                HStack {
                    Text(fileProgressCaption(staging))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { Task { await acquisition.cancel(row.id) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Cancel the download of \(row.descriptor.displayName)")
                }
            }
        }
    }

    private func fileProgressCaption(_ staging: LocalModelStagingSummary) -> String {
        let sizes = "\(LocalModelPresentation.formatBytes(staging.completedBytes))"
            + " of \(LocalModelPresentation.formatBytes(staging.totalBytes))"
        guard let number = staging.fileNumber, staging.fileCount > 1 else { return sizes }
        return "File \(number) of \(staging.fileCount) · \(sizes)"
    }

    @ViewBuilder
    private func loadFailureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OGStatusLabel(message, kind: .error, systemImage: "exclamationmark.triangle")
            if let failedLoadModelId {
                // Retry seam for the headroom gate: the user swipes other apps
                // away, watches headroom recover, and retries without leaving
                // the screen.
                HStack(spacing: 12) {
                    Button("Try again") { load(failedLoadModelId) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(loadingModelId != nil)
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        let available = MemoryHeadroom.availableBytes()
                        if available > 0 {
                            Text("Headroom now: \(LocalModelPresentation.formatBytes(available))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recommended (MLX)

    private var recommendedSection: some View {
        Section {
            let entries = LocalModelCatalog.entries.filter {
                isVisible($0.descriptor) && !isInstalled($0.descriptor.id)
            }
            if entries.isEmpty {
                Text("No MLX models match this filter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.descriptor.id) { entry in
                catalogRow(entry: entry)
            }
        } header: {
            Text("Recommended")
        } footer: {
            Text("These models are tested on iPhone and optimized for size. Larger models need more RAM. Keep the app open while downloading — the screen stays awake automatically.")
        }
    }

    @ViewBuilder
    private func catalogRow(entry: LocalModelCatalog.Entry) -> some View {
        let compatible = ProcessInfo.processInfo.physicalMemory
            >= UInt64(entry.minimumRAMGB * 1_073_741_824)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.descriptor.displayName).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(entry.estimatedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(LocalModelPresentation
                            .capabilityBadges(entry.descriptor.capabilities)) { badge in
                            Label(badge.text, systemImage: badge.systemImage ?? "circle")
                                .font(.caption2)
                                .foregroundStyle(OGTheme.okLabel)
                                .accessibilityLabel(badge.spokenLabel)
                        }
                    }
                }
                Spacer()

                if downloadingModelId == entry.descriptor.id.rawValue, let service = localService {
                    DownloadProgressRow(service: service) {
                        service.cancelDownload()
                        downloadingModelId = nil
                    }
                } else if !compatible {
                    // The model's OWN requirement — this badge was hardcoded
                    // "Needs 8 GB" and misreported every other tier.
                    Label("Needs \(Int(entry.minimumRAMGB)) GB", systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(OGTheme.warnLabel)
                } else {
                    Button("Download") { downloadMLXModel(entry.descriptor.id.rawValue) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.primary)
                        .accessibilityLabel("Download \(entry.descriptor.displayName), "
                                                + "\(entry.estimatedSize)")
                }
            }
            Text(entry.notes)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Curated GGUF

    private var ggufCatalogSection: some View {
        Section {
            let entries = LocalModelCatalog.bundledGGUFEntries().filter {
                isVisible($0.descriptor) && !isInstalled($0.id) && acquisition.staging[$0.id] == nil
            }
            if entries.isEmpty {
                Text("No GGUF models match this filter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.id) { entry in
                ggufCatalogRow(entry)
            }
        } header: {
            Text("GGUF models")
        } footer: {
            Text("Each of these is pinned to an exact version and checked against its published checksum before it's installed.")
        }
    }

    @ViewBuilder
    private func ggufCatalogRow(_ entry: LocalModelCatalog.GGUFEntry) -> some View {
        let fit = acquisition.fitReport(for: entry.descriptor)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.descriptor.displayName).lineLimit(2)
                    HStack(spacing: 6) {
                        ForEach([LocalModelPresentation.runtimeBadge(entry.descriptor.runtime)]
                            + (LocalModelPresentation
                                .quantizationBadge(entry.descriptor.quantization)
                                .map { [$0] } ?? [])) { badge in
                            Text(badge.text)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(badge.spokenLabel)
                        }
                        Text(LocalModelPresentation.formatBytes(fit.downloadBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Download") {
                    Task {
                        await acquisition.startDownload(descriptor: entry.descriptor,
                                                        origin: .curatedCatalog)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.primary)
                .disabled(!fit.canInstall || acquisition.isWorking)
                .accessibilityLabel("Download \(entry.descriptor.displayName), "
                                        + LocalModelPresentation.formatBytes(fit.downloadBytes))
                .accessibilityHint(fit.canInstall
                                       ? LocalModelPresentation.verdictText(fit.loadVerdict)
                                       : (fit.blockers.first?.localizedMessage ?? ""))
            }
            if !entry.notes.isEmpty {
                Text(entry.notes).font(.caption).foregroundStyle(.secondary)
            }
            if let blocker = fit.blockers.first {
                OGStatusLabel(blocker.localizedMessage, kind: .error)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Custom

    private var customSection: some View {
        Section {
            if ggufEnabled {
                Button {
                    showImportSheet = true
                } label: {
                    Label("Import from a repository", systemImage: "square.and.arrow.down.on.square")
                }
                .accessibilityHint("Choose a GGUF model from a public model repository.")
            }
            HStack {
                TextField("MLX model ID", text: $customModelId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Custom MLX model ID")
                Button("Download") {
                    let id = customModelId.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty else { return }
                    downloadMLXModel(id)
                }
                .disabled(customModelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add a model")
        } footer: {
            Text(ggufEnabled
                     ? "Repository imports are pinned to an exact version and verified against a published checksum. An MLX model ID is fetched whole from the hub, as it always has been."
                     : "Paste any MLX model ID, e.g. \"mlx-community/phi-3-mini-4k-instruct-4bit\". GGUF models are turned off — turn them on to import from a repository.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            LocalModelDiagnosticsCard()
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("What the last on-device run measured. Speed and first-token time depend on the model, the context length and how warm the phone is.")
        }
    }

    // MARK: - Row assembly

    /// One row's worth of facts, whatever the model's provenance.
    private struct ManagedModel: Identifiable {
        let id: LocalModelID
        let descriptor: LocalModelDescriptor
        let installation: InstalledLocalModel?
        let state: LocalModelRowState
        let onDiskBytes: Int64?

        var isIncompatible: Bool {
            if case .incompatible = state { return true }
            return false
        }
    }

    /// Everything on this iPhone: installation records, anything still staging, and any MLX
    /// snapshot on disk that has no record yet.
    ///
    /// The last of those matters more than it looks: the installed-records migration is allowed to
    /// defer or fail, and a screen that listed only records would tell a user their models were
    /// gone when they are sitting on disk exactly where they were.
    private var installedRows: [ManagedModel] {
        var rows: [LocalModelID: ManagedModel] = [:]

        for installation in acquisition.installed {
            rows[installation.id] = makeRow(descriptor: installation.descriptor,
                                            installation: installation)
        }
        for rawID in legacyDownloadedIds {
            let id = LocalModelID(rawID)
            guard rows[id] == nil else { continue }
            let descriptor = LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: rawID)
            rows[id] = makeRow(descriptor: descriptor,
                               installation: LocalModelSelection.installation(for: id,
                                                                              repository: acquisition.repository))
        }
        for (id, descriptor) in acquisition.stagedDescriptors where rows[id] == nil {
            rows[id] = makeRow(descriptor: descriptor, installation: nil)
        }
        return rows.values.sorted { $0.descriptor.displayName < $1.descriptor.displayName }
    }

    private func makeRow(descriptor: LocalModelDescriptor,
                         installation: InstalledLocalModel?) -> ManagedModel {
        // The offered descriptor is the catalog's when there is one, so an installed model at an
        // older revision can be seen to be behind.
        let offered = LocalModelCatalog.bundledGGUFEntries()
            .first { $0.id == descriptor.id }?.descriptor
            ?? LocalModelCatalog.descriptor(for: descriptor.id)
            ?? descriptor
        let state = LocalModelRowState.derive(.init(
            descriptor: offered,
            installation: installation,
            plan: nil,
            isResident: residentModelId == descriptor.id,
            recordedIncompatibility: incompatibilities[descriptor.id],
            runtimeAvailability: availability(for: descriptor.runtime)))
        // Staging is applied on top rather than passed in: the acquisition object has already
        // folded the live byte reading into the summary, and rebuilding a plan here to re-derive
        // it would be a second answer to the same question.
        let resolved = acquisition.staging[descriptor.id].map { LocalModelRowState.staged($0) } ?? state
        return ManagedModel(id: descriptor.id,
                            descriptor: descriptor,
                            installation: installation,
                            state: resolved,
                            onDiskBytes: installation.flatMap { _ in
                                localService?.modelSizeOnDisk(descriptor.id.rawValue)
                            })
    }

    private func availability(for runtime: LocalModelRuntime) -> LocalModelRuntimeAvailability {
        switch runtime {
        case .mlx: return .available
        case .llamaCpp: return ggufEnabled ? .available : .disabled
        }
    }

    private func isInstalled(_ id: LocalModelID) -> Bool {
        acquisition.repository.isInstalled(id) || legacyDownloadedIds.contains(id.rawValue)
    }

    private func isVisible(_ descriptor: LocalModelDescriptor) -> Bool {
        runtimeFilter.accepts(descriptor.runtime)
            && capabilityFilter.accepts(descriptor.capabilities)
    }

    private func filtered(_ rows: [ManagedModel]) -> [ManagedModel] {
        rows.filter { isVisible($0.descriptor) }
    }

    // MARK: - Actions

    private func refreshEverything() async {
        legacyDownloadedIds = localService?.downloadedModelIds() ?? []
        acquisition.releaseResident = { [weak appState] id in
            guard let coordinator = appState?.llmService.localInferenceCoordinator() else { return }
            if await coordinator.loadedModel?.id == id { await coordinator.unload() }
        }
        await acquisition.restore()
        await refreshResident()
        if let activeModel = Config.activeModel, activeModel.llmProvider == .local {
            selectedModelId = LocalModelSelection.store(repository: acquisition.repository)
                .selectedID()?.rawValue ?? activeModel.model
        }
    }

    private func refreshResident() async {
        if let coordinator = appState.llmService.localInferenceCoordinator(),
           let loaded = await coordinator.loadedModel {
            residentModelId = loaded.id
            return
        }
        // The direct MLX route is still the shipping path with the coordinator flag off, and it is
        // the same service either way — so what it reports is the truth about residency.
        residentModelId = (localService?.isModelLoaded == true)
            ? localService?.loadedModelId.map { LocalModelID($0) }
            : nil
    }

    /// Record the selection as a stable id, and keep the legacy string field in step.
    private func select(_ id: LocalModelID) {
        selectedModelId = id.rawValue
        LocalModelSelection.store(repository: acquisition.repository).select(id)
        appState.llmService.refreshActiveModel()
    }

    /// The MLX fetch, unchanged. It cannot go through the verified pipeline: an MLX entry has no
    /// pinned revision and no per-file digests, which `installationFaults()` refuses on purpose.
    private func downloadMLXModel(_ modelId: String) {
        downloadingModelId = modelId
        downloadError = nil
        Task {
            do {
                try await localService?.downloadModel(modelId)
                legacyDownloadedIds = localService?.downloadedModelIds() ?? []
                await acquisition.refresh()
                downloadingModelId = nil
                LocalModelAcquisition.post("\(modelId) downloaded.")
            } catch is CancellationError {
                downloadingModelId = nil   // user cancelled — not an error to surface
            } catch {
                downloadError = error.localizedDescription
                downloadingModelId = nil
            }
        }
    }

    private func confirmRemoval(_ row: ManagedModel) {
        pendingRemoval = PendingRemoval(
            id: row.id,
            displayName: row.descriptor.displayName,
            message: acquisition.removalConfirmation(for: row.id,
                                                     displayName: row.descriptor.displayName))
    }

    private func remove(_ id: LocalModelID) async {
        if acquisition.repository.isInstalled(id) {
            await acquisition.delete(id)
        } else {
            await acquisition.cancel(id)
        }
        // A legacy hub snapshot has a record pointing at it but its bytes live in the MLX cache;
        // removing the record alone would leave the weights on disk.
        if legacyDownloadedIds.contains(id.rawValue) {
            try? localService?.deleteModel(id.rawValue)
        }
        if residentModelId == id { residentModelId = nil }
        incompatibilities[id] = nil
        if selectedModelId == id.rawValue {
            LocalModelSelection.store(repository: acquisition.repository).clearSelection()
            selectedModelId = ""
        }
        legacyDownloadedIds = localService?.downloadedModelIds() ?? []
        await acquisition.refresh()
        await refreshResident()
    }

    // MARK: - Load / unload

    @ViewBuilder
    private func loadControl(for row: ManagedModel) -> some View {
        if case .staged = row.state {
            EmptyView()
        } else if row.isIncompatible {
            EmptyView()
        } else if loadingModelId == row.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if residentModelId == row.id {
            Button { unload() } label: {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OGTheme.okLabel)
                    .frame(minWidth: loadTapTarget, minHeight: loadTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(row.descriptor.displayName) is loaded — tap to unload")
        } else if row.installation != nil {
            Button { load(row.id) } label: {
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
            .accessibilityLabel("Load \(row.descriptor.displayName) into memory")
        }
    }

    /// Load through the coordinator whenever one exists, whatever the runtime.
    ///
    /// That is the point of the coordinator: it is the single owner of residency, so loading a GGUF
    /// model here evicts a resident MLX one rather than the two of them competing for the same
    /// memory. With no coordinator available the MLX service is used directly, exactly as before.
    private func load(_ id: LocalModelID) {
        loadingModelId = id
        loadError = nil
        failedLoadModelId = nil
        Task {
            let installation = LocalModelSelection.installation(for: id,
                                                                repository: acquisition.repository)
            do {
                if let coordinator = appState.llmService.localInferenceCoordinator() {
                    _ = try await coordinator.load(
                        installation,
                        configuration: LocalLoadConfiguration(
                            contextLength: installation.descriptor.contextLength > 0
                                ? installation.descriptor.contextLength
                                : LocalModelBudget.contextWindow(for: id.rawValue)))
                } else {
                    try await localService?.loadModel(id.rawValue)
                }
                incompatibilities[id] = nil
                LocalModelAcquisition.post("\(installation.descriptor.displayName) loaded.")
            } catch {
                // A typed refusal about the *model* is recorded as an incompatibility, which
                // changes the row and unlocks the reason action. Anything else stays a retryable
                // load error with its Try again button.
                if let incompatibility = LocalModelIncompatibility.from(error) {
                    incompatibilities[id] = incompatibility
                    loadError = nil
                    LocalModelAcquisition.post(incompatibility.spokenLabel)
                } else {
                    loadError = error.localizedDescription
                    failedLoadModelId = id
                }
            }
            loadingModelId = nil
            await refreshResident()
        }
    }

    private func unload() {
        Task {
            if let coordinator = appState.llmService.localInferenceCoordinator() {
                await coordinator.unload()
            }
            localService?.unloadModel()
            await refreshResident()
            LocalModelAcquisition.post("Model unloaded.")
        }
    }

    // MARK: - Leaving mid-download

    /// The plan's rule, said out loud: leaving the screen during a background download explicitly
    /// says the download continues.
    private func announceBackgroundContinuation() {
        guard let notice = acquisition.backgroundContinuationNotice() else { return }
        LocalModelAcquisition.post(notice)
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
