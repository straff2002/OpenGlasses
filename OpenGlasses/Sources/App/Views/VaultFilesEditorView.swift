import SwiftUI

/// Generic editor for any registered vault's markdown files (edits write to the Documents overlay;
/// bundled templates are never mutated). Used by the Personal Notes vault; reusable for others.
@MainActor
struct VaultFilesEditorView: View {
    let vaultId: String
    let title: String

    private var store: VaultStore? { VaultRegistry.shared.store(forId: vaultId) }

    var body: some View {
        Group {
            if let store, VaultRegistry.shared.isUnlocked(vaultId) {
                List(store.manifest.files, id: \.self) { filename in
                    NavigationLink {
                        VaultSingleFileEditor(store: store, filename: filename)
                    } label: {
                        Label(displayName(filename), systemImage: "doc.text")
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
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .navigationTitle(filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "_", with: " ").capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { _ = try? store.write(filename, contents: text); dismiss() }
                }
            }
            .onAppear { text = store.read(filename) ?? "" }
    }
}
