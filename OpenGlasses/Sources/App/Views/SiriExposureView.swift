import SwiftUI

/// Settings → Siri & Search (Plan BQ P1) — the user-curated Siri surface.
///
/// Three sections mirror the catalog's three sources: built-in action toggles, harvested
/// user-authored capabilities (capture flows / procedures / playbooks / custom tools), and
/// hand-made actions. Every mutation persists via `Config.setSiriExposure` and refreshes
/// Siri's phrase predictions with `updateAppShortcutParameters()`.
struct SiriExposureView: View {
    @State private var config = Config.siriExposure
    @State private var contentConfig = Config.siriContentIndex
    @State private var editingAction: SiriActionDefinition?
    @State private var showingEditor = false

    var body: some View {
        List {
            Section {
                Text("Choose what Siri can run. Say \"Run <action> on OpenGlasses\" — or create your own actions below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in Actions") {
                ForEach(BuiltinSiriAction.all) { builtin in
                    Toggle(builtin.displayName, isOn: builtinBinding(builtin.id))
                }
            }

            let harvested = harvestedEntries
            if !harvested.isEmpty {
                Section {
                    ForEach(harvested, id: \.id) { capability in
                        Toggle(isOn: capabilityBinding(capability.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capability.title)
                                Text(capability.kind.displayLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Your Capabilities")
                } footer: {
                    Text("Capture flows, procedures, playbooks, and custom tools you've authored. Off by default — turn one on to run it by voice.")
                }
            }

            Section {
                ForEach(config.userActions) { action in
                    Button {
                        editingAction = action
                        showingEditor = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.displayName)
                                    .foregroundStyle(.primary)
                                Text(bindingSummary(action.binding))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Named so VoiceOver doesn't reach an unnamed switch;
                            // `.labelsHidden()` only hides it visually.
                            Toggle(action.displayName, isOn: userActionBinding(action.id))
                                .labelsHidden()
                        }
                    }
                }
                .onDelete { offsets in
                    config.userActions.remove(atOffsets: offsets)
                    save()
                }

                Button {
                    editingAction = nil
                    showingEditor = true
                } label: {
                    Label("Add Action", systemImage: "plus.circle")
                }
            } header: {
                Text("Custom Actions")
            } footer: {
                Text("Built-in actions stay visible in the Shortcuts app even when off — turning one off makes Siri refuse it and hides it from the action list.")
            }

            contentIndexSections
        }
        .navigationTitle("Siri & Search")
        .sheet(isPresented: $showingEditor) {
            SiriActionEditorView(existing: editingAction) { saved in
                if let index = config.userActions.firstIndex(where: { $0.id == saved.id }) {
                    config.userActions[index] = saved
                } else {
                    config.userActions.append(saved)
                }
                save()
            }
        }
    }

    // MARK: Content in Search (Plan BQ P2)

    @ViewBuilder
    private var contentIndexSections: some View {
        if Config.hipaaMode {
            Section("Content in Search") {
                Text("Spotlight donation is disabled while Medical Compliance Mode is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(SiriContentType.allCases.filter { $0 != .fieldSession }, id: \.rawValue) { type in
                    Toggle(type.displayLabel, isOn: contentTypeBinding(type))
                }
            } header: {
                Text("Content in Search")
            } footer: {
                Text("Exposed content appears in Spotlight and Siri search. Conversations donate titles only. Health data, recognized people, and audio are never indexed.")
            }

            let vaults = fieldSessionVaultIds
            if !vaults.isEmpty {
                Section {
                    ForEach(vaults, id: \.self) { vaultId in
                        Toggle(vaultId, isOn: fieldSessionVaultBinding(vaultId))
                    }
                } header: {
                    Text("Field Sessions in Search")
                } footer: {
                    Text("Per-vault. Only session metadata (asset, date, outcome) is donated — never the audit log or captured values.")
                }
            }
        }
    }

    /// Vaults with any completed session — the candidates for per-vault opt-in.
    private var fieldSessionVaultIds: [String] {
        Array(Set(FieldSessionService.shared.history
            .filter { $0.endedAt != nil }
            .map(\.vaultId)))
            .sorted()
    }

    private func contentTypeBinding(_ type: SiriContentType) -> Binding<Bool> {
        Binding(
            get: { contentConfig.isEnabled(type) },
            set: { enabled in
                if type.defaultEnabled {
                    if enabled {
                        contentConfig.disabledTypes.remove(type.rawValue)
                    } else {
                        contentConfig.disabledTypes.insert(type.rawValue)
                    }
                } else {
                    if enabled {
                        contentConfig.optInTypes.insert(type.rawValue)
                    } else {
                        contentConfig.optInTypes.remove(type.rawValue)
                    }
                }
                saveContentConfig()
            }
        )
    }

    private func fieldSessionVaultBinding(_ vaultId: String) -> Binding<Bool> {
        Binding(
            get: { contentConfig.fieldSessionVaults.contains(vaultId) },
            set: { enabled in
                if enabled {
                    contentConfig.fieldSessionVaults.insert(vaultId)
                } else {
                    contentConfig.fieldSessionVaults.remove(vaultId)
                }
                saveContentConfig()
            }
        )
    }

    private func saveContentConfig() {
        Config.setSiriContentIndex(contentConfig)
        SpotlightIndexService.shared.requestRefresh()
    }

    // MARK: State plumbing

    private var harvestedEntries: [(id: String, title: String, kind: SiriCapabilityKind)] {
        SiriActionCatalogProvider.current().entries
            .filter { $0.source == .harvested }
            .compactMap { entry in
                guard case .capability(let kind, let capabilityId) = entry.binding else { return nil }
                return (
                    id: SiriExposureConfig.capabilityKey(kind: kind, id: capabilityId),
                    title: entry.displayName,
                    kind: kind
                )
            }
    }

    private func builtinBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !config.disabledBuiltinActions.contains(id) },
            set: { enabled in
                if enabled {
                    config.disabledBuiltinActions.remove(id)
                } else {
                    config.disabledBuiltinActions.insert(id)
                }
                save()
            }
        )
    }

    private func capabilityBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { config.enabledCapabilityIds.contains(key) },
            set: { enabled in
                if enabled {
                    config.enabledCapabilityIds.insert(key)
                } else {
                    config.enabledCapabilityIds.remove(key)
                }
                save()
            }
        )
    }

    private func userActionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { config.userActions.first { $0.id == id }?.isEnabled ?? false },
            set: { enabled in
                if let index = config.userActions.firstIndex(where: { $0.id == id }) {
                    config.userActions[index].isEnabled = enabled
                    save()
                }
            }
        )
    }

    private func bindingSummary(_ binding: SiriActionBinding) -> String {
        switch binding {
        case .builtin(let id): return "Built-in: \(id)"
        case .prompt(let text): return "Ask: \(text.prefix(60))"
        case .tool(let name, _): return "Tool: \(name)"
        case .capability(let kind, let id): return "\(kind.displayLabel): \(id)"
        }
    }

    private func save() {
        Config.setSiriExposure(config)
        OpenGlassesShortcuts.updateAppShortcutParameters()
    }
}

