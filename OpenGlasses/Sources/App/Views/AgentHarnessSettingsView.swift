import SwiftUI

/// Settings for the Remote Agent Harness (Plan N): pick the default backend and configure a Custom
/// URL endpoint. Surfaced from Agentic Features, so it only appears when Agent Mode is on.
struct AgentHarnessSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var defaultKind: AgentHarnessKind = Config.defaultAgentHarness
    @State private var config: CustomHarnessConfig = Config.customAgentHarness ?? CustomHarnessConfig()
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Picker("Default backend", selection: $defaultKind) {
                    Text(AgentHarnessKind.openclaw.displayName).tag(AgentHarnessKind.openclaw)
                    Text(AgentHarnessKind.custom.displayName).tag(AgentHarnessKind.custom)
                }
                .onChange(of: defaultKind) { _, kind in
                    Config.setDefaultAgentHarness(kind)
                }
            } header: {
                Text("Default")
            } footer: {
                Text("Which backend the “code_agent” voice tool dispatches to. OpenClaw uses your existing gateway connection; Custom uses the endpoint below.")
            }

            Section {
                TextField("Name (e.g. My Agent SDK)", text: $config.name)
                urlField("Start URL (POST)", text: $config.startURL)
                urlField("Status URL — use {id}", text: $config.statusURLTemplate)
                urlField("Cancel URL — use {id} (optional)", text: $config.cancelURLTemplate)
            } header: {
                Text("Custom endpoint")
            } footer: {
                Text("Point OpenGlasses at any agent endpoint you already run. {id} is replaced with the run id, e.g. https://host/runs/{id}.")
            }

            Section("Authentication") {
                TextField("Header name", text: $config.authHeader)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Header value (e.g. Bearer …)", text: $config.authValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                fieldRow("Prompt field", text: $config.promptField)
                fieldRow("Project field", text: $config.projectField)
                fieldRow("Run-id path", text: $config.idPath)
                fieldRow("Status path", text: $config.statusPath)
            } header: {
                Text("Field mapping")
            } footer: {
                Text("Body keys sent on start, and dot-paths read from the responses (e.g. data.run.id).")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(saved ? "Saved" : "Save endpoint", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(!config.isConfigured)

                if Config.customAgentHarness != nil {
                    Button(role: .destructive) {
                        Config.setCustomAgentHarness(nil)
                        config = CustomHarnessConfig()
                        appState.rebuildAgentHarnessRegistry()
                        saved = false
                    } label: {
                        Label("Remove endpoint", systemImage: "trash")
                    }
                }
            } footer: {
                Text("Stored securely in the Keychain. The token never leaves your device except to the endpoint you set.")
            }
        }
        .navigationTitle("Remote Agents")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        Config.setCustomAgentHarness(config)
        appState.rebuildAgentHarnessRegistry()
        saved = true
    }

    @ViewBuilder
    private func urlField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
    }

    @ViewBuilder
    private func fieldRow(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}
