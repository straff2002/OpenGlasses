import SwiftUI

/// Editor for the Personal Health Vault (Plan B). Lists the vault's markdown files and lets the user
/// edit each one; edits are written to the Documents overlay (the bundled templates are never
/// mutated). Gated by the Medical Compliance unlock.
@MainActor
struct HealthVaultEditorView: View {
    private let store = VaultRegistry.shared.store(forId: "health")
    private var unlocked: Bool { VaultRegistry.shared.isUnlocked("health") }

    var body: some View {
        Group {
            if !unlocked {
                ContentUnavailableView(
                    "Health Vault Locked",
                    systemImage: "lock",
                    description: Text("The Personal Health Vault unlocks with the Medical Compliance subscription.")
                )
            } else if let store {
                List(store.manifest.files, id: \.self) { filename in
                    NavigationLink {
                        HealthVaultFileEditor(store: store, filename: filename)
                    } label: {
                        Label(displayName(filename), systemImage: icon(filename))
                    }
                }
            } else {
                ContentUnavailableView("Health Vault Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Health Vault")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func displayName(_ filename: String) -> String {
        filename.replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func icon(_ filename: String) -> String {
        switch filename {
        case "biometrics.md": return "heart.text.square"
        case "conditions.md": return "cross.case"
        case "dietary_context.md": return "fork.knife"
        case "lab_baselines.md": return "testtube.2"
        case "medications.md": return "pills"
        case "wearables.md": return "applewatch"
        default: return "doc.text"
        }
    }
}

/// Edits a single health vault file. Loads merged bundle+overlay content; saves to the overlay.
@MainActor
private struct HealthVaultFileEditor: View {
    let store: VaultStore
    let filename: String

    @State private var text: String = ""
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
        }
        .navigationTitle(filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "_", with: " ").capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    _ = try? store.write(filename, contents: text)
                    saved = true
                    dismiss()
                }
            }
        }
        .onAppear { text = store.read(filename) ?? "" }
    }
}