/// Add/edit one hand-made Siri action: a spoken name plus what it does — a canned prompt to
/// the assistant, one native-tool call, or one of the user's custom tools (Agent Mode only).
struct SiriActionEditorView: View {
    enum BindingKind: String, CaseIterable, Identifiable {
        case prompt = "Ask the Assistant"
        case tool = "Run a Tool"
        case customTool = "Run a Custom Tool"
        var id: String { rawValue }
    }

    let existing: SiriActionDefinition?
    let onSave: (SiriActionDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var synonymsText = ""
    @State private var bindingKind: BindingKind = .prompt
    @State private var promptText = ""
    @State private var toolName = ""
    @State private var toolArgsJSON = ""
    @State private var customToolId = ""
    @State private var validationMessage: String?

    private var availableToolNames: [String] {
        (AppStateProvider.shared?.nativeToolRegistry.allTools.map(\.name) ?? []).sorted()
    }

    private var customToolNames: [String] {
        Config.customTools.map(\.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Action name (what you'll say)", text: $displayName)
                    TextField("Other names, comma-separated (optional)", text: $synonymsText)
                }

                Section("What it does") {
                    Picker("Type", selection: $bindingKind) {
                        ForEach(availableKinds) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }

                    switch bindingKind {
                    case .prompt:
                        TextField("Instruction for the assistant", text: $promptText, axis: .vertical)
                            .lineLimit(2...5)
                    case .tool:
                        Picker("Tool", selection: $toolName) {
                            Text("Choose…").tag("")
                            ForEach(availableToolNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        TextField("Arguments JSON (optional)", text: $toolArgsJSON, axis: .vertical)
                            .font(.footnote.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    case .customTool:
                        Picker("Custom Tool", selection: $customToolId) {
                            Text("Choose…").tag("")
                            ForEach(customToolNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Action" : "Edit Action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAction() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private var availableKinds: [BindingKind] {
        var kinds: [BindingKind] = [.prompt, .tool]
        if Config.agentModeEnabled && !customToolNames.isEmpty {
            kinds.append(.customTool)
        }
        return kinds
    }

    private func load() {
        guard let existing else { return }
        displayName = existing.displayName
        synonymsText = existing.synonyms.joined(separator: ", ")
        switch existing.binding {
        case .prompt(let text):
            bindingKind = .prompt
            promptText = text
        case .tool(let name, let argsJSON):
            bindingKind = .tool
            toolName = name
            toolArgsJSON = argsJSON
        case .capability(kind: .customTool, id: let id):
            bindingKind = .customTool
            customToolId = id
        case .builtin, .capability:
            bindingKind = .prompt
        }
    }

    private func saveAction() {
        let binding: SiriActionBinding
        switch bindingKind {
        case .prompt: binding = .prompt(text: promptText)
        case .tool: binding = .tool(name: toolName, argsJSON: toolArgsJSON)
        case .customTool: binding = .capability(kind: .customTool, id: customToolId)
        }

        let synonyms = synonymsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var definition = existing ?? SiriActionDefinition(displayName: "", binding: binding)
        definition.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.synonyms = synonyms
        definition.binding = binding

        let catalog = SiriActionCatalogProvider.current()
        if let issue = SiriActionCatalog.validate(
            definition,
            existing: catalog.entries,
            availableToolNames: availableToolNames.isEmpty ? nil : Set(availableToolNames),
            agentModeEnabled: Config.agentModeEnabled,
            blockedToolNames: Config.hipaaMode ? Config.hipaaDisabledTools : []
        ) {
            validationMessage = Self.message(for: issue)
            return
        }

        onSave(definition)
        dismiss()
    }

    private static func message(for issue: SiriActionCatalog.ValidationIssue) -> String {
        switch issue {
        case .emptyName:
            return "Give the action a name — it's what you'll say to Siri."
        case .duplicateName(let name):
            return "An action named \"\(name)\" already exists."
        case .emptyPrompt:
            return "Enter the instruction to send to the assistant."
        case .unknownTool(let tool):
            return "No tool named \"\(tool)\" exists."
        case .invalidArgsJSON:
            return "Arguments must be a valid JSON object, like {\"action\": \"start\"}."
        case .toolBlockedByCompliance(let tool):
            return "\"\(tool)\" is unavailable while Medical Compliance Mode is on."
        case .agentModeRequired:
            return "Custom tools need Agentic Features enabled (Settings → Agentic Features)."
        }
    }
}
