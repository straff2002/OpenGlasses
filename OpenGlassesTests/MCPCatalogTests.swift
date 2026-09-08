import XCTest
@testable import OpenGlasses

/// Tests for the curated MCP catalogue (Plan V): JSON decode + per-entry validation, URL-template
/// substitution, one-tap install producing a safe-default `MCPServerConfig`, and the guarantee that
/// a catalogue-installed server's tools still go through the Plan R discovery-time scanner.
@MainActor
final class MCPCatalogTests: XCTestCase {

    // A synthetic catalogue exercising both transports, both auth kinds, single + multi field, and
    // a deliberately malformed entry — independent of whatever ships in the bundle.
    private let sampleJSON = Data("""
    {
      "version": 2,
      "servers": [
        {
          "id": "ha",
          "label": "Home Assistant",
          "transport": "sse",
          "url_template": "http://{host}:8123/mcp_server/sse",
          "auth": { "kind": "bearer", "hint": "Long-Lived Access Token" },
          "fields": [{ "key": "host", "label": "HA host", "placeholder": "192.168.1.10" }],
          "scopes": ["Control devices"],
          "icon": "house.fill"
        },
        {
          "id": "custom",
          "label": "Custom",
          "transport": "http",
          "url_template": "http://{host}:{port}/mcp",
          "auth": { "kind": "bearer" },
          "fields": [
            { "key": "host", "label": "Host" },
            { "key": "port", "label": "Port" }
          ]
        },
        {
          "id": "notion",
          "label": "Notion",
          "transport": "http",
          "url_template": "https://mcp.notion.com/mcp",
          "auth": { "kind": "oauth", "hint": "Sign in with Notion" }
        },
        {
          "id": "broken",
          "label": "Broken",
          "transport": "http",
          "url_template": "",
          "auth": { "kind": "none" }
        }
      ]
    }
    """.utf8)

    private func loadSample() throws -> MCPCatalog {
        try MCPCatalog.load(from: sampleJSON)
    }

    /// Look up a sample entry by id, failing the test cleanly (not crashing the runner) if decoding
    /// ever drops it — a force-unwrap here would SIGTRAP the whole suite and mask other results.
    private func entry(_ id: String) throws -> MCPCatalogEntry {
        try XCTUnwrap(loadSample().entries.first { $0.id == id }, "sample entry '\(id)' missing")
    }

    // MARK: - Decode + validation

    func testLoadsValidEntriesAndParsesFields() throws {
        let catalog = try loadSample()
        XCTAssertEqual(catalog.version, 2)
        // "broken" (missing url_template) is dropped; the three valid entries survive.
        XCTAssertEqual(catalog.entries.map(\.id), ["ha", "custom", "notion"])

        let ha = catalog.entries[0]
        XCTAssertEqual(ha.transport, .sse)
        XCTAssertEqual(ha.auth.kind, .bearer)
        XCTAssertEqual(ha.fields.first?.key, "host")
        XCTAssertEqual(ha.icon, "house.fill")
    }

    func testTransportAndAuthKindParsedPerEntry() throws {
        let catalog = try loadSample()
        XCTAssertEqual(catalog.entries.first { $0.id == "notion" }?.transport, .http)
        XCTAssertEqual(catalog.entries.first { $0.id == "notion" }?.auth.kind, .oauth)
        XCTAssertEqual(catalog.entries.first { $0.id == "ha" }?.transport, .sse)
    }

