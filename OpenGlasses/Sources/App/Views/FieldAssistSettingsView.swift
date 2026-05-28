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
                                    try? sessionService.pauseSession()
                                } else {
                                    try? sessionService.resumeSession()
                                }
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button("End Session", role: .destructive) {
                                try? sessionService.endSession(outcome: .resolved)
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
                            try? sessionService.startSession(vaultId: defaultVaultId, assetId: nil, mode: mode)
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
}

#Preview {
    NavigationStack {
        FieldAssistSettingsView()
    }
}
