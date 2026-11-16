import SwiftUI

/// Plan LW P1 — building one vault of your own on the phone: its manuals (add one, review what the
/// phone found in it), its models (from a nameplate), its files, the vault check, and the export for
/// publishing.
@MainActor
struct VaultAuthoringView: View {
    @EnvironmentObject private var appState: AppState
    let vaultId: String

    @ObservedObject private var indexing = VaultIndexingMonitor.shared
    @State private var manifest: VaultManifest?
    @State private var ledger = VaultDocumentLedger()
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var addingModel = false
    @State private var reviewing: ReviewTarget?
    @State private var exportWarnings: ExportWarnings?
    @State private var shareItem: ShareItem?

    struct ReviewTarget: Identifiable, Hashable {
        let file: String
        let title: String
        var id: String { file }
    }

    struct ExportWarnings: Identifiable {
        let id = UUID()
        let warnings: [PublishingCheck.Warning]
    }

    var body: some View {
        Form {
            manualsSection
            Section {
                Button { addingModel = true } label: {
                    Label("Add this model from a nameplate…", systemImage: "camera.viewfinder")
                }
                .disabled(manifest?.documents.isEmpty ?? true)
            } header: {
                Text("Models")
            } footer: {
                Text("Photograph the plate at the unit, pick the model it shows, and say which manual covers it.")
            }
            Section("Vault") {
                NavigationLink {
                    VaultFilesEditorView(vaultId: vaultId, title: manifest?.name ?? "")
                } label: {
                    Label("Files", systemImage: "doc.text")
                }
                NavigationLink {
                    VaultCheckView(vaultId: vaultId)
                } label: {
                    Label("Vault check", systemImage: "checklist")
                }
            }
            Section {
                Button { exportForPublishing() } label: {
                    Label("Export for publishing…", systemImage: "square.and.arrow.up")
                }
                Button { export() } label: {
                    Label("Export a private copy", systemImage: "square.and.arrow.up.on.square")
                }
            } footer: {
                Text("An export carries the vault's files and the list of manuals it was written against, never the manuals themselves. The publishing export first lists what to look at; a private copy doesn't.")
            }
            if let message { Section { OGStatusLabel(message, kind: .ok) } }
            if let errorMessage { Section { OGStatusLabel(errorMessage, kind: .error) } }
        }
        .navigationTitle(manifest.map { Text(verbatim: $0.name) } ?? Text("Vault"))
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear(perform: reload)
        .onChange(of: indexing.runs.count) { _, _ in reload() }
        .navigationDestination(item: $reviewing) { target in
            DraftReviewView(vaultId: vaultId, file: target.file, title: target.title)
        }
        .sheet(isPresented: $addingModel) {
            NameplateModelSheet(vaultId: vaultId) { message = String(localized: "Model added to models.md.") }
        }
        .sheet(item: $exportWarnings) { item in
            PublishingCheckSheet(warnings: item.warnings) {
                exportWarnings = nil
                export()
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: item.items) }
    }

    private var manualsSection: some View {
        Section {
            ForEach(manifest?.documents ?? [], id: \.file) { document in
                manualRow(document)
            }
            if let run = indexing.run(for: vaultId) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexing \(run.headline)")
                    ProgressView(value: Double(run.completed), total: Double(max(run.total, 1)))
                }
            }
            AddManualControls(vaultId: vaultId, onAdded: { added in
                manifest = added
                Task { await index(added) }
            }, disabled: indexing.isIndexingAny)
        } header: {
            Text("Manuals")
        } footer: {
            Text("Each manual is saved and indexed on this phone. When it's ready, review what the phone found in it: fault codes, models and symptoms.")
        }
    }

    @ViewBuilder
    private func manualRow(_ document: VaultDocument) -> some View {
        let entry = ledger.entries.first { $0.file == document.file }
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: document.title)
            if let edition = document.edition {
                Text(verbatim: edition).font(.caption).foregroundStyle(.secondary)
            }
            if entry != nil {
                Button("Review drafts") { reviewing = .init(file: document.file, title: document.title) }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("vaultAuthoring.review.\(document.file)")
            } else {
                Text("Not indexed yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        manifest = VaultImporter.installedManifest(id: vaultId)
        ledger = VaultImporter.documentLedger(for: vaultId)
    }

    private func index(_ added: VaultManifest) async {
        let store = appState.documentStore
        errorMessage = nil
        do {
            ledger = try await indexing.sync(added, into: store)
            message = String(localized: "Manual ready. Tap Review drafts under it to see what the phone found.")
        } catch {
            ledger = VaultImporter.documentLedger(for: vaultId)
            errorMessage = error.localizedDescription
        }
    }

    private func exportForPublishing() {
        guard let manifest else { return }
        let store = VaultRegistry.shared.store(for: manifest)
        var files: [String: String] = [:]
        for file in manifest.files { files[file] = store.read(file) ?? "" }
        let warnings = PublishingCheck.warnings(files: files, record: VaultAuthoringRecord.load(vaultId: vaultId),
                                                privateExport: false)
        if warnings.isEmpty { export() } else { exportWarnings = ExportWarnings(warnings: warnings) }
    }

    private func export() {
        do {
            shareItem = ShareItem(items: [try VaultExporter.export(id: vaultId)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// What to look at before the vault goes out to be published. Warnings only: export anyway, or not.
@MainActor
struct PublishingCheckSheet: View {
    let warnings: [PublishingCheck.Warning]
    let onExport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        OGStatusLabel(PublishingCheck.message(warning), kind: .warn)
                    }
                } footer: {
                    Text("These don't stop the export. Fix them first if the vault is going to other companies.")
                }
                Section {
                    Button("Export anyway") { onExport() }
                }
            }
            .navigationTitle("Before you publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
