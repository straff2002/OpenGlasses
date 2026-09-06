import SwiftUI

/// Settings for the Web HUD mirror (Plan BP) — the entitlement-free Ray-Ban Display path:
/// the glasses' built-in 600×600 web view fetches a page served from the phone and polls
/// the current HUD frame. Read-only mirror; all interaction stays on the phone/band.
struct WebHUDMirrorSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var enabled = Config.hudMirrorEnabled
    @State private var exportedPreview: URL?

    private var legacyTransportAvailable: Bool {
        LocalServiceExposurePolicy.current.permitsListener(for: .webHUDMirror)
    }

    var body: some View {
        Form {
            if Config.hipaaMode {
                Section {
                    Label("Disabled in HIPAA mode", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("The mirror serves HUD content over the network, so HIPAA mode hard-disables it.")
                }
            }

            Section {
                Toggle("Web HUD Mirror", isOn: $enabled)
                    .disabled(Config.hipaaMode || !Config.agentModeEnabled || !legacyTransportAvailable)
                    .onChange(of: enabled) { _, newValue in
                        Config.hudMirrorEnabled = newValue
                        if newValue {
                            appState.webHUDMirror.startIfEnabled()
                        } else {
                            appState.webHUDMirror.stop()
                        }
                    }
                if !Config.agentModeEnabled {
                    Label("Requires Agent Mode", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OGTheme.warnLabel)
                } else if !legacyTransportAvailable {
                    Label("Unavailable in production builds", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if legacyTransportAvailable {
                    Text("Serves the current HUD frame to the glasses' built-in web view — no display entitlement needed. Read-only: item labels render, actions stay on the phone.")
                } else {
                    Text("Secure browser sharing is not implemented yet; the legacy cleartext listener is limited to Debug development builds.")
                }
            }

            if enabled, appState.webHUDMirror.isRunning {
                Section {
                    if let url = appState.webHUDMirror.registrationURL {
                        Text(url)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        ShareLink(item: url) { Label("Share URL", systemImage: "square.and.arrow.up") }
                    } else {
                        Text("No Wi-Fi address available").foregroundStyle(.secondary)
                    }
                    Button("Rotate Token", role: .destructive) {
                        appState.webHUDMirror.rotateToken()
                    }
                } header: {
                    Text("Registration URL")
                } footer: {
                    Text("Register this URL once in the Meta AI app's Developer Mode. The access token rides the URL hash, which never appears in requests or logs. Rotating the token invalidates the registered URL.")
                }
            }

            Section {
                Button("Export Preview Page") {
                    exportPreview()
                }
                if let exportedPreview {
                    ShareLink(item: exportedPreview) { Label("Share Preview HTML", systemImage: "doc.richtext") }
                }
            } header: {
                Text("Desktop Dev Loop")
            } footer: {
                Text("Writes the current HUD frame as a self-contained HTML file — open it in any browser at 600\u{00D7}600 to preview exactly what the glasses would render. Arrow keys stand in for the D-pad.")
            }
        }
        .navigationTitle("Web HUD Mirror")
        .ogFormStyle()
        .onAppear {
            // Policy enforcement does not trust this preference. Clearing it prevents a stale
            // Debug opt-in from appearing active after installation of a production build.
            if !legacyTransportAvailable {
                enabled = false
                Config.hudMirrorEnabled = false
            }
        }
    }

    private func exportPreview() {
        let screen = appState.glassesDisplay.mirrorScreen ?? HUDScreen(
            title: "OpenGlasses",
            lines: [HUDLine("Web HUD mirror preview", icon: .info),
                    HUDLine("Black is transparent on glasses", emphasis: .secondary)],
            items: [HUDItem(id: "a", label: "Sample item", style: .primary) {},
                    HUDItem(id: "b", label: "Another item") {}])
        let html = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: screen)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hud-preview.html")
        try? html.write(to: url, atomically: true, encoding: .utf8)
        exportedPreview = url
    }
}
