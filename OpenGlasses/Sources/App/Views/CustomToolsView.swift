import SwiftUI

/// Manage user-defined custom tools that map to Siri Shortcuts or URL schemes.
struct CustomToolsView: View {
    @EnvironmentObject var appState: AppState
    @State private var tools: [CustomToolDefinition] = Config.customTools
    @State private var showAddSheet = false
    @State private var editingTool: CustomToolDefinition? = nil

    var body: some View {
        List {
            if tools.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Custom Tools",
                        systemImage: "hammer",
                        description: Text("Add tools that trigger Siri Shortcuts or open URL schemes when the AI calls them.")
                    )
                }
            } else {
                Section {
                    ForEach(tools) { tool in
                        Button {
                            editingTool = tool
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(tool.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(tool.actionType.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    Text(tool.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        tools.remove(atOffsets: indexSet)
                        saveAndReload()
                    }
                } header: {
                    Text("Custom Tools")
                } footer: {
                    Text("These tools are available to the AI alongside built-in tools. Disable them in Settings → Tools.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How it works", systemImage: "info.circle")
                        .font(.footnote.weight(.medium))
                    Text("Define a tool name and description. When the AI decides to use your tool, it will run the Siri Shortcut or open the URL you configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Example: A \"log_water\" tool that runs your \"Log Water\" shortcut, or a \"open_notion\" tool that opens notion://.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Custom Tools")
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
            CustomToolEditorView(tool: nil, existingNames: nativeToolNames()) { newTool in
                tools.append(newTool)
                saveAndReload()
            }
        }
        .sheet(item: $editingTool) { tool in
            CustomToolEditorView(tool: tool, existingNames: nativeToolNames()) { updated in
                if let idx = tools.firstIndex(where: { $0.id == updated.id }) {
                    tools[idx] = updated
                }
                saveAndReload()
            }
        }
    }

    private func nativeToolNames() -> Set<String> {
        let native = appState.nativeToolRouter.registry.allTools.map(\.name)
        let custom = tools.map(\.name)
        return Set(native).subtracting(Set(custom))
    }

    private func saveAndReload() {
        Config.setCustomTools(tools)
        appState.nativeToolRouter.registry.registerCustomTools()
    }
}

// MARK: - Editor

struct CustomToolEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let tool: CustomToolDefinition?
    let existingNames: Set<String>
    let onSave: (CustomToolDefinition) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var actionType: CustomToolDefinition.ActionType = .shortcut
    @State private var shortcutName = ""
    @State private var urlTemplate = ""
    @State private var parameters: [CustomToolDefinition.CustomToolParam] = []

    private var nameError: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }  // Don't show error for empty
        if trimmed.contains(" ") { return "Use underscores instead of spaces" }
        if existingNames.contains(trimmed) && trimmed != tool?.name {
            return "A built-in tool with this name already exists"
        }
        return nil
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !description.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard nameError == nil else { return false }
        switch actionType {
        case .shortcut: return !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        case .urlScheme: return !urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Identity
                Section {
                    TextField("Tool name (e.g. log_water)", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if let error = nameError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    TextField("Description for the AI", text: $description)
                } header: {
                    Text("Tool Identity")
                } footer: {
                    Text("The name is how the AI calls this tool. The description tells it when to use it.")
                }

                // MARK: Action
                Section {
                    Picker("Action Type", selection: $actionType) {
                        ForEach(CustomToolDefinition.ActionType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    switch actionType {
                    case .shortcut:
                        TextField("Shortcut name (exact)", text: $shortcutName)
                            .autocorrectionDisabled()
                    case .urlScheme:
                        TextField("URL template", text: $urlTemplate)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                } header: {
                    Text("Action")
                } footer: {
                    switch actionType {
                    case .shortcut:
                        Text("Enter the exact name of your Siri Shortcut. The first parameter value is passed as input.")
                    case .urlScheme:
                        Text("Use {{param_name}} for placeholders. Example: myapp://action?value={{amount}}")
                    }
                }

                // MARK: Parameters
                Section {
                    ForEach($parameters) { $param in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Name", text: $param.name)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                Picker("", selection: $param.type) {
                                    Text("String").tag("string")
                                    Text("Number").tag("number")
                                }
                                .labelsHidden()
                                .frame(width: 100)
                            }
                            TextField("Description", text: $param.description)
                                .font(.footnote)
                            Toggle("Required", isOn: $param.required)
                                .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        parameters.remove(atOffsets: indexSet)
                    }

                    Button {
                        parameters.append(CustomToolDefinition.CustomToolParam(
                            id: UUID().uuidString,
                            name: "",
                            type: "string",
                            description: "",
                            required: true
                        ))
                    } label: {
                        Label("Add Parameter", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Parameters")
                } footer: {
                    Text("Define what information the AI should provide when calling this tool.")
                }
            }
            .navigationTitle(tool != nil ? "Edit Tool" : "New Custom Tool")
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
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let tool {
                    name = tool.name
                    description = tool.description
                    actionType = tool.actionType
                    shortcutName = tool.shortcutName ?? ""
                    urlTemplate = tool.urlTemplate ?? ""
                    parameters = tool.parameters
                }
            }
        }
    }

    private func save() {
        let definition = CustomToolDefinition(
            id: tool?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces).lowercased(),
            description: description.trimmingCharacters(in: .whitespaces),
            parameters: parameters.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty },
            actionType: actionType,
            shortcutName: actionType == .shortcut ? shortcutName.trimmingCharacters(in: .whitespaces) : nil,
            urlTemplate: actionType == .urlScheme ? urlTemplate.trimmingCharacters(in: .whitespaces) : nil
        )
        onSave(definition)
    }
}
