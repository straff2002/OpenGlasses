import SwiftUI

/// Settings UI for the Field Assist (B2B) feature: master toggle, vault picker,
/// default session mode, and a manual session start/end for debugging.
@MainActor
struct FieldAssistSettingsView: View {
    @StateObject private var sessionService = FieldSessionService.shared
    @AppStorage("fieldAssistEnabled") private var enabled: Bool = false
    @AppStorage("fieldAssistDeveloperUnlocked") private var developerUnlocked: Bool = false
    @AppStorage("fieldAssistDefaultVaultId") private var defaultVaultId: String = "refrigeration"
    @AppStorage("fieldAssistDefaultMode") private var defaultMode: String = "ai_only"

    var body: some View {
        Form {
            // ──────────────── Toggle
            Section {
                Toggle("Enable Field Assist", isOn: $enabled)
                    .tint(AppAccent.color)
            } footer: {
                Text("Field Assist provides hands-free, domain-grounded guidance for service technicians. When enabled, the `field_session` tool becomes available and an active session injects the relevant knowledge vault into the AI's context.")
            }

            // ──────────────── Vault selection
            if enabled {
                Section("Default Vault") {
                    ForEach(VaultRegistry.shared.allManifests, id: \.id) { manifest in
                        let unlocked = VaultRegistry.shared.isUnlocked(manifest)
                        Button {
                            if unlocked {
                                defaultVaultId = manifest.id
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manifest.name)
                                        .foregroundStyle(.primary)
                                    Text("v\(manifest.version) — \(manifest.files.count) reference files")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if defaultVaultId == manifest.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppAccent.color)
                                } else if !unlocked {
                                    Text("Locked")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!unlocked)
                    }
                }

                // ──────────────── Session mode
                Section {
                    Picker("Mode", selection: $defaultMode) {
                        Text("AI-Only").tag("ai_only")
                        Text("Human-Assisted (v2)").tag("human_assisted").disabled(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Default Session Mode")
                } footer: {
                    Text("AI-Only uses the vault to ground responses. Human-Assisted brings a remote expert into the session — coming in v2.")
                }

                // ──────────────── Expert escalation
                Section {
                    Picker("Stream transport", selection: Binding(
                        get: { Config.expertStreamTransport },
                        set: { Config.setExpertStreamTransport($0) }
                    )) {
                        ForEach(ExpertStreamKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                } header: {
                    Text("Expert Stream Transport")
                } footer: {
                    Text("How the glasses view reaches the expert. MJPEG streams one-way video to a browser viewer. WebRTC is peer-to-peer with two-way audio and needs a signaling URL (and TURN for cross-network use) configured below.")
                }

                if Config.expertStreamTransport == .meetingLink {
                    Section {
                        webrtcField("Meeting URL", "https://zoom.us/j/… or Teams/Meet/Whereby", { Config.expertMeetingURL }, { Config.setExpertMeetingURL($0) })
                    } header: {
                        Text("Meeting Link")
                    } footer: {
                        Text("Zero-infrastructure: on escalation the technician's device opens this meeting and the expert is paged the same link. Your meeting tool (Zoom/Teams/Meet/Whereby) hosts the call — nothing for you to run.")
                    }
                }

                if Config.expertStreamTransport == .webrtc {
                    Section {
                        webrtcField("Signaling URL", "wss://signal.example/ws", { Config.expertSignalingURL }, { Config.setExpertSignalingURL($0) })
                        webrtcField("STUN", "stun:…", { Config.expertStunURL }, { Config.setExpertStunURL($0) })
                        webrtcField("TURN", "turn:… (optional)", { Config.expertTurnURL }, { Config.setExpertTurnURL($0) })
                        webrtcField("TURN user", "username", { Config.expertTurnUsername }, { Config.setExpertTurnUsername($0) })
                        webrtcField("TURN secret", "credential", { Config.expertTurnCredential }, { Config.setExpertTurnCredential($0) })
                    } header: {
                        Text("WebRTC Connection")
                    } footer: {
                        Text("Required for WebRTC. The signaling server relays SDP/ICE between the glasses and the expert's browser. TURN is needed when peers are on different networks (e.g. cellular).")
                    }
                }

                Section {
                    TextField("https://hooks.slack.com/…", text: Binding(
                        get: { Config.expertWebhookURL },
                        set: { Config.setExpertWebhookURL($0) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                } header: {
                    Text("Expert Escalation Webhook")
                } footer: {
                    Text("Optional. When a technician escalates, the expert pool is paged with the live join URL via this Slack-compatible webhook (in addition to an on-device notification).")
                }

                // ──────────────── Active session
                Section("Active Session") {
                    if let session = sessionService.activeSession {
                        let vault = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
                        VStack(alignment: .leading, spacing: 6) {
                            Text(vault).font(.headline)
                            if let asset = session.assetId {
                                Text("Asset: \(asset)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Status: \(session.outcome.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button(session.pausedAt == nil ? "Pause" : "Resume") {
                                if session.pausedAt == nil {
                                    _ = try? sessionService.pauseSession()
                                } else {
                                    _ = try? sessionService.resumeSession()
                                }
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button("End Session", role: .destructive) {
                                _ = try? sessionService.endSession(outcome: .resolved)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("No active session.")
                            .foregroundStyle(.secondary)
                    }
                }

                // ──────────────── Manual start (debug aid)
                if !sessionService.isSessionActive {
                    Section("Start Session") {
                        Button("Start Default Session") {
                            let mode = FieldSession.Mode(rawValue: defaultMode) ?? .aiOnly
                            _ = try? sessionService.startSession(vaultId: defaultVaultId, assetId: nil, mode: mode)
                        }
                        .disabled(!VaultRegistry.shared.isUnlocked(defaultVaultId))
                    }
                }

                // ──────────────── History
                Section("Recent Sessions") {
                    if sessionService.history.isEmpty {
                        Text("No prior sessions.").foregroundStyle(.secondary)
                    } else {
                        ForEach(sessionService.history.prefix(5), id: \.id) { session in
                            let vault = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vault).font(.subheadline)
                                Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) — \(session.outcome.rawValue) — \(Int(session.billableSeconds / 60)) min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // ──────────────── Developer unlock
            Section {
                Toggle("Developer unlock (skip IAP)", isOn: $developerUnlocked)
                    .tint(AppAccent.color)
            } footer: {
                Text("Internal only. Bypasses per-pack IAP gates so all vaults are usable during development. Disable before shipping.")
            }
        }
        .navigationTitle("Field Assist")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A labeled text field bound to a Config getter/setter (used for WebRTC connection fields).
    @ViewBuilder
    private func webrtcField(_ title: String, _ placeholder: String,
                             _ get: @escaping @Sendable () -> String, _ set: @escaping @Sendable (String) -> Void) -> some View {
        TextField(placeholder, text: Binding(get: get, set: set))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
    }
}

#Preview {
    NavigationStack {
        FieldAssistSettingsView()
    }
}
