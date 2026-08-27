import SwiftUI

/// Settings for the developer-only MCP Glasses server (Plan E). Lets a Claude Code session on the
/// same network see through the glasses and push text/TTS. Requires Agent Mode to be on.
@MainActor
struct MCPServerSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var server = MCPGlassesServer.shared
    @AppStorage("mcpServerEnabled") private var enabled: Bool = false

    private var agentModeOn: Bool { Config.agentModeEnabled }

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP Glasses Server", isOn: $enabled)
                    .tint(AppAccent.color)
                    .disabled(!agentModeOn)
                    .onChange(of: enabled) { _, newValue in
                        if newValue && agentModeOn {
                            appState.startMCPServer()
                        } else {
                            MCPGlassesServer.shared.stop()
                        }
                    }
            } footer: {
                if agentModeOn {
                    Text("Exposes the glasses camera and TTS to a Claude Code session on your network. Developer-only.")
                } else {
                    Text("Requires Agent Mode. Enable Agent Mode first, then turn this on.")
                }
            }

            if server.isRunning {
                Section("Connection") {
                    LabeledContent("Status", value: "Running")
                    if let ip = MCPGlassesServer.lanIPAddress() {
                        LabeledContent("LAN URL", value: "http://\(ip):\(server.port)")
                    }
                    LabeledContent("Endpoints", value: "/see_glasses, /glasses_status, /send_to_glasses")
                }
                Section("Access token") {
                    Text(server.accessToken)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = server.accessToken
                    } label: {
                        Label("Copy token", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        server.regenerateToken()
                    } label: {
                        Label("Regenerate token", systemImage: "arrow.clockwise")
                    }
                }
                Section {
                    Text("Every request must send `Authorization: Bearer <token>`. Configure your Claude Code MCP bridge with the LAN URL and this token. Keep it on your trusted local network — these endpoints expose the live camera, so don't put them behind a public tunnel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("MCP Server")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }
}
