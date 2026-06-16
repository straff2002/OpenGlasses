import SwiftUI

/// Manage MCP (Model Context Protocol) server connections.
/// Add servers by URL, discover their tools, enable/disable.
struct MCPServersView: View {
    @EnvironmentObject var appState: AppState
    @State private var servers: [MCPServerConfig] = Config.mcpServers
    @State private var showAddSheet = false
    @State private var discoveredCount: Int = 0
    @State private var isDiscovering = false

    var body: some View {
        List {
            // MARK: Servers
            Section {
                if servers.isEmpty {
                    Text("No MCP servers configured. Add one to connect external tools.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(server.label)
                                        .foregroundStyle(Color(.label))
                                        .lineLimit(1)
                                    Circle()
                                        .fill(server.enabled ? .green : .gray)
                                        .frame(width: 8, height: 8)
                                        .accessibilityHidden(true)
                                }
                                Text(server.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("Enable \(server.label)", isOn: Binding(
                                get: { server.enabled },
                                set: { enabled in
                                    if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                                        servers[idx].enabled = enabled
                                        Config.setMCPServers(servers)
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(server.label), \(server.enabled ? "enabled" : "disabled"). \(server.url)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                servers.removeAll { $0.id == server.id }
                                Config.setMCPServers(servers)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("MCP Servers")
            } footer: {
                Text("MCP servers expose tools the AI can call. Popular servers: Home Assistant, Notion, GitHub, Slack, and more.")
            }

            // MARK: Catalogue (Plan V) — one-tap install of vetted servers
            Section {
                NavigationLink {
                    MCPCatalogView { newServer in
                        servers.append(newServer)
                        Config.setMCPServers(servers)
                    }
                } label: {
                    Label("Browse catalogue", systemImage: "square.grid.2x2")
                }
            } footer: {
                Text("Install a vetted server in one tap — it lands on the safe \"Redact\" data policy and is screened before any tool runs. Or use ＋ above to add one by URL.")
            }

            // MARK: Discover
            if !servers.filter(\.enabled).isEmpty {
                Section {
                    Button {
                        discover()
                    } label: {
                        HStack {
                            if isDiscovering {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Discovering…")
                            } else {
                                Image(systemName: "magnifyingglass")
                                Text("Discover Tools")
                                if discoveredCount > 0 {
                                    Spacer()
                                    Text("\(discoveredCount) tools found")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(isDiscovering)
                } footer: {
                    Text("Queries all enabled servers for available tools. Discovered tools are automatically available to the AI.")
                }
            }

            // MARK: Safety & Trust (Plan R)
            if !servers.isEmpty {
                Section {
                    NavigationLink {
                        MCPServerTrustView(mcpClient: appState.mcpClient)
                    } label: {
                        Label("Safety & Trust", systemImage: "shield.lefthalf.filled")
                    }
                } footer: {
                    Text("Per-server outbound data policy, tool trust badges, and recent egress decisions.")
                }
            }

            // MARK: Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("What is MCP?", systemImage: "info.circle")
                        .font(.footnote.weight(.medium))
                    Text("Model Context Protocol is an open standard for AI tool servers. Any MCP-compatible server can be connected — the app discovers its tools automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Example: connect your Home Assistant MCP server and the AI can control any HA device via voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("MCP Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            MCPServerEditorView { newServer in
                servers.append(newServer)
                Config.setMCPServers(servers)
            }
        }
    }

    private func discover() {
        isDiscovering = true
        Task {
            await appState.mcpClient.discoverAllTools()
            discoveredCount = appState.mcpClient.discoveredTools.count
            isDiscovering = false
        }
    }
}

// MARK: - Editor

struct MCPServerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (MCPServerConfig) -> Void

    @State private var label: String
    @State private var url: String
    @State private var authHeader: String
    @State private var authValue: String
    @State private var transport: MCPTransportKind
    @State private var authKind: MCPAuthKind

    /// `prefill` seeds the form (catalogue one-tap install lands here with label/url/transport/auth
    /// already set); the user can still edit anything before saving. Defaults to a blank manual add.
    init(prefill: MCPServerConfig? = nil, onSave: @escaping (MCPServerConfig) -> Void) {
        self.onSave = onSave
        _label      = State(initialValue: prefill?.label ?? "")
        _url        = State(initialValue: prefill?.url ?? "")
        _transport  = State(initialValue: prefill?.transport ?? .http)
        _authKind   = State(initialValue: prefill?.authKind ?? .bearer)
        let existing = prefill?.headers.first
        _authHeader = State(initialValue: existing?.key ?? "Authorization")
        _authValue  = State(initialValue: existing?.value ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (e.g. Home Assistant)", text: $label)
                    TextField("Server URL", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Picker("Transport", selection: $transport) {
                        ForEach(MCPTransportKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    if !transport.isLive {
                        Text("The MCP endpoint URL. \(transport.label) connections aren't wired for live calls yet — the server will be saved but won't connect until SSE support ships.")
                    } else {
                        Text("The MCP endpoint URL, e.g. http://192.168.1.100:8000/mcp")
                    }
                }

                Section {
                    TextField("Header name (e.g. Authorization)", text: $authHeader)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Header value (e.g. Bearer xxx)", text: $authValue)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Authentication (Optional)")
                } footer: {
                    if authKind == .oauth {
                        Text("This server uses OAuth. Automated sign-in is coming; for now paste an access token here as a Bearer value.")
                    } else {
                        Text("Most MCP servers require a Bearer token or API key in the Authorization header.")
                    }
                }
            }
            .navigationTitle(label.isEmpty ? "Add MCP Server" : "Add \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        var headers: [String: String] = [:]
                        if !authHeader.isEmpty && !authValue.isEmpty {
                            headers[authHeader] = authValue
                        }
                        let server = MCPServerConfig(
                            id: UUID().uuidString,
                            label: label.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces),
                            headers: headers,
                            enabled: true,
                            policy: .redact,          // safe default (Plan R) — same as a catalogue install
                            transport: transport,
                            authKind: authKind
                        )
                        onSave(server)
                        dismiss()
                    }
                    .disabled(label.isEmpty || url.isEmpty)
                }
            }
        }
    }
}
