import SwiftUI

/// Generic viewer/editor for any registered vault's markdown files.
///
/// When the vault is unlocked, files are editable (edits write to the Documents overlay; the
/// read-only baseline is never mutated). When the vault is **locked**, the same screen becomes a
/// read-only **preview** so a prospective buyer can browse the reference content before unlocking.
@MainActor
struct VaultFilesEditorView: View {
    let vaultId: String
    let title: String

    private var store: VaultStore? { VaultRegistry.shared.store(forId: vaultId) }
    private var unlocked: Bool { VaultRegistry.shared.isUnlocked(vaultId) }

    var body: some View {
        Group {
            if let store {
                List {
                    if !unlocked {
                        Section {
                            Label("Preview only — unlock to edit", systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(store.manifest.files, id: \.self) { filename in
                            NavigationLink {
                                VaultSingleFileEditor(store: store, filename: filename, readOnly: !unlocked)
                            } label: {
                                Label(displayName(filename), systemImage: "doc.text")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Unavailable", systemImage: "lock")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func displayName(_ filename: String) -> String {
        filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}

@MainActor
private struct VaultSingleFileEditor: View {
    let store: VaultStore
    let filename: String
    var readOnly: Bool = false
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var displayName: String {
        filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    var body: some View {
        Group {
            if readOnly {
                ScrollView {
                    Text(text.isEmpty ? "(empty)" : text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !readOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { _ = try? store.write(filename, contents: text); dismiss() }
                }
            }
        }
        .onAppear { text = store.read(filename) ?? "" }
    }
}
