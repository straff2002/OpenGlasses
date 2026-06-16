import XCTest
@testable import OpenGlasses

/// Tests for Plan N Phase 2: the Custom URL harness config/request building, `JSONPath`, the
/// `CustomAgentHarness` HTTP shape (via the shared `URLProtocol` stub), the `AgentHarnessRegistry`
/// active-resolution, and the registry-backed dispatch + `switch_harness` tool action.
@MainActor
final class AgentCustomHarnessTests: XCTestCase {

    private func config(start: String = "https://agent.test/start") -> CustomHarnessConfig {
        var c = CustomHarnessConfig()
        c.startURL = start
        c.statusURLTemplate = "https://agent.test/runs/{id}"
        c.authHeader = "Authorization"
        c.authValue = "Bearer tok"
        return c
    }

    // MARK: - CustomHarnessConfig

    func testIsConfiguredRequiresValidStartURL() {
        XCTAssertFalse(CustomHarnessConfig().isConfigured)
        XCTAssertTrue(config().isConfigured)
    }

    func testConfigCodableRoundTrip() throws {
        let original = config()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomHarnessConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStatusURLSubstitutesId() {
        XCTAssertEqual(config().statusURL(runID: "abc")?.absoluteString, "https://agent.test/runs/abc")
        var c = CustomHarnessConfig(); c.statusURLTemplate = ""
        XCTAssertNil(c.statusURL(runID: "abc"))
    }

    func testStartRequestBadURLIsNil() {
        var c = CustomHarnessConfig(); c.startURL = ""
        XCTAssertNil(c.startRequest(prompt: "p", project: nil))
    }

    // MARK: - JSONPath

    func testJSONPathNestedExtraction() {
        let json: [String: Any] = ["data": ["run": ["id": "r1", "n": 3, "ok": true]]]
        XCTAssertEqual(JSONPath.string(at: "data.run.id", in: json), "r1")
        XCTAssertEqual(JSONPath.string(at: "data.run.n", in: json), "3")     // number coerced
        XCTAssertEqual(JSONPath.string(at: "data.run.ok", in: json), "true") // bool coerced
        XCTAssertNil(JSONPath.string(at: "data.run.missing", in: json))
        XCTAssertNil(JSONPath.string(at: "data.run.id.too.deep", in: json))  // walks past a leaf
    }

    // MARK: - CustomAgentHarness over the URLProtocol stub

    func testStartBuildsRequestAndParsesRun() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"id":"run-9","status":"running"}"#.utf8)
        let harness = CustomAgentHarness(config: config(), session: MockURLProtocol.session())

