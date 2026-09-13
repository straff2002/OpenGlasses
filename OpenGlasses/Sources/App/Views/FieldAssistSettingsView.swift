import StoreKit
import SwiftUI

/// Settings UI for the Field Assist (B2B) feature: master toggle, vault picker,
/// default session mode, and a manual session start/end for debugging.
@MainActor
struct FieldAssistSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var sessionService = FieldSessionService.shared
    @StateObject private var license = LicenseService.shared
    @StateObject private var store = StoreKitService.shared
    @AppStorage("fieldAssistEnabled") private var enabled: Bool = false
    @AppStorage("fieldAssistDefaultVaultId") private var defaultVaultId: String = "refrigeration"
    @AppStorage("fieldAssistDefaultMode") private var defaultMode: String = "ai_only"

    @State private var licenseCode = ""
    @State private var licenseMessage: String?
    @State private var licenseMessageIsError = false
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    /// Whether the equipment row is showing its heading and provenance (Plan EL P2).
    @State private var equipmentExpanded = false
    /// Where job reports may go, and to whom (Plan EM P2).
    @State private var delivery = DeliverySettings()
    /// The recipient fields as typed. Kept raw so the list is only parsed on the way out — a
    /// getter that re-joins what you are typing eats the comma you just pressed.
    @State private var emailRecipientsText = ""
    @State private var messageRecipientsText = ""
    /// The task whose detail is open on the session card.
    @State private var expandedTaskId: String?
    /// The read-back, shown as well as spoken — a technician confirms what they can see.
    @State private var readBack: [String]?
    /// Why a report could not be staged, in the policy's own words.
    @State private var deliveryError: String?
    /// How many of this job's records the queue is still holding. Read on appearance and when a
    /// delivery finishes rather than from the view body — the queue is SQLite, and the body is
    /// re-evaluated on every published change the session makes.
    @State private var unsentRecordCount = 0

    var body: some View {
        Form {
            // ──────────────── Toggle
            Section {
                Toggle("Enable Field Assist", isOn: $enabled)
                    .tint(AppAccent.color)
                    .disabled(!Config.fieldAssistUnlocked)
            } footer: {
                Text("Field Assist provides hands-free, domain-grounded guidance for service technicians. When enabled, the `field_session` tool becomes available and an active session injects the relevant knowledge vault into the AI's context.")
            }

            // ──────────────── Entitlement (paywall when locked, status when unlocked)
            if Config.fieldAssistUnlocked {
                entitlementStatus
            } else {
                entitlementPaywall
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

                // ──────────────── Reference file editing
                Section {
                    ForEach(VaultRegistry.shared.allManifests.filter { VaultRegistry.shared.isUnlocked($0) }, id: \.id) { manifest in
                        NavigationLink {
                            VaultFilesEditorView(vaultId: manifest.id, title: manifest.name)
                        } label: {
                            Label("\(manifest.name) — \(manifest.files.count) files", systemImage: "doc.text")
                        }
                        .swipeActions(edge: .leading) {
                            if VaultExporter.isExportable(manifest) {
                                Button {
                                    exportVault(manifest)
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                                .tint(AppAccent.color)
                            }
                        }
                    }
                } header: {
                    Text("Reference Files")
                } footer: {
                    Text("Edit a vault's grounding references in-app — edits write to a private overlay and never touch the bundled baseline. Swipe a free or imported vault to export it with your edits; paid bundled packs can't be exported.")
                }

                // ──────────────── Offline sync (Plan T)
                Section {
                    NavigationLink {
                        SyncStatusView(engine: appState.syncEngine, reachability: appState.reachability)
                    } label: {
                        Label("Field Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Work done without signal is saved on the device and syncs automatically when you're back online. Tap to see what's queued.")
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
                    Text("How the glasses view reaches the expert. MJPEG streams one-way video to a browser viewer through a relay you run. WebRTC is peer-to-peer with two-way audio and needs a signaling URL (and TURN for cross-network use) configured below.")
                }

                if Config.expertStreamTransport == .mjpeg {
                    Section {
                        webrtcField("Relay URL", "wss://relay.example/ws",
                                    { Config.webRTCSignalingURL }, { Config.setWebRTCSignalingURL($0) })
                        webrtcField("Viewer link base", "https://relay.example/view",
                                    { Config.webRTCViewerBaseURL }, { Config.setWebRTCViewerBaseURL($0) })
                    } header: {
                        Text("MJPEG Relay")
                    } footer: {
                        Text("Required for MJPEG. The app ships with no relay, so run your own and enter it here — video goes only to that server. The relay URL is the WebSocket the phone pushes JPEG frames to; the viewer link base is the page the expert opens, with the room code added to it.")
                    }
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

                // ──────────────── Job reports (Plan EM P2)
                jobReportSection

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

                        equipmentRows

                        taskRows

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
        }
        .navigationTitle("Field Assist")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear {
            delivery = Config.deliverySettings
            emailRecipientsText = delivery.emailRecipients.joined(separator: ", ")
            messageRecipientsText = delivery.messageRecipients.joined(separator: ", ")
            refreshUnsentCount()
            license.loadStored()
            // Defensive: a lapsed entitlement (expired license, revoked purchase) disables the toggle.
            if enabled && !Config.fieldAssistUnlocked { enabled = false }
        }
        .onChange(of: sessionService.lastDeliveryCancelled) { _, _ in refreshUnsentCount() }
        .onChange(of: sessionService.activeSession?.id) { _, _ in refreshUnsentCount() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
        .sheet(isPresented: Binding(get: { readBack != nil }, set: { if !$0 { readBack = nil } })) {
            readBackSheet
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("Can't send that report", isPresented: .constant(deliveryError != nil)) {
            Button("OK") { deliveryError = nil }
        } message: {
            Text(deliveryError ?? "")
        }
    }

    // MARK: - Job reports (where the finished record goes)

    /// Recipients, the organisation's endpoint, and which channels a report may use.
    ///
    /// Local for now. These are the organisation's call rather than each technician's — site data
    /// usually is — and an organisation profile is where they will come from; the merge rule is
    /// already written (`DeliverySettings.applying(organisation:)`), so this screen becomes the
    /// override rather than the source.
    @ViewBuilder
    private var jobReportSection: some View {
        Section {
            TextField("office@example.com, dispatch@example.com", text: $emailRecipientsText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .onChange(of: emailRecipientsText) { _, value in
                    delivery.emailRecipients = Self.recipients(from: value)
                    Config.setDeliverySettings(delivery)
                }
            TextField("+64 21 000 000", text: $messageRecipientsText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.phonePad)
                .onChange(of: messageRecipientsText) { _, value in
                    delivery.messageRecipients = Self.recipients(from: value)
                    Config.setDeliverySettings(delivery)
                }
        } header: {
            Text("Job Reports")
        } footer: {
            Text("Where a finished job report goes when nobody names anybody. The first line is email, the second is Messages; separate several with commas. Saying \u{201C}send the job report to base\u{201D} fills the composer in and you tap Send.")
        }

        Section {
            TextField("https://ops.example.com/job-reports", text: Binding(
                get: { delivery.endpoint },
                set: { delivery.endpoint = $0; Config.setDeliverySettings(delivery) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Bearer token (optional)", text: Binding(
                get: { delivery.endpointToken },
                set: { delivery.endpointToken = $0; Config.setDeliverySettings(delivery) }))
        } header: {
            Text("Office Endpoint")
        } footer: {
            Text("Optional. With an endpoint set, job records and parts requests are posted there through the offline queue — no tap needed — and retried until they arrive. The token is kept in the Keychain, never in preferences.")
        }

        Section {
            ForEach(DeliveryChannel.allCases) { channel in
                Toggle(channel.label, isOn: Binding(
                    get: { delivery.allowedChannels.contains(channel) },
                    set: { allowed in
                        if allowed { delivery.allowedChannels.insert(channel) }
                        else { delivery.allowedChannels.remove(channel) }
                        Config.setDeliverySettings(delivery)
                    }))
                    .tint(AppAccent.color)
                    .disabled(channel == .endpoint && !delivery.hasEndpoint)
            }
        } header: {
            Text("Allowed Channels")
        } footer: {
            Text("Which routes a job report may leave by. Site data is the organisation's call — switch a channel off and the assistant refuses it out loud and names the ones that are allowed. The endpoint becomes available once one is configured above.")
        }
    }

    /// "office@x, dispatch@y" → two recipients; blank entries are dropped rather than stored.
    static func recipients(from raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Tasks (what was recommended, decided and done)

    /// The job's tasks on the session card, with the read-back and the report button beside them.
    /// P1 recorded all of this and showed none of it; a wrong decision needs a screen to be seen on.
    @ViewBuilder
    private var taskRows: some View {
        let model = TaskSectionModel(host: sessionService, unsentCount: unsentRecordCount)
        let rows = model.rows

        HStack {
            Text(rows.isEmpty ? "Tasks" : "Tasks — \(model.headline)")
                .font(.subheadline)
            Spacer()
        }

        if rows.isEmpty {
            Text(model.emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                Button {
                    expandedTaskId = (expandedTaskId == row.id) ? nil : row.id
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(row.statusLabel)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                        if let evidence = row.evidence {
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        }
                        if expandedTaskId == row.id {
                            if row.isOperatorAdded {
                                Text("Added by the technician").font(.caption).foregroundStyle(.secondary)
                            }
                            if let why = row.why {
                                Text("Why: \(why)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let procedure = row.procedureLine {
                                Text(procedure).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(row.parts, id: \.self) { part in
                                Text("Part: \(part)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let note = row.completionNote {
                                Text("Note: \(note)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let citation = row.citation {
                                Text("Cited \(citation)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let safety = row.safetyNote {
                                Text(safety).font(.caption).foregroundStyle(OGTheme.warnLabel)
                            }
                        }
                    }
                }
            }
        }

        if let unsent = model.unsentLine {
            Text(unsent)
                .font(.caption)
                .foregroundStyle(OGTheme.warnLabel)
        }

        HStack {
            Button("Read back the job") {
                let model = TaskSectionModel(host: sessionService)
                readBack = model.readBack
                if let speech = model.readBackSpeech {
                    Task { await appState.speechService.speak(speech) }
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)

            Spacer()

            Button("Send report…") { sendReport() }
                .buttonStyle(.bordered)
                .font(.subheadline)
        }
    }

    /// The read-back on screen as well as in the ear — a technician confirms what they can see.
    @ViewBuilder
    private var readBackSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((readBack ?? []).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("The job so far")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { readBack = nil }
                }
            }
        }
    }

    private func refreshUnsentCount() {
        guard let id = sessionService.activeSession?.id else {
            unsentRecordCount = 0
            return
        }
        unsentRecordCount = QueuedRecordRows.outstandingCount(
            in: appState.offlineQueue.all(limit: 200), sessionId: id)
    }

    /// Stage the default delivery — the same route the spoken "send the job report" takes, so the
    /// button and the sentence cannot end up doing different things.
    private func sendReport() {
        guard let record = sessionService.workRecord() else { return }
        let policy = DeliveryPolicy(settings: Config.deliverySettings)
        guard let channel = policy.defaultChannel else {
            deliveryError = "No channel is allowed for job reports. Set one up under Job Reports above."
            return
        }
        switch policy.decide(channel: channel) {
        case .refused(let reason):
            deliveryError = reason
        case .allowed(let recipients):
            sessionService.stageDelivery(DeliveryRequest.make(
                record: record, channel: channel, recipients: recipients,
                attachments: sessionService.reportAttachments()))
        }
    }

    // MARK: - Equipment (the machine the session is working on)

    /// The active machine on the session card: the model token, its heading, where the
    /// recognition came from and when — plus one tap to correct it and one to forget it. A vault
    /// whose core names no models draws nothing here at all.
    @ViewBuilder
    private var equipmentRows: some View {
        let equipment = EquipmentSectionModel(host: sessionService)
        switch equipment.state {
        case .unavailable:
            EmptyView()

        case .unset(let choices):
            equipmentPicker(equipment, choices: choices) {
                Label("Set equipment", systemImage: "barcode.viewfinder")
                    .font(.subheadline)
            }

        case .identified(let detail, let choices):
            Button {
                equipmentExpanded.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Equipment: \(detail.model)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if equipmentExpanded {
                            Text(detail.heading)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(detail.provenance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: equipmentExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Equipment \(detail.model), \(detail.provenance). Tap for details.")

            HStack {
                equipmentPicker(equipment, choices: choices) {
                    Text("Change").font(.subheadline)
                }
                Spacer()
                Button("Clear", role: .destructive) { equipment.clear() }
                    .font(.subheadline)
            }
        }
    }

    /// The vault's own model headings, as a menu. Selecting one records it as picked on the phone.
    @ViewBuilder
    private func equipmentPicker<Content: View>(
        _ equipment: EquipmentSectionModel,
        choices: [EquipmentSectionModel.Choice],
        @ViewBuilder label: () -> Content
    ) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    equipment.select(choice)
                } label: {
                    if choice.isActive {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        } label: {
            label()
        }
    }

    private func exportVault(_ manifest: VaultManifest) {
        do {
            let url = try VaultExporter.export(id: manifest.id)
            shareItem = ShareItem(items: [url])
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Entitlement UI

    /// IAP identifiers a Field Assist entitlement unlocks (mirror of VaultRegistry's gating cases).
    private static let fieldAssistIAPs: Set<String> = ["field_assist_refrigeration", "field_assist_it", "enterprise"]

    /// Field-Assist-gated vaults, for the locked preview surface.
    private var fieldAssistVaults: [VaultManifest] {
        VaultRegistry.shared.allManifests.filter { manifest in
            guard let iap = manifest.gating.iap else { return false }
            return Self.fieldAssistIAPs.contains(iap)
        }
    }

    private var entitlementState: FieldAssistEntitlementStatus.State {
        FieldAssistEntitlementStatus.make(decision: FieldAssistEntitlement.shared.decision())
    }

    @ViewBuilder
    private var entitlementPaywall: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(FieldAssistPaywallCopy.locked, systemImage: "lock.fill")
                    .font(.headline)
                Text(FieldAssistPaywallCopy.lockedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch entitlementState {
                case .expired(let date):
                    if license.activeLicense != nil || UserDefaults.standard.string(forKey: LicenseService.storageKey) != nil {
                        Text(FieldAssistPaywallCopy.renewLicense)
                            .font(.caption)
                            .foregroundStyle(OGTheme.errorLabel)
                    } else {
                        Text(FieldAssistPaywallCopy.subscriptionLapsed)
                            .font(.caption)
                            .foregroundStyle(OGTheme.errorLabel)
                        Text("Lapsed \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .unverifiableLicense:
                    Text(FieldAssistPaywallCopy.unverifiable)
                        .font(.caption)
                        .foregroundStyle(OGTheme.errorLabel)
                default:
                    EmptyView()
                }
            }
        }

        if !fieldAssistVaults.isEmpty {
            Section {
                ForEach(fieldAssistVaults, id: \.id) { manifest in
                    NavigationLink {
                        VaultFilesEditorView(vaultId: manifest.id, title: manifest.name)
                    } label: {
                        Label("\(manifest.name) — \(manifest.files.count) files", systemImage: "eye")
                    }
                }
            } header: {
                Text("Preview Vaults")
            } footer: {
                Text("Browse the reference content read-only. Unlocking lets you edit it, run grounded sessions, and export.")
            }
        }

        licenseEntrySection

        Section {
            purchaseRow(store.fieldAssistProduct, title: "One-time unlock", subtitle: "Yours on this Apple ID, no renewal")
            purchaseRow(store.fieldAssistMonthlyProduct, title: "Monthly", subtitle: "Cancel anytime")
            purchaseRow(store.fieldAssistAnnualProduct, title: "Annual", subtitle: "Billed once a year")
            if store.fieldAssistProduct == nil && store.fieldAssistMonthlyProduct == nil && store.fieldAssistAnnualProduct == nil {
                Text("Purchase is unavailable right now. Check your connection and App Store sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Restore Purchases") { Task { await store.restorePurchases() } }
            if let error = store.purchaseError {
                Text(error).font(.caption).foregroundStyle(OGTheme.errorLabel)
            }
        } header: {
            Text(FieldAssistPaywallCopy.purchaseHeader)
        } footer: {
            Text(FieldAssistPaywallCopy.purchaseFooter)
        }
    }

    @ViewBuilder
    private var licenseEntrySection: some View {
        Section {
            TextField("Paste licence code", text: $licenseCode, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
            Button("Activate Licence") { activateLicense() }
                .disabled(licenseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let licenseMessage {
                Text(licenseMessage)
                    .font(.caption)
                    .foregroundStyle(licenseMessageIsError ? OGTheme.errorLabel : OGTheme.okLabel)
            }
        } header: {
            Text(FieldAssistPaywallCopy.licenseHeader)
        } footer: {
            Text(FieldAssistPaywallCopy.licenseFooter)
        }
    }

    @ViewBuilder
    private func purchaseRow(_ product: Product?, title: String, subtitle: String) -> some View {
        if let product {
            Button {
                Task { await store.purchase(product) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(product.displayPrice).foregroundStyle(.secondary)
                }
            }
            .disabled(store.isPurchasing)
        }
    }

    @ViewBuilder
    private var entitlementStatus: some View {
        Section {
            if case .granted(let grant) = entitlementState {
                LabeledContent("Tier", value: grant.tier.label)
                LabeledContent("Source", value: grant.sourceLabel)
                if let lic = license.activeLicense, case .organizationLicense = grant.source {
                    LabeledContent("Licensed to", value: lic.licensee)
                    if let plan = lic.planLabel { LabeledContent("Plan", value: plan) }
                    if let seats = lic.seats { LabeledContent("Seats", value: "\(seats)") }
                    if let reference = lic.reference, !reference.isEmpty { LabeledContent("Reference", value: reference) }
                }
                LabeledContent("Expires", value: grant.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                if let warning = grant.warning {
                    Label(FieldAssistPaywallCopy.expiring(warning), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(OGTheme.errorLabel)
                }
                if grant.tier == .solo {
                    Text(FieldAssistPaywallCopy.teamOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .storeProduct(let productID) = grant.source,
                   StoreKitService.fieldAssistSubscriptionIds.contains(productID) {
                    Button(FieldAssistPaywallCopy.manageSubscription) { Task { await store.showManageSubscription() } }
                }
                Text(grant.tier.capabilitySummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if license.activeLicense != nil {
                Button("Remove Licence", role: .destructive) {
                    license.clear()
                    licenseCode = ""
                    licenseMessage = nil
                    if enabled && !Config.fieldAssistUnlocked { enabled = false }
                }
            }
        } header: {
            Text("Entitlement")
        } footer: {
            if license.activeLicense?.seats != nil {
                Text(FieldAssistPaywallCopy.seatsNote)
            }
        }

        // A solo device can still enter (or renew) an organisation code from here.
        if license.activeLicense == nil {
            licenseEntrySection
        }
    }

    private func activateLicense() {
        do {
            let payload = try license.activate(code: licenseCode)
            licenseMessageIsError = false
            licenseMessage = "Activated — licensed to \(payload.licensee)."
            licenseCode = ""
        } catch {
            licenseMessageIsError = true
            licenseMessage = error.localizedDescription
        }
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
            .environmentObject(AppState())
    }
}
