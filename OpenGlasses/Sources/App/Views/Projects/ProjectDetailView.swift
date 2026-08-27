import SwiftUI

/// The "manage this context" home for a Project (Plan AN). A Project is a `Persona`
/// plus its **scoped documents** (namespace = persona id) and its **conversations**
/// (threads tagged with that persona). Read/manage in one place; editing the
/// persona's prompt/model stays in `PersonaEditorView`.
struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    let project: Persona

    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var exportError: String?

    private var documentStore: DocumentStore { appState.documentStore }
    private var store: ConversationStore { appState.conversationStore }

    private var documents: [DocumentStore.DocumentRef] {
        documentStore.list(namespace: project.id)
    }
    private var threads: [ConversationThread] {
        store.threads(forPersona: project.id).sorted { $0.updatedAt > $1.updatedAt }
    }
    private var presetName: String {
        Config.savedPresets.first { $0.id == project.presetId }?.name ?? "Default"
    }

    var body: some View {
        List {
            Section("Context") {
                LabeledContent("Persona", value: project.name)
                LabeledContent("Personality", value: presetName)
                if let soul = project.soulOverride, !soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(soul)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

            Section {
                if documents.isEmpty {
                    Text("No documents in this project yet. Attach files or scan documents from a chat in this project to ground answers here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(documents) { doc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.name).font(.subheadline)
                            Text("\(doc.sourceType) · \(doc.chunkCount) section\(doc.chunkCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        idx.map { documents[$0].id }.forEach { documentStore.forget(documentId: $0) }
                    }
                }
            } header: {
                Text("Documents (\(documents.count))")
            } footer: {
                if !documents.isEmpty {
                    Text("Answers in this project are grounded in these documents and cite them. Local-only.")
                }
            }

            Section("Conversations (\(threads.count))") {
                if threads.isEmpty {
                    Text("No conversations in this project yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(threads) { thread in
                        NavigationLink(value: thread.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title).font(.subheadline).lineLimit(1)
                                Text(thread.updatedAt, style: .relative)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .navigationDestination(for: String.self) { id in
            ChatThreadView(threadId: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportProject()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export project")
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func exportProject() {
        do {
            let url = try ProjectExporter.exportFile(persona: project, store: documentStore)
            shareItem = ShareItem(items: [url])
        } catch {
            exportError = error.localizedDescription
        }
    }
}
