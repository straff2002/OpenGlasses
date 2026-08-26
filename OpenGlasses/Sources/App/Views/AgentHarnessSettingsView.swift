import SwiftUI

/// Settings for the Remote Agent Harness (Plan N): pick the default backend and configure a Custom
/// URL endpoint. Surfaced from Agentic Features, so it only appears when Agent Mode is on.
struct AgentHarnessSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var defaultKind: AgentHarnessKind = Config.defaultAgentHarness
    @State private var config: CustomHarnessConfig = Config.customAgentHarness ?? CustomHarnessConfig()
    @State private var saved = false
    // Codex / Claude Code remote (Plan N Phase 3)
    @State private var codexToken: String = Config.codexAgentToken
    @State private var codexBaseURL: String = Config.codexAgentBaseURL
    @State private var claudeToken: String = Config.claudeRemoteToken
    @State private var claudeBaseURL: String = Config.claudeRemoteBaseURL

    var body: some View {
        Form {
            Section {
                Picker("Default backend", selection: $defaultKind) {
                    ForEach(AgentHarnessKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
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
                SecretInputField(placeholder: "OpenAI Codex API token", text: $codexToken)
                urlField("Base URL (optional override)", text: $codexBaseURL)
                SecretInputField(placeholder: "Claude Code API token", text: $claudeToken)
                urlField("Base URL (optional override)", text: $claudeBaseURL)
                Button {
                    saveRemotePresets()
                } label: {
                    Label("Save Codex / Claude Code", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("OpenAI Codex · Claude Code (remote)")
            } footer: {
                Text("Paste a token to enable the backend — the endpoints are pre-filled (override the base URL only if your deployment differs). Tokens are stored in the Keychain. Live dispatch is verified against your endpoint.")
            }

            Section {
                TextField("Name (e.g. My Agent SDK)", text: $config.name)
                urlField("Start URL (POST)", text: $config.startURL)
                urlField("Status URL — use {id}", text: $config.statusURLTemplate)
                urlField("Cancel URL — use {id} (optional)", text: $config.cancelURLTemplate)
            } header: {
                Text("Custom endpoint")
            } footer: {
                if let issue = config.transportIssue {
                    Label(issue, systemImage: "lock.slash")
                        .foregroundStyle(OGTheme.errorLabel)
                } else {
                    Text("Point OpenGlasses at any agent endpoint you already run. {id} is replaced with the run id, e.g. https://host/runs/{id}.")
                }
            }

            Section("Authentication") {
                TextField("Header name", text: $config.authHeader)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecretInputField(placeholder: "Header value (e.g. Bearer …)", text: $config.authValue)
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

    private func saveRemotePresets() {
        Config.setCodexAgentToken(codexToken.trimmingCharacters(in: .whitespaces))
        Config.setCodexAgentBaseURL(codexBaseURL.trimmingCharacters(in: .whitespaces))
        Config.setClaudeRemoteToken(claudeToken.trimmingCharacters(in: .whitespaces))
        Config.setClaudeRemoteBaseURL(claudeBaseURL.trimmingCharacters(in: .whitespaces))
        appState.rebuildAgentHarnessRegistry()
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
