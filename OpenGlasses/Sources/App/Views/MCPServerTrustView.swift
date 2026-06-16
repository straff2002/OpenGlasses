import SwiftUI

/// Safety panel for MCP servers (Plan R): per-server outbound egress policy, discovered-tool
/// trust badges (from the discovery-time `ToolDefinitionScanner`), and a log of recent egress
/// decisions. The deterministic screens do the enforcing; this surfaces what they decided so
/// the user can tighten a server to `Block` or see why a tool was quarantined.
struct MCPServerTrustView: View {
    @ObservedObject var mcpClient: MCPClient
    @State private var servers: [MCPServerConfig] = Config.mcpServers

    var body: some View {
        List {
            // MARK: Per-server outbound policy
            Section {
                if servers.isEmpty {
                    Text("No MCP servers configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(server.label)
                                .font(.subheadline.weight(.medium))
                            Picker("Outbound policy for \(server.label)", selection: policyBinding(for: server)) {
                                ForEach(EgressPolicy.allCases) { policy in
                                    Text(policy.label).tag(policy)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(currentPolicy(for: server).detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Outbound Data Policy")
            } footer: {
                Text("Screens tool arguments for secrets and personal data before they leave the device. Default: Redact.")
            }

            // MARK: Discovered tools + trust badges
            Section {
                if mcpClient.discoveredTools.isEmpty {
                    Text("No tools discovered yet. Run “Discover Tools” on the MCP Servers screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mcpClient.discoveredTools) { tool in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.qualifiedName)
                                    .font(.subheadline.monospaced())
                                    .lineLimit(1)
                                if !tool.trust.reason.isEmpty {
                                    Text(tool.trust.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            trustBadge(tool.trust)
                        }
                    }
                }
            } header: {
                Text("Discovered Tools")
            } footer: {
                Text("Definitions are scanned at discovery. Blocked tools are never offered to the AI; quarantined tools are only offered under their full server-prefixed name.")
            }

            // MARK: Recent egress decisions
            if !mcpClient.recentEgressDecisions.isEmpty {
                Section("Recent Egress Decisions") {
                    ForEach(mcpClient.recentEgressDecisions) { decision in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(decision.serverLabel) · \(decision.toolName)")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if !decision.hits.isEmpty {
                                    Text(decision.hits.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            egressBadge(decision.action)
                        }
                    }
                }
            }
        }
        .navigationTitle("Safety & Trust")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { servers = Config.mcpServers }
    }

    // MARK: - Bindings

    private func currentPolicy(for server: MCPServerConfig) -> EgressPolicy {
        servers.first { $0.id == server.id }?.policy ?? .redact
    }

    private func policyBinding(for server: MCPServerConfig) -> Binding<EgressPolicy> {
        Binding(
            get: { currentPolicy(for: server) },
            set: { newValue in
                guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
                servers[idx].policy = newValue
                Config.setMCPServers(servers)
                mcpClient.servers = servers          // keep the live client in sync for the next call
            }
        )
    }

    // MARK: - Badges

    @ViewBuilder
    private func trustBadge(_ trust: ToolTrust) -> some View {
        switch trust {
        case .trusted:
            badge("Trusted", systemImage: "checkmark.shield", color: .green)
        case .quarantined:
            badge("Quarantined", systemImage: "exclamationmark.shield", color: .orange)
        case .blocked:
            badge("Blocked", systemImage: "xmark.shield", color: .red)
        }
    }

    @ViewBuilder
    private func egressBadge(_ action: EgressDecision.Action) -> some View {
        switch action {
        case .allowed:  badge("Allowed", systemImage: "paperplane", color: .gray)
        case .redacted: badge("Redacted", systemImage: "eye.slash", color: .orange)
        case .blocked:  badge("Blocked", systemImage: "hand.raised", color: .red)
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}
