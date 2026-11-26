import SwiftUI

/// Plan LW P1 — *New Vault…*: a name, a trade and the models (optional). The vault is made by the
/// caller (`VaultAuthoring.createVault`, or the My Manuals move), which this sheet waits on.
@MainActor
struct NewVaultSheet: View {
    var moving = false
    var initialName = ""
    let onCreate: (_ name: String, _ template: TradeTemplate, _ models: [VaultStarter.Model]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var templateId: TradeTemplate.ID = .hvacR
    @State private var modelsText = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Vault name", text: $name)
                        .accessibilityIdentifier("newVault.name")
                    Picker("Trade", selection: $templateId) {
                        ForEach(TradeTemplate.all, id: \.id) { template in
                            // The template's own name, which is data.
                            Text(verbatim: template.name).tag(template.id)
                        }
                    }
                } footer: {
                    Text("The trade sets the safety starter, the symptom headings and the questions the vault check asks. You can edit all of them.")
                }
                Section {
                    TextField("Models (optional)", text: $modelsText, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("newVault.models")
                } footer: {
                    Text("One per line, or separated by commas. Put other spellings in brackets, such as QX-100 (QX100). You can add models later.")
                }
                if moving {
                    Section {
                        Text("Your manuals move into this vault and out of My Manuals. Each one is copied and checked before My Manuals is emptied.")
                            .font(.footnote)
                    }
                }
                if working {
                    Section {
                        if moving { ProgressView("Moving your manuals…") } else { ProgressView("Making the vault…") }
                    }
                }
                if let errorMessage {
                    Section { OGStatusLabel(errorMessage, kind: .error) }
                }
            }
            .diagnosticScreen()
            .navigationTitle(moving ? Text("Move into a vault") : Text("New Vault"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { create() } label: { if moving { Text("Move into a vault") } else { Text("Create") } }
                        .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("newVault.create")
                }
            }
            .onAppear { if name.isEmpty { name = initialName } }
        }
    }

    private func create() {
        working = true
        errorMessage = nil
        let template = TradeTemplate.template(id: templateId)
        let models = VaultAuthoring.models(fromText: modelsText)
        Task {
            defer { working = false }
            do {
                try await onCreate(name, template, models)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
