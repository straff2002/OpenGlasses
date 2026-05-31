import SwiftUI
import UniformTypeIdentifiers

/// Manage customer-imported vaults (Plan H, Enterprise tier). Import a folder containing
/// manifest.json + markdown + procedures/, validated before install; list and remove installed packs.
@MainActor
struct VaultManagerView: View {
    @State private var installed: [VaultManifest] = VaultImporter.installedManifests()
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var shareItem: ShareItem?

    var body: some View {
        Form {
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import Vault Folder…", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Select a folder containing manifest.json, the listed markdown files, and an optional procedures/ directory. The pack is validated before it's installed.")
            }

            if !installed.isEmpty {
                Section {
                    ForEach(installed, id: \.id) { manifest in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manifest.name)
                            Text("\(manifest.id) · v\(manifest.version) · \(manifest.files.count) files")
                                .font(.caption).foregroundStyle(.secondary)
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
                    .onDelete(perform: remove)
                } header: {
                    Text("Installed Vaults")
                } footer: {
                    Text("Swipe a vault to export it as a folder (manifest.json + markdown + procedures/). Exports include your in-app edits and re-import directly via “Import Vault Folder…”.")
                }
            }

            if let successMessage {
                Section { Text(successMessage).font(.caption).foregroundStyle(.green) }
            }
        }
        .navigationTitle("Custom Vaults")
        .navigationBarTitleDisplayMode(.inline)
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
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let manifest = try VaultImporter.install(from: url)
                VaultRegistry.shared.reloadUserManifests()
                installed = VaultImporter.installedManifests()
                successMessage = "Installed \(manifest.name)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(at offsets: IndexSet) {
        for index in offsets {
            VaultImporter.uninstall(id: installed[index].id)
        }
        VaultRegistry.shared.reloadUserManifests()
        installed = VaultImporter.installedManifests()
    }
}
