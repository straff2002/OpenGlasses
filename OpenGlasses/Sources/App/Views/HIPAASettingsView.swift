import SwiftUI
import LocalAuthentication

/// International medical compliance frameworks and what safeguards they require.
enum MedicalFramework: String, CaseIterable, Identifiable {
    case hipaa = "HIPAA"
    case hitech = "HITECH"
    case australianPrivacy = "Australian Privacy Act"
    case myHealthRecords = "My Health Records Act"
    case nzHIPC = "NZ HIPC"
    case gdprHealth = "GDPR (Health Data)"
    case pipeda = "PIPEDA"
    case ukDPA = "UK Data Protection Act"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .hipaa, .hitech: return "🇺🇸"
        case .australianPrivacy, .myHealthRecords: return "🇦🇺"
        case .nzHIPC: return "🇳🇿"
        case .gdprHealth: return "🇪🇺"
        case .pipeda: return "🇨🇦"
        case .ukDPA: return "🇬🇧"
        }
    }

    var region: String {
        switch self {
        case .hipaa, .hitech: return "United States"
        case .australianPrivacy, .myHealthRecords: return "Australia"
        case .nzHIPC: return "New Zealand"
        case .gdprHealth: return "European Union"
        case .pipeda: return "Canada"
        case .ukDPA: return "United Kingdom"
        }
    }

    var summary: String {
        switch self {
        case .hipaa:
            return "Health Insurance Portability and Accountability Act — requires encryption, access control, audit trails, and BAAs for PHI."
        case .hitech:
            return "Health Information Technology for Economic and Clinical Health Act — extends HIPAA with breach notification and enhanced penalties."
        case .australianPrivacy:
            return "Privacy Act 1988 (APP 11) — requires entities to take reasonable steps to protect personal information from misuse, loss, and unauthorised access."
        case .myHealthRecords:
            return "My Health Records Act 2012 — governs the My Health Record system. Requires encryption, access controls, and penalties for unauthorised access to health records."
        case .nzHIPC:
            return "Health Information Privacy Code 2020 — governs how health agencies collect, use, store, and disclose health information. Requires secure storage and purpose limitation."
        case .gdprHealth:
            return "General Data Protection Regulation Article 9 — health data is a special category requiring explicit consent, data minimisation, encryption, and DPIAs."
        case .pipeda:
            return "Personal Information Protection and Electronic Documents Act — requires consent, limiting collection, and safeguards appropriate to the sensitivity of health information."
        case .ukDPA:
            return "Data Protection Act 2018 (UK GDPR) — health data as special category, requires appropriate policy documents, encryption, and lawful basis for processing."
        }
    }

    /// Technical safeguards covered by Medical Compliance mode (in-app).
    var coveredSafeguards: [MedicalSafeguard] {
        switch self {
        case .hipaa:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage]
        case .hitech:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage, .breachNotification]
        case .australianPrivacy:
            return [.encryption, .accessControl, .dataRetention, .disableCloudLeakage, .purposeLimitation]
        case .myHealthRecords:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage]
        case .nzHIPC:
            return [.encryption, .accessControl, .dataRetention, .purposeLimitation, .disableCloudLeakage]
        case .gdprHealth:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage, .dataMinimisation]
        case .pipeda:
            return [.encryption, .accessControl, .dataRetention, .disableCloudLeakage, .purposeLimitation]
        case .ukDPA:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage, .dataMinimisation]
        }
    }

    /// Organisational requirements NOT covered by the app — the user's responsibility.
    var organisationalRequirements: [String] {
        switch self {
        case .hipaa:
            return [
                "Signed BAA with each cloud LLM provider",
                "Staff privacy and security training",
                "Risk assessment and management plan",
                "Policies and procedures documentation"
            ]
        case .hitech:
            return [
                "Breach notification procedures (60-day rule)",
                "All HIPAA administrative requirements",
                "Meaningful use attestation (if applicable)"
            ]
        case .australianPrivacy:
            return [
                "Privacy Impact Assessment (PIA)",
                "APP-compliant privacy policy",
                "Staff awareness training",
                "Data breach notification to OAIC (if serious)"
            ]
        case .myHealthRecords:
            return [
                "Registration with Australian Digital Health Agency",
                "Authorised representative management",
                "Staff training on My Health Record obligations",
                "Notifiable data breach reporting"
            ]
        case .nzHIPC:
            return [
                "Health agency registration",
                "Patient consent processes",
                "Staff training on HIPC obligations",
                "Privacy breach notification to OPC"
            ]
        case .gdprHealth:
            return [
                "Data Protection Impact Assessment (DPIA)",
                "Explicit consent for health data processing",
                "Data Processing Agreement (DPA) with cloud providers",
                "Data Protection Officer (DPO) appointment",
                "Records of processing activities"
            ]
        case .pipeda:
            return [
                "Privacy officer designation",
                "Meaningful consent documentation",
                "Privacy breach reporting to OPC",
                "Responding to access requests"
            ]
        case .ukDPA:
            return [
                "Data Protection Impact Assessment (DPIA)",
                "Appropriate policy document for special category data",
                "Data Processing Agreement with cloud providers",
                "ICO registration",
                "Breach notification to ICO within 72 hours"
            ]
        }
    }
}

