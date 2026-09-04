import SwiftUI
import UniformTypeIdentifiers

/// Manage customer-imported vaults (Plan H, Enterprise tier). Import a folder containing
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
    @StateObject private var packs = VaultPackCatalogService()
    @ObservedObject private var store = StoreKitService.shared

    /// Custom vaults are a team capability; the import button says so instead of failing later.
    private var teamCheck: FieldAssistTierCheck { FieldAssistEntitlement.shared.check(atLeast: .team) }

    var body: some View {
        Form {
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import Vault Folder…", systemImage: "square.and.arrow.down")
                }
                .disabled(syncProgress != nil || !teamCheck.isGranted)
                if case .insufficientTier = teamCheck {
                    Text(FieldAssistPaywallCopy.teamOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .denied = teamCheck {
                    Text("Custom vaults need a Field Assist team licence.")
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
                    }
                    .onDelete(perform: remove)
                } header: {
                    Text("Installed Vaults")
                } footer: {
                    Text("Swipe a vault to export it as a folder (manifest.json + markdown + procedures/ + documents). Exports include your in-app edits and re-import directly via “Import Vault Folder…”.")
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
                ForEach(manifest.documents, id: \.file) { document in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(document.title)
                            .font(.caption)
                        Spacer()
                        if let entry = ledger.entries.first(where: { $0.file == document.file }) {
                            Text(Self.entrySummary(entry))
                                .font(.caption2)
                                .foregroundStyle((entry.lowConfidencePages ?? 0) > 0 ? OGTheme.errorLabel : .secondary)
                        } else {
                            Text("not indexed")
                                .font(.caption2)
                                .foregroundStyle(OGTheme.errorLabel)
                        }
                    }
                }
                Button("Re-index manuals") {
                    Task { await sync(manifest) }
                }
                .font(.caption)
                .disabled(syncProgress != nil)
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

    /// "412 sections · 38 pages read by recognition · 3 low confidence".
    static func entrySummary(_ entry: VaultDocumentLedger.Entry) -> String {
        var parts = ["\(entry.chunkCount) sections"]
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
                if report.manifest.hasDocuments {
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
        for index in offsets {
            VaultImporter.uninstall(id: installed[index].id, documentStore: appState.documentStore)
        }
        VaultRegistry.shared.reloadUserManifests()
        reloadLedgers()
    }
}
