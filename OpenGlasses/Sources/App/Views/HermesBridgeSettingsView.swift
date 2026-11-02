import SwiftUI

/// Settings → Connections → Gateways → Hermes Agent (Plan CL P5, Plan JP): route conversation turns through a
/// Hermes agent on the wearer's network — over Hermes Agent's own API server, or over the separate
/// glasses bridge script. Gateway-class feature, so it only takes effect while Agent Mode is on.
struct HermesBridgeSettingsView: View {
    @ObservedObject var appState: AppState

    @State private var enabled = Config.hermesBridgeEnabled
    @State private var kind = Config.hermesConnectionKind
    @State private var host = Config.hermesBridgeHost
    @State private var bridgePort = String(Config.hermesBridgePort)
    @State private var apiPort = String(Config.hermesAPIPort)
    @State private var token = Config.hermesBridgeToken
    @State private var apiKey = Config.hermesAgentAPIKey
    @State private var probeResult: HermesConnectionDiagnosis?
    @State private var probing = false

    var body: some View {
        Form {
            Section {
                Toggle("Route via Hermes Agent", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        Config.setHermesBridgeEnabled(value)
                        applyConnectionState()
                    }
            } footer: {
                if !Config.agentModeEnabled {
                    Text("Requires Agent Mode (Settings → Assistant → Agentic Features). Until it's on, turns keep using the normal model path.")
                } else {
                    Text("When on, Hermes answers your questions with its own tools and memory; the app still transcribes and speaks on-device. If Hermes can't be reached, the turn falls back to the normal model path automatically.")
                }
            }

            Section {
                Picker("Connection", selection: $kind) {
                    ForEach(HermesConnectionKind.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: kind) { _, value in
                    Config.setHermesConnectionKind(value)
                    probeResult = nil
                    applyConnectionState()
                }
            } footer: {
                Text("API server talks to Hermes Agent's built-in API server directly. Bridge script talks to the glasses bridge script, a separate program run beside Hermes.")
            }

            switch kind {
            case .apiServer: apiServerFields
            case .bridgeScript: bridgeScriptFields
            }

            Section {
                Button {
                    runProbe()
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if probing { ProgressView() }
                    }
                }
                .disabled(probing || host.trimmingCharacters(in: .whitespaces).isEmpty)

                if let probeResult, !probing {
                    probeResultRow(probeResult)
                }

                Button("Start a New Hermes Conversation") {
                    switch kind {
                    case .apiServer: appState.hermesAgent.resetConversation()
                    case .bridgeScript: appState.hermesBridge.resetSession()
                    }
                }
            } footer: {
                if let hint = HermesConnectionKind.portHint(kind: kind, host: host, port: currentPort) {
                    Text(portHintText(suggesting: hint))
                }
            }
        }
        .navigationTitle("Hermes Agent")
        .ogFormStyle()
        .onAppear {
            // Pins the default for an install that never chose, so typing a host here cannot
            // flip the kind on screen.
            Config.settleHermesConnectionKind()
            kind = Config.hermesConnectionKind
        }
    }

    // MARK: - Per-kind fields

    private var apiServerFields: some View {
        Section {
            hostField
            TextField("Port", text: $apiPort)
                .keyboardType(.numberPad)
                .onChange(of: apiPort) { _, value in
                    Config.setHermesAPIPort(Int(value) ?? HermesAgentAPI.defaultPort)
                }
            SecretInputField(placeholder: String(localized: "API key (API_SERVER_KEY)"), text: $apiKey)
                .onChange(of: apiKey) { _, value in Config.setHermesAgentAPIKey(value) }
        } header: {
            Text("Hermes API server")
        } footer: {
            Text("On the Hermes machine, set API_SERVER_ENABLED=true and an API_SERVER_KEY (enter the same key here), and set API_SERVER_HOST=0.0.0.0 so the phone can reach it — by default the server only listens on that machine. The default port is 8642. When a question needs eyes, one glasses picture goes with it, through the same privacy filter as every picture the app sends.")
        }
    }

    private var bridgeScriptFields: some View {
        Section {
            hostField
            TextField("Port", text: $bridgePort)
                .keyboardType(.numberPad)
                .onChange(of: bridgePort) { _, value in
                    Config.setHermesBridgePort(Int(value) ?? HermesBridgeProtocol.defaultPort)
                }
            SecretInputField(placeholder: String(localized: "Bridge token (optional)"), text: $token)
                .onChange(of: token) { _, value in Config.setHermesBridgeToken(value) }
        } header: {
            Text("Glasses bridge script")
        } footer: {
            Text("Run the glasses bridge script (hermes_bridge.py) beside Hermes; it prints its address and port when it starts, 8765 by default. It asks for a glasses picture when a question needs eyes. The bridge token is the script's HERMES_BRIDGE_TOKEN, not an API key — leave it empty unless the script was started with one.")
        }
    }

    private var hostField: some View {
        TextField("Host (the Hermes machine's address)", text: $host)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .onChange(of: host) { _, value in
                Config.setHermesBridgeHost(value)
                probeResult = nil
            }
            .onSubmit(commitHost)
    }

    // MARK: - Test Connection

    private func probeResultRow(_ result: HermesConnectionDiagnosis) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.isSuccess ? OGTheme.okLabel : OGTheme.errorLabel)
                .accessibilityHidden(true)
            Text(result.explanation)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.isSuccess
                            ? String(localized: "Connected. \(result.explanation)")
                            : String(localized: "Not connected. \(result.explanation)"))
    }

    private func runProbe() {
        probing = true
        probeResult = nil
        Task {
            let result: HermesConnectionDiagnosis
            switch kind {
            case .apiServer: result = await appState.hermesAgent.checkConnection()
            case .bridgeScript: result = await appState.hermesBridge.checkConnection()
            }
            probeResult = result
            probing = false
            // The row appears under the button; VoiceOver users hear the outcome without hunting.
            AccessibilityNotification.Announcement(result.explanation).post()
        }
    }

    private func portHintText(suggesting other: HermesConnectionKind) -> String {
        switch other {
        case .apiServer:
            return String(localized: "Port 8642 is where Hermes's API server listens. If that's what you set up, switch Connection to API server.")
        case .bridgeScript:
            return String(localized: "Port 8765 is where the glasses bridge script listens. If that's what you set up, switch Connection to Bridge script.")
        }
    }

    // MARK: - Helpers

    private var currentPort: Int {
        switch kind {
        case .apiServer: return Int(apiPort) ?? HermesAgentAPI.defaultPort
        case .bridgeScript: return Int(bridgePort) ?? HermesBridgeProtocol.defaultPort
        }
    }

    /// Only the bridge-script kind holds a socket; the API server is asked per turn.
    private func applyConnectionState() {
        if appState.hermesBridge.isEnabled {
            appState.hermesBridge.connect()
        } else {
            appState.hermesBridge.disconnect()
        }
    }

    /// Show the host as it will be dialled — the scheme in front, and a port pasted with the host
    /// moved into the kind's port field (`GatewayAddress`). Both fields save through `onChange`.
    private func commitHost() {
        switch kind {
        case .apiServer:
            let current = Int(apiPort) ?? HermesAgentAPI.defaultPort
            guard let values = GatewayAddress.fieldValues(host: host, port: current) else { return }
            host = values.host
            apiPort = String(values.port)
        case .bridgeScript:
            let current = Int(bridgePort) ?? HermesBridgeProtocol.defaultPort
            guard let values = GatewayAddress.fieldValues(host: host, port: current, webSocket: true) else { return }
            host = values.host
            bridgePort = String(values.port)
        }
    }
}
