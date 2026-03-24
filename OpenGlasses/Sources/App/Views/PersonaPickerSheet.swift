import SwiftUI

/// Quick persona switcher — tap to manually activate a persona.
/// Shows all enabled personas with their wake word, model, and preset.
struct PersonaPickerSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let personas = Config.enabledPersonas

                if personas.isEmpty {
                    ContentUnavailableView(
                        "No Personas",
                        systemImage: "person.2",
                        description: Text("Add personas in Settings to use different wake words and models.")
                    )
                } else {
                    ForEach(personas) { persona in
                        Button {
                            activatePersona(persona)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(persona.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\"\(persona.wakePhrase)\"")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        let modelName = Config.savedModels.first { $0.id == persona.modelId }?.name ?? "No model"
                                        let presetName = Config.savedPresets.first { $0.id == persona.presetId }?.name ?? "Default"
                                        Text(modelName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("·")
                                            .foregroundStyle(.secondary)
                                        Text(presetName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if appState.activePersona?.id == persona.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Personas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.light)
    }

    private func activatePersona(_ persona: Persona) {
        appState.activePersona = persona
        Config.setActiveModelId(persona.modelId)
        Config.setActivePresetId(persona.presetId)
        appState.llmService.refreshActiveModel()
        appState.llmService.clearHistory()
        print("🎭 Manually activated persona: \(persona.name)")
        dismiss()
    }
}
