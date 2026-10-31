import XCTest
@testable import OpenGlasses

/// Plan KE P0 — a vault that says `vault_only` is sealed while a job on it is open: every way out
/// to outside knowledge is shut by the app, not by a rule in the prompt.
///
/// The tools are spies registered under the real names, so "refused" is a counting claim, and the
/// gate is the router's own with its seam thrown.
@MainActor
final class VaultOnlyPolicyTests: XCTestCase {

    // MARK: - Every tool is decided

    /// A new tool in the field profile fails here until someone decides it.
    func testEveryFieldToolIsDecided() {
        let decided = VaultOnlyPolicy.keptTools.union(VaultOnlyPolicy.sealedTools)
        XCTAssertEqual(FieldToolProfile.names.subtracting(decided).sorted(), [],
                       "add it to VaultOnlyPolicy: kept, or sealed")
    }

    func testEveryToolACoreSetCarriesIsDecided() {
        let decided = VaultOnlyPolicy.keptTools.union(VaultOnlyPolicy.sealedTools)
        XCTAssertEqual(ToolExposureCore.everyday.subtracting(decided).sorted(), [])
        // The on-device list is not narrowed by the profile, so all of it has to be kept outright.
        XCTAssertEqual(LLMService.localSafeTools.subtracting(VaultOnlyPolicy.keptTools).sorted(), [])
    }

    func testNothingIsBothKeptAndSealed() {
        XCTAssertEqual(VaultOnlyPolicy.keptTools.intersection(VaultOnlyPolicy.sealedTools).sorted(), [])
    }

    func testTheWaysOutAreSealedAndTheJobsToolsAreNot() {
        for name in ["web_search", "get_news", "qr_context", "discover_capabilities", "execute",
                     "mcp__acme__fetch_page", "a_tool_nobody_has_heard_of"] {
            XCTAssertTrue(VaultOnlyPolicy.isSealed(tool: name), name)
        }
        for name in ["manual_lookup", "show_source", "equipment_lookup", "set_timer", "get_weather",
                     "get_directions", ToolLookupTool.toolName] {
            XCTAssertFalse(VaultOnlyPolicy.isSealed(tool: name), name)
        }
    }

    // MARK: - Which job is sealed

    func testOnlyAnOpenJobOnASealedVaultIsSealed() {
        XCTAssertFalse(VaultOnlyPolicy.isSealed(jobOpen: false, recordedOnJob: nil, vaultSays: true))
        XCTAssertFalse(VaultOnlyPolicy.isSealed(jobOpen: true, recordedOnJob: nil, vaultSays: nil))
        XCTAssertFalse(VaultOnlyPolicy.isSealed(jobOpen: true, recordedOnJob: nil, vaultSays: false))
        XCTAssertTrue(VaultOnlyPolicy.isSealed(jobOpen: true, recordedOnJob: nil, vaultSays: true))
        XCTAssertTrue(VaultOnlyPolicy.isSealed(jobOpen: true, recordedOnJob: true, vaultSays: nil),
                      "the job keeps the seal it started under")
    }

    // MARK: - Declared and listed

    private let all = ["calendar", "field_session", "get_news", "get_weather", "manual_lookup",
                       "qr_context", "smart_home", "web_search"]

