import SwiftUI
import UniformTypeIdentifiers

/// Global manager for the on-device document knowledge base (Plan O follow-up). Lists
/// every ingested document grouped by project namespace, with delete and add-text /
/// import-file. Complements the per-project view in `ProjectDetailView`; here you see
/// everything across projects in one place. Local-only.
struct DocumentsView: View {
    @EnvironmentObject var appState: AppState
    @State private var refreshToken = 0
    @State private var showAddText = false
    @State private var importing = false
    @State private var message: String?

    private var store: DocumentStore { appState.documentStore }

    /// Documents grouped by namespace ("global" first), each newest-first.
    private var groups: [(namespace: String, docs: [DocumentStore.DocumentRef])] {
        _ = refreshToken
        // Vault manuals (`vault:<id>`) are managed from Custom Vaults, not here — a personal
        // documents surface must not list, and cannot delete, a customer's reference tier.
        let byNS = Dictionary(grouping: store.list().filter { !DocumentStore.isVaultNamespace($0.namespace) }, by: \.namespace)
        return byNS.keys.sorted { a, b in
            if a == "global" { return true }
            if b == "global" { return false }
            return a < b
        }.map { ns in (ns, byNS[ns]!.sorted { $0.createdAt > $1.createdAt }) }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView("No documents", systemImage: "doc.text",
                                       description: Text("Add text or import a file to build your private on-device knowledge base."))
            } else {
                ForEach(groups, id: \.namespace) { group in
                    Section(group.namespace == "global" ? "Global" : projectName(for: group.namespace)) {
                        ForEach(group.docs) { doc in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.name).font(.subheadline)
                                Text("\(doc.sourceType) · \(doc.chunkCount) section\(doc.chunkCount == 1 ? "" : "s") · \(doc.createdAt, style: .date)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idx in
                            idx.map { group.docs[$0].id }.forEach { store.forget(documentId: $0) }
                            refreshToken += 1
                        }
                    }
                }
            }
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAddText = true } label: { Label("Add text…", systemImage: "text.alignleft") }
                    Button { importing = true } label: { Label("Import file…", systemImage: "doc.badge.plus") }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add document")
            }
        }
        .sheet(isPresented: $showAddText) {
            AddTextDocumentSheet { name, text in
                Task { await ingest(name: name, text: text, sourceType: "text"); refreshToken += 1 }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("Documents", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func projectName(for id: String) -> String {
        Config.savedPersonas.first { $0.id == id }?.name ?? id
    }

    private func ingest(name: String, text: String, sourceType: String) async {
        if await store.ingest(name: name, text: text, sourceType: sourceType) == nil {
            message = "Couldn't save \"\(name)\" — the text may be too short."
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            if case let .failure(error) = result { message = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            message = "Couldn't read \(url.lastPathComponent) as text."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        Task { await ingest(name: name, text: text, sourceType: "file"); refreshToken += 1 }
    }
}

/// Small sheet to paste a named text document.
private struct AddTextDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String) -> Void
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Text") {
                    TextEditor(text: $text).frame(minHeight: 160)
                }
            }
            .navigationTitle("Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .ogFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Note" : name, text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
