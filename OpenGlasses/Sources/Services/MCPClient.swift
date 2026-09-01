import Foundation

/// Lightweight MCP (Model Context Protocol) client for connecting to external tool servers.
/// Discovers tools via tools/list, executes them via tools/call.
/// Supports Streamable HTTP transport (JSON-RPC over HTTP POST).
@MainActor
final class MCPClient: ObservableObject {
    @Published var servers: [MCPServerConfig] = Config.mcpServers
    @Published var discoveredTools: [MCPTool] = []
    @Published var isDiscovering = false

    /// Recent outbound egress-screen decisions (most recent first), for the trust UI. Capped.
    @Published private(set) var recentEgressDecisions: [EgressDecision] = []

    /// Live source of native tool names, so the discovery-time `ToolDefinitionScanner` can flag
    /// MCP tools that collide with local ones. Injected by AppState; empty until then (the
    /// high-impact shadow check uses `PromptInjectionPolicy.highImpactTools` directly, so the
    /// critical safety check works even without this).
    var nativeToolNames: () -> Set<String> = { [] }

    /// Test seam: when set, every JSON-RPC round-trip goes through this transport instead of the
    /// factory-selected one, so discovery is testable without the network.
    var transportOverride: MCPTransport?

    // MARK: - Tool Discovery

    /// Re-discover tools for installed servers at launch (BM P6). Discovered tools live only in
    /// memory, so without this they vanish on relaunch until the user re-taps "Discover Tools" —
    /// quietly breaking the catalogue's promise and leaving the Plan R definition screen
    /// point-in-time. Discovery re-runs `ToolDefinitionScanner` per tool, so a definition that
    /// changed since the last launch is re-screened too. No-op with no enabled servers.
    func rediscoverAtLaunch() async {
        guard servers.contains(where: \.enabled) else { return }
        await discoverAllTools()
    }

    /// Discover all tools from all configured MCP servers.
    func discoverAllTools() async {
        isDiscovering = true
        defer { isDiscovering = false }

        var tools: [MCPTool] = []
        for server in servers where server.enabled {
            let serverTools = await discoverTools(from: server)
            tools.append(contentsOf: serverTools)
        }
        discoveredTools = tools
        PrivacyLog.mcpDiscovery(tools: tools.count, servers: servers.filter(\.enabled).count)
    }