    func testMalformedEntryRejectedOthersSurvive() throws {
        let (catalog, rejected) = try MCPCatalog.loadStrict(from: sampleJSON)
        XCTAssertEqual(catalog.entries.count, 3)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected.first?.contains("broken") ?? false)
        XCTAssertTrue(rejected.first?.contains("url_template") ?? false)
    }

    func testDuplicateIdRejected() throws {
        let json = Data("""
        { "version": 1, "servers": [
            { "id": "dup", "label": "A", "transport": "http", "url_template": "http://a", "auth": {"kind":"none"} },
            { "id": "dup", "label": "B", "transport": "http", "url_template": "http://b", "auth": {"kind":"none"} }
        ]}
        """.utf8)
        let (catalog, rejected) = try MCPCatalog.loadStrict(from: json)
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertTrue(rejected.contains { $0.contains("duplicate") })
    }

    func testEntryWithUnmatchedPlaceholderRejected() throws {
        // url_template references {host} but declares no matching field — uninstallable.
        let json = Data("""
        { "version": 1, "servers": [
            { "id": "bad", "label": "Bad", "transport": "http",
              "url_template": "http://{host}/mcp", "auth": {"kind":"none"}, "fields": [] }
        ]}
        """.utf8)
        let (catalog, rejected) = try MCPCatalog.loadStrict(from: json)
        XCTAssertTrue(catalog.entries.isEmpty)
        XCTAssertTrue(rejected.first?.contains("{host}") ?? false)
    }

    // MARK: - URL-template substitution

    func testURLTemplateSubstitutionSingleField() throws {
        let ha = try entry("ha")
        XCTAssertEqual(ha.placeholderKeys, ["host"])
        XCTAssertEqual(ha.resolvedURL(from: ["host": "192.168.1.50"]),
                       "http://192.168.1.50:8123/mcp_server/sse")
    }

    func testURLTemplateSubstitutionMultiField() throws {
        let custom = try entry("custom")
        XCTAssertEqual(Set(custom.placeholderKeys), ["host", "port"])
        XCTAssertEqual(custom.resolvedURL(from: ["host": "127.0.0.1", "port": "9000"]),
                       "http://127.0.0.1:9000/mcp")
    }

    func testURLTemplateMissingOrBlankValueReturnsNil() throws {
        let custom = try entry("custom")
        XCTAssertNil(custom.resolvedURL(from: ["host": "127.0.0.1"]))         // missing port
        XCTAssertNil(custom.resolvedURL(from: ["host": "127.0.0.1", "port": "  "]))  // blank port
    }

    func testFieldlessTemplateNeedsNoValues() throws {
        let notion = try entry("notion")
        XCTAssertTrue(notion.placeholderKeys.isEmpty)
        XCTAssertEqual(notion.resolvedURL(from: [:]), "https://mcp.notion.com/mcp")
    }

    // MARK: - One-tap install

    func testInstallDefaultsToRedactPolicy() throws {
        // THE safety requirement: a one-tap install never lands on `.allow` — it funnels through
        // the Plan R egress screen by defaulting to `.redact`.
        let ha = try entry("ha")
        let config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "10.0.0.2"], token: "tok"))
        XCTAssertEqual(config.policy, .redact)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.url, "http://10.0.0.2:8123/mcp_server/sse")
    }

    func testInstallBearerPrefillsAuthorizationHeader() throws {
        let ha = try entry("ha")
        let config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "10.0.0.2"], token: "abc123"))
        XCTAssertEqual(config.headers["Authorization"], "Bearer abc123")
        XCTAssertEqual(config.authKind, .bearer)
    }

    func testInstallDoesNotDoublePrefixBearer() throws {
        let ha = try entry("ha")
        let config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "h"], token: "Bearer xyz"))
        XCTAssertEqual(config.headers["Authorization"], "Bearer xyz")
    }

    func testInstallCarriesTransportFromEntry() throws {
        let ha = try entry("ha")
        let config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "h"], token: nil))
        XCTAssertEqual(config.transport, .sse)
    }

    func testInstallOAuthLeavesHeadersEmpty() throws {
        let notion = try entry("notion")
        let config = try XCTUnwrap(notion.makeServerConfig())
        XCTAssertTrue(config.headers.isEmpty)        // OAuth automation deferred — no token prefilled
        XCTAssertEqual(config.authKind, .oauth)
    }

    func testInstallReturnsNilWhenURLUnresolvable() throws {
        let ha = try entry("ha")
        XCTAssertNil(ha.makeServerConfig(values: [:], token: "tok"))   // {host} unfilled
    }

    // MARK: - Plan R wiring: installed servers are screened at discovery

    func testCatalogueInstalledServerToolsRunThroughScanner() throws {
        // Build a config exactly as a one-tap install would, then prove its discovered tools are
        // subject to the same tool-poisoning screen as a hand-added server: a poisoned shadow tool
        // is blocked and never offered to the model.
        let ha = try entry("ha")
        let config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "h"], token: "t"))

        let poisoned = MCPTool(name: "send_message", description: "Send a friendly message",
                               inputSchema: ["type": "object"], serverId: config.id, serverLabel: config.label)
        let trust = ToolDefinitionScanner.scan(poisoned, nativeNames: [])
        XCTAssertFalse(trust.isOffered, "a high-impact shadow from a catalogue server must be blocked")

        // And the declarations layer excludes it, mirroring the live discovery path.
        let client = MCPClient()
        client.servers = [config]
        var scanned = poisoned
        scanned.trust = trust
        client.discoveredTools = [scanned]
        let offeredNames = ToolDeclarations.mcpToolDeclarations(mcpClient: client).compactMap { $0["name"] as? String }
        XCTAssertFalse(offeredNames.contains { $0.contains("send_message") })
    }

    // MARK: - Bundled catalogue


    // MARK: - The self-hosted graph-memory entry

    private func bundledGraphMemory() throws -> MCPCatalogEntry {
        let catalog = try XCTUnwrap(MCPCatalog.bundled(Bundle(for: MCPClient.self)))
        return try XCTUnwrap(catalog.entries.first { $0.id == "graph_memory" },
                             "the bundled catalogue should offer a self-hosted graph-memory server")
    }

    /// The entry is on the shipped Streamable HTTP path with a bearer token and two fields — not
    /// the deferred SSE one, which would list a server that cannot actually connect.
    func testGraphMemoryEntryDecodesWithBothFieldsAndItsTransport() throws {
        let entry = try bundledGraphMemory()
        XCTAssertEqual(entry.transport, .http)
        XCTAssertTrue(entry.transport.isLive)
        XCTAssertEqual(entry.auth.kind, .bearer)
        XCTAssertEqual(entry.fields.map(\.key), ["host", "port"])
        XCTAssertEqual(Set(entry.placeholderKeys), ["host", "port"])
        XCTAssertNil(entry.validationError)
    }

    /// Both halves of the address are the wearer's to give, and a half-filled one must never
    /// resolve into a URL that quietly points somewhere else.
    func testGraphMemoryURLNeedsBothHostAndPort() throws {
        let entry = try bundledGraphMemory()
        XCTAssertEqual(entry.resolvedURL(from: ["host": "127.0.0.1", "port": "8080"]),
                       "http://127.0.0.1:8080/mcp")
        XCTAssertNil(entry.resolvedURL(from: ["host": "127.0.0.1"]))
        XCTAssertNil(entry.resolvedURL(from: ["host": "127.0.0.1", "port": "  "]))
        XCTAssertNil(entry.resolvedURL(from: ["host": " ", "port": "8080"]))
    }

    /// A memory server is exactly the kind of server it would be tempting to trust, so it gets
    /// the same safe default as everything else: the outbound screen, not `.allow`.
    func testGraphMemoryInstallLandsOnRedact() throws {
        let entry = try bundledGraphMemory()
        let config = try XCTUnwrap(entry.makeServerConfig(
            values: ["host": "127.0.0.1", "port": "8080"], token: "tok"))
        XCTAssertEqual(config.policy, .redact)
        XCTAssertEqual(config.transport, .http)
        XCTAssertEqual(config.headers["Authorization"], "Bearer tok")
    }

    /// The catalogue had no agent gate before this entry, so the field opts in rather than out:
    /// this row wants Agent Mode, and the five that shipped without one are untouched.
    func testRequiresAgentModeIsSetHereAndNowhereElse() throws {
        let catalog = try XCTUnwrap(MCPCatalog.bundled(Bundle(for: MCPClient.self)))
        for entry in catalog.entries {
            XCTAssertEqual(entry.requiresAgentMode, entry.id == "graph_memory",
                           "\(entry.id) has the wrong agent-mode requirement")
        }
    }

    /// An entry that never mentions the field decodes as ungated — the default is what keeps a
    /// third-party catalogue row from becoming accidentally agent-only.
    func testRequiresAgentModeDefaultsToFalseWhenAbsent() throws {
        XCTAssertFalse(try entry("ha").requiresAgentMode)
    }

    /// The two-field template has the same trap the one-field one does: a placeholder with no
    /// field behind it can never be filled, so the entry is refused rather than shipped broken.
    func testEntryWithUnmatchedPortPlaceholderRejected() throws {
        let json = Data("""
        { "version": 1, "servers": [
            { "id": "bad", "label": "Bad", "transport": "http",
              "url_template": "http://{host}:{port}/mcp", "auth": {"kind":"bearer"},
              "fields": [{ "key": "host", "label": "Host" }] }
        ]}
        """.utf8)
        let (catalog, rejected) = try MCPCatalog.loadStrict(from: json)
        XCTAssertTrue(catalog.entries.isEmpty)
        XCTAssertTrue(rejected.first?.contains("{port}") ?? false, "got: \(rejected)")
    }

    func testBundledCatalogueLoadsAndEveryEntryIsValid() throws {
        // The catalogue ships in the app bundle; locate it via an app-target class.
        let catalog = try XCTUnwrap(MCPCatalog.bundled(Bundle(for: MCPClient.self)),
                                    "mcp-catalog.json should be bundled with the app target")
        XCTAssertGreaterThanOrEqual(catalog.entries.count, 4)

        for entry in catalog.entries {
            XCTAssertNil(entry.validationError, "\(entry.id) failed validation: \(entry.validationError ?? "")")
            XCTAssertFalse(entry.label.isEmpty)
            // Every placeholder is fillable, and a fully-filled install resolves to a URL.
            let values = Dictionary(uniqueKeysWithValues: entry.fields.map { ($0.key, "x") })
            XCTAssertNotNil(entry.resolvedURL(from: values), "\(entry.id) URL did not resolve")
            // And a one-tap install always produces the safe default policy.
            XCTAssertEqual(entry.makeServerConfig(values: values, token: "t")?.policy, .redact)
        }
    }

    // MARK: - Custom auth-header kind (BM P6)

    private let headerEntryJSON = Data("""
    { "version": 1, "servers": [
        { "id": "keyed", "label": "Keyed", "transport": "http",
          "url_template": "https://api.example.com/mcp",
          "auth": { "kind": "header", "header": "X-API-Key", "hint": "Your API key" } }
    ]}
    """.utf8)

    func testHeaderAuthKindInstallRoundTripsCustomHeader() throws {
        let catalog = try MCPCatalog.load(from: headerEntryJSON)
        let keyed = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(keyed.auth.kind, .header)
        XCTAssertEqual(keyed.auth.header, "X-API-Key")

        let config = try XCTUnwrap(keyed.makeServerConfig(token: "  sk-abc123  "))
        XCTAssertEqual(config.headers, ["X-API-Key": "sk-abc123"])   // verbatim — no Bearer prefix
        XCTAssertEqual(config.authKind, .header)
        XCTAssertEqual(config.policy, .redact)                       // safe default preserved

        // And the installed config survives the persistence round-trip intact.
        let back = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.headers["X-API-Key"], "sk-abc123")
        XCTAssertEqual(back.authKind, .header)
    }

    func testHeaderAuthKindEmptyTokenLeavesHeadersEmpty() throws {
        let keyed = try XCTUnwrap(try MCPCatalog.load(from: headerEntryJSON).entries.first)
        XCTAssertTrue(try XCTUnwrap(keyed.makeServerConfig(token: "   ")).headers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(keyed.makeServerConfig(token: nil)).headers.isEmpty)
    }

    func testHeaderAuthKindWithoutHeaderNameIsRejected() throws {
        let json = Data("""
        { "version": 1, "servers": [
            { "id": "nameless", "label": "Nameless", "transport": "http",
              "url_template": "https://api.example.com/mcp", "auth": { "kind": "header" } }
        ]}
        """.utf8)
        let (catalog, rejected) = try MCPCatalog.loadStrict(from: json)
        XCTAssertTrue(catalog.entries.isEmpty)
        XCTAssertTrue(rejected.first?.contains("header name") ?? false, "got: \(rejected)")
    }

    // MARK: - Launch-time re-discovery (BM P6)

    private static let toolsListJSON = Data("""
    { "jsonrpc": "2.0", "id": 1, "result": { "tools": [
        { "name": "get_status", "description": "Read the device status.",
          "inputSchema": { "type": "object" } },
        { "name": "send_message", "description": "Send a friendly message.",
          "inputSchema": { "type": "object" } }
    ]}}
    """.utf8)

    func testRelaunchRediscoveryRepopulatesToolsAndRescans() async throws {
        // Fresh client models a relaunch: nothing discovered in memory, servers persisted.
        let ha = try entry("ha")
        let config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "h"], token: "t"))
        let client = MCPClient()
        client.transportOverride = StubMCPTransport(body: Self.toolsListJSON)
        client.servers = [config]
        client.discoveredTools = []

        await client.rediscoverAtLaunch()

        XCTAssertEqual(client.discoveredTools.count, 2, "relaunch must repopulate discovered tools")
        // The Plan R scanner re-ran: the high-impact shadow is blocked, the benign tool offered.
        XCTAssertEqual(client.discoveredTools.filter { $0.trust.isOffered }.map(\.name), ["get_status"])
        let poisoned = try XCTUnwrap(client.discoveredTools.first { $0.name == "send_message" })
        XCTAssertFalse(poisoned.trust.isOffered)
    }

    func testRediscoveryAtLaunchSkipsDisabledServers() async throws {
        let ha = try entry("ha")
        var config = try XCTUnwrap(ha.makeServerConfig(values: ["host": "h"], token: "t"))
        config.enabled = false
        let client = MCPClient()
        client.transportOverride = StubMCPTransport(body: Self.toolsListJSON)
        client.servers = [config]
        client.discoveredTools = []

        await client.rediscoverAtLaunch()
        XCTAssertTrue(client.discoveredTools.isEmpty)
    }
}

/// Canned-response transport for discovery tests — no network.
private struct StubMCPTransport: MCPTransport {
    let body: Data
    func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data { body }
}
