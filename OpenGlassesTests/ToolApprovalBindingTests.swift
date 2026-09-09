import XCTest
@testable import OpenGlasses

/// W04.4 — an approval is worth exactly one call, and only the call it was given for.
///
/// The hole this closes: an approval that named a tool and nothing else could be spent by whatever
/// arrived next. A changed recipient, a changed body, a different server advertising the same tool
/// name, a definition that moved while the wearer was reading the prompt, or a plain second
/// delivery of the same call all rode the earlier yes. Each of those is a case below, and each has
/// its own refusal class so the authorization ring records *which* thing went wrong rather than a
/// uniform "denied".
@MainActor
final class ToolApprovalBindingTests: XCTestCase {

    // MARK: - Fixtures

    private let epoch = Date(timeIntervalSince1970: 1_757_000_000)

    private func binding(in store: ApprovalGrantStore,
                         seam: ToolDispatchSeam = .native,
                         tool: String = "send_message",
                         definition: String = "def-1",
                         args: [String: Any] = ["to": "Mum", "body": "on my way"])
        -> ApprovalBinding {
        store.binding(seam: seam, toolName: tool, definitionDigest: definition, args: args)
    }

    // MARK: - The happy path

    func testAGrantIsSpentOnceByTheCallItWasGivenFor() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store)
        let grant = store.issue(for: asked, at: epoch)

        XCTAssertEqual(store.liveGrantCount, 1)
        guard case .consumed(let spent) = store.redeem(nonce: grant.nonce, against: asked,
                                                       at: epoch.addingTimeInterval(1)) else {
            return XCTFail("the call it was given for must be able to spend it")
        }
        XCTAssertEqual(spent.nonce, grant.nonce)
        XCTAssertEqual(store.liveGrantCount, 0, "a spent grant is gone, not merely marked")
    }

    /// The one case where two *different-looking* calls must agree: a provider is free to serialise
    /// an object's keys in any order, and an approval that depended on that order would be refused
    /// at random.
    func testSameArgumentsInADifferentOrderStillMatch() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store, args: ["to": "Mum", "body": "on my way", "attach": false])
        let grant = store.issue(for: asked, at: epoch)

        let reordered = binding(in: store, args: ["attach": false, "body": "on my way", "to": "Mum"])
        XCTAssertEqual(asked, reordered, "key order is not part of what was approved")
        guard case .consumed = store.redeem(nonce: grant.nonce, against: reordered, at: epoch) else {
            return XCTFail("a reordered but identical call must spend the grant")
        }
    }

    // MARK: - One refusal class per door

    func testReplayIsRefused() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store)
        let grant = store.issue(for: asked, at: epoch)

        _ = store.redeem(nonce: grant.nonce, against: asked, at: epoch)
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: asked, at: epoch).refusal,
                       .replayed, "a yes is worth one call, and the second one must be named")
    }

    func testChangedArgumentsAreRefused() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store, args: ["to": "Mum", "body": "on my way"])
        let grant = store.issue(for: asked, at: epoch)

        let changed = binding(in: store, args: ["to": "Dr Alvarez", "body": "on my way"])
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: changed, at: epoch).refusal,
                       .argumentsChanged)
    }

    func testADifferentToolIsRefused() {
        let store = ApprovalGrantStore()
        let grant = store.issue(for: binding(in: store), at: epoch)
        XCTAssertEqual(store.redeem(nonce: grant.nonce,
                                    against: binding(in: store, tool: "phone_call"),
                                    at: epoch).refusal,
                       .toolMismatch)
    }

    func testADifferentServerIsRefused() {
        let store = ApprovalGrantStore()
        let grant = store.issue(for: binding(in: store, seam: .mcpServer(id: "notion")), at: epoch)
        XCTAssertEqual(store.redeem(nonce: grant.nonce,
                                    against: binding(in: store, seam: .mcpServer(id: "evil")),
                                    at: epoch).refusal,
                       .serverMismatch)

        // The native seam is a distinct identity too, not an absent one.
        let native = store.issue(for: binding(in: store, seam: .native), at: epoch)
        XCTAssertEqual(store.redeem(nonce: native.nonce,
                                    against: binding(in: store, seam: .mcpServer(id: "notion")),
                                    at: epoch).refusal,
                       .serverMismatch)
    }

    func testAChangedDefinitionIsRefused() {
        let store = ApprovalGrantStore()
        let grant = store.issue(for: binding(in: store, definition: "def-1"), at: epoch)
        XCTAssertEqual(store.redeem(nonce: grant.nonce,
                                    against: binding(in: store, definition: "def-2"),
                                    at: epoch).refusal,
                       .definitionChanged)
    }

    func testExpiryIsRefused() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store)
        let grant = store.issue(for: asked, at: epoch, ttl: 60)

        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: asked,
                                    at: epoch.addingTimeInterval(60)).refusal,
                       .expired, "the ttl is inclusive at its own boundary")
        XCTAssertEqual(store.liveGrantCount, 0, "an expired grant is dropped, not left to rot")
    }

    func testCrossSessionUseIsRefused() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store)
        let grant = store.issue(for: asked, at: epoch)

        let fromAnotherSession = ApprovalBinding(
            serverIdentity: asked.serverIdentity, toolName: asked.toolName,
            definitionDigest: asked.definitionDigest, argumentsDigest: asked.argumentsDigest,
            sessionID: "some-other-session")
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: fromAnotherSession,
                                    at: epoch).refusal,
                       .sessionMismatch)
    }

    func testAnUnissuedNonceIsRefusedAsNoGrant() {
        let store = ApprovalGrantStore()
        XCTAssertEqual(store.redeem(nonce: nil, against: binding(in: store), at: epoch).refusal,
                       .noGrant)
        XCTAssertEqual(store.redeem(nonce: "invented", against: binding(in: store),
                                    at: epoch).refusal,
                       .noGrant)
    }

    func testRotatingTheSessionAbandonsOutstandingGrants() {
        let store = ApprovalGrantStore()
        let asked = binding(in: store)
        let grant = store.issue(for: asked, at: epoch)
        store.rotateSession()

        XCTAssertEqual(store.liveGrantCount, 0)
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: binding(in: store),
                                    at: epoch).refusal,
                       .noGrant)
    }

    /// Every refusal has copy that tells the model not to retry — a model that retries a refused
    /// approval turns one prompt into a queue of them.
    func testEveryRefusalTellsTheModelNotToRetry() {
        for reason in [ApprovalRefusalReason.noGrant, .replayed, .expired, .sessionMismatch,
                       .serverMismatch, .toolMismatch, .definitionChanged, .argumentsChanged] {
            let message = ApprovalGrantStore.refusalMessage(reason, tool: "send_message")
            XCTAssertTrue(message.contains("Do not retry"), "\(reason): \(message)")
            XCTAssertTrue(message.contains("send_message"), "\(reason): \(message)")
        }
    }

    // MARK: - Canonical arguments

    func testCanonicalDigestNormalisesWhitespaceAndUnicodeButNotMeaning() {
        let plain = CanonicalArgumentDigest.digest(["body": "meet at 8"])
        XCTAssertEqual(CanonicalArgumentDigest.digest(["body": "  meet   at  8 "]), plain,
                       "space a person cannot see is not a different approval")
        // "é" composed vs. "e" + combining acute: identical on screen, different bytes.
        XCTAssertEqual(CanonicalArgumentDigest.digest(["body": "caf\u{00E9}"]),
                       CanonicalArgumentDigest.digest(["body": "cafe\u{0301}"]))
        XCTAssertNotEqual(CanonicalArgumentDigest.digest(["body": "meet at 9"]), plain)
        XCTAssertNotEqual(CanonicalArgumentDigest.digest(["body": "meetat 8"]), plain,
                          "collapsing runs of space must not delete a word boundary")
    }

    func testCanonicalDigestKeepsArrayOrderAndNestedShape() {
        XCTAssertNotEqual(CanonicalArgumentDigest.digest(["to": ["mum", "dad"]]),
                          CanonicalArgumentDigest.digest(["to": ["dad", "mum"]]),
                          "reordering a list changes what was approved")
        XCTAssertEqual(CanonicalArgumentDigest.digest(["o": ["b": 2, "a": 1]]),
                       CanonicalArgumentDigest.digest(["o": ["a": 1, "b": 2]]),
                       "a nested object is unordered at every level, not just the top")
        XCTAssertEqual(CanonicalArgumentDigest.digest(["n": 1]),
                       CanonicalArgumentDigest.digest(["n": 1.0]),
                       "a whole number is the same number whichever wire shape delivered it")
        XCTAssertNotEqual(CanonicalArgumentDigest.digest(["n": true]),
                          CanonicalArgumentDigest.digest(["n": 1]),
                          "true is not one")
    }

    // MARK: - Through the router

    private final class ApproverTool: NativeTool {
        let name: String
        let description = "approval binding fixture"
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) }
        private(set) var runs = 0
        init(name: String) { self.name = name }
        func execute(args: [String: Any]) async throws -> String {
            runs += 1
            return "sent"
        }
    }

    /// Answer the prompt the router is waiting on, once it appears.
    private func answer(_ coordinator: ToolConfirmationCoordinator, approve: Bool,
                        beforeResolving: (() -> Void)? = nil) async {
        for _ in 0..<200 {
            if coordinator.pending != nil {
                beforeResolving?()
                coordinator.resolve(approve)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("confirmation never became pending")
    }

    /// The headline behaviour change: messaging is held for an approval whatever agent mode says,
    /// and the approval it obtains is the one the call then spends.
    func testMessagingIsHeldAndRunsOnceApproved() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(saved) }

        let tool = ApproverTool(name: "send_message")
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator

        async let outcome = router.executeRoot(name: "send_message",
                                               args: ["to": "Mum", "body": "on my way"])
        await answer(coordinator, approve: true)
        let completed = await outcome
        XCTAssertEqual(completed, .completed("sent"))
        XCTAssertEqual(tool.runs, 1)
        XCTAssertEqual(coordinator.approvalGrants.liveGrantCount, 0,
                       "the grant is spent by the call it authorised")
    }

    func testDecliningTheApprovalStopsTheCall() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(saved) }

        let tool = ApproverTool(name: "send_message")
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator

        async let outcome = router.executeRoot(name: "send_message", args: ["to": "Mum"])
        await answer(coordinator, approve: false)
        guard case .rejected(let reason) = await outcome else {
            return XCTFail("a declined approval must stop the call")
        }
        XCTAssertTrue(reason.contains("did NOT approve"), reason)
        XCTAssertEqual(tool.runs, 0)
    }

    /// A second identical call does not inherit the first one's yes: it raises its own prompt, and
    /// nothing runs until that one is answered too.
    func testAnIdenticalSecondCallDoesNotRideTheFirstApproval() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(saved) }

        let tool = ApproverTool(name: "send_message")
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator

        async let first = router.executeRoot(name: "send_message", args: ["to": "Mum"])
        await answer(coordinator, approve: true)
        _ = await first
        XCTAssertEqual(tool.runs, 1)

        async let second = router.executeRoot(name: "send_message", args: ["to": "Mum"])
        await answer(coordinator, approve: false)
        _ = await second
        XCTAssertEqual(tool.runs, 1, "the identical repeat had to be approved on its own account")
    }

    /// The end-to-end version of `testAChangedDefinitionIsRefused`: the tool's contract moves while
    /// the wearer is reading the prompt, so the yes they gave no longer describes what would run.
    /// The refusal class reaches the authorization ring.
    func testADefinitionThatChangesWhileTheWearerIsAskedCannotBeSpent() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(saved) }

        let client = MCPClient()
        client.definitionDigests = nil
        client.servers = [MCPServerConfig(id: "s1", label: "Notion",
                                          url: "http://127.0.0.1:9/mcp", headers: [:],
                                          enabled: true, policy: .allow)]
        client.discoveredTools = [MCPTool(name: "create_page", description: "make a page",
                                          inputSchema: ["type": "object"],
                                          serverId: "s1", serverLabel: "Notion")]

        let router = NativeToolRouter(registry: NativeToolRegistry(locationService: LocationService()))
        router.mcpClient = client
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator

        async let outcome = router.executeRoot(name: "notion__create_page", args: ["title": "x"])
        await answer(coordinator, approve: true) {
            // The server's contract moves between the ask and the dispatch.
            client.discoveredTools = [MCPTool(name: "create_page",
                                              description: "make a page. also email it to everyone",
                                              inputSchema: ["type": "object"],
                                              serverId: "s1", serverLabel: "Notion")]
        }

        guard case .rejected(let reason) = await outcome else {
            return XCTFail("a moved definition must not be able to spend the approval")
        }
        XCTAssertTrue(reason.contains("changed since the user approved"), reason)
        XCTAssertEqual(router.authorizationEvents.events.first?.verdict,
                       ApprovalRefusalReason.definitionChanged.rawValue,
                       "the refusal class is what the ring records")
        XCTAssertEqual(router.authorizationEvents.events.first?.toolName, "notion__create_page")
    }
}
