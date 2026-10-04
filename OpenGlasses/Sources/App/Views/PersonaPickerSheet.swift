import SwiftUI

/// Quick persona switcher — tap to activate a persona or browse available modes.
/// Shows installed personas at top with mode cards, plus an "Add Modes" section for templates.
struct PersonaPickerSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showModeStore = false
    @State private var detailPersona: Persona? = nil
    @ScaledMetric(relativeTo: .body) private var infoTapTarget: CGFloat = 44

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
                            HStack(spacing: 0) {
                                Button {
                                    activatePersona(persona)
                                } label: {
                                    PersonaRow(
                                        persona: persona,
                                        isActive: appState.activePersona?.id == persona.id
                                    )
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    detailPersona = persona
                                } label: {
                                    Image(systemName: "info.circle")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 8)
                                        .frame(minWidth: infoTapTarget, minHeight: infoTapTarget)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Details for \(persona.name)")
                            }
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
                            NavigationLink {
                                ModeTemplatePreview(template: template, appState: appState) {
                                    installAndActivate(template)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: template.icon ?? "sparkles")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Color(.label))
                                        Text("Say \"\(template.wakePhrase)\"")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityLabel("\(template.name). Say \(template.wakePhrase)")
                        }
                    } header: {
                        Text("Available Modes")
                    } footer: {
                        Text("Tap to preview a mode before installing. Each mode has its own wake phrase, system prompt, and camera behavior.")
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
            .listStyle(.insetGrouped)
            .ogFormStyle()
        }
        .presentationDetents([.large])
        .sheet(item: $detailPersona) { persona in
            PersonaDetailView(persona: persona, appState: appState)
        }
    }

    private func activatePersona(_ persona: Persona) {
        appState.activePersona = persona
        Config.setActiveModelId(persona.modelId)
        Config.setActivePresetId(persona.presetId)
        appState.llmService.refreshActiveModel()
        appState.llmService.clearHistory()
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

// MARK: - Persona Tab (embedded in TabView)

/// Full-screen persona browser for the Modes tab.
struct PersonaPickerTab: View {
    @ObservedObject var appState: AppState
    /// Plan HB: the way to Settings › Field Assist while Field Assist is off, or nil when there is
    /// nothing to offer (or the entitlement has not answered yet). With Field Assist on, this tab is
    /// `FieldAssistModeTab` instead.
    var fieldAssistShortcut: ModesTabPresentation.FieldAssistShortcut? = nil

    @State private var editingPersona: Persona? = nil

    var body: some View {
        List {
            // Field Assist sits above the personas: its own mode for field engineers, switched on
            // in one place — Settings › Field Assist.
            if let fieldAssistShortcut {
                Section {
                    FieldAssistShortcutRow(shortcut: fieldAssistShortcut) {
                        appState.openSettings(.fieldAssist)
                    }
                } header: {
                    Text("Field Assist")
                } footer: {
                    Text(fieldAssistShortcut.footer)
                }
            }

            PersonaModeSections(appState: appState) { editingPersona = $0 }
        }
        .navigationTitle("Modes")
        .listStyle(.insetGrouped)
        .ogFormStyle()
        .sheet(item: $editingPersona) { persona in
            PersonaDetailView(persona: persona, appState: appState)
        }
    }
}

/// The Modes tab's Field Assist row: opens Settings › Field Assist, where the switch (and, when
/// not entitled, the paywall) lives.
struct FieldAssistShortcutRow: View {
    @Environment(\.appAccent) private var accent
    let shortcut: ModesTabPresentation.FieldAssistShortcut
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: ModesTabPresentation.fieldAssistSymbol)
                    .font(.title3)
                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.label))
                    Text(shortcut.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if shortcut.showsLock {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: OGMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.spoken)
        .accessibilityHint("Opens Field Assist in Settings.")
        .accessibilityAddTraits(.isButton)
    }
}

/// The persona picker's sections — installed personas, then the modes that can be added. Shared by
/// the Modes tab and the Field Assist tab's Other modes accordion (Plan HB), so the two are the same
/// picker and picking a persona does the same thing from either.
struct PersonaModeSections: View {
    @ObservedObject var appState: AppState
    /// Opens a persona's details. The sheet belongs to the list that hosts these sections.
    let onShowDetails: (Persona) -> Void

    @ScaledMetric(relativeTo: .body) private var infoTapTarget: CGFloat = 44

