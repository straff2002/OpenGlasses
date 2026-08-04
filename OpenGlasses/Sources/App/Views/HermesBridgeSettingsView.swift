import SwiftUI

/// Settings → Connections → Hermes Bridge (Plan CL P5): route conversation
/// turns through a Hermes agent running on a Mac on the LAN. Gateway-class
/// feature, so it only takes effect while Agent Mode is on.
struct HermesBridgeSettingsView: View {
    @ObservedObject var appState: AppState

    @State private var enabled = Config.hermesBridgeEnabled
    @State private var host = Config.hermesBridgeHost
    @State private var port = String(Config.hermesBridgePort)
    @State private var token = Config.hermesBridgeToken
    @State private var probeResult: Bool?
    @State private var probing = false

    var body: some View {
        Form {
            Section {
                Toggle("Route via Hermes Bridge", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        Config.setHermesBridgeEnabled(value)
                        if value { appState.hermesBridge.connect() }
                        else { appState.hermesBridge.disconnect() }
                    }
            } footer: {
                if !Config.agentModeEnabled {
                    Text("Requires Agent Mode (Settings → Tools & Actions → Agentic Features). Until it's on, turns keep using the normal model path.")
                } else {
                    Text("When on, the bridge answers your queries with its own tools and memory; the app still transcribes and speaks on-device. If the bridge is unreachable the turn falls back to the normal model path automatically.")
                }
            }

            Section {
                TextField("Host (Mac's LAN address)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: host) { _, value in Config.setHermesBridgeHost(value) }

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .onChange(of: port) { _, value in
                        Config.setHermesBridgePort(Int(value) ?? HermesBridgeProtocol.defaultPort)
                    }

                SecretInputField(placeholder: "Auth Token (optional)", text: $token)
                    .onChange(of: token) { _, value in Config.setHermesBridgeToken(value) }
            } header: {
                Text("Bridge")
            } footer: {
                Text("The bridge prints its address and port when it starts. Leave the token empty unless the bridge was started with one.")
            }

            Section {
                Button {
                    probing = true
                    probeResult = nil
                    Task {
                        probeResult = await appState.hermesBridge.checkConnection()
                        probing = false
                    }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if probing {
                            ProgressView()
                        } else if let probeResult {
                            Image(systemName: probeResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(probeResult ? .green : .red)
                        }
                    }
                }
                .disabled(probing || host.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Reset Bridge Conversation") {
                    appState.hermesBridge.resetSession()
                }
            }
        }
        .navigationTitle("Hermes Bridge")
        .ogFormStyle()
    }
}
