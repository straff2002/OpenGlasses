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
    /// The provincial and territorial health acts (Plan NJ §8, Decision 6): one entry with a
    /// province picker over `CanadianHealthAct`. PIPEDA stays its own entry for the federal act.
    case canadianHealthActs = "Canadian health acts"
    case ukDPA = "UK Data Protection Act"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .hipaa, .hitech: return "🇺🇸"
        case .australianPrivacy, .myHealthRecords: return "🇦🇺"
        case .nzHIPC: return "🇳🇿"
        case .gdprHealth: return "🇪🇺"
        case .pipeda, .canadianHealthActs: return "🇨🇦"
        case .ukDPA: return "🇬🇧"
        }
    }

    var region: String {
        switch self {
        case .hipaa, .hitech: return String(localized: "United States")
        case .australianPrivacy, .myHealthRecords: return String(localized: "Australia")
        case .nzHIPC: return String(localized: "New Zealand")
        case .gdprHealth: return String(localized: "European Union")
        case .pipeda: return String(localized: "Canada")
        case .canadianHealthActs: return String(localized: "Canada, by province")
        case .ukDPA: return String(localized: "United Kingdom")
        }
    }

    var summary: String {
        switch self {
        case .hipaa:
            return String(localized: "Health Insurance Portability and Accountability Act — requires encryption, access control, audit trails, and BAAs for PHI.")
        case .hitech:
            return String(localized: "Health Information Technology for Economic and Clinical Health Act — extends HIPAA with breach notification and enhanced penalties.")
        case .australianPrivacy:
            return String(localized: "Privacy Act 1988 (APP 11) — requires entities to take reasonable steps to protect personal information from misuse, loss, and unauthorised access.")
        case .myHealthRecords:
            return String(localized: "My Health Records Act 2012 — governs the My Health Record system. Requires encryption, access controls, and penalties for unauthorised access to health records.")
        case .nzHIPC:
            return String(localized: "Health Information Privacy Code 2020 — governs how health agencies collect, use, store, and disclose health information. Requires secure storage and purpose limitation.")
        case .gdprHealth:
            return String(localized: "General Data Protection Regulation Article 9 — health data is a special category requiring explicit consent, data minimisation, encryption, and DPIAs.")
        case .pipeda:
            return String(localized: "Personal Information Protection and Electronic Documents Act — requires consent, limiting collection, and safeguards appropriate to the sensitivity of health information.")
        case .canadianHealthActs:
            return String(localized: "Each province and territory has its own act for a clinic's health information. Choose the clinic's province or territory to see its act, what it calls a supplier, the agreement that needs, who a breach is reported to, and the clinic's other duties.")
        case .ukDPA:
            return String(localized: "Data Protection Act 2018 (UK GDPR) — health data as special category, requires appropriate policy documents, encryption, and lawful basis for processing.")
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
        case .canadianHealthActs:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage, .dataMinimisation]
        case .ukDPA:
            return [.encryption, .accessControl, .auditLog, .dataRetention, .disableCloudLeakage, .dataMinimisation]
        }
    }

    /// The requirements, with the Canada entry's for the province or territory chosen.
    func organisationalRequirements(in jurisdiction: CanadianJurisdiction) -> [String] {
        self == .canadianHealthActs ? CanadianHealthAct.act(for: jurisdiction).duties : organisationalRequirements
    }

    /// Organisational requirements NOT covered by the app — the user's responsibility.
    var organisationalRequirements: [String] {
        switch self {
        case .hipaa:
            return [
                String(localized: "Signed BAA with each cloud AI provider and with any other service that receives PHI, including any the app's maker runs"),
                String(localized: "Staff privacy and security training"),
                String(localized: "Risk assessment and management plan"),
                String(localized: "Policies and procedures documentation")
            ]
        case .hitech:
            return [
                String(localized: "Breach notification procedures (60-day rule)"),
                String(localized: "All HIPAA administrative requirements"),
                String(localized: "Promoting Interoperability attestation (formerly Meaningful Use), if applicable")
            ]
        case .australianPrivacy:
            return [
                String(localized: "Privacy Impact Assessment (PIA)"),
                String(localized: "APP-compliant privacy policy"),
                String(localized: "Staff awareness training"),
                String(localized: "Data breach notification to OAIC (if serious)")
            ]
        case .myHealthRecords:
            return [
                String(localized: "Registration with the Australian Digital Health Agency, only if you connect to My Health Record"),
                String(localized: "Authorised representative management"),
                String(localized: "Staff training on My Health Record obligations"),
                String(localized: "Notifiable data breach reporting")
            ]
        case .nzHIPC:
            return [
                String(localized: "Patient consent processes"),
                String(localized: "Staff training on HIPC obligations"),
                String(localized: "Privacy breach notification to OPC")
            ]
        case .gdprHealth:
            return [
                String(localized: "Data Protection Impact Assessment (DPIA)"),
                String(localized: "Explicit consent for health data processing"),
                String(localized: "Data Processing Agreement (DPA) with cloud providers"),
                String(localized: "Data Protection Officer (DPO) appointment"),
                String(localized: "Records of processing activities")
            ]
        case .pipeda:
            return [
                String(localized: "Privacy officer designation"),
                String(localized: "Meaningful consent documentation"),
                String(localized: "Privacy breach reporting to the OPC where PIPEDA applies. A clinic in Ontario, Nova Scotia, New Brunswick or Newfoundland and Labrador reports health information breaches to its provincial commissioner or ombud instead: see Canadian health acts"),
                String(localized: "Responding to access requests")
            ]
        case .canadianHealthActs:
            return CanadianHealthAct.act(for: .ontario).duties
        case .ukDPA:
            return [
                String(localized: "Data Protection Impact Assessment (DPIA)"),
                String(localized: "Appropriate policy document for special category data"),
                String(localized: "Data Processing Agreement with cloud providers"),
                String(localized: "ICO registration"),
                String(localized: "Breach notification to ICO within 72 hours")
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

    /// The safeguard's name as shown. The raw value is its stable identifier and stays English.
    var title: String {
        switch self {
        case .encryption: return String(localized: "Encryption at Rest")
        case .accessControl: return String(localized: "Biometric Access Control")
        case .auditLog: return String(localized: "Audit Logging")
        case .dataRetention: return String(localized: "Data Retention Policy")
        case .baa: return String(localized: "Cloud Provider Agreements")
        case .disableCloudLeakage: return String(localized: "Prevent Data Leakage")
        case .breachNotification: return String(localized: "Breach Notification")
        case .purposeLimitation: return String(localized: "Purpose Limitation")
        case .dataMinimisation: return String(localized: "Data Minimisation")
        }
    }

    var detail: String {
        switch self {
        case .encryption:
            return String(localized: "While this mode is on, recordings (audio and video), their transcripts, the list of recorded sessions, the audit log and clinical exports can't be read while the phone is locked, and are kept out of iCloud backup. A recording that's still being written can finish while the phone is locked. Protection starts when you turn the mode on and also covers recordings already saved in the app at that moment. Copies in Photos or a folder you chose are outside this protection.")
        case .accessControl:
            return String(localized: "Face ID, Touch ID, or device passcode is required every time the app returns to the foreground.")
        case .auditLog:
            return String(localized: "Data access events are logged with timestamps on this phone, while Medical mode is on: recordings started and stopped, files saved, shared or deleted. The log keeps its latest 1,000 entries and names no user. Exportable for compliance review.")
        case .dataRetention:
            return String(localized: "Configurable auto-purge removes transcripts and recordings older than the retention period. Files are deleted; flash storage cannot be overwritten; backups and shared copies are not reached.")
        case .baa:
            return String(localized: "When cloud AI models are used, a reminder is shown that an agreement must be in place with the AI provider: a Business Associate Agreement (US), a Data Processing Agreement (EU, UK, Australia, New Zealand), or in Canada an agreement with the provider as your information manager or service provider. With 'Local LLM Only' on, no AI provider receives clinical data, so no agreement with one is needed. Agreements with your record system and any other service that receives patient data still apply.")
        case .disableCloudLeakage:
            return String(localized: "Web search, external messaging, and cloud memory sync tools are disabled, so clinical data does not leave the phone through them. With Local Only on, captured data leaves the phone only to your own record system.")
        case .breachNotification:
            return String(localized: "The audit log on this phone, kept while Medical mode is on, records data access events for a breach investigation and the notices it may need.")
        case .purposeLimitation:
            return String(localized: "Clinical recordings and transcripts are stored separately from general notes, with clear labelling of purpose.")
        case .dataMinimisation:
            return String(localized: "Memory system does not persist clinical details beyond the session unless explicitly requested. Auto-purge enforces retention limits.")
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
    /// The province or territory the Canada entry shows (Plan NJ §8).
    @AppStorage(CanadianJurisdiction.defaultsKey) private var jurisdictionRaw = CanadianJurisdiction.ontario.rawValue

    @ObservedObject var hipaaService: HIPAAComplianceService
    @ObservedObject var exportService: MedicalExportService

    private let retentionOptions = [30, 60, 90, 180, 365, 0]

    private var jurisdiction: CanadianJurisdiction { CanadianJurisdiction(rawValue: jurisdictionRaw) ?? .ontario }

    /// Plan NJ §7: an organisation's profile pins these; they are drawn locked, naming it.
    private var modeLocked: Bool { PolicyEnvelope.isLocked(.hipaaMode) }
    private var localOnlyLocked: Bool { PolicyEnvelope.isLocked(.hipaaLocalOnly) }
    private var retentionLocked: Bool { PolicyEnvelope.isLocked(.hipaaRetentionDays) }

    /// The choices, with the figure in force when an organisation set one that is not among them.
    private var retentionChoices: [Int] {
        retentionOptions.contains(retentionDays) ? retentionOptions : [retentionDays] + retentionOptions
    }

    var body: some View {
        List {
            // MARK: - Master Toggle
            Section {
                Toggle("Medical Compliance Mode", isOn: $complianceEnabled)
                    .disabled(modeLocked)
                    .onChange(of: complianceEnabled) { _, newValue in
                        // A pinned mode is not the person's to change; the switch is disabled.
                        guard !modeLocked else { return }
                        if newValue {
                            showConfirmEnable = true
                        } else {
                            showConfirmDisable = true
                        }
                    }
                if modeLocked {
                    ManagedLockNote(organization: ManagedLockReason.organization)
                }
            } header: {
                Label("Clinical Data Protection", systemImage: "cross.case.fill")
            } footer: {
                Text("Enables safeguards for handling protected health information during clinical recordings, consultations, and interactions.")
            }

            if complianceEnabled {
                // MARK: - What Changes
                Section {
                    changeRow(icon: biometricIcon, color: AppAccent.color, title: "App Lock",
                              detail: "\(biometricName) required to open app")
                    changeRow(icon: "lock.doc.fill", color: AppAccent.color, title: "File Protection",
                              detail: "Recordings, transcripts, audit log and exports unreadable while locked")
                    changeRow(icon: "icloud.slash.fill", color: OGTheme.warnLabel, title: "iCloud Backup",
                              detail: "Clinical data excluded from backup")
                    changeRow(icon: "magnifyingglass", color: OGTheme.errorLabel, title: "Web Search",
                              detail: "Disabled — prevents clinical query leakage")
                    changeRow(icon: "paperplane.fill", color: OGTheme.errorLabel, title: "External Messaging",
                              detail: "Disabled — prevents uncontrolled PHI sharing")
                    changeRow(icon: "dot.radiowaves.left.and.right", color: OGTheme.errorLabel, title: "Live Streaming",
                              detail: "Disabled — camera and microphone never go to a streaming service")
                    changeRow(icon: "person.2.wave.2", color: OGTheme.errorLabel, title: "Live Expert View",
                              detail: "Disabled — an expert gets the job record, never the camera or microphone")
                    changeRow(icon: "cloud.fill", color: OGTheme.errorLabel, title: "Cloud Memory Sync",
                              detail: "Disabled — memories stay on-device only")
                    changeRow(icon: "globe", color: OGTheme.warnLabel, title: "Caption Translation",
                              detail: "On-device only — audio never streams to the cloud")
                    changeRow(icon: "list.clipboard.fill", color: AppAccent.color, title: "Audit Logging",
                              detail: "Data access events are recorded on this phone, while Medical mode is on")
                    changeRow(icon: "calendar.badge.clock", color: AppAccent.color, title: "Auto-Purge",
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
                                        .foregroundStyle(OGTheme.okLabel)
                                    ForEach(framework.coveredSafeguards, id: \.self) { safeguard in
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(OGTheme.okLabel)
                                            Text(safeguard.title)
                                                .font(.caption)
                                        }
                                    }
                                }

                                // Canada's health acts (Plan NJ §8): the province picks the act.
                                if framework == .canadianHealthActs {
                                    canadaPicker
                                }

                                // Organisation's responsibility
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your organisation's responsibility")
                                        .font(.caption.bold())
                                        .foregroundStyle(OGTheme.warnLabel)
                                    ForEach(framework.organisationalRequirements(in: jurisdiction), id: \.self) { req in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "person.fill")
                                                .font(.caption2)
                                                .foregroundStyle(OGTheme.warnLabel)
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
                        .tint(AppAccent.color)
                        .disabled(localOnlyLocked)
                        .onChange(of: localOnly) { _, val in
                            guard !localOnlyLocked else { return }
                            Config.hipaaLocalOnly = val
                            // Compliance mode has its own teardown hook; this switch had none, so
                            // turning it on mid-session used to leave live sockets streaming until
                            // the next launch.
                            MedicalEgressCoordinator.announceModeChange()
                        }
                    if localOnlyLocked {
                        ManagedLockNote(organization: ManagedLockReason.organization)
                    }
                } header: {
                    Text("Data Routing")
                } footer: {
                    if localOnly {
                        Text("All AI queries are processed on-device. No clinical data is sent to an AI provider; it leaves the phone only to your own record system.")
                    } else {
                        Label {
                            Text("Cloud LLM providers may process clinical data. Ensure you have a signed agreement (BAA, DPA, or equivalent) with your provider.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(OGTheme.warnLabel)
                    }
                }

                // MARK: - Data Retention
                Section {
                    Picker("Auto-Purge After", selection: $retentionDays) {
                        ForEach(retentionChoices, id: \.self) { days in
                            Text(days == 0 ? "Never (manual only)" : "\(days) days").tag(days)
                        }
                    }
                    .disabled(retentionLocked)
                    .onChange(of: retentionDays) { _, val in
                        guard !retentionLocked else { return }
                        Config.hipaaRetentionDays = val
                    }
                    if retentionLocked {
                        ManagedLockNote(organization: ManagedLockReason.organization)
                    }

                    Button {
                        hipaaService.enforceRetentionPolicy()
                    } label: {
                        Label("Run Purge Now", systemImage: "trash")
                    }
                } header: {
                    Text("Data Retention")
                } footer: {
                    Text("Transcripts and temporary recordings older than the retention period are deleted when the app opens or returns to the foreground, whether or not compliance mode is on. Deletion removes the file from this phone. It cannot reach a copy that already left it — an existing backup, or a transcript you shared — so delete those where they are.")
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
                            if exportService.configurationStore.configuration.isConfigured {
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
        .ogFormStyle()
        .alert("Enable Medical Compliance?", isPresented: $showConfirmEnable) {
            Button("Enable") {
                hipaaService.setMode(true)
            }
            Button("Cancel", role: .cancel) {
                complianceEnabled = false
            }
        } message: {
            Text("This will:\n• Require biometric authentication to open the app\n• Make recordings, transcripts, the audit log and exports unreadable while the phone is locked, including recordings already saved\n• Disable web search and external messaging\n• Exclude clinical data from iCloud backup\n• Enable audit logging of all data access")
        }
        .alert("Disable Medical Compliance?", isPresented: $showConfirmDisable) {
            Button("Disable", role: .destructive) {
                hipaaService.setMode(false)
            }
            Button("Cancel", role: .cancel) {
                complianceEnabled = true
            }
        } message: {
            Text("Disabling compliance mode will remove encryption enforcement and allow clinical data to be sent to cloud services. Existing protected files will retain their encryption.")
        }
    }

    // MARK: - Canada

    /// The province or territory picker and its act (Plan NJ §8).
    private var canadaPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Province or territory", selection: $jurisdictionRaw) {
                ForEach(CanadianJurisdiction.allCases) { place in
                    Text(place.name).tag(place.rawValue)
                }
            }
            .pickerStyle(.menu)
            let act = CanadianHealthAct.act(for: jurisdiction)
            Text(verbatim: act.title)
                .font(.caption.bold())
            Text("A supplier is the act's \(act.vendorTerm). A stock list that is inventory-only holds no patient's health information, so none of the duties below is triggered by it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func changeRow(icon: String, color: Color, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
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
        default: return String(localized: "Passcode")
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
                    Label(safeguard.title, systemImage: safeguard.icon)
                }
            }
        }
        .navigationTitle("Safeguard Details")
        .ogFormStyle()
    }
}

// MARK: - Audit Log View

/// Displays the compliance audit log with export capability.
struct AuditLogView: View {
    @ObservedObject var hipaaService: HIPAAComplianceService
    @State private var showExportSheet = false
    @State private var export: HIPAAComplianceService.AuditLogExport?

    private func prepareExport() {
        export = try? hipaaService.exportProtectedAuditLog()
        showExportSheet = true
    }

    private func releaseExport() {
        guard let export else { return }
        hipaaService.releaseAuditLogExport(export)
        self.export = nil
    }

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
                                .foregroundStyle(AppAccent.color)
                            Spacer()
                            Text(entry.at, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // Typed classes and counts, never a detail sentence (W05.2).
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Audit Log")
        .ogFormStyle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    prepareExport()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(hipaaService.auditLog.isEmpty)
            }
        }
        .sheet(isPresented: $showExportSheet, onDismiss: releaseExport) {
            // The export is a protected, backup-excluded, TTL-bound file rather than a string
            // handed straight to the share sheet (W05.4); releasing on dismiss is what ends it.
            if let export {
                ShareLink(item: export.fileURL) {
                    Label("Export Audit Log", systemImage: "doc.text")
                }
                .presentationDetents([.medium])
            } else {
                Text("The audit log could not be prepared for export.")
                    .font(.callout)
                    .padding()
                    .presentationDetents([.medium])
            }
        }
    }
}
