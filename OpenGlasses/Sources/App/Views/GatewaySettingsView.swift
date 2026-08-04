import SwiftUI

/// Manage multiple gateway endpoints (OpenClaw, NanoClaw, NemoClaw, custom).
/// Each gateway has its own host, token, connection mode, and priority.
struct GatewaySettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.appAccent) private var accent
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
                        Text("A gateway is a small server (e.g. running on your Mac or a Raspberry Pi) that gives the AI access to more capabilities — smart-home control, local automations, custom tools. Run OpenClaw, NanoClaw, NemoClaw, or any compatible server and point this app at it.")
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
                            .fill(.green)
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
                        Label("Hermes Bridge", systemImage: "laptopcomputer.and.iphone")
                        Spacer()
                        if Config.hermesBridgeEnabled {
                            Text(appState.hermesBridge.status == .connected ? "Connected" : "On")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Agent Bridge")
            } footer: {
                Text("Gateways add tools the assistant can call. The Hermes Bridge goes further: when enabled, an agent on your Mac answers whole conversations with its own tools and memory.")
            }

            // Remote invoke (Plan BH): per-class consent for gateway-initiated device commands.
            remoteInvokeSection
        }
        .navigationTitle("Gateways")
        .sheet(isPresented: $showAddSheet) {
            AddGatewaySheet { newGateway in
                gateways.append(newGateway)
                updatePriorities()
                save()
            }
        }
        .sheet(item: $editingGateway) { gateway in
            EditGatewaySheet(gateway: gateway) { updated in
                if let idx = gateways.firstIndex(where: { $0.id == updated.id }) {
                    gateways[idx] = updated
                    save()
                }
            }
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
            Toggle("Status & transcript (observe)", isOn: $remoteObserve)
                .onChange(of: remoteObserve) { _, v in Config.remoteInvokeObserveEnabled = v }
            Toggle("Speak & display (output)", isOn: $remoteOutput)
                .onChange(of: remoteOutput) { _, v in Config.remoteInvokeOutputEnabled = v }
            Toggle("Camera & recording (capture)", isOn: $remoteCapture)
                .onChange(of: remoteCapture) { _, v in Config.remoteInvokeCaptureEnabled = v }
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
            Text("Lets a gateway agent ask the glasses to act (speak, show text, check status — and with capture enabled, take photos or record). Everything is denied while Agent Mode is off; capture always asks for confirmation and announces itself before a sensor starts.")
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
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            if !gateway.enabled {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
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
                                Image(systemName: "chevron.right")
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
        case .openclaw: return "Full-featured multi-user gateway with 56+ skills"
        case .nanoclaw: return "Lightweight single-user agent with container isolation"
        case .nemoclaw: return "NVIDIA NeMo-powered agent gateway"
        case .custom: return "Any OpenClaw-compatible WebSocket endpoint"
        }
    }
}

// MARK: - Edit Gateway Sheet

struct EditGatewaySheet: View {
    @State var gateway: GatewayConfig
    var onSave: (GatewayConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var testStatus: String = ""
    @State private var setupCodeInput: String = ""
    @State private var pairingMessage: String = ""

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
                    SecretInputField(placeholder: "Token", text: $gateway.token)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("The gateway token from your server's config — or leave blank and pair this device below.")
                }

                Section {
                    if let deviceToken = gateway.deviceToken, !deviceToken.isEmpty {
                        HStack {
                            Label("Paired", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text("This device").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Unpair This Device", role: .destructive) {
                            gateway.deviceToken = nil
                            gateway.deviceId = nil
                            gateway.setupCode = nil
                            pairingMessage = "Unpaired. Save to apply."
                        }
                    } else {
                        TextField("Setup Code", text: $setupCodeInput, axis: .vertical)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.footnote, design: .monospaced))
                        Button("Pair With Setup Code") {
                            let trimmed = setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if SetupCode.decode(trimmed) != nil {
                                gateway.setupCode = trimmed
                                pairingMessage = "Setup code saved. Save the gateway, then approve this device on your gateway to finish pairing."
                            } else {
                                pairingMessage = "That setup code isn't valid."
                            }
                        }
                        .disabled(setupCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !pairingMessage.isEmpty {
                        Text(pairingMessage).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Device Pairing")
                } footer: {
                    Text("Pair with a one-time setup code instead of a shared token. The gateway issues a per-device token you can revoke independently.")
                }

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
                        TextField("Port", value: $gateway.port, format: .number)
                            .keyboardType(.numberPad)
                    }

                    if gateway.connectionModeEnum != .lan {
                        TextField("Tunnel / Tailscale Host", text: $gateway.tunnelHost)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
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
                            Image(systemName: testStatus.contains("Connected") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testStatus.contains("Connected") ? .green : .red)
                            Text(testStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(gateway)
                        dismiss()
                    }
                }
            }
        }
    }

    private func testConnection() {
        testStatus = "Testing..."
        let host: String
        switch gateway.connectionModeEnum {
        case .lan: host = gateway.lanURL
        case .tunnel: host = gateway.tunnelURL
        case .auto: host = !gateway.lanURL.isEmpty ? gateway.lanURL : gateway.tunnelURL
        }
        let normalized = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard let url = URL(string: "\(normalized)/health") else {
            testStatus = "Invalid URL"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(gateway.token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    testStatus = "Failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    testStatus = "Connected (\(http.statusCode))"
                } else if let http = response as? HTTPURLResponse {
                    testStatus = "HTTP \(http.statusCode)"
                } else {
                    testStatus = "No response"
                }
            }
        }.resume()
    }
}
