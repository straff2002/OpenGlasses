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
                if let collision = config.fieldCollisionIssue {
                    Label(collision, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OGTheme.errorLabel)
                } else {
                    Text("Body keys sent on start, and dot-paths read from the responses (e.g. data.run.id).")
                }
            }

            Section {
                fieldRow("Agent field", text: $config.agentField)
                fieldRow("Agent value", text: $config.agentValue)
            } header: {
                Text("Which agent")
            } footer: {
                Text("For an endpoint that fronts more than one coding agent: the body key and the value to send in it. Both blank means the endpoint decides. This is a fixed request value — it isn't chosen by what you say or which voice persona is active.")
            }

            Section {
                urlField("Answer URL (POST) — use {id}", text: $config.inputURLTemplate)
                fieldRow("Answer field", text: $config.inputField)
                fieldRow("Question prompt path", text: $config.questionPromptPath)
                fieldRow("Question id path", text: $config.questionIDPath)
                fieldRow("Question revision path", text: $config.questionRevisionPath)
                fieldRow("Question kind path", text: $config.questionKindPath)
            } header: {
                Text("Questions and answers")
            } footer: {
                if config.acceptsReplies {
                    Text("Answers are POSTed here with the question's id and revision, plus an answer id that stays the same if a send has to be retried. Without a question-id path, two questions worded the same way are told apart only by the order they arrive in. A question whose kind path says “text” can be answered in words; anything else is treated as a confirmation.")
                } else {
                    Text("Optional. Without an answer address, a question this endpoint asks can be heard but not answered — and you'll be told so rather than left thinking a reply went through.")
                }
            }

            Section {
                fieldRow("Summary / final text path", text: $config.finalTextPath)
                fieldRow("Files created path", text: $config.filesCreatedPath)
                fieldRow("Files modified path", text: $config.filesModifiedPath)
                fieldRow("Commands run path", text: $config.commandsRunPath)
                fieldRow("Pushed path", text: $config.pushedPath)
                fieldRow("Pull-request URL path", text: $config.prURLPath)
                fieldRow("Error message path", text: $config.errorPath)
            } header: {
                Text("Result mapping")
            } footer: {
                if config.mapsAnyResultField {
                    Text("Read from the same status response, so following a run costs no extra requests.")
                } else {
                    Text("Optional dot-paths read from the same status response. Leave one blank if your endpoint doesn't report it — anything unmapped is reported as unknown rather than as “nothing changed”.")
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(saved ? "Saved" : "Save endpoint", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(!config.isConfigured || config.fieldCollisionIssue != nil)

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
        .ogFormStyle()
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
