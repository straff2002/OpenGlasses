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
                                        OGBadge(text: "Off")
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
                            Image(systemName: "chevron.forward")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(spokenLabel(for: persona))
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
        .ogFormStyle()
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
                let name = imported.name
                let documents = bundle.documents.count
                importMessage = documents == 1
                    ? String(localized: "Imported \"\(name)\" with 1 document.")
                    : String(localized: "Imported \"\(name)\" with \(documents) documents.")
            }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    /// The row as VoiceOver reads it: name (and whether it is off), wake phrase, model.
    private func spokenLabel(for persona: Persona) -> String {
        let name = persona.name
        let phrase = persona.wakePhrase
        let model = modelName(for: persona.modelId)
        return persona.enabled
            ? String(localized: "\(name). Wake phrase: \(phrase). \(model)")
            : String(localized: "\(name), disabled. Wake phrase: \(phrase). \(model)")
    }

    private func modelName(for modelId: String) -> String {
        Config.savedModels.first { $0.id == modelId }?.name ?? String(localized: "No model")
    }

    private func presetName(for presetId: String) -> String {
        Config.savedPresets.first { $0.id == presetId }?.name ?? String(localized: "Default")
    }
}

// MARK: - Editor

struct PersonaEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let persona: Persona?
    let onSave: (Persona) -> Void

    @State private var name = ""
    @State private var wakePhrase = Config.defaultWakePhrase
    @State private var wakeAlts = ""
    @State private var selectedModelId = ""
    @State private var selectedPresetId = "preset-default"
    @State private var enabled = true
    @State private var editingPromptPreset: PromptPreset? = nil

    private let wakePhrasePresets = Config.wakePhrasePresets + ["hey gemini", "hey gpt"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } header: {
                    Text("Persona Name")
                } footer: {
                    Text("Whatever it's called, a persona is still an AI assistant, and it says so whenever anyone asks.")
                }

                Section {
                    Picker("Wake Phrase", selection: $wakePhrase) {
                        ForEach(wakePhrasePresets, id: \.self) { phrase in
                            Text(phrase.capitalized).tag(phrase)
                        }
                        if Config.isCustomWakePhrase(wakePhrase, presets: wakePhrasePresets) {
                            Text("Custom: \(wakePhrase)").tag(wakePhrase)
                        }
                    }
                    .onChange(of: wakePhrase) { oldValue, newValue in
                        // Re-seed the alternatives for the new phrase, but only when the field is
                        // still the previous phrase's suggestions. Anything the user typed is
                        // theirs — the old behaviour overwrote it on the next keystroke in the
                        // custom field, which is the field right below this one.
                        let previous = Config.defaultAlternativesForPhrase(oldValue)
                            .joined(separator: ", ")
                        guard wakeAlts.trimmingCharacters(in: .whitespaces).isEmpty
                                || wakeAlts == previous else { return }
                        wakeAlts = Config.defaultAlternativesForPhrase(newValue)
                            .joined(separator: ", ")
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
                    Text("Say this phrase to activate this persona. Add alternatives for common misrecognitions. A short phrase — one word — is matched exactly, so add the ways the recogniser writes it down.")
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
                        OGStatusLabel("Add a model in Settings → Assistant → AI Models first", kind: .warn)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Which AI model responds when this persona is activated. Add models in Settings → Assistant → AI Models.")
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
            .ogFormStyle()
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