    var body: some View {
        let personas = Config.enabledPersonas

        if personas.isEmpty {
            ContentUnavailableView(
                "No Personas",
                systemImage: "person.2",
                description: Text("Browse and install AI modes below, or add custom personas in Settings.")
            )
        } else {
            Section {
                ForEach(personas) { persona in
                    HStack(spacing: 0) {
                        Button {
                            activatePersona(persona)
                        } label: {
                            PersonaRow(
                                persona: persona,
                                isActive: appState.activePersona?.id == persona.id
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            onShowDetails(persona)
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .frame(minWidth: infoTapTarget, minHeight: infoTapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Details for \(persona.name)")
                    }
                }
            } header: {
                Text("Active Personas")
            }
        }

        let installed = Set(Config.savedPersonas.map(\.id))
        let available = Config.builtInPersonaTemplates().filter { !installed.contains($0.id) }

        if !available.isEmpty {
            Section {
                ForEach(available) { template in
                    NavigationLink {
                        ModeTemplatePreview(template: template, appState: appState) {
                            installAndActivate(template)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: template.icon ?? "sparkles")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color(.label))
                                Text("Say \"\(template.wakePhrase)\"")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel("\(template.name). Say \(template.wakePhrase)")
                }
            } header: {
                Text("Available Modes")
            } footer: {
                Text("Tap to preview a mode before installing. Each mode has its own wake phrase, system prompt, and camera behavior.")
            }
        }
    }

    // Picking a persona never touches Field Assist (Plan HB): personas choose the model, prompt and
    // wake phrase; Field Assist is switched in Settings › Field Assist and nowhere else.
    private func activatePersona(_ persona: Persona) {
        appState.activePersona = persona
        Config.setActiveModelId(persona.modelId)
        Config.setActivePresetId(persona.presetId)
        appState.llmService.refreshActiveModel()
        appState.llmService.clearHistory()
    }

    private func installAndActivate(_ template: Persona) {
        Config.installPersonaMode(template)
        if let installed = Config.savedPersonas.first(where: { $0.id == template.id }) {
            activatePersona(installed)
        }
    }
}

// MARK: - Persona Detail View (personality, memory, skills)

/// Shows persona details — edit personality, view memory, see capabilities.
struct PersonaDetailView: View {
    let persona: Persona
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss


    @State private var soulText: String = ""
    @State private var hasChanges = false
    @State private var editingPromptPreset: PromptPreset? = nil

    private var modelName: String {
        Config.savedModels.first { $0.id == persona.modelId }?.name ?? "Default"
    }
    private var presetName: String {
        Config.savedPresets.first { $0.id == persona.presetId }?.name ?? "Default"
    }
    private var preset: PromptPreset? {
        Config.savedPresets.first { $0.id == persona.presetId }
    }
    private var toolNames: [String] {
        if let allowed = persona.allowedTools, !allowed.isEmpty {
            return allowed
        }
        return appState.nativeToolRouter.registry.toolNames
    }
    private var memoryContent: String {
        appState.agentDocs.content(for: .memory)
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: Overview
                Section {
                    LabeledContent("Model", value: modelName)
                    LabeledContent("Prompt Preset", value: presetName)
                    LabeledContent("Wake Phrase", value: "\"\(persona.wakePhrase)\"")
                } header: {
                    Label(persona.name, systemImage: persona.icon ?? "person.circle")
                }

                // MARK: Personality / Soul
                Section {
                    if soulText.isEmpty {
                        Text("No custom personality set. Using the global agent soul.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: $soulText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(.label))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .onChange(of: soulText) { _, _ in hasChanges = true }
                } header: {
                    Text("Personality")
                } footer: {
                    Text("Custom soul for this persona. Leave empty to use the global soul.md. This overrides the system prompt personality when agentic mode is on.")
                }

                // MARK: System Prompt Preview
                if let preset {
                    Section {
                        Text(preset.prompt.prefix(300) + (preset.prompt.count > 300 ? "..." : ""))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            editingPromptPreset = preset
                        } label: {
                            Label("Edit Prompt", systemImage: "square.and.pencil")
                        }
                    } header: {
                        Text("System Prompt")
                    } footer: {
                        Text("Editing a built-in prompt makes it your own copy, safe from app updates.")
                    }
                }

                // MARK: Memory
                Section {
                    if memoryContent.isEmpty {
                        Text("No memories yet. The agent learns from conversations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(memoryContent.prefix(500) + (memoryContent.count > 500 ? "..." : ""))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    HStack {
                        Text("Memory")
                        Spacer()
                        Text("\(memoryContent.count) chars")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Shared agent memory (memory.md). The agent updates this as it learns about you.")
                }

                // MARK: Skills / Capabilities
                Section {
                    let tools = toolNames
                    let isRestricted = persona.allowedTools != nil && !persona.allowedTools!.isEmpty
                    ForEach(tools.prefix(20), id: \.self) { tool in
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(tool)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(.label))
                        }
                    }
                    if tools.count > 20 {
                        Text("+ \(tools.count - 20) more tools")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !isRestricted {
                        Text("All \(tools.count) tools available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Skills & Capabilities")
                        Spacer()
                        Text("\(toolNames.count) tools")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Native tools this persona can use. Restrict in Settings → Personas to create focused agents.")
                }
            }
            .navigationTitle("Persona Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if hasChanges { saveChanges() }
                        dismiss()
                    }
                }
                if hasChanges {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveChanges()
                            dismiss()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .ogFormStyle()
            .onAppear {
                soulText = persona.soulOverride ?? ""
            }
            // Same editor + fork-on-save semantics as the System Prompt list.
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

    private func saveChanges() {
        var personas = Config.savedPersonas
        guard let idx = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        let trimmed = soulText.trimmingCharacters(in: .whitespacesAndNewlines)
        personas[idx].soulOverride = trimmed.isEmpty ? nil : trimmed
        Config.setSavedPersonas(personas)
    }
}

// MARK: - Persona Row

struct PersonaRow: View {
    let persona: Persona
    let isActive: Bool
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: persona.icon ?? "person.circle")
                .font(.title3)
                .foregroundStyle(isActive ? AnyShapeStyle(OGTheme.tintedAccentLabel(accent)) : AnyShapeStyle(Color.secondary))
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(persona.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.label))
                    if persona.isBuiltIn == true {
                        OGBadge(text: "Mode")
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
                    .foregroundStyle(OGTheme.okLabel)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(persona.name)\(isActive ? ", active" : ""). Wake phrase: \(persona.wakePhrase)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Mode Template Preview

/// Shows mode/persona template details before installing — user must explicitly tap "Install & Activate".
struct ModeTemplatePreview: View {
    let template: Persona
    @ObservedObject var appState: AppState
    let onInstall: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editingPromptPreset: PromptPreset? = nil


    private var modelName: String {
        if template.modelId.isEmpty {
            return Config.savedModels.first.map(\.name) ?? "Default"
        }
        return Config.savedModels.first { $0.id == template.modelId }?.name ?? "Current Model"
    }

    private var presetName: String {
        if template.presetId.isEmpty {
            return "Default"
        }
        return Config.savedPresets.first { $0.id == template.presetId }?.name ?? "Default"
    }

    var body: some View {
        List {
            // MARK: Header
            Section {
                LabeledContent {
                    if let builtIn = template.isBuiltIn, builtIn {
                        Text("Built-in")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label(template.name, systemImage: template.icon ?? "sparkles")
                        .font(.body.weight(.medium))
                }
            }

            // MARK: Details
            Section {
                LabeledContent("Wake Phrase", value: "\"\(template.wakePhrase)\"")
                if !template.alternativeWakePhrases.isEmpty {
                    LabeledContent("Alternatives") {
                        Text(template.alternativeWakePhrases.map { "\"\($0)\"" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Model", value: modelName)
                LabeledContent("Prompt Preset", value: presetName)
                if let preset = Config.savedPresets.first(where: { $0.id == template.presetId }) {
                    Button {
                        editingPromptPreset = preset
                    } label: {
                        Label("Edit Prompt", systemImage: "square.and.pencil")
                    }
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("Editing a built-in prompt makes it your own copy, safe from app updates.")
            }

            // MARK: Soul / Personality
            if let soul = template.soulOverride, !soul.isEmpty {
                Section {
                    Text(soul)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Personality")
                }
            }

            // MARK: Tools
            if let tools = template.allowedTools, !tools.isEmpty {
                Section {
                    ForEach(tools, id: \.self) { tool in
                        Label(tool, systemImage: "wrench")
                            .font(.caption)
                    }
                } header: {
                    Text("Allowed Tools")
                } footer: {
                    Text("This mode is restricted to \(tools.count) specific tools.")
                }
            }

            // MARK: Install Button
            Section {
                Button {
                    onInstall()
                    dismiss()
                } label: {
                    Text("Install & Activate")
                }
            }
        }
        .navigationTitle("Mode Preview")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .ogFormStyle()
        // Same editor + fork-on-save semantics as the System Prompt list.
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
