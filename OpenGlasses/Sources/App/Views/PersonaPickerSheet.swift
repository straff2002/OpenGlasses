import SwiftUI

/// Quick persona switcher — tap to activate a persona or browse available modes.
/// Shows installed personas at top with mode cards, plus an "Add Modes" section for templates.
struct PersonaPickerSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showModeStore = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Installed Personas
                let personas = Config.enabledPersonas

                if personas.isEmpty {
                    ContentUnavailableView(
                        "No Personas",
                        systemImage: "person.2",
                        description: Text("Tap + to browse and install AI modes, or add custom personas in Settings.")
                    )
                } else {
                    Section {
                        ForEach(personas) { persona in
                            Button {
                                activatePersona(persona)
                            } label: {
                                PersonaRow(
                                    persona: persona,
                                    isActive: appState.activePersona?.id == persona.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Active Personas")
                    }
                }

                // MARK: - Available Modes (not yet installed)
                let installed = Set(Config.savedPersonas.map(\.id))
                let available = Config.builtInPersonaTemplates().filter { !installed.contains($0.id) }

                if !available.isEmpty {
                    Section {
                        ForEach(available) { template in
                            Button {
                                installAndActivate(template)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: template.icon ?? "sparkles")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("Say \"\(template.wakePhrase)\"")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Available Modes")
                    } footer: {
                        Text("Tap to install and activate a mode. Each mode has its own wake phrase, system prompt, and camera behavior.")
                    }
                }
            }
            .navigationTitle("Personas & Modes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
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

    private func installAndActivate(_ template: Persona) {
        Config.installPersonaMode(template)
        // Re-fetch the installed version (has model ID filled in)
        if let installed = Config.savedPersonas.first(where: { $0.id == template.id }) {
            activatePersona(installed)
        }
    }
}

// MARK: - Persona Row

struct PersonaRow: View {
    let persona: Persona
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: persona.icon ?? "person.circle")
                .font(.title3)
                .foregroundStyle(isActive ? .blue : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(persona.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if persona.isBuiltIn == true {
                        Text("Mode")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text("\"\(persona.wakePhrase)\"")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    let modelName = Config.savedModels.first { $0.id == persona.modelId }?.name ?? "Default model"
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
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
    }
}
