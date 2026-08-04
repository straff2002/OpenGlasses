import SwiftUI

/// Manage personas — each bundles a wake word, AI model, and system prompt.
/// Multiple personas can be active simultaneously.
struct PersonasView: View {
    @State private var personas: [Persona] = Config.savedPersonas
    @State private var editingPersona: Persona? = nil
    @State private var showAddSheet = false
    @State private var projectForDetail: Persona? = nil   // Plan AN — project detail surface
    @State private var importingProject = false
    @State private var importMessage: String?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section {
                ForEach(personas) { persona in
                    Button {
                        editingPersona = persona
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(persona.name)
                                        .foregroundStyle(Color(.label))
                                        .lineLimit(1)
                                    if !persona.enabled {
                                        Text("Off")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                }
                                Text("\"\(persona.wakePhrase)\"")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(modelName(for: persona.modelId))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text("·")
                                        .foregroundStyle(.secondary)
                                    Text(presetName(for: persona.presetId))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(persona.name)\(!persona.enabled ? ", disabled" : ""). Wake phrase: \(persona.wakePhrase). \(modelName(for: persona.modelId))")
                    .accessibilityHint("Double-tap to edit")
                    .swipeActions(edge: .trailing) {
                        if personas.count > 1 {
                            Button(role: .destructive) {
                                deletePersona(persona)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            projectForDetail = persona
                        } label: {
                            Label("Project", systemImage: "folder")
                        }
                        .tint(AppAccent.color)
                    }
                }
            } header: {
                Text("Personas")
            } footer: {
                Text("Each persona has its own wake word, AI model, and personality. All enabled personas listen simultaneously — say any wake word to activate that persona.")
            }
        }
        .navigationTitle("Personas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showAddSheet = true } label: { Label("New persona", systemImage: "plus") }
                    Button { importingProject = true } label: { Label("Import project…", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $importingProject, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert("Project import", isPresented: .constant(importMessage != nil)) {
            Button("OK") { importMessage = nil }
        } message: { Text(importMessage ?? "") }
        .sheet(isPresented: $showAddSheet) {
            PersonaEditorView(persona: nil) { newPersona in
                personas.append(newPersona)
                Config.setSavedPersonas(personas)
            }
        }
        .sheet(item: $editingPersona) { persona in
            PersonaEditorView(persona: persona) { updated in
                if let idx = personas.firstIndex(where: { $0.id == updated.id }) {
                    personas[idx] = updated
                    Config.setSavedPersonas(personas)
                }
            }
        }
        .sheet(item: $projectForDetail) { persona in
            NavigationStack {
                ProjectDetailView(project: persona)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { projectForDetail = nil }
                        }
                    }
            }
        }
    }

    private func deletePersona(_ persona: Persona) {
        personas.removeAll { $0.id == persona.id }
        Config.setSavedPersonas(personas)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else {
            if case let .failure(error) = result { importMessage = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bundle = try ProjectBundleCodec.decode(Data(contentsOf: url))
            Task {
                let imported = await ProjectExporter.importBundle(bundle, into: appState.documentStore)
                personas = Config.savedPersonas
                importMessage = "Imported \"\(imported.name)\" with \(bundle.documents.count) document\(bundle.documents.count == 1 ? "" : "s")."
            }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func modelName(for modelId: String) -> String {
        Config.savedModels.first { $0.id == modelId }?.name ?? "No model"
    }

    private func presetName(for presetId: String) -> String {
        Config.savedPresets.first { $0.id == presetId }?.name ?? "Default"
    }
}

// MARK: - Editor

struct PersonaEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let persona: Persona?
    let onSave: (Persona) -> Void

    @State private var name = ""
    @State private var wakePhrase = "openglasses"
    @State private var wakeAlts = ""
    @State private var selectedModelId = ""
    @State private var selectedPresetId = "preset-default"
    @State private var enabled = true
    @State private var editingPromptPreset: PromptPreset? = nil

    private let wakePhrasePresets = [
        "openglasses", "hey openglasses", "hey claude", "hey jarvis", "hey rayban",
        "hey computer", "hey assistant", "hey gemini", "hey gpt"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } header: {
                    Text("Persona Name")
                }

                Section {
                    Picker("Wake Phrase", selection: $wakePhrase) {
                        ForEach(wakePhrasePresets, id: \.self) { phrase in
                            Text(phrase.capitalized).tag(phrase)
                        }
                        if !wakePhrasePresets.contains(wakePhrase) && !wakePhrase.isEmpty {
                            Text("Custom: \(wakePhrase)").tag(wakePhrase)
                        }
                    }
                    .onChange(of: wakePhrase) { _, newValue in
                        let defaults = Config.defaultAlternativesForPhrase(newValue)
                        wakeAlts = defaults.joined(separator: ", ")
                    }

                    TextField("Custom wake phrase", text: $wakePhrase)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Alternative spellings", text: $wakeAlts)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Wake Word")
                } footer: {
                    Text("Say this phrase to activate this persona. Add alternatives for common misrecognitions.")
                }

                Section {
                    let models = Config.savedModels
                    Picker("AI Model", selection: $selectedModelId) {
                        Text("None").tag("")
                        ForEach(models, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }

                    if models.isEmpty {
                        Label("Add a model in Settings → AI Models first", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Which AI model responds when this persona is activated. Add models in Settings → AI Models.")
                }

                Section {
                    Picker("System Prompt", selection: $selectedPresetId) {
                        ForEach(Config.savedPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }

                    Button {
                        editingPromptPreset = Config.savedPresets.first { $0.id == selectedPresetId }
                    } label: {
                        Label("Edit Prompt", systemImage: "square.and.pencil")
                    }
                    .disabled(!Config.savedPresets.contains { $0.id == selectedPresetId })
                } header: {
                    Text("Personality")
                } footer: {
                    Text("The system prompt that shapes how this persona responds. Editing a built-in prompt makes it your own copy, safe from app updates.")
                }

                Section {
                    Toggle("Enabled", isOn: $enabled)
                } footer: {
                    Text("Disabled personas won't listen for their wake word.")
                }
            }
            .navigationTitle(persona != nil ? "Edit Persona" : "New Persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedModelId.isEmpty)
                }
            }
            .onAppear {
                if let p = persona {
                    name = p.name
                    wakePhrase = p.wakePhrase
                    wakeAlts = p.alternativeWakePhrases.joined(separator: ", ")
                    selectedModelId = p.modelId
                    selectedPresetId = p.presetId
                    enabled = p.enabled
                } else {
                    // Default for new persona
                    if let firstModel = Config.savedModels.first {
                        selectedModelId = firstModel.id
                    }
                }
            }
            // Edit the selected preset in place — same editor and fork-on-save
            // semantics as the System Prompt list, so built-ins become the
            // user's own copy.
            .sheet(item: $editingPromptPreset) { preset in
                PromptPresetEditorView(preset: preset) { updated in
                    var presets = Config.savedPresets
                    if let idx = presets.firstIndex(where: { $0.id == updated.id }) {
                        presets[idx] = updated
                    } else {
                        presets.append(updated)
                    }
                    Config.setSavedPresets(presets)
                }
            }
        }
    }

    private func save() {
        let alts = wakeAlts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        let result = Persona(
            id: persona?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            wakePhrase: wakePhrase.lowercased().trimmingCharacters(in: .whitespaces),
            alternativeWakePhrases: alts,
            modelId: selectedModelId,
            presetId: selectedPresetId,
            enabled: enabled
        )
        onSave(result)
    }
}