/// Individual safeguards that Medical Compliance mode implements.
enum MedicalSafeguard: String, CaseIterable {
    case encryption = "Encryption at Rest"
    case accessControl = "Biometric Access Control"
    case auditLog = "Audit Logging"
    case dataRetention = "Data Retention Policy"
    case baa = "Cloud Provider Agreements"
    case disableCloudLeakage = "Prevent Data Leakage"
    case breachNotification = "Breach Notification"
    case purposeLimitation = "Purpose Limitation"
    case dataMinimisation = "Data Minimisation"

    var icon: String {
        switch self {
        case .encryption: return "lock.doc.fill"
        case .accessControl: return "faceid"
        case .auditLog: return "list.clipboard.fill"
        case .dataRetention: return "calendar.badge.clock"
        case .baa: return "doc.text.fill"
        case .disableCloudLeakage: return "icloud.slash.fill"
        case .breachNotification: return "exclamationmark.bubble.fill"
        case .purposeLimitation: return "scope"
        case .dataMinimisation: return "minus.circle.fill"
        }
    }

    var detail: String {
        switch self {
        case .encryption:
            return "All recordings, transcripts, and clinical data are encrypted at rest using NSFileProtectionComplete. Data is only accessible when the device is unlocked."
        case .accessControl:
            return "Face ID, Touch ID, or device passcode is required every time the app returns to the foreground."
        case .auditLog:
            return "All data access events are logged with timestamps — recordings started/stopped, files saved, shared, or deleted. Exportable for compliance review."
        case .dataRetention:
            return "Configurable auto-purge removes transcripts and recordings older than the retention period. Supports secure deletion (data overwrite before removal)."
        case .baa:
            return "When cloud LLMs are used, a reminder is shown that a Business Associate Agreement (US) or Data Processing Agreement (EU/UK/AU/NZ) must be in place. Enable 'Local LLM Only' to avoid this requirement."
        case .disableCloudLeakage:
            return "Web search, external messaging, and cloud memory sync tools are disabled to prevent clinical data from leaving the device via uncontrolled channels."
        case .breachNotification:
            return "Audit log provides a record of all data access for breach investigation and notification requirements."
        case .purposeLimitation:
            return "Clinical recordings and transcripts are stored separately from general notes, with clear labelling of purpose."
        case .dataMinimisation:
            return "Memory system does not persist clinical details beyond the session unless explicitly requested. Auto-purge enforces retention limits."
        }
    }
}

// MARK: - Medical Compliance Settings View

/// Settings view for international medical compliance mode.
/// Replaces the US-centric "HIPAA" framing with a framework-aware approach.
struct HIPAASettingsView: View {
    @State private var complianceEnabled = Config.hipaaMode
    @State private var localOnly = Config.hipaaLocalOnly
    @State private var retentionDays = Config.hipaaRetentionDays
    @State private var showConfirmEnable = false
    @State private var showConfirmDisable = false
    @State private var expandedFramework: MedicalFramework?

    @ObservedObject var hipaaService: HIPAAComplianceService
    @ObservedObject var exportService: MedicalExportService

    private let retentionOptions = [30, 60, 90, 180, 365, 0]

