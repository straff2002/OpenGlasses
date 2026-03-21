import SwiftUI

/// Manage system prompt presets — select, add, edit, delete.
struct PromptPresetsView: View {
    @State private var presets: [PromptPreset] = Config.savedPresets
    @State private var activeId: String = Config.activePresetId
    @State private var showAddSheet = false
    @State private var editingPreset: PromptPreset? = nil

    var body: some View {
        List {
            Section {
                ForEach(presets) { preset in
                    Button {
                        activeId = preset.id
                        Config.setActivePresetId(preset.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if preset.isBuiltIn {
                                        Text("Built-in")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(preset.prompt.prefix(80) + (preset.prompt.count > 80 ? "…" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if preset.id == activeId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            editingPreset = preset
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)

                        if !preset.isBuiltIn {
                            Button(role: .destructive) {
                                deletePreset(preset)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Tap to select the active prompt. Swipe to edit or delete custom presets.")
            }
        }
        .navigationTitle("System Prompt")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            PromptPresetEditorView(preset: nil) { newPreset in
                presets.append(newPreset)
                Config.setSavedPresets(presets)
            }
        }
        .sheet(item: $editingPreset) { preset in
            PromptPresetEditorView(preset: preset) { updated in
                if let idx = presets.firstIndex(where: { $0.id == updated.id }) {
                    presets[idx] = updated
                    Config.setSavedPresets(presets)
                }
            }
        }
    }

    private func deletePreset(_ preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
        if activeId == preset.id {
            activeId = "preset-default"
            Config.setActivePresetId("preset-default")
        }
        Config.setSavedPresets(presets)
    }
}

// MARK: - Editor

struct PromptPresetEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let preset: PromptPreset?
    let onSave: (PromptPreset) -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""

    var isEditing: Bool { preset != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } header: {
                    Text("Preset Name")
                }

                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 200)
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("This prompt shapes how the AI responds. It's included with every message.")
                }
            }
            .navigationTitle(isEditing ? "Edit Preset" : "New Preset")
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let preset {
                    name = preset.name
                    prompt = preset.prompt
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespaces)

        if var existing = preset {
            existing.name = trimmedName
            existing.prompt = trimmedPrompt
            existing.isBuiltIn = false  // Editing a built-in makes it user-owned
            onSave(existing)
        } else {
            let newPreset = PromptPreset(
                id: UUID().uuidString,
                name: trimmedName,
                prompt: trimmedPrompt,
                isBuiltIn: false
            )
            onSave(newPreset)
        }
    }
}
