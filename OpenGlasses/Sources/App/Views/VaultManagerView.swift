import SwiftUI
import UniformTypeIdentifiers

/// Manage the reader's own vaults (Plan H). Import a folder containing
/// manifest.json + markdown + procedures/ + documents/, validated before install; list and remove
/// installed packs. Reference documents (OEM manuals) are chunked into the on-device document
/// store after install and shown per vault with their section counts.
@MainActor
struct VaultManagerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var installed: [VaultManifest] = VaultImporter.installedManifests()
    @State private var ledgers: [String: VaultDocumentLedger] = [:]
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var warnings: [String] = []
    @State private var syncProgress: (vaultId: String, title: String, completed: Int, total: Int)?
    /// Recognition runs before chunking for a scanned manual and is the slow part; it gets its own line.
    @State private var recognitionProgress: (title: String, done: Int, total: Int)?
    @State private var shareItem: ShareItem?
    /// Manual file names each vault's removal journal has an unfinished removal for. Re-read with
    /// the ledgers, because a removal interrupted by a previous launch is a state the list has to
    /// show — the manual is already unreachable and the row must not claim otherwise.
    @State private var pendingRemovals: [String: Set<String>] = [:]
    /// The manual a confirmation is up for.
    @State private var confirmingRemoval: ManualRemovalRequest?
    /// The removal currently running, so the row says so and everything that touches the same
    /// vault stands down until it returns.
    @State private var removalInFlight: ManualRemovalRequest?
    /// What the last removal attempt came to, and — when it can be retried — what to retry.
    @State private var removalOutcome: ManualRemovalOutcome?
    @StateObject private var packs = VaultPackCatalogService()
    @ObservedObject private var store = StoreKitService.shared

    /// One manual of one vault, named the way a removal is addressed: by the manifest's file name,
    /// never by the title a citation might have got wrong.
    private struct ManualRemovalRequest: Identifiable, Equatable {
        let vaultId: String
        let vaultName: String
        let file: String
        let title: String
        /// Finishing a removal that was interrupted rather than starting a new one.
        let isRetry: Bool
        var id: String { "\(vaultId)/\(file)" }
    }

    private struct ManualRemovalOutcome: Equatable {
        let outcome: VaultManualRemovalPresentation.Outcome
        /// Non-nil when the message comes with a Retry.
        let retry: ManualRemovalRequest?
    }

    /// Vaults of your own are a capability, not a tier; the import button says what is missing
    /// instead of failing later, and asks exactly what the importer asks.
    private var ownVaultsGate: CustomVaultGateState { CustomVaultGateState.current() }

    var body: some View {
        Form {
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import Vault Folder…", systemImage: "square.and.arrow.down")
                }
                .disabled(syncProgress != nil || removalInFlight != nil || !ownVaultsGate.allowsImport)
                if let explanation = ownVaultsGate.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Select a folder containing manifest.json, the listed markdown files, an optional procedures/ directory, and any manuals the manifest lists under documents (PDF, EPUB, Markdown, or text). The pack is validated before it's installed; manuals are indexed on this device for retrieval.")
            }

            packsSection

            if !installed.isEmpty {
                Section {
                    ForEach(installed, id: \.id) { manifest in
                        vaultRow(manifest)
                            // A vault with a removal running is mid-rewrite of the manifest the
                            // uninstall would read; the swipe stands down until it finishes.
                            .deleteDisabled(isBusy(manifest.id))
                    }
                    .onDelete(perform: remove)
                } header: {
                    Text("Installed Vaults")
                } footer: {
                    Text("Swipe a vault to export it as a folder — manifest.json, the markdown with your in-app edits, and procedures/. Manuals stay on this phone: the export still lists the ones the vault needs, and whoever imports it adds those files themselves. Removing one manual leaves the rest of its vault working.")
                }
            }

            if let syncProgress {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if let recognitionProgress, recognitionProgress.done < recognitionProgress.total {
                            Text("Reading \(recognitionProgress.title) — page \(recognitionProgress.done + 1) of \(recognitionProgress.total) by recognition…")
                            ProgressView(value: Double(recognitionProgress.done), total: Double(max(recognitionProgress.total, 1)))
                            Text("Scanned pages are read on this phone. Keep the app open; an interrupted read resumes where it stopped.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("Indexing \(syncProgress.title)…")
                            ProgressView(value: Double(syncProgress.completed), total: Double(max(syncProgress.total, 1)))
                        }
                    }
                }
            }

            if let removalInFlight {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Removing \(removalInFlight.title)…")
                        ProgressView()
                        Text("The manual is already unavailable to answers. Keep the app open until this finishes.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let removalOutcome {
                Section {
                    OGStatusLabel(removalOutcome.outcome.message,
                                  kind: removalOutcome.outcome.isFailure ? .error : .ok)
                    if let retry = removalOutcome.retry {
                        Button("Retry removal") {
                            self.removalOutcome = nil
                            Task { await performRemoval(retry) }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .disabled(isBusy(retry.vaultId))
                    }
                }
            }

            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Warnings")
                }
            }

            if let successMessage {
                Section { Text(successMessage).font(.caption).foregroundStyle(OGTheme.okLabel) }
            }
        }
        .navigationTitle("Custom Vaults")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear {
            reloadLedgers()
            if case .idle = packs.catalogState { Task { await packs.loadCatalog() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            handleImport(result)
        }
        .alert("Failed", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Destructive and named. The vault's own delete is a swipe on the vault row; this is a
        // button under one manual, and the message says which manual of which vault it is.
        .confirmationDialog(VaultManualRemovalPresentation.confirmationTitle(manual: confirmingRemoval?.title ?? ""),
                            isPresented: Binding(get: { confirmingRemoval != nil },
                                                 set: { if !$0 { confirmingRemoval = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmingRemoval) { request in
            // Two literals rather than one ternary, so both stay in the string catalogue.
            if request.isRetry {
                Button("Finish removing", role: .destructive) { confirm(request) }
            } else {
                Button("Remove manual", role: .destructive) { confirm(request) }
            }
            Button("Keep", role: .cancel) { confirmingRemoval = nil }
        } message: { request in
            Text(VaultManualRemovalPresentation.confirmationMessage(manual: request.title,
                                                                    vault: request.vaultName))
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
    }

    // MARK: - Packs (Plan EG)

    @ViewBuilder
    private var packsSection: some View {
        Section {
            switch packs.catalogState {
            case .idle, .loading:
                Text("Loading packs…").foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await packs.loadCatalog() } }.font(.caption)
            case .loaded(let entries):
                if entries.isEmpty {
                    Text("No packs are published yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in packRow(entry) }
                }
            }
        } header: {
            Text("Packs")
        } footer: {
            Text("Authored vaults, signed by the vendor: fault codes, nameplate references, safety rules and procedures for a trade. Packs never include manufacturer manuals; add your own to a pack the same way as to any vault.")
        }
    }

    @ViewBuilder
    private func packRow(_ entry: VaultPackCatalogEntry) -> some View {
        let state = packs.rowState(for: entry)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                Spacer()
                Text("v\(entry.version)").font(.caption2).foregroundStyle(.secondary)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
            }
            if let author = entry.author, !author.isEmpty {
                Text("By \(author)").font(.caption2).foregroundStyle(.secondary)
            }
            switch packs.installStates[entry.id] {
            case .downloading?: Text("Downloading…").font(.caption)
            case .installing?: Text("Installing…").font(.caption)
            case .failed(let reason)?: Text(reason).font(.caption).foregroundStyle(OGTheme.errorLabel)
            case .installed(let warnings)?:
                if !warnings.isEmpty { Text(warnings.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary) }
            case nil: EmptyView()
            }
            packAction(entry, state: state)
        }
    }

    @ViewBuilder
    private func packAction(_ entry: VaultPackCatalogEntry, state: VaultPackRowState) -> some View {
        let busy = packs.installStates[entry.id] == .downloading || packs.installStates[entry.id] == .installing
        switch state {
        case .needsNewerApp(let minBuild):
            Text("Needs app build \(minBuild) or newer.").font(.caption).foregroundStyle(.secondary)
        case .needsFieldAssist:
            Text("Unlock Field Assist to use packs.").font(.caption).foregroundStyle(.secondary)
        case .buy(let productId):
            if let product = store.loadedProduct(id: productId) {
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    HStack { Text("Buy"); Spacer(); Text(product.displayPrice).foregroundStyle(.secondary) }
                }
                .disabled(store.isPurchasing)
            } else {
                Text("Price unavailable right now. Check your connection and App Store sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .install:
            Button("Install") { Task { await packs.install(entry); reloadLedgers() } }.disabled(busy)
        case .update(let installedVersion):
            Button("Update from v\(installedVersion)") { Task { await packs.install(entry); reloadLedgers() } }.disabled(busy)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(OGTheme.okLabel)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func vaultRow(_ manifest: VaultManifest) -> some View {
        let ledger = ledgers[manifest.id] ?? VaultDocumentLedger()
        let pack = VaultImporter.installedPack(for: manifest.id)
        VStack(alignment: .leading, spacing: 4) {
            Text(manifest.name)
            Text("\(manifest.id) · v\(manifest.version) · \(manifest.files.count) files")
                .font(.caption).foregroundStyle(.secondary)
            if let pack {
                Text("Pack v\(pack.version)\(pack.author.map { " · by \($0)" } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if manifest.hasDocuments {
                let rows = manualRows(for: manifest, ledger: ledger)
                ForEach(rows) { row in
                    manualRow(row, manifest: manifest, ledger: ledger)
                }
                // The same sentence for every manual of a signed pack, so it is said once.
                if let reason = rows.compactMap(\.unavailableReason).first {
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Re-index manuals") {
                    Task { await sync(manifest) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(syncProgress != nil || isBusy(manifest.id))
            }
        }
        .swipeActions(edge: .leading) {
            if VaultExporter.isExportable(manifest) {
                Button {
                    exportVault(manifest)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .tint(AppAccent.color)
            }
        }
    }

    /// One manual: what it is, what the index has of it, and — for a vault the reader imported —
    /// the action that takes it out. The action sits under the manual it belongs to and nowhere
    /// near the swipe that deletes the whole vault.
    @ViewBuilder
    private func manualRow(_ row: VaultManualRowState, manifest: VaultManifest,
                           ledger: VaultDocumentLedger) -> some View {
        let entry = ledger.entries.first { $0.file == row.file }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: row.isPendingRemoval ? "doc.badge.ellipsis" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.title)
                    .font(.caption)
                Spacer()
                Text(row.statusText)
                    .font(.caption2)
                    .foregroundStyle(row.isStatusAdverse || (entry?.lowConfidencePages ?? 0) > 0
                                     ? OGTheme.errorLabel : .secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.accessibilityLabel))

            if let action = row.action {
                let request = ManualRemovalRequest(vaultId: manifest.id, vaultName: manifest.name,
                                                   file: row.file, title: row.title,
                                                   isRetry: action == .retryRemoval)
                Group {
                    // Literals rather than the state's `title`, so the two words stay in the
                    // string catalogue; the state keeps them for the tests and for VoiceOver.
                    switch action {
                    case .remove:
                        Button("Remove manual…", role: .destructive) { confirmingRemoval = request }
                    case .retryRemoval:
                        Button("Retry removal", role: .destructive) { confirmingRemoval = request }
                    }
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .disabled(!row.isActionEnabled)
                .accessibilityLabel(Text(verbatim: "\(action.title.replacingOccurrences(of: "…", with: "")): \(row.title)"))
                .accessibilityHint(Text(verbatim: row.accessibilityActionHint ?? ""))
            }
        }
    }

    /// Start the removal a confirmation was shown for.
    private func confirm(_ request: ManualRemovalRequest) {
        confirmingRemoval = nil
        Task { await performRemoval(request) }
    }

    /// The rows for one vault's manuals, decided by [[VaultManualRowState]] rather than inline, so
    /// what a row offers is provable without a screen.
    private func manualRows(for manifest: VaultManifest,
                            ledger: VaultDocumentLedger) -> [VaultManualRowState] {
        let eligibility = VaultManualRemoval.eligibility(of: manifest.id)
        let pending = pendingRemovals[manifest.id] ?? []
        let inFlight = removalInFlight?.vaultId == manifest.id ? removalInFlight?.file : nil
        return manifest.documents.map { document in
            let entry = ledger.entries.first { $0.file == document.file }
            return VaultManualRowState.make(document: document, ledgerEntry: entry,
                                            summary: entry.map(Self.entrySummary),
                                            pendingFiles: pending, inFlightFile: inFlight,
                                            eligibility: eligibility,
                                            isVaultBusy: isBusy(manifest.id))
        }
    }

    /// Whether an operation owns this vault: a removal this screen started, an index running for
    /// it, or anything else holding the per-vault lock (an uninstall, a launch-time recovery).
    private func isBusy(_ vaultId: String) -> Bool {
        if removalInFlight?.vaultId == vaultId { return true }
        if syncProgress?.vaultId == vaultId { return true }
        return VaultOperationLock.isBusy(vaultId)
    }

    /// "412 sections · 11 diagram pages · 38 pages read by recognition · 3 low confidence".
    static func entrySummary(_ entry: VaultDocumentLedger.Entry) -> String {
        var parts = ["\(entry.chunkCount) sections"]
        if let diagrams = entry.diagramPages, diagrams > 0 {
            parts.append("\(diagrams) diagram page\(diagrams == 1 ? "" : "s")")
        }
        if let ocr = entry.ocrPages, ocr > 0 {
            parts.append("\(ocr) page\(ocr == 1 ? "" : "s") read by recognition")
            if let low = entry.lowConfidencePages, low > 0 {
                parts.append("\(low) low confidence")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func reloadLedgers() {
        installed = VaultImporter.installedManifests()
        ledgers = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, VaultImporter.documentLedger(for: $0.id)) })
        pendingRemovals = Dictionary(uniqueKeysWithValues: installed.map {
            ($0.id, VaultManualRemoval.pendingFiles(for: $0.id))
        })
    }

    /// Take one manual out of an installed vault.
    ///
    /// Nothing is reported until the operation returns: a removal is four durable steps behind a
    /// journal, and "removed" printed before they finish is the one message this screen must never
    /// show. Removing installed content is deliberately not gated on the licence — importing
    /// manuals is the paid capability, deleting your own is not, and a lapsed team must still be
    /// able to take a superseded manual out of a vault its technicians are working from
    /// (`VaultManualRemoval.isPermittedByEntitlement`).
    private func performRemoval(_ request: ManualRemovalRequest) async {
        successMessage = nil
        removalOutcome = nil
        removalInFlight = request
        // The journal is written before anything durable changes, so the row says "Removing…"
        // from this point whatever happens next.
        defer { removalInFlight = nil; reloadLedgers() }
        do {
            let result = try await VaultManualRemoval.remove(file: request.file,
                                                             fromVault: request.vaultId,
                                                             documentStore: appState.documentStore)
            // The live session reads from this vault and may have the manual's page on screen.
            appState.vaultDidRemoveManual(result)
            removalOutcome = ManualRemovalOutcome(
                outcome: VaultManualRemovalPresentation.success(result, vaultName: request.vaultName),
                retry: nil)
        } catch {
            let outcome = VaultManualRemovalPresentation.outcome(for: error, manual: request.title,
                                                                 vaultName: request.vaultName)
            // "Already gone" means this list was stale, not that anything failed: re-read it and
            // say so plainly rather than raising a failure alert over a manual that has gone.
            if case .alreadyGone = outcome { VaultRegistry.shared.reloadUserManifests() }
            removalOutcome = ManualRemovalOutcome(outcome: outcome,
                                                  retry: outcome.isRetryable ? request : nil)
        }
    }

    private func exportVault(_ manifest: VaultManifest) {
        successMessage = nil
        do {
            let url = try VaultExporter.export(id: manifest.id)
            shareItem = ShareItem(items: [url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Swift.Result<URL, Error>) {
        successMessage = nil
        warnings = []
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try VaultImporter.installReporting(from: url)
                VaultRegistry.shared.reloadUserManifests()
                warnings = report.warnings
                reloadLedgers()
                successMessage = "Installed \(report.manifest.name)."
                // Not `hasDocuments`: a manifest re-imported with its manuals removed still has to
                // reconcile what the previous import indexed, or those passages stay retrievable.
                if VaultImporter.needsDocumentSync(manifest: report.manifest) {
                    Task { await sync(report.manifest) }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sync(_ manifest: VaultManifest) async {
        syncProgress = (manifest.id, manifest.documents.first?.title ?? manifest.name, 0, 1)
        recognitionProgress = nil
        defer { syncProgress = nil; recognitionProgress = nil }
        do {
            let ledger = try await VaultImporter.syncDocuments(
                manifest: manifest, into: appState.documentStore,
                renderPolicy: ScanRenderPolicy(),
                progress: { title, completed, total in
                    recognitionProgress = nil
                    syncProgress = (manifest.id, title, completed, total)
                },
                recognitionProgress: { title, done, total in
                    recognitionProgress = (title, done, total)
                })
            ledgers[manifest.id] = ledger
            let sections = ledger.entries.reduce(0) { $0 + $1.chunkCount }
            successMessage = "Indexed \(ledger.entries.count) manual\(ledger.entries.count == 1 ? "" : "s") for \(manifest.name) (\(sections) sections)."
        } catch {
            ledgers[manifest.id] = VaultImporter.documentLedger(for: manifest.id)
            errorMessage = error.localizedDescription
        }
    }

    private func remove(at offsets: IndexSet) {
        // Uninstall is serialised against an in-flight index or manual removal for the same vault,
        // so it awaits rather than running straight through the swipe handler.
        let ids = offsets.map { installed[$0].id }
        Task {
            for id in ids {
                await VaultImporter.uninstall(id: id, documentStore: appState.documentStore)
            }
            VaultRegistry.shared.reloadUserManifests()
            reloadLedgers()
        }
    }
}