        let run = try await harness.start(prompt: "add a toggle", project: "my-app")
        XCTAssertEqual(run.id, "run-9")
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.harness, .custom)

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://agent.test/start")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any]
        XCTAssertEqual(body?["prompt"] as? String, "add a toggle")
        XCTAssertEqual(body?["project"] as? String, "my-app")
    }

    func testStartUsesCustomFieldMapping() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"data":{"runId":"R7"},"state":"queued"}"#.utf8)
        var c = config()
        c.idPath = "data.runId"
        c.statusPath = "state"
        c.promptField = "task"
        let harness = CustomAgentHarness(config: c, session: MockURLProtocol.session())

        let run = try await harness.start(prompt: "do it", project: nil)
        XCTAssertEqual(run.id, "R7")
        XCTAssertEqual(run.status, .queued)

        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any]
        XCTAssertEqual(body?["task"] as? String, "do it")
        XCTAssertNil(body?["project"])   // omitted when nil
    }

    func testStartThrowsWhenNoRunId() async {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"status":"running"}"#.utf8)
        let harness = CustomAgentHarness(config: config(), session: MockURLProtocol.session())
        do { _ = try await harness.start(prompt: "p", project: nil); XCTFail("expected throw") }
        catch let e as AgentHarnessError {
            guard case .transport(let msg) = e else { return XCTFail("wrong case") }
            XCTAssertTrue(msg.contains("run id"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testStartThrowsOnHTTPError() async {
        MockURLProtocol.reset()
        MockURLProtocol.statusCode = 401
        MockURLProtocol.responseBody = Data("unauthorized".utf8)
        let harness = CustomAgentHarness(config: config(), session: MockURLProtocol.session())
        do { _ = try await harness.start(prompt: "p", project: nil); XCTFail("expected throw") }
        catch let e as AgentHarnessError {
            guard case .transport(let msg) = e else { return XCTFail("wrong case") }
            XCTAssertTrue(msg.contains("401"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testStatusPolls() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"status":"completed"}"#.utf8)
        let harness = CustomAgentHarness(config: config(), session: MockURLProtocol.session())
        let run = AgentRun(id: "r", harness: .custom, prompt: "p", project: nil, status: .running, startedAt: Date())
        let status = try await harness.status(run)
        XCTAssertEqual(status, .completed)
    }

    // MARK: - AgentRunStatus.parse (shared)

    func testStatusParseTolerantSpellings() {
        XCTAssertEqual(AgentRunStatus.parse("in_progress"), .running)
        XCTAssertEqual(AgentRunStatus.parse("SUCCESS"), .completed)
        XCTAssertEqual(AgentRunStatus.parse("canceled"), .cancelled)
        XCTAssertNil(AgentRunStatus.parse("weird"))
    }

    // MARK: - AgentHarnessRegistry resolution

    func testRegistryPrefersConfiguredDefault() {
        let registry = AgentHarnessRegistry([
            StubHarness(kind: .openclaw, configured: true),
            StubHarness(kind: .custom, configured: true),
        ])
        XCTAssertEqual(registry.active(defaultKind: .custom)?.kind, .custom)
        XCTAssertEqual(registry.active(defaultKind: .openclaw)?.kind, .openclaw)
    }

    func testRegistryFallsBackWhenDefaultUnconfigured() {
        let registry = AgentHarnessRegistry([
            StubHarness(kind: .openclaw, configured: true),
            StubHarness(kind: .custom, configured: false),
        ])
        // Default custom isn't configured → first configured (openclaw).
        XCTAssertEqual(registry.active(defaultKind: .custom)?.kind, .openclaw)
    }

    func testRegistryNilWhenNoneConfigured() {
        let registry = AgentHarnessRegistry([StubHarness(kind: .openclaw, configured: false)])
        XCTAssertNil(registry.active(defaultKind: .openclaw))
    }

    // MARK: - Registry-backed dispatch + switch_harness tool

    func testSessionDispatchUsesRegistryActive() async {
        let service = AgentSessionService()
        service.configure(registry: AgentHarnessRegistry([StubHarness(kind: .custom, configured: true)]),
                          speak: { _ in })
        let result = await service.dispatch(prompt: "p", project: nil)
        guard case .success(let run) = result else { return XCTFail("expected success") }
        XCTAssertEqual(run.harness, .custom)
    }

    func testSessionDispatchFailsWhenRegistryEmpty() async {
        let service = AgentSessionService()
        service.configure(registry: AgentHarnessRegistry([StubHarness(kind: .openclaw, configured: false)]),
                          speak: { _ in })
        guard case .failure = await service.dispatch(prompt: "p", project: nil) else {
            return XCTFail("expected failure")
        }
    }

    func testToolSwitchHarnessUnknownAndUnconfigured() async throws {
        let prior = Config.agentModeEnabled
        defer { Config.setAgentModeEnabled(prior) }
        Config.setAgentModeEnabled(true)

        let unknown = try await AgentControlTool().execute(args: ["action": "switch_harness", "harness": "nope"])
        XCTAssertTrue(unknown.contains("Which agent backend"))

        // With no configured custom registry on the shared session, switching to custom is refused.
        AgentSessionService.shared.setRegistry(AgentHarnessRegistry([StubHarness(kind: .custom, configured: false)]))
        let unconfigured = try await AgentControlTool().execute(args: ["action": "switch_harness", "harness": "custom"])
        XCTAssertTrue(unconfigured.contains("isn't configured"))
    }
}

/// Minimal harness for registry/dispatch tests.
private struct StubHarness: AgentHarness {
    let kind: AgentHarnessKind
    let configured: Bool
    var displayName: String { kind.displayName }
    var isConfigured: Bool { configured }
    func start(prompt: String, project: String?) async throws -> AgentRun {
        AgentRun(id: "stub", harness: kind, prompt: prompt, project: project, status: .running, startedAt: Date())
    }
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func status(_ run: AgentRun) async throws -> AgentRunStatus { run.status }
    func cancel(_ run: AgentRun) async throws {}
}