    var body: some View {
        List {
            // MARK: - Master Toggle
            Section {
                Toggle("Medical Compliance Mode", isOn: $complianceEnabled)
                    .tint(AppAccent.aiCoral)
                    .onChange(of: complianceEnabled) { _, newValue in
                        if newValue {
                            showConfirmEnable = true
                        } else {
                            showConfirmDisable = true
                        }
                    }
            } header: {
                Label("Clinical Data Protection", systemImage: "cross.case.fill")
            } footer: {
                Text("Enables safeguards for handling protected health information during clinical recordings, consultations, and interactions.")
            }

            if complianceEnabled {
                // MARK: - What Changes
                Section {
                    changeRow(icon: biometricIcon, color: AppAccent.aiCoral, title: "App Lock",
                              detail: "\(biometricName) required to open app")
                    changeRow(icon: "lock.doc.fill", color: AppAccent.aiCoral, title: "File Encryption",
                              detail: "Recordings and transcripts encrypted at rest")
                    changeRow(icon: "icloud.slash.fill", color: .orange, title: "iCloud Backup",
                              detail: "Clinical data excluded from backup")
                    changeRow(icon: "magnifyingglass", color: .red, title: "Web Search",
                              detail: "Disabled — prevents clinical query leakage")
                    changeRow(icon: "paperplane.fill", color: .red, title: "External Messaging",
                              detail: "Disabled — prevents uncontrolled PHI sharing")
                    changeRow(icon: "cloud.fill", color: .red, title: "Cloud Memory Sync",
                              detail: "Disabled — memories stay on-device only")
                    changeRow(icon: "list.clipboard.fill", color: AppAccent.aiCoral, title: "Audit Logging",
                              detail: "All data access events are recorded")
                    changeRow(icon: "calendar.badge.clock", color: AppAccent.aiCoral, title: "Auto-Purge",
                              detail: "Old data deleted after retention period")
                } header: {
                    Text("What Changes")
                }

                // MARK: - Framework Coverage
                Section {
                    ForEach(MedicalFramework.allCases) { framework in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedFramework == framework },
                            set: { expandedFramework = $0 ? framework : nil }
                        )) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(framework.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                // Covered by the app
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Covered by this app")
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                    ForEach(framework.coveredSafeguards, id: \.self) { safeguard in
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                            Text(safeguard.rawValue)
                                                .font(.caption)
                                        }
                                    }
                                }

                                // Organisation's responsibility
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your organisation's responsibility")
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                    ForEach(framework.organisationalRequirements, id: \.self) { req in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "person.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                            Text(req)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Text(framework.flag)
                                Text(framework.rawValue)
                                Spacer()
                                Text(framework.region)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Framework Coverage")
                } footer: {
                    Text("Medical Compliance mode implements the technical safeguards required by these frameworks. Organisational policies (training, incident response, DPAs) are your responsibility.")
                }

                // MARK: - Data Routing
                Section {
                    Toggle("Local LLM Only", isOn: $localOnly)
                        .tint(AppAccent.aiCoral)
                        .onChange(of: localOnly) { _, val in
                            Config.hipaaLocalOnly = val
                        }
                } header: {
                    Text("Data Routing")
                } footer: {
                    if localOnly {
                        Text("All AI queries are processed on-device. No clinical data is sent to cloud providers.")
                    } else {
                        Label {
                            Text("Cloud LLM providers may process clinical data. Ensure you have a signed agreement (BAA, DPA, or equivalent) with your provider.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }
                }

                // MARK: - Data Retention
                Section {
                    Picker("Auto-Purge After", selection: $retentionDays) {
                        ForEach(retentionOptions, id: \.self) { days in
                            Text(days == 0 ? "Never (manual only)" : "\(days) days").tag(days)
                        }
                    }
                    .onChange(of: retentionDays) { _, val in
                        Config.hipaaRetentionDays = val
                    }

                    Button {
                        hipaaService.enforceRetentionPolicy()
                    } label: {
                        Label("Run Purge Now", systemImage: "trash")
                    }
                } header: {
                    Text("Data Retention")
                } footer: {
                    Text("Transcripts and temporary recordings older than the retention period are automatically deleted on app launch. Secure deletion overwrites data before removal.")
                }

                // MARK: - Audit Log
                Section {
                    NavigationLink {
                        AuditLogView(hipaaService: hipaaService)
                    } label: {
                        HStack {
                            Text("Audit Log")
                            Spacer()
                            Text("\(hipaaService.auditLog.count) entries")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Compliance")
                }

                // MARK: - Medical Export
                Section {
                    NavigationLink {
                        MedicalExportSettingsView(exportService: exportService)
                    } label: {
                        HStack {
                            Label("Medical Export", systemImage: "arrow.up.doc.fill")
                            Spacer()
                            let config = FHIRConfig.fromDefaults()
                            if !config.baseURL.isEmpty {
                                Text("Configured")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Data Export")
                } footer: {
                    Text("Configure FHIR server, EMR platform, and export preferences for clinical transcripts.")
                }

                // MARK: - Safeguard Detail
                Section {
                    NavigationLink {
                        SafeguardDetailView()
                    } label: {
                        Label("Technical Safeguard Details", systemImage: "shield.checkered")
                    }
                }

                // MARK: - Subscription
                Section {
                    if let status = StoreKitService.shared.subscriptionStatus {
                        HStack {
                            Text("Plan")
                            Spacer()
                            Text(status.planName)
                                .foregroundStyle(.secondary)
                        }
                        if let expiry = status.expirationDate {
                            HStack {
                                Text("Renews")
                                Spacer()
                                Text(expiry, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Manage Subscription") {
                            Task { await StoreKitService.shared.showManageSubscription() }
                        }
                    }
                } header: {
                    Text("Subscription")
                }

                // MARK: - Disclaimer
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Important Notice", systemImage: "info.circle.fill")
                            .font(.subheadline.bold())

                        Text("""
                            This app provides technical safeguards (encryption, access control, audit \
                            logging, data retention) to support medical data compliance. It does not \
                            constitute a complete compliance programme.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("""
                            Your organisation is responsible for: staff training, risk assessments, \
                            incident response procedures, data processing agreements with cloud providers, \
                            and any jurisdiction-specific administrative requirements.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Medical Compliance")
        .alert("Enable Medical Compliance?", isPresented: $showConfirmEnable) {
            Button("Enable") {
                Config.hipaaMode = true
                hipaaService.log(action: "COMPLIANCE_ENABLED", detail: "Medical compliance mode enabled")
            }
            Button("Cancel", role: .cancel) {
                complianceEnabled = false
            }
        } message: {
            Text("This will:\n• Require biometric authentication to open the app\n• Encrypt all recordings and transcripts at rest\n• Disable web search and external messaging\n• Exclude clinical data from iCloud backup\n• Enable audit logging of all data access")
        }
        .alert("Disable Medical Compliance?", isPresented: $showConfirmDisable) {
            Button("Disable", role: .destructive) {
                hipaaService.log(action: "COMPLIANCE_DISABLED", detail: "Medical compliance mode disabled")
                Config.hipaaMode = false
            }
            Button("Cancel", role: .cancel) {
                complianceEnabled = true
            }
        } message: {
            Text("Disabling compliance mode will remove encryption enforcement and allow clinical data to be sent to cloud services. Existing protected files will retain their encryption.")
        }
    }

    // MARK: - Helpers

    private func changeRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var biometricName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    private var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }
}

// MARK: - Safeguard Detail View

/// Detailed breakdown of each technical safeguard implemented.
struct SafeguardDetailView: View {
    var body: some View {
        List {
            ForEach(MedicalSafeguard.allCases, id: \.self) { safeguard in
                Section {
                    Text(safeguard.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Label(safeguard.rawValue, systemImage: safeguard.icon)
                }
            }
        }
        .navigationTitle("Safeguard Details")
    }
}

// MARK: - Audit Log View

/// Displays the compliance audit log with export capability.
struct AuditLogView: View {
    @ObservedObject var hipaaService: HIPAAComplianceService
    @State private var showExportSheet = false

    var body: some View {
        List {
            if hipaaService.auditLog.isEmpty {
                Text("No audit events recorded.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hipaaService.auditLog.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.action)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppAccent.aiCoral)
                            Spacer()
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Audit Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(hipaaService.auditLog.isEmpty)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            let text = hipaaService.exportAuditLog()
            ShareLink(item: text) {
                Label("Export Audit Log", systemImage: "doc.text")
            }
            .presentationDetents([.medium])
        }
    }
}
