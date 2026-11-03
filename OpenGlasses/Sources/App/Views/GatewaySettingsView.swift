import SwiftUI

/// Manage multiple gateway endpoints (OpenClaw, NanoClaw, NemoClaw, custom).
/// Each gateway has its own host, token, connection mode, and priority.
struct GatewaySettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @ObservedObject private var adminGate = AdminGate.shared
    @State private var gateways: [GatewayConfig] = Config.savedGateways
    @State private var editingGateway: GatewayConfig?
    @State private var showAddSheet = false
    @State private var remoteObserve = Config.remoteInvokeObserveEnabled
    @State private var remoteOutput = Config.remoteInvokeOutputEnabled
    @State private var remoteCapture = Config.remoteInvokeCaptureEnabled

    var body: some View {
        List {
            if gateways.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Gateways Configured")
                            .font(.headline)
                        Text("A gateway is a small server (e.g. running on your computer or a Raspberry Pi) that gives the AI access to more capabilities — smart-home control, local automations, custom tools. Run OpenClaw, NanoClaw, NemoClaw, or any compatible server and point this app at it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } footer: {
                    Text("Skip this section if you don't run your own server — most users won't need a gateway.")
                }
            } else {
                Section {
                    ForEach(gateways) { gateway in
                        Button {
                            editingGateway = gateway
                        } label: {
                            gatewayRow(gateway)
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { from, to in
                        gateways.move(fromOffsets: from, toOffset: to)
                        updatePriorities()
                        save()
                    }
                    .onDelete { indexSet in
                        gateways.remove(atOffsets: indexSet)
                        updatePriorities()
                        save()
                    }
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("Drag to reorder priority. The app tries gateways top-to-bottom until one responds.")
                }
            }

            // Active connection status
            if let name = appState.openClawBridge.activeGatewayName {
                Section {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(OGTheme.ok)
                            .frame(width: 8, height: 8)
                        Text("Connected to \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let conn = appState.openClawBridge.resolvedConnection {
                            Text(conn.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                } header: {
                    Text("Status")
                }
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Gateway", systemImage: "plus.circle.fill")
                }
            }

            // Agent bridge (Plan CL P5): unlike the tool gateways above, the bridge
            // takes over whole conversation turns — it lives here because "connects
            // the app to an external agent" is one concept to the user.
            Section {
                NavigationLink {
                    HermesBridgeSettingsView(appState: appState)
                } label: {
                    HStack {
                        Label("Hermes Agent", systemImage: "laptopcomputer.and.iphone")
                        Spacer()
                        if Config.hermesBridgeEnabled {
                            // Only the bridge script holds a socket whose state means something;
                            // the API server is asked per turn, so "On" is all there is to say.
                            Text(Config.hermesConnectionKind == .bridgeScript
                                 && appState.hermesBridge.status == .connected ? "Connected" : "On")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Agent Bridge")
            } footer: {
                Text("Gateways add tools the assistant can call. Hermes Agent goes further: when enabled, an agent on your computer answers whole conversations with its own tools and memory.")
            }

            // Remote invoke (Plan BH): per-class consent for gateway-initiated device commands.
            remoteInvokeSection
        }
        .navigationTitle("Gateways")
        .ogFormStyle()
        .sheet(isPresented: $showAddSheet) {
            AddGatewaySheet { newGateway in
                gateways.append(newGateway)
                updatePriorities()
                save()
            }
        }
        .sheet(item: $editingGateway) { gateway in
            EditGatewaySheet(appState: appState, gateway: gateway) { updated in
                if let idx = gateways.firstIndex(where: { $0.id == updated.id }) {
                    gateways[idx] = updated
                    save()
                }
            }
        }
        // A pairing stores its device token (or drops its setup code) behind this list's back;
        // reload so the next save does not write the old copy over it.
        .onChange(of: appState.gatewayPairing) { _, _ in
            gateways = Config.savedGateways
        }
    }

    @ViewBuilder
    private var remoteInvokeSection: some View {
        Section {
            if !Config.agentModeEnabled {
                Label("Requires Agent Mode", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Plan HA C4: a switch the organisation pinned is not shown to the technician; an
            // administrator sees it read-only with the organisation named.
            if adminGate.presentation(.key(.remoteInvokeObserveEnabled)).isShown {
                Toggle("Status & capabilities (observe)", isOn: $remoteObserve)
                    .onChange(of: remoteObserve) { _, v in Config.remoteInvokeObserveEnabled = v }
                    .disabled(PolicyEnvelope.isLocked(.remoteInvokeObserveEnabled))
                ManagedSettingNote(key: .remoteInvokeObserveEnabled)
            }
            if adminGate.presentation(.key(.remoteInvokeOutputEnabled)).isShown {
                Toggle("Speak & display (output)", isOn: $remoteOutput)
                    .onChange(of: remoteOutput) { _, v in Config.remoteInvokeOutputEnabled = v }
                    .disabled(PolicyEnvelope.isLocked(.remoteInvokeOutputEnabled))
                ManagedSettingNote(key: .remoteInvokeOutputEnabled)
            }
            if adminGate.presentation(.key(.remoteInvokeCaptureEnabled)).isShown {
                Toggle("Camera, recording & transcript (capture)", isOn: $remoteCapture)
                    .onChange(of: remoteCapture) { _, v in Config.remoteInvokeCaptureEnabled = v }
                    .disabled(PolicyEnvelope.isLocked(.remoteInvokeCaptureEnabled))
                ManagedSettingNote(key: .remoteInvokeCaptureEnabled)
            }
            NavigationLink {
                RemoteInvokeAuditView(service: appState.remoteInvoke)
            } label: {
                HStack {
                    Text("Activity Log")
                    Spacer()
                    Text("\(appState.remoteInvoke.auditLog.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Remote Invoke")
        } footer: {
            #if AVENKIN_PHONE_ONLY
            Text("Lets a gateway agent ask Avenkin to act (speak, check status — and with capture enabled, take photos, record, or read back the recent transcript). Everything is denied while Agent Mode is off; capture always asks for confirmation and announces itself before a sensor starts or recorded speech is read back.")
            #else
            Text("Lets a gateway agent ask Avenkin to act (speak, show text on the glasses, check status — and with capture enabled, take photos, record, or read back the recent transcript). Everything is denied while Agent Mode is off; capture always asks for confirmation and announces itself before a sensor starts or recorded speech is read back.")
            #endif
        }
    }

    private func gatewayRow(_ gateway: GatewayConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: gateway.gatewayProvider.icon)
                .font(.title3)
                .foregroundStyle(gateway.enabled ? accent : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gateway.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.label))
                    Text(gateway.gatewayProvider.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }

                let host = !gateway.tunnelURL.isEmpty ? gateway.tunnelURL : gateway.lanURL
                if !host.isEmpty {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text(gateway.connectionModeEnum.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !gateway.token.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(OGTheme.okLabel)
                    }
                }
            }

            Spacer()

            if !gateway.enabled {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func updatePriorities() {
        for i in gateways.indices {
            gateways[i].priority = i
        }
    }

    private func save() {
        Config.setSavedGateways(gateways)
        appState.openClawBridge.clearCachedEndpoint()
    }
}

// MARK: - Add Gateway Sheet

struct AddGatewaySheet: View {
    var onSave: (GatewayConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var selectedProvider: GatewayProvider = .openclaw

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(GatewayProvider.allCases) { provider in
                        Button {
                            selectedProvider = provider
                            let gateway = GatewayConfig.newGateway(provider: provider)
                            onSave(gateway)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: provider.icon)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color(.label))
                                    Text(providerDescription(provider))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Choose Provider")
                } footer: {
                    Text("All providers use the same WebSocket protocol. You can add multiple gateways for failover.")
                }
            }
            .navigationTitle("Add Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .ogFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func providerDescription(_ provider: GatewayProvider) -> String {
        switch provider {
        case .openclaw: return String(localized: "Full-featured multi-user gateway with 56+ skills")
        case .nanoclaw: return String(localized: "Lightweight single-user agent with container isolation")
        case .nemoclaw: return String(localized: "NVIDIA NeMo-powered agent gateway")
        case .custom: return String(localized: "Any OpenClaw-compatible WebSocket endpoint")
        }
    }
}

// MARK: - Edit Gateway Sheet

struct EditGatewaySheet: View {
    @ObservedObject var appState: AppState
    @State var gateway: GatewayConfig
    var onSave: (GatewayConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var testStatus: String = ""
    /// Whether the last connection test reached the gateway — kept apart from the (localized) words.
    @State private var testSucceeded = false
    @State private var setupCodeInput: String = ""
    @State private var pairingMessage: String = ""
    /// A setup code whose address differs from the saved one, held until the wearer decides.
    @State private var pendingAddressChange: PendingAddressChange?

    private struct PendingAddressChange: Equatable {
        let address: SetupCodeAddress
        let setupCode: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $gateway.name)
                    Picker("Provider", selection: Binding(
                        get: { gateway.gatewayProvider },
                        set: { gateway.provider = $0.rawValue }
                    )) {
                        ForEach(GatewayProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    Toggle("Enabled", isOn: $gateway.enabled)
                } header: {
                    Text("General")
                }

                Section {
                    SecretInputField(placeholder: String(localized: "Token"), text: $gateway.token)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("The gateway token from your server's config — or leave blank and pair this device below.")
                }

                devicePairingSection

                Section {
                    Picker("Connection Mode", selection: Binding(
                        get: { gateway.connectionModeEnum },
                        set: { gateway.connectionMode = $0.rawValue }
                    )) {
                        ForEach(OpenClawConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if gateway.connectionModeEnum != .tunnel {
                        TextField("LAN Host", text: $gateway.lanHost)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(commitAddressFields)
                        TextField("Port", value: $gateway.port, format: .number)
                            .keyboardType(.numberPad)
                    }

                    if gateway.connectionModeEnum != .lan {
                        TextField("Tunnel / Tailscale Host", text: $gateway.tunnelHost)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(commitAddressFields)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("LAN for local network, Tunnel for Tailscale/remote access, Auto tries LAN first.")
                }

                Section {
                    Button("Test Connection") {
                        testConnection()
                    }
                    if !testStatus.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testSucceeded ? OGTheme.okLabel : OGTheme.errorLabel)
                            Text(testStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .ogFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        commitAddressFields()
                        onSave(gateway)
                        dismiss()
                    }
                }
            }
            .onChange(of: appState.gatewayPairing) { old, new in
                // Only when a pairing for this gateway starts or ends — a plain status change
                // must not undo an unpair the wearer has not saved yet.
                let started = new.pairingGatewayId == gateway.id && old.pairingGatewayId != gateway.id
                let ended = new.lastPairingGatewayId == gateway.id && new.pairingGatewayId != gateway.id
                    && (old.pairingGatewayId == gateway.id || old.lastPairingEnd != new.lastPairingEnd)
                if started || ended { reloadPairingFields() }
            }
        }
    }

    // MARK: - Device pairing

    private var pairing: GatewayPairingSnapshot { appState.gatewayPairing }
    private var isPairingThisGateway: Bool { pairing.pairingGatewayId == gateway.id }

    @ViewBuilder
    private var devicePairingSection: some View {
        Section {
            // Pairing opens the gateway's event socket, which only runs with Agent Mode on.
            if !Config.agentModeEnabled {
                Label("Requires Agent Mode", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let deviceToken = gateway.deviceToken, !deviceToken.isEmpty {
                HStack {
                    Label("Paired", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(OGTheme.okLabel)
                    Spacer()
                    Text("This device").font(.caption).foregroundStyle(.secondary)
                }
                Button("Unpair This Device", role: .destructive) {
                    gateway.deviceToken = nil
                    gateway.deviceId = nil
                    gateway.setupCode = nil
                    pairingMessage = String(localized: "Unpaired. Save to apply.")
                }
            } else if isPairingThisGateway {
                pairingStatusRow
                Button("Cancel Pairing", role: .destructive) {
                    appState.openClawEventClient.cancelPairing()
                }
            } else if let change = pendingAddressChange {
                Text("This setup code is for a different address from the one saved for this gateway. Pair with the address in the code, or cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Use the Code's Address and Pair") {
                    gateway = change.address.replacing(in: gateway)
                    pendingAddressChange = nil
                    beginPairing(setupCode: change.setupCode)
                }
                Button("Cancel", role: .cancel) {
                    pendingAddressChange = nil
                    pairingMessage = ""
                }
            } else {
                TextField("Setup Code", text: $setupCodeInput, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.footnote, design: .monospaced))
                Button("Pair With Setup Code") {
                    pairWithSetupCode()
                }
                .disabled(!Config.agentModeEnabled
                          || setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let ended = endedPairingMessage {
                    Text(ended).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !pairingMessage.isEmpty {
                Text(pairingMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Device Pairing")
        } footer: {
            Text("Pair with a one-time setup code instead of a shared token. The gateway issues a per-device token you can revoke independently. A setup code fills in the gateway's address when none is saved.")
        }
    }

    /// The running pairing, as the event client last reported it.
    private var pairingStatusRow: some View {
        HStack(spacing: 8) {
            switch pairing.status {
            case .waitingApproval?:
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                Text("Waiting for approval. Approve this device on your gateway.")
            case .error?:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(OGTheme.errorLabel)
                Text("The gateway didn't accept the connection. Check its address and setup code, or cancel and try again.")
            case .paired?:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OGTheme.okLabel)
                Text("Connected. Finishing pairing…")
            case .connecting?, .disconnected?, nil:
                ProgressView()
                Text("Connecting to the gateway…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// How the last pairing for this gateway ended, when it ended without pairing.
    private var endedPairingMessage: String? {
        guard pairing.lastPairingGatewayId == gateway.id else { return nil }
        switch pairing.lastPairingEnd {
        case .timedOut?:
            return String(localized: "Pairing timed out before the device was approved. Get a new setup code from your gateway and try again.")
        case .cancelled?:
            return String(localized: "Pairing cancelled.")
        case .paired?, nil:
            return nil
        }
    }

    /// Check the code and its address, then pair — or ask first if the address differs.
    private func pairWithSetupCode() {
        pairingMessage = ""
        let trimmed = setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = SetupCode.decode(trimmed) else {
            pairingMessage = String(localized: "That setup code isn't valid.")
            return
        }
        guard case let .success(address) = SetupCodeAddress.parse(
            payload.url, defaultPort: gateway.gatewayProvider.defaultPort) else {
            pairingMessage = String(localized: "The address in this setup code can't be used. Check the code with your gateway.")
            return
        }
        switch address.apply(to: gateway) {
        case .filled(let updated):
            gateway = updated
            beginPairing(setupCode: trimmed)
        case .matches:
            beginPairing(setupCode: trimmed)
        case .differs:
            pendingAddressChange = PendingAddressChange(address: address, setupCode: trimmed)
        }
    }

    /// Save the gateway as it stands (the client pairs the saved copy), then start pairing.
    private func beginPairing(setupCode: String) {
        guard gateway.enabled else {
            pairingMessage = String(localized: "Turn this gateway on to pair with it.")
            return
        }
        gateway.setupCode = setupCode
        onSave(gateway)
        setupCodeInput = ""
        appState.openClawEventClient.startPairing(gatewayId: gateway.id, setupCode: setupCode)
    }

    /// The client writes the pairing fields to the saved gateway; keep this sheet's copy in step
    /// so Save does not put the old ones back.
    private func reloadPairingFields() {
        guard let saved = Config.savedGateways.first(where: { $0.id == gateway.id }) else { return }
        gateway.deviceToken = saved.deviceToken
        gateway.deviceId = saved.deviceId
        gateway.setupCode = saved.setupCode
    }

    /// Show the hosts as they will be used: a scheme added to a bare name, and a port typed in
    /// the LAN host moved into the port field (`GatewayAddress`).
    private func commitAddressFields() {
        if let lan = GatewayAddress.fieldValues(host: gateway.lanHost, port: gateway.port) {
            gateway.lanHost = lan.host
            gateway.port = lan.port
        }
        if let tunnel = GatewayAddress.normalise(gateway.tunnelHost) {
            gateway.tunnelHost = tunnel
        }
    }

    private func testConnection() {
        testStatus = String(localized: "Testing...")
        testSucceeded = false
        let host: String
        switch gateway.connectionModeEnum {
        case .lan: host = gateway.lanURL
        case .tunnel: host = gateway.tunnelURL
        case .auto: host = !gateway.lanURL.isEmpty ? gateway.lanURL : gateway.tunnelURL
        }
        let normalized = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard MedicalEgressGuard.allows(.gatewayConnectionTest) else {
            testStatus = MedicalEgressRefusal.userMessage
            return
        }
        guard let url = try? EndpointPolicy.require("\(normalized)/health", for: .gatewayConnectionTest) else {
            testStatus = String(localized: "Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(gateway.token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    testStatus = String(localized: "Failed: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    testStatus = String(localized: "Connected (\(http.statusCode))")
                    testSucceeded = true
                } else if let http = response as? HTTPURLResponse {
                    testStatus = "HTTP \(http.statusCode)"
                } else {
                    testStatus = String(localized: "No response")
                }
            }
        }.resume()
    }
}
