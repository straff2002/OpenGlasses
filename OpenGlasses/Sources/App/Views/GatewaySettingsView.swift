import SwiftUI

/// Manage multiple gateway endpoints (OpenClaw, NanoClaw, NemoClaw, custom).
/// Each gateway has its own host, token, connection mode, and priority.
struct GatewaySettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @State private var gateways: [GatewayConfig] = Config.savedGateways
    @State private var editingGateway: GatewayConfig?
    @State private var showAddSheet = false

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
                    SecureField("Token", text: $gateway.token)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("The gateway token from your server's config.")
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