    /// Discover tools from a single MCP server.
    func discoverTools(from server: MCPServerConfig) async -> [MCPTool] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:] as [String: Any],
        ]

        guard let data = try? await mcpRequest(server: server, payload: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]] else {
            PrivacyLog.mcpFailed(.discovery, server: PrivateIdentifier(server.id))
            return []
        }

        let nativeNames = nativeToolNames()
        return toolsArray.compactMap { toolDict -> MCPTool? in
            guard let name = toolDict["name"] as? String else { return nil }
            let description = toolDict["description"] as? String ?? ""
            let inputSchema = toolDict["inputSchema"] as? [String: Any] ?? [:]
            var tool = MCPTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                serverId: server.id,
                serverLabel: server.label
            )
            // Discovery-time tool-poisoning scan (Plan R): attacker-authored definitions are
            // screened before they can ever be offered to the model.
            tool.trust = ToolDefinitionScanner.scan(tool, nativeNames: nativeNames)
            // The scanner's reason quotes the attacker-authored definition it objected to, so the
            // verdict is logged and the reason stays in the trust UI.
            if case .blocked = tool.trust {
                PrivacyLog.mcpToolScreened(.blocked, tool: name, server: PrivateIdentifier(server.id))
            } else if case .quarantined = tool.trust {
                PrivacyLog.mcpToolScreened(.quarantined, tool: name, server: PrivateIdentifier(server.id))
            }
            return tool
        }
    }

    // MARK: - Tool Execution

    /// Resolve an *offered* (non-blocked) discovered tool by the name the model/router uses —
    /// its fully-qualified name (`serverlabel__tool`), with a bare-name fallback for safety.
    func offeredTool(matching name: String) -> MCPTool? {
        discoveredTools.first { ($0.qualifiedName == name || $0.name == name) && $0.trust.isOffered }
    }

    /// The server config owning `tool`.
    func server(id: String) -> MCPServerConfig? {
        servers.first { $0.id == id }
    }

    /// Record an outbound egress-screen decision for the trust UI / audit. Caps the log.
    func recordEgress(serverLabel: String, toolName: String, verdict: EgressVerdict) {
        let action: EgressDecision.Action
        let logged: PrivacyLog.MCPEgressAction
        switch verdict {
        case .block:  action = .blocked;  logged = .blocked
        case .redact: action = .redacted; logged = .redacted
        case .allow:  action = .allowed;  logged = .allowed
        }
        recentEgressDecisions.insert(
            EgressDecision(serverLabel: serverLabel, toolName: toolName, action: action, hits: verdict.hits),
            at: 0)
        if recentEgressDecisions.count > 20 {
            recentEgressDecisions.removeLast(recentEgressDecisions.count - 20)
        }
        // The pattern names that fired describe the content that was about to leave the device,
        // so the count goes to the log; the names themselves stay in the on-device trust UI.
        PrivacyLog.mcpEgress(logged, tool: toolName, server: PrivateIdentifier(serverLabel),
                             hits: verdict.hits.count)
    }

    /// Perform the actual `tools/call` network request. Egress screening is applied by the
    /// caller (`NativeToolRouter`) before this runs; `arguments` here are already screened.
    /// The JSON-RPC `name` is the server's *bare* tool name, never the qualified one.
    ///
    /// `idempotencyKey` identifies the operation across redeliveries. `tools/call` has no key field
    /// of its own, so it rides in the request's `_meta` — the one place the protocol reserves for
    /// exactly this, and which a server that doesn't understand it ignores. It is a digest, so it
    /// carries no argument content off the device.
    func performCall(tool: MCPTool, server: MCPServerConfig, arguments: [String: Any],
                     idempotencyKey: String? = nil) async -> String {
        let payload = Self.callPayload(toolName: tool.name, arguments: arguments,
                                       idempotencyKey: idempotencyKey)

        guard let data = try? await mcpRequest(server: server, payload: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return "MCP server '\(server.label)' returned an error for tool '\(tool.name)'."
        }

        // MCP tools return content array with text/image parts
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            return texts.joined(separator: "\n")
        }

        // Fallback: serialize the result
        if let resultData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
            return String(data: resultData, encoding: .utf8) ?? "Got result from MCP tool."
        }
        return "Tool executed successfully."
    }

    /// The `tools/call` request body. Pure and static so the wire shape — including whether an
    /// idempotency key actually reaches the server — is assertable without a network.
    nonisolated static func callPayload(toolName: String, arguments: [String: Any],
                                        idempotencyKey: String?) -> [String: Any] {
        var params: [String: Any] = ["name": toolName, "arguments": arguments]
        if let idempotencyKey {
            params["_meta"] = [Self.idempotencyMetaKey: idempotencyKey]
        }
        return [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": params,
        ]
    }

    /// Namespaced so it can never collide with a protocol-reserved `_meta` key.
    nonisolated static let idempotencyMetaKey = "nz.co.skunkworks.openglasses/idempotency-key"

    // MARK: - Server Management

    func addServer(_ server: MCPServerConfig) {
        servers.append(server)
        Config.setMCPServers(servers)
    }

    func removeServer(id: String) {
        servers.removeAll { $0.id == id }
        discoveredTools.removeAll { $0.serverId == id }
        Config.setMCPServers(servers)
        HTTPTransport.resetSessions()
    }

    func updateServer(_ server: MCPServerConfig) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let old = servers[idx]
        servers[idx] = server
        Config.setMCPServers(servers)

        // Issue #246: config changes must invalidate what was discovered under the OLD config —
        // a rotated token or changed URL otherwise keeps serving stale tool definitions (and a
        // disabled server's tools stayed callable). Re-discover live when the server remains
        // enabled and something material changed, so the catalogue heals without a manual tap.
        let materialChange = old.url != server.url || old.headers != server.headers
            || old.transport != server.transport || old.enabled != server.enabled
        guard materialChange else { return }
        discoveredTools.removeAll { $0.serverId == server.id }
        // The MCP session was minted under the old config — a rotated token or new URL must
        // re-handshake, not reuse the stale mcp-session-id.
        HTTPTransport.resetSessions()
        if server.enabled {
            Task { [weak self] in
                guard let self else { return }
                let tools = await self.discoverTools(from: server)
                self.discoveredTools.append(contentsOf: tools)
            }
        }
    }

    // MARK: - Transport

    /// Single JSON-RPC round-trip seam. Selects the transport for `server.transport` and delegates;
    /// `discoverTools`/`performCall` are transport-agnostic, so the Plan R egress screen and inbound
    /// framing stay in exactly one place. HTTP behaviour is unchanged from before the extraction;
    /// SSE selection is wired but its live streaming is deferred (Plan V) — it throws cleanly.
    private func mcpRequest(server: MCPServerConfig, payload: [String: Any]) async throws -> Data {
        let transport = transportOverride ?? MCPTransportFactory.transport(for: server.transport)
        do {
            return try await transport.request(payload, server: server)
        } catch {
            PrivacyLog.mcpFailed(.transport, server: PrivateIdentifier(server.id),
                                 SafeErrorSummary(error))
            throw error
        }
    }
}

