import SwiftUI

/// Lists all registered native tools with toggle, description, and parameter info.
/// Part of the open-source transparency — users can see and control what the AI can do.
struct ToolsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var disabledTools: Set<String> = Config.disabledTools
    @State private var searchText = ""

    private var allTools: [(name: String, description: String, params: [String: Any])] {
        appState.nativeToolRouter.registry.allTools
            .map { (name: $0.name, description: $0.description, params: $0.parametersSchema) }
            .sorted { $0.name < $1.name }
    }

    private var filteredTools: [(name: String, description: String, params: [String: Any])] {
        if searchText.isEmpty { return allTools }
        let query = searchText.lowercased()
        return allTools.filter {
            $0.name.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    private var enabledCount: Int {
        allTools.filter { !disabledTools.contains($0.name) }.count
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Total tools", value: "\(allTools.count)")
                LabeledContent("Enabled", value: "\(enabledCount) of \(allTools.count)")
            } header: {
                Text("Overview")
            } footer: {
                Text("Disabled tools won't be included in the AI's system prompt and can't be called.")
            }

            Section {
                ForEach(filteredTools, id: \.name) { tool in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tool.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if let properties = tool.params["properties"] as? [String: Any], !properties.isEmpty {
                                Divider()
                                Text("Parameters")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(Array(properties.keys.sorted()), id: \.self) { key in
                                    if let paramInfo = properties[key] as? [String: Any] {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(key)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Text(paramInfo["type"] as? String ?? "any")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { !disabledTools.contains(tool.name) },
                                set: { enabled in
                                    if enabled {
                                        disabledTools.remove(tool.name)
                                    } else {
                                        disabledTools.insert(tool.name)
                                    }
                                    Config.setDisabledTools(disabledTools)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(tool.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Native Tools")
            }

            if Config.isOpenClawConfigured {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenClaw Gateway")
                            Text("56+ tools via your Mac — messaging, web search, smart home, and more.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("External Tools")
                } footer: {
                    Text("OpenClaw tools are managed on your Mac. The 'execute' tool is added to the prompt when the gateway is connected.")
                }
            }
        }
        .navigationTitle("Tools")
        .searchable(text: $searchText, prompt: "Search tools")
    }
}
