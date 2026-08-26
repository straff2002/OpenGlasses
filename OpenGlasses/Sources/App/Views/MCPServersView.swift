import SwiftUI

/// Manage MCP (Model Context Protocol) server connections.
/// Add servers by URL, edit them in place, discover their tools, enable/disable.
///
/// All mutations go through the LIVE `appState.mcpClient` — issue #246: this view used to edit a
/// private copy and write UserDefaults directly, so the running client kept using the old config
/// (deleted servers stayed callable, a rotated token wasn't sent until force-quit).
struct MCPServersView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false
    @State private var editingServer: MCPServerConfig?
    @State private var discoveredCount: Int = 0
    @State private var isDiscovering = false

    var body: some View {
        // Nested ObservableObjects don't propagate through @EnvironmentObject — observe the
        // client directly so the list re-renders on add/edit/delete.
        MCPServersList(
            mcpClient: appState.mcpClient,
            showAddSheet: $showAddSheet,
            editingServer: $editingServer,
            discoveredCount: $discoveredCount,
            isDiscovering: $isDiscovering
        )
    }
}

private struct MCPServersList: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var mcpClient: MCPClient
    @Binding var showAddSheet: Bool
    @Binding var editingServer: MCPServerConfig?
    @Binding var discoveredCount: Int
    @Binding var isDiscovering: Bool

    private var servers: [MCPServerConfig] { mcpClient.servers }

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
                            // Tap the row to EDIT (issue #246: rotating a token used to require
                            // delete + re-add).
                            Button {
                                editingServer = server
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(server.label)
                                            .foregroundStyle(Color(.label))
                                            .lineLimit(1)
                                        Circle()
                                            .fill(server.enabled ? OGTheme.ok : .gray)
                                            .frame(width: 8, height: 8)
                                            .accessibilityHidden(true)
                                    }
                                    Text(server.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Toggle("Enable \(server.label)", isOn: Binding(
                                get: { server.enabled },
                                set: { enabled in
                                    var updated = server
                                    updated.enabled = enabled
                                    mcpClient.updateServer(updated)
                                }
                            ))
                            .labelsHidden()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(server.label), \(server.enabled ? "enabled" : "disabled"). \(server.url)")
                        .accessibilityHint("Double-tap to edit")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                mcpClient.removeServer(id: server.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("MCP Servers")
            } footer: {
                Text("MCP servers expose tools the AI can call. Tap a server to edit it (URL, token, transport). Popular servers: Home Assistant, Notion, GitHub, Slack, and more.")
            }

            // MARK: Catalogue (Plan V) — one-tap install of vetted servers
            Section {
                NavigationLink {
                    MCPCatalogView { newServer in
                        mcpClient.addServer(newServer)
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
                mcpClient.addServer(newServer)
            }
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditorView(prefill: server, isEditing: true) { updated in
                mcpClient.updateServer(updated)
            }
        }
    }

    private func discover() {
        isDiscovering = true
        Task {
            await mcpClient.discoverAllTools()
            discoveredCount = mcpClient.discoveredTools.count
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

    /// Edit mode (issue #246): preserves the server's identity/enabled/policy so a token rotation
    /// or URL fix is an in-place update, not a delete-and-re-add.
    private let isEditing: Bool
    private let existing: MCPServerConfig?

    /// `prefill` seeds the form (catalogue one-tap install lands here with label/url/transport/auth
    /// already set); the user can still edit anything before saving. Defaults to a blank manual add.
    /// With `isEditing: true`, saving keeps the prefilled server's id (and enabled/policy).
    init(prefill: MCPServerConfig? = nil, isEditing: Bool = false, onSave: @escaping (MCPServerConfig) -> Void) {
        self.onSave = onSave
        self.isEditing = isEditing
        self.existing = prefill
        _label      = State(initialValue: prefill?.label ?? "")
        _url        = State(initialValue: prefill?.url ?? "")
        _transport  = State(initialValue: prefill?.transport ?? .http)
        _authKind   = State(initialValue: prefill?.authKind ?? .bearer)
        let existingHeader = prefill?.headers.first
        _authHeader = State(initialValue: existingHeader?.key ?? "Authorization")
        _authValue  = State(initialValue: existingHeader?.value ?? "")
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
                    SecretInputField(placeholder: "Header value (e.g. Bearer xxx)", text: $authValue)
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
            .navigationTitle(isEditing ? "Edit \(existing?.label ?? "Server")"
                                       : (label.isEmpty ? "Add MCP Server" : "Add \(label)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        var headers: [String: String] = [:]
                        if !authHeader.isEmpty && !authValue.isEmpty {
                            headers[authHeader] = authValue
                        }
                        let server = MCPServerConfig(
                            id: (isEditing ? existing?.id : nil) ?? UUID().uuidString,
                            label: label.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces),
                            headers: headers,
                            enabled: (isEditing ? existing?.enabled : nil) ?? true,
                            policy: (isEditing ? existing?.policy : nil) ?? .redact,   // safe default (Plan R)
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