    func testTheProfileDropsWhatTheSealShuts() {
        XCTAssertEqual(FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: true, vaultOnly: true),
                       ["field_session", "get_weather", "manual_lookup"])
    }

    func testTheSealHoldsWithTheProfileSwitchedOff() {
        XCTAssertEqual(FieldToolProfile.declaredNames(all: all, fieldJobActive: false, enabled: false, vaultOnly: true),
                       ["calendar", "field_session", "get_weather", "manual_lookup"])
    }

    func testWithoutTheKeyTheListsAreAsTheyWere() {
        XCTAssertEqual(FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: true),
                       FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: true, vaultOnly: false))
        XCTAssertTrue(FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: true).contains("web_search"))
    }

    func testTheDeclarableNamesAgree() {
        let declared = ToolDeclarations.declarableNames(all, isEnabled: { _ in true }, hipaaMode: false,
                                                        hipaaDisabled: [], fieldJobActive: true,
                                                        fieldProfileEnabled: true, vaultOnly: true)
        XCTAssertFalse(declared.contains("web_search"))
        XCTAssertFalse(declared.contains("qr_context"))
        XCTAssertTrue(declared.contains("manual_lookup"))
    }

    func testTheCoreSetDropsWhatTheSealShuts() {
        let sealed = ToolExposureCore.names(fieldJobActive: true, accessibilityMode: false, vaultOnly: true)
        XCTAssertFalse(sealed.contains("web_search"))
        XCTAssertFalse(sealed.contains("get_news"))
        XCTAssertTrue(sealed.contains("manual_lookup"))
        let open = ToolExposureCore.names(fieldJobActive: true, accessibilityMode: false)
        XCTAssertTrue(open.contains("web_search"))
        XCTAssertTrue(open.contains("get_news"))
    }

    /// A tool remembered from earlier in the conversation stays out too: what is available decides.
    func testARememberedSealedToolIsNotDeclared() {
        let available = FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: true, vaultOnly: true)
        let decision = ToolExposurePolicy.decide(mode: .always, available: available, fullSetBytes: 1_000,
                                                 contextWindow: 200_000,
                                                 core: ToolExposureCore.names(fieldJobActive: true, accessibilityMode: false,
                                                                              vaultOnly: true),
                                                 remembered: ["web_search"])
        XCTAssertFalse(decision.declared.contains("web_search"))
        XCTAssertFalse(ToolExposurePolicy.roundDeclared(decision, promoted: ["web_search"])?.contains("web_search") ?? true)
    }

    /// The acknowledgement examples named `web_search` whether it was offered or not, and a model
    /// told to call a tool calls it.
    func testThePromptNamesSearchOnlyWhenItIsOffered() async {
        let open = await LLMService.promptLayoutForTesting(nativeToolNames: ["get_weather", "web_search"]).combined
        XCTAssertTrue(open.contains("then call web_search"))
        let sealed = await LLMService.promptLayoutForTesting(nativeToolNames: ["get_weather"]).combined
        XCTAssertFalse(sealed.contains("web_search"), "the rule examples are the only place it could come from")
        XCTAssertTrue(sealed.contains("then call get_weather."))
    }

    func testASealedJobDeclaresNoMCPTool() {
        let client = MCPClient()
        client.discoveredTools = [MCPTool(name: "fetch_page", description: "Fetch a page", inputSchema: [:],
                                          serverId: "acme", serverLabel: "Acme")]
        XCTAssertTrue(ToolDeclarations.mcpToolDeclarations(mcpClient: client, vaultOnly: true).isEmpty)
        XCTAssertEqual(ToolDeclarations.mcpToolDeclarations(mcpClient: client, vaultOnly: false).count, 1)
    }

    func testASealedToolCannotBeLookedUpBackIn() {
        let declarations: [[String: Any]] = [
            ["name": "web_search", "description": "d", "parameters": [:] as [String: Any]],
            ["name": "mcp__acme__fetch_page", "description": "d", "parameters": [:] as [String: Any]],
            ["name": "manual_lookup", "description": "d", "parameters": [:] as [String: Any]],
        ]
        let sealed = ToolLookupTool.declarable(declarations, vaultOnly: true)
        XCTAssertEqual(sealed.compactMap { $0["name"] as? String }, ["manual_lookup"])
        let reply = ToolLookupTool.render(requested: ["web_search", "mcp__acme__fetch_page", "manual_lookup"],
                                          declarable: sealed)
        XCTAssertTrue(reply.contains("Not available: web_search, mcp__acme__fetch_page."), reply)
        XCTAssertEqual(ToolLookupTool.declarable(declarations, vaultOnly: false).count, 3)
    }

    // MARK: - Refused at dispatch

    private final class ExecutionSpy { var count = 0 }

    private struct SpyTool: NativeTool {
        let name: String
        let description = "spy"
        let spy: ExecutionSpy
        var parametersSchema: [String: Any] { ["type": "object"] }
        func execute(args: [String: Any]) async throws -> String {
            spy.count += 1
            return "ran:\(name)"
        }
    }

    private func router(with names: [String], spy: ExecutionSpy, sealed: Bool = true) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        for name in names { registry.register(SpyTool(name: name, spy: spy)) }
        let router = NativeToolRouter(registry: registry)
        router.vaultOnlySealed = { sealed }
        return router
    }

    func testARememberedNameIsRefusedAndNothingRuns() async throws {
        let spy = ExecutionSpy()
        let router = router(with: ["web_search", "get_news", "qr_context"], spy: spy)

        for name in ["web_search", "get_news", "qr_context"] {
            let outcome = await router.executeRoot(name: name, args: ["query": "QX100 fan will not start"])
            XCTAssertEqual(outcome, .rejected(reason: VaultOnlyPolicy.refusal(tool: name)), name)
            XCTAssertEqual(outcome.retryDisposition, .retryWillBeRefused)
        }
        XCTAssertEqual(spy.count, 0, "a refusal that still executes is the bug")
        let event = try XCTUnwrap(router.authorizationEvents.events.first)
        XCTAssertEqual(event.verdict, ToolRefusalReason.vaultOnlySealed.rawValue)
    }

    /// A goal step's "Do it" runs as a person's own call, not a model's.
    func testAGoalStepCannotSearch() async {
        let spy = ExecutionSpy()
        let router = router(with: ["web_search"], spy: spy)
        let goal = Goal(id: UUID(), title: "Learn the QX100", createdAt: Date(), source: .wearer)
        let step = GoalStep(id: UUID(), title: "Read up on it")
        guard case .tool(let name, _) = StepActionRun.run(for: .search(query: "QX100 service"), step: step,
                                                          goal: goal, calendar: .current) else {
            return XCTFail("a search step is one tool call")
        }

        let outcome = await router.execute(.root(name: name, arguments: ToolArguments(["query": "QX100 service"]),
                                                 origin: .user))

        XCTAssertEqual(outcome, .rejected(reason: VaultOnlyPolicy.refusal(tool: "web_search")))
        XCTAssertEqual(spy.count, 0)
    }

    func testASkillPackCannotSearch() async throws {
        let spy = ExecutionSpy()
        let router = router(with: ["web_search"], spy: spy)
        let pack = SkillPackToolWrapper(
            packId: "com.example.pack",
            action: SkillPackAction(name: "do_it", description: "Fixture.", parametersSchema: ["type": "object"],
                                    binding: .tool(name: "web_search", boundArgs: [:])),
            dispatchChild: { [weak router] call in
                await router?.execute(call) ?? .failedBeforeExecution(reason: "no authority")
            })

        let result = try await pack.execute(args: [:])

        XCTAssertEqual(result, VaultOnlyPolicy.refusal(tool: "web_search"))
        XCTAssertEqual(spy.count, 0)
    }

    /// An unknown name would fall through to MCP or the gateway. So would a kept name whose native
    /// tool is switched off, which the policy's list alone would let past.
    func testNothingFallsThroughToAServerOrTheGateway() async {
        let spy = ExecutionSpy()
        let router = router(with: [], spy: spy)

        for name in ["mcp__acme__fetch_page", "execute", "a_tool_nobody_has_heard_of", "capture_photo"] {
            let outcome = await router.executeRoot(name: name, args: ["task": "look it up"])
            XCTAssertEqual(outcome, .rejected(reason: VaultOnlyPolicy.refusal(tool: name)), name)
        }
    }

    func testAKeptToolStillRuns() async {
        let spy = ExecutionSpy()
        let router = router(with: ["manual_lookup", "set_timer"], spy: spy)

        let manual = await router.executeRoot(name: "manual_lookup", args: [:])
        XCTAssertEqual(manual, .completed("ran:manual_lookup"))
        let timer = await router.executeRoot(name: "set_timer", args: [:])
        XCTAssertEqual(timer, .completed("ran:set_timer"))
        XCTAssertTrue(router.authorizationEvents.events.isEmpty)
    }

    func testWithNoSealTheRouterIsAsItWas() async {
        let spy = ExecutionSpy()
        let router = router(with: ["web_search"], spy: spy, sealed: false)

        let outcome = await router.executeRoot(name: "web_search", args: [:])

        XCTAssertEqual(outcome, .completed("ran:web_search"))
        XCTAssertEqual(spy.count, 1)
    }

    // MARK: - The re-ask, which never passes the router

    func testTheWebReAskDoesNothingOnASealedJob() async {
        var asked = 0
        let answer = await UncertaintyReask.answer(
            question: "and the other one?", originalAnswer: "I am not sure.", vaultOnly: true,
            history: [(role: "user", content: "QX100")],
            search: { _ in asked += 1; return "from the web" },
            rewriteQuery: { query in asked += 1; return query },
            regenerate: { _ in asked += 1; return "grounded" })
        XCTAssertEqual(answer, "I am not sure.")
        XCTAssertEqual(asked, 0, "not even the rewrite: nothing about the turn is prepared for a search")
    }

    /// Nothing else may hold a search tool of its own: `vaultOnly` is required on the re-ask, and
    /// these are the only other places one can be made outside the router.
    func testOnlyTheRegistryAndTheReAskConstructASearchTool() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources found at \(root.path)")
        var holders = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("WebSearchTool()") || source.contains("NewsTool()") {
                holders.insert(file.lastPathComponent)
            }
        }
        XCTAssertEqual(holders, ["LLMService.swift", "NativeToolRegistry.swift"])
    }

    // MARK: - The manifest

    private func manifest(_ json: String) throws -> VaultManifest {
        try JSONDecoder().decode(VaultManifest.self, from: Data(json.utf8))
    }

    func testTheKeyIsRead() throws {
        let base = #""id": "v", "name": "V", "version": "1", "files": []"#
        XCTAssertEqual(try manifest("{\(base), \"vault_only\": true}").vaultOnly, true)
        XCTAssertTrue(try manifest("{\(base), \"vault_only\": true}").isVaultOnly)
        XCTAssertFalse(try manifest("{\(base), \"vault_only\": false}").isVaultOnly)
        XCTAssertNil(try manifest("{\(base)}").vaultOnly)
        XCTAssertFalse(try manifest("{\(base)}").isVaultOnly)
    }

    /// Read as false, a seal the author asked for would silently not be there.
    func testAMalformedKeyRefusesTheManifest() {
        let json = #"{"id": "v", "name": "V", "version": "1", "files": [], "vault_only": "yes"}"#
        XCTAssertThrowsError(try manifest(json))
    }

    func testAManifestWithoutTheKeyEncodesWithoutIt() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = VaultManifest(id: "v", name: "V", version: "1", files: [])
        let text = try XCTUnwrap(String(data: encoder.encode(plain), encoding: .utf8))
        XCTAssertFalse(text.contains("vault_only"), text)
        let sealed = VaultManifest(id: "v", name: "V", version: "1", files: [], vaultOnly: true)
        let sealedText = try XCTUnwrap(String(data: encoder.encode(sealed), encoding: .utf8))
        XCTAssertTrue(sealedText.contains("\"vault_only\":true"), sealedText)
    }

    func testTheSealTravelsWithTheVault() throws {
        let sealed = VaultManifest(id: "v", name: "V", version: "1", files: [],
                                   documents: [VaultDocument(file: "a.pdf", title: "Acme Service Manual A123"),
                                               VaultDocument(file: "b.pdf", title: "Acme Parts List B456")],
                                   vaultOnly: true)
        let exported = sealed.markingDocumentsNotIncluded()
        XCTAssertEqual(exported.vaultOnly, true, "an export carries it")
        XCTAssertEqual(exported.markingDocumentsIncluded().vaultOnly, true, "and so does its import")
        XCTAssertEqual(VaultManualRemoval.reducedManifest(sealed, removing: "a.pdf").vaultOnly, true)
        XCTAssertEqual(try JSONDecoder().decode(VaultManifest.self, from: JSONEncoder().encode(exported)).vaultOnly, true)
    }

    // MARK: - The job remembers

    func testASavedJobDecodesWithoutTheFieldAndKeepsItWhenSet() throws {
        var session = FieldSession(id: "s", vaultId: "v", assetId: nil, mode: .aiOnly, startedAt: Date(),
                                   outcome: .inProgress, escalations: [], billableSeconds: 0)
        let plain = try JSONEncoder().encode(session)
        XCTAssertFalse(try XCTUnwrap(String(data: plain, encoding: .utf8)).contains("vaultOnly"))
        XCTAssertNil(try JSONDecoder().decode(FieldSession.self, from: plain).vaultOnly)

        session.vaultOnly = true
        let sealed = try JSONDecoder().decode(FieldSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(sealed.vaultOnly, true)
    }

    func testAJobOnASealedVaultIsSealedAndTheNextIsNot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = EntitlementTestScope.grant()
        let previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        defer {
            EntitlementTestScope.restore(previous)
            UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled")
        }
        let manifest = VaultManifest(id: "vault_only_fixture", name: "Sealed Fixture", version: "1.0.0",
                                     files: ["notes.md"],
                                     promptRules: ["Never fabricate.", "Cite the source."], vaultOnly: true)
        let folder = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try "# Notes".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let installed = try VaultImporter.install(from: folder)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        defer {
            VaultImporter.uninstall(id: installed.id)
            VaultRegistry.shared.reloadUserManifests()
            VaultRegistry.shared.resetCache()
        }
        XCTAssertTrue(installed.isVaultOnly, "the install keeps the key")

        let service = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        XCTAssertFalse(service.vaultOnlyJobOpen, "no job, no seal")
        let session = try service.startSession(vaultId: installed.id, assetId: nil)
        XCTAssertEqual(session.vaultOnly, true)
        XCTAssertTrue(service.vaultOnlyJobOpen)

        _ = try service.pauseSession()
        XCTAssertTrue(service.vaultOnlyJobOpen, "a paused job is still the job")
        _ = try service.resumeSession()
        _ = try service.endSession(outcome: .resolved)
        XCTAssertFalse(service.vaultOnlyJobOpen, "the seal ends with the job")
    }
}
