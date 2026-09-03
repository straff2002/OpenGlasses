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
    @State private var shareItem: ShareItem?

    var body: some View {
        Form {
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import Vault Folder…", systemImage: "square.and.arrow.down")
                }
                .disabled(syncProgress != nil)
            } footer: {
                Text("Select a folder containing manifest.json, the listed markdown files, an optional procedures/ directory, and any manuals the manifest lists under documents (PDF, EPUB, Markdown, or text). The pack is validated before it's installed; manuals are indexed on this device for retrieval.")
            }

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
                        Text("Indexing \(syncProgress.title)…")
                        ProgressView(value: Double(syncProgress.completed), total: Double(max(syncProgress.total, 1)))
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
        .onAppear(perform: reloadLedgers)
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

    // MARK: - Rows

    @ViewBuilder
    private func vaultRow(_ manifest: VaultManifest) -> some View {
        let ledger = ledgers[manifest.id] ?? VaultDocumentLedger()
        VStack(alignment: .leading, spacing: 4) {
            Text(manifest.name)
            Text("\(manifest.id) · v\(manifest.version) · \(manifest.files.count) files")
                .font(.caption).foregroundStyle(.secondary)
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
                            Text("\(entry.chunkCount) sections")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
            Button {
                exportVault(manifest)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(AppAccent.color)
        }
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
        defer { syncProgress = nil }
        do {
            let ledger = try await VaultImporter.syncDocuments(manifest: manifest, into: appState.documentStore) { title, completed, total in
                syncProgress = (manifest.id, title, completed, total)
            }
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
