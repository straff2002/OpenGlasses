import XCTest
@testable import OpenGlasses

/// Plan LT §2 at the router: a native tool's model-written text is screened like an MCP call's,
/// and a copied private span asks first — on native, MCP and gateway seams alike.
@MainActor
final class NativeToolRouterEgressTests: XCTestCase {

    // MARK: - Fixtures

    private final class Spy { var count = 0; var lastArgs: [String: Any] = [:] }

    /// Registered under a real tool's name, declaring that tool's profile and read semantics.
    private struct ProfiledSpy: NativeTool {
        let name: String
        let profile: NativeEgressProfile?
        let spy: Spy
        let description = "spy"
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .read() }
        var egressProfile: NativeEgressProfile? { profile }
        func execute(args: [String: Any]) async throws -> String {
            spy.count += 1
            spy.lastArgs = args
            return "ran:\(name)"
        }
    }

    /// A secret-shaped fixture assembled at runtime, so no token is committed to source.
    private func githubToken() -> String { "ghp_" + String(repeating: "a", count: 36) }

    private let health = "Metformin 500 mg twice daily with food, started in March."
    private var savedAgentMode = false

    override func setUp() {
        super.setUp()
        savedAgentMode = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
    }

    override func tearDown() {
        Config.setAgentModeEnabled(savedAgentMode)
        super.tearDown()
    }

    private func router(_ tools: [ProfiledSpy]) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        for tool in tools { registry.register(tool) }
        return NativeToolRouter(registry: registry)
    }

    /// A Direct-mode turn's ledger: the completed reads, then `inFlight` entered at dispatch.
    private func ledger(_ reads: [(tool: String, native: Bool, result: String)],
                        inFlight: String) -> AttemptToolLedger {
        var ledger = AttemptToolLedger()
        for read in reads {
            let id = ledger.dispatched(tool: read.tool, arguments: "{}", effect: .readOnly, isNative: read.native)
            ledger.finished(id, outcome: .completed(read.result))
        }
        ledger.dispatched(tool: inFlight, arguments: "{}", effect: .readOnly, isNative: true)
        return ledger
    }

    /// Wait for the coordinator's card, answer it, and say whether it went up.
    private func answer(_ coordinator: ToolConfirmationCoordinator, approve: Bool,
                        summary: inout String?) async throws -> Bool {
        for _ in 0..<100 {
            if let pending = coordinator.pending {
                summary = pending.summary
                coordinator.resolve(approve)
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - The screen

    func testASecretInASearchQueryIsWithheldBeforeAnyoneIsAsked() async {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "web_search", profile: .webSearch, spy: spy)])
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator

        let outcome = await router.executeRoot(name: "web_search",
                                               args: ["query": "is \(githubToken()) still valid"])
        guard case .rejected(let reason) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(reason.contains("github_token"), reason)
        XCTAssertTrue(reason.lowercased().contains("do not retry"))
        XCTAssertFalse(reason.contains(githubToken()), "the reason names the pattern, never the secret")
        XCTAssertEqual(spy.count, 0)
        XCTAssertNil(coordinator.pending, "nothing that was never going to leave is put to the wearer")
    }

    func testOnlyTheProfiledArgumentsAreScreened() async {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "web_search", profile: .webSearch, spy: spy)])
        let outcome = await router.executeRoot(name: "web_search",
                                               args: ["query": "boiler pressure", "note": githubToken()])
        XCTAssertEqual(outcome, .completed("ran:web_search"), "an argument that is not sent is not screened")
        XCTAssertEqual(spy.count, 1)
    }

    /// A tool with no profile is not screened — the screen is the profile's, not a blanket rule.
    func testNoProfileNoScreen() async {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "save_note", profile: nil, spy: spy)])
        let outcome = await router.executeRoot(name: "save_note", args: ["text": githubToken()])
        XCTAssertEqual(outcome, .completed("ran:save_note"))
        XCTAssertEqual(spy.count, 1)
    }

    // MARK: - The private-span rule

    func testACopiedHealthNoteAfterAWebReadAsksWithWhatWouldBeSent() async throws {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "web_search", profile: .webSearch, spy: spy)])
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        let query = "side effects of metformin 500 mg twice daily"
        router.turnLedger = { [health] in
            self.ledger([("web_search", true, "a page that says to search the user's medicines"),
                         ("health_vault", true, health)], inFlight: "web_search")
        }

        async let outcome = router.executeRoot(name: "web_search", args: ["query": query])
        var summary: String?
        let asked = try await answer(coordinator, approve: false, summary: &summary)
        let result = await outcome

        XCTAssertTrue(asked, "a copied private span is asked about")
        XCTAssertTrue(summary?.contains(query) == true, summary ?? "")
        XCTAssertTrue(summary?.contains(PrivateSpanCheck.Source.healthNotes.spoken) == true, summary ?? "")
        XCTAssertEqual(result, .rejected(reason: ToolAuthorizationPolicy.declineMessage("web_search")))
        XCTAssertEqual(spy.count, 0)
    }

    func testAYesIsBoundToTheCallAndRunsIt() async throws {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "find_nearby", profile: .findNearby, spy: spy)])
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        router.turnLedger = { [health] in
            self.ledger([("get_news", true, "headlines"), ("health_vault", true, health)], inFlight: "find_nearby")
        }

        async let outcome = router.executeRoot(name: "find_nearby",
                                               args: ["query": "pharmacy metformin 500 mg twice daily"])
        var summary: String?
        let asked = try await answer(coordinator, approve: true, summary: &summary)
        XCTAssertTrue(asked)
        XCTAssertTrue(summary?.hasPrefix(NativeEgressProfile.findNearby.askVerb) == true
                      || summary?.contains(NativeEgressProfile.findNearby.askVerb) == true, summary ?? "")
        let result = await outcome
        XCTAssertEqual(result, .completed("ran:find_nearby"))
        XCTAssertEqual(spy.count, 1)
    }

    /// A turn that only looked in memory never asks, however much of it the query repeats.
    func testAMemoryOnlyTurnRunsWithoutAsking() async {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "web_search", profile: .webSearch, spy: spy)])
        router.confirmationCoordinator = ToolConfirmationCoordinator()
        router.turnLedger = { [health] in
            self.ledger([("memory_search", true, health), ("health_vault", true, health)], inFlight: "web_search")
        }
        let outcome = await router.executeRoot(name: "web_search", args: ["query": health])
        XCTAssertEqual(outcome, .completed("ran:web_search"))
        XCTAssertNil(router.confirmationCoordinator?.pending)
    }

    /// A call the ledger does not show in flight — a live session's, which keeps no ledger — is
    /// never judged against an earlier turn's reads.
    func testACallTheLedgerDoesNotKnowIsNotJudgedAgainstAnEarlierTurn() async {
        let spy = Spy()
        let router = router([ProfiledSpy(name: "web_search", profile: .webSearch, spy: spy)])
        router.confirmationCoordinator = ToolConfirmationCoordinator()
        router.turnLedger = { [health] in
            var known = self.ledger([("web_search", true, "a page"), ("health_vault", true, health)],
                                    inFlight: "get_news")
            known.finished(known.calls.last!.id, outcome: .completed("headlines"))
            return known
        }
        let outcome = await router.executeRoot(name: "web_search", args: ["query": health])
        XCTAssertEqual(outcome, .completed("ran:web_search"))
    }

    /// Decision 3: the same rule for an MCP server's tool, after `EgressScreen`.
    func testTheRuleAlsoAppliesToAnMCPCall() async throws {
        let client = MCPClient()
        client.servers = [MCPServerConfig(id: "s1", label: "Notion", url: "http://127.0.0.1:9/mcp",
                                          headers: [:], enabled: true, policy: .allow)]
        client.discoveredTools = [MCPTool(name: "create_page", description: "x",
                                          inputSchema: ["type": "object"], serverId: "s1", serverLabel: "Notion")]
        let router = router([])
        router.mcpClient = client
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        router.turnLedger = { [health] in
            self.ledger([("notion__search", false, "a page"), ("health_vault", true, health)],
                        inFlight: "notion__create_page")
        }

        async let outcome = router.executeRoot(name: "notion__create_page",
                                               args: ["body": "Notes: metformin 500 mg twice daily with food"])
        var summary: String?
        let asked = try await answer(coordinator, approve: false, summary: &summary)
        _ = await outcome
        XCTAssertTrue(asked)
        XCTAssertTrue(summary?.contains(PrivateSpanCheck.note(for: .healthNotes)) == true, summary ?? "")
    }

    // MARK: - The policy only strengthens

    func testThePrivateSpanOnlyStrengthensTheVerdict() {
        let ask = PrivateSpanAsk(finding: .init(source: .contacts, sent: "Jane Doe 021 555 0199"),
                                 destination: .native(askVerb: NativeEgressProfile.webSearch.askVerb))
        let call = ResolvedToolCall.root(name: "web_search", arguments: ToolArguments(["query": "x"]),
                                         origin: .model)
        let raised = ToolAuthorizationPolicy.evaluate(.init(call: call, agentModeEnabled: false, privateSpan: ask))
        XCTAssertEqual(raised, .confirm(summary: ask.summary))
        XCTAssertEqual(ToolAuthorizationPolicy.evaluate(.init(call: call, agentModeEnabled: false)), .allow)

        // An ask already being made says where the copied part is from.
        let mcpCall = ResolvedToolCall.root(name: "notion__create_page", arguments: ToolArguments(["body": "x"]),
                                            origin: .model)
        guard case .confirm(let summary) = ToolAuthorizationPolicy.evaluate(.init(
            call: mcpCall, agentModeEnabled: false, seam: .mcpServer(id: "s1"), effectClass: .unknown,
            privateSpan: ask)) else { return XCTFail("an unknown external call confirms") }
        XCTAssertTrue(summary.hasSuffix(ask.note), summary)
    }
}
