import SwiftUI

/// Settings view for configuring medical platform exports.
/// Accessible from Medical Compliance settings.
struct MedicalExportSettingsView: View {
    @ObservedObject var exportService: MedicalExportService
    @State private var config = FHIRConfigurationStore.shared.configuration
    @State private var selectedPlatform: MedicalPlatform = FHIRConfigurationStore.shared.configuration.platform
    /// Transient editor state. The stored credential is never decrypted back into this field —
    /// once saved, the UI can only report that one exists, replace it, or clear it.
    @State private var tokenDraft = ""
    @State private var isReplacingCredential = false
    @State private var hasStoredCredential = FHIRConfigurationStore.shared.hasStoredCredential()
    @State private var patientIDDraft = ""
    @State private var practitionerIDDraft = ""
    @State private var autoExportEnabled = Config.autoExportEnabled
    @State private var defaultExportFormat: ExportFormat = Config.defaultExportFormat
    @State private var showTestResult = false
    @State private var testResultMessage = ""
    @State private var isTesting = false
    @State private var saveMessage: String?

    private var store: FHIRConfigurationStore { exportService.configurationStore }

    var body: some View {
        List {
            // MARK: - Platform Selection
            Section {
                ForEach(MedicalPlatform.allCases) { platform in
                    Button {
                        selectedPlatform = platform
                        config.platformType = platform.rawValue
                        store.save(config)
                    } label: {
                        HStack(spacing: 12) {
                            Text(platform.flag)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.rawValue)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(platform.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if selectedPlatform == platform {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("Platform")
            } footer: {
                Text("Select your target EMR or health record system. FHIR R4 works with most modern systems including Epic and Cerner.")
            }

            // MARK: - FHIR Configuration (for FHIR-based platforms)
            if selectedPlatform.usesFHIR {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://fhir.example.com/r4", text: $config.baseURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    credentialRow

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Patient ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Optional — e.g. 12345", text: $patientIDDraft)
                            .autocapitalization(.none)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Practitioner ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Optional — e.g. dr-smith-001", text: $practitionerIDDraft)
                            .autocapitalization(.none)
                    }

                    Button {
                        saveConfiguration()
                    } label: {
                        Label("Save Configuration", systemImage: "checkmark.circle")
                    }
                    .tint(Color.accentColor)

                    if let saveMessage {
                        Text(saveMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("FHIR Server")
                } footer: {
                    if selectedPlatform == .epic {
                        Text("Epic uses SMART on FHIR. Obtain a bearer token from your Epic administrator.")
                    } else if selectedPlatform == .cerner {
                        Text("Oracle Health (Cerner) uses FHIR R4 with Millennium platform integration.")
                    } else {
                        Text("Enter the base URL of your FHIR R4 server and an authentication token.")
                    }
                }

                // Test Connection
                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!config.isConfigured || isTesting)
                } footer: {
                    Text("Sends a metadata request to verify the FHIR server is reachable and responds to capability queries.")
                }
            }

            // MARK: - Auto Export
            Section {
                Toggle("Auto-Export on Recording Stop", isOn: $autoExportEnabled)
                    .tint(Color.accentColor)
                    .onChange(of: autoExportEnabled) { _, val in
                        Config.autoExportEnabled = val
                    }

                Picker("Default Format", selection: $defaultExportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .onChange(of: defaultExportFormat) { _, val in
                    Config.defaultExportFormat = val
                }
            } header: {
                Text("Automation")
            } footer: {
                if autoExportEnabled && selectedPlatform.usesFHIR {
                    Text("Transcripts will be automatically uploaded to the configured FHIR server when a recording stops. You can also share manually at any time.")
                } else if autoExportEnabled {
                    Text("A share sheet will be presented with the transcript in the selected format when a recording stops.")
                } else {
                    Text("You can still share transcripts manually via the share button or by asking the AI assistant.")
                }
            }

            // MARK: - Manual Share Info
            if selectedPlatform == .manual {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share Sheet")
                                .font(.subheadline)
                            Text("AirDrop, email, Files, or any installed app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Files App")
                                .font(.subheadline)
                            Text("Transcripts saved to Documents/Transcripts folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice Command")
                                .font(.subheadline)
                            Text("\"Share the transcript\" or \"Export the recording\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Manual Sharing Options")
                }
            }

            // MARK: - Platform-Specific Notes
            if !selectedPlatform.usesFHIR && selectedPlatform != .manual {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Coming Soon", systemImage: "clock.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.accentColor)

                        Text(platformNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("For now, use FHIR R4 or Manual Share to export transcripts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Medical Export")
        .ogFormStyle()
        .onAppear(perform: loadProtectedValues)
        .alert("Connection Test", isPresented: $showTestResult) {
            Button("OK") {}
        } message: {
            Text(testResultMessage)
        }
    }

    // MARK: - Credential

    /// A stored credential is reported, never rendered. Entry is only offered when there is
    /// nothing stored, or after the user explicitly asks to replace what is.
    @ViewBuilder
    private var credentialRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bearer Token")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasStoredCredential && !isReplacingCredential {
                HStack(spacing: 12) {
                    Label("Credential stored", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace") {
                        tokenDraft = ""
                        isReplacingCredential = true
                    }
                    .buttonStyle(.borderless)
                    Button("Clear", role: .destructive) {
                        store.clearCredential()
                        tokenDraft = ""
                        hasStoredCredential = false
                        isReplacingCredential = false
                        saveMessage = "Credential cleared."
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                SecretInputField(placeholder: "Pre-obtained OAuth token", text: $tokenDraft)
            }
        }
    }

    // MARK: - Helpers

    private var platformNote: String {
        switch selectedPlatform {
        case .myHealthRecord:
            return "My Health Record integration requires registration with the Australian Digital Health Agency and a conformant FHIR gateway. Contact your ADHA representative."
        case .nzHealthConnect:
            return "NZ Health Connect integration requires a Health Information Platform (HIP) connector. Contact your PHO or DHB IT team."
        case .nhsSpine:
            return "NHS Spine integration requires an NHS Digital connection agreement and MESH mailbox. Contact your trust's IT department."
        default:
            return ""
        }
    }

    /// Clinical identifiers are editable, so they are loaded back into their fields; the
    /// credential deliberately is not.
    private func loadProtectedValues() {
        // @State initializers cannot reach `exportService`, so the injected store is the authority
        // from here on — it and the singleton are the same object outside tests.
        config = store.configuration
        selectedPlatform = config.platform
        hasStoredCredential = store.hasStoredCredential()
        guard let context = try? store.loadPrivateContext() else { return }
        patientIDDraft = context.patientID ?? ""
        practitionerIDDraft = context.practitionerID ?? ""
    }

    private func saveConfiguration() {
        store.save(config)
        do {
            if !tokenDraft.isEmpty {
                try store.storeCredential(FHIRCredential(bearerToken: tokenDraft))
                tokenDraft = ""
                isReplacingCredential = false
                hasStoredCredential = true
            }
            try store.storePrivateContext(
                FHIRPrivateContext(patientID: patientIDDraft, practitionerID: practitionerIDDraft)
            )
            saveMessage = "Configuration saved."
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        isTesting = true
        Task {
            guard let url = config.endpoint(for: "metadata") else {
                testResultMessage = "Invalid server URL."
                showTestResult = true
                isTesting = false
                return
            }

            var request = URLRequest(url: url)
            request.setValue("application/fhir+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            // Read the credential only here, for this one request.
            let draft = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if let token = (try? store.loadCredential())?.bearerToken ?? (draft.isEmpty ? nil : draft) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if (200...299).contains(status) {
                    testResultMessage = "Connected successfully (HTTP \(status)). The FHIR server is reachable and responded to the capability statement request."
                } else {
                    testResultMessage = "Server responded with HTTP \(status). Check your URL and authentication credentials."
                }
            } catch {
                testResultMessage = "Connection failed: \(error.localizedDescription)"
            }

            showTestResult = true
            isTesting = false
        }
    }
}