// MARK: - Models

struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id: String
    var label: String            // "Home Assistant", "Notion", "GitHub"
    var url: String              // "http://192.168.1.100:8000/mcp"
    var headers: [String: String] // {"Authorization": "Bearer xxx"}
    var enabled: Bool
    /// Outbound egress policy for this server's tool calls (Plan R). Default `.redact`.
    var policy: EgressPolicy = .redact
    /// Wire transport this server speaks (Plan V). Default `.http` — the only live path today, and
    /// the behaviour every pre-Plan-V server had implicitly.
    var transport: MCPTransportKind = .http
    /// How this server authenticates (Plan V). Metadata for the catalogue/editor + future OAuth;
    /// the actual credential still travels in `headers`. Default `.bearer`.
    var authKind: MCPAuthKind = .bearer

    static func == (lhs: MCPServerConfig, rhs: MCPServerConfig) -> Bool {
        lhs.id == rhs.id
    }
}

extension MCPServerConfig {
    private enum CodingKeys: String, CodingKey {
        case id, label, url, headers, enabled, policy, transport, authKind
    }

    /// Backward-compatible decoder: servers persisted before Plan R/V have no `policy`, `transport`,
    /// or `authKind` key and must keep decoding (a throw here would wipe the user's saved MCP
    /// servers). Defaults mirror the implicit behaviour those older configs already had.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(String.self, forKey: .id)
        label     = try c.decode(String.self, forKey: .label)
        url       = try c.decode(String.self, forKey: .url)
        headers   = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled   = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        policy    = try c.decodeIfPresent(EgressPolicy.self, forKey: .policy) ?? .redact
        transport = try c.decodeIfPresent(MCPTransportKind.self, forKey: .transport) ?? .http
        authKind  = try c.decodeIfPresent(MCPAuthKind.self, forKey: .authKind) ?? .bearer
    }
}

struct MCPTool: Identifiable {
    let id = UUID()
    let name: String             // "create_note"
    let description: String      // "Create a note in Notion"
    let inputSchema: [String: Any]
    let serverId: String         // Which server owns this
    let serverLabel: String      // "Notion"
    /// Discovery-time trust verdict (Plan R). Default `.trusted` for directly-constructed tools;
    /// `discoverTools` sets the real verdict via `ToolDefinitionScanner`.
    var trust: ToolTrust = .trusted

    /// Fully-qualified, namespace-isolated name — the ONLY name the model and router see, so a
    /// server can't shadow a native tool. Sanitised to a valid tool-name token. ("notion__create_note")
    var qualifiedName: String { "\(Self.sanitizeToken(serverLabel.lowercased()))__\(Self.sanitizeToken(name))" }

    /// Reduce an arbitrary label/name to `[A-Za-z0-9_-]` so the qualified name is a valid tool
    /// identifier for every provider (Anthropic/OpenAI require `^[A-Za-z0-9_-]+$`).
    static func sanitizeToken(_ s: String) -> String {
        let mapped = s.map { ch -> Character in
            if ch == "_" || ch == "-" { return ch }
            if ch.isASCII, ch.isLetter || ch.isNumber { return ch }
            return "_"
        }
        let token = String(mapped)
        return token.isEmpty ? "x" : token
    }
}

/// One outbound egress-screen decision, surfaced in the trust UI.
struct EgressDecision: Identifiable {
    enum Action: String { case blocked, redacted, allowed }
    let id = UUID()
    let date = Date()
    let serverLabel: String
    let toolName: String         // bare tool name
    let action: Action
    let hits: [String]           // pattern names that fired
}
