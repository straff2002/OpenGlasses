import XCTest
@testable import OpenGlasses

/// Lifecycle and audit-log tests for FieldSessionService + SessionLogger.
///
/// These tests run against a temporary sessions root and use the bundled refrigeration vault, with
/// an injected always-granted entitlement, so they exercise the real VaultRegistry gating path.
@MainActor
final class FieldSessionServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var service: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldSessionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()

        service = FieldSessionService(sessionsRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testStartingASessionMakesItActive() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: "Unit 47B", mode: .aiOnly)
        XCTAssertNotNil(service.activeSession)
        XCTAssertEqual(session.vaultId, "refrigeration")
        XCTAssertEqual(session.assetId, "Unit 47B")
        XCTAssertEqual(session.mode, .aiOnly)
        XCTAssertEqual(session.outcome, .inProgress)
        XCTAssertTrue(service.isSessionActive)
    }

    func testCannotStartTwoSessions() throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        XCTAssertThrowsError(try service.startSession(vaultId: "refrigeration", assetId: nil)) { error in
            guard case FieldSessionError.alreadyActive = error else {
                return XCTFail("Expected .alreadyActive, got \(error)")
            }
        }
    }

    func testUnknownVaultThrows() {
        XCTAssertThrowsError(try service.startSession(vaultId: "does_not_exist", assetId: nil)) { error in
            guard case FieldSessionError.unknownVault = error else {
                return XCTFail("Expected .unknownVault, got \(error)")
            }
        }
    }

    func testLockedVaultThrows() throws {
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        UserDefaults.standard.set(false, forKey: "agentModeEnabled")
        VaultRegistry.shared.resetCache()

        XCTAssertThrowsError(try service.startSession(vaultId: "refrigeration", assetId: nil)) { error in
            guard case FieldSessionError.vaultLocked = error else {
                return XCTFail("Expected .vaultLocked, got \(error)")
            }
        }
    }

    func testPauseAndResumeAccumulatesBillableTime() throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        // Simulate a short interval before pausing.
        Thread.sleep(forTimeInterval: 0.05)
        let paused = try service.pauseSession()
        XCTAssertGreaterThan(paused.billableSeconds, 0)
        XCTAssertNotNil(paused.pausedAt)
        XCTAssertEqual(paused.outcome, .paused)

        let resumed = try service.resumeSession()
        XCTAssertNil(resumed.pausedAt)
        XCTAssertEqual(resumed.outcome, .inProgress)
    }

    func testEndSessionMarksOutcomeAndClearsActive() throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let ended = try service.endSession(outcome: .resolved)
        XCTAssertEqual(ended.outcome, .resolved)
        XCTAssertNotNil(ended.endedAt)
        XCTAssertNil(service.activeSession)
        XCTAssertFalse(service.isSessionActive)
    }

    func testEndingWithNoSessionThrows() {
        XCTAssertThrowsError(try service.endSession()) { error in
            guard case FieldSessionError.noActiveSession = error else {
                return XCTFail("Expected .noActiveSession, got \(error)")
            }
        }
    }

    func testRecordEscalationAppendsToSession() throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        service.recordEscalation(reason: "Manifold gauge shows -5 psig, unit is off — cannot interpret")
        XCTAssertEqual(service.activeSession?.escalations.count, 1)
        XCTAssertEqual(service.activeSession?.escalations.first?.reason.hasPrefix("Manifold"), true)
    }

    // MARK: - Audit log

    func testSessionLoggerCreatesSessionFile() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: "Unit 9")
        let sessionFile = tempRoot
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("session.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    func testSessionLoggerAppendsEvents() throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        service.logUserMessage("I see E5 on the display")
        service.logAssistantMessage("E5 is a low-pressure fault.", citations: ["error_codes.md"])
        _ = try service.endSession(outcome: .resolved)

        let logFile = tempRoot
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("log.jsonl")
        let contents = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 4) // started, user, assistant, ended

        XCTAssertTrue(contents.contains("session_started"))
        XCTAssertTrue(contents.contains("user_message"))
        XCTAssertTrue(contents.contains("assistant_message"))
        XCTAssertTrue(contents.contains("session_ended"))
        XCTAssertTrue(contents.contains("E5"))
    }

    // MARK: - Prompt context

    func testPromptContextNilWhenNoSession() {
        XCTAssertNil(service.promptContext())
    }

    func testPromptContextIncludesVaultContent() throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let prompt = service.promptContext()
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("KNOWLEDGE VAULT — Refrigeration Service") ?? false)
        XCTAssertTrue(prompt?.contains("Never fabricate") ?? false)
    }

    // MARK: - History persistence

    func testHistoryPersistsAcrossInstances() throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: "Unit X")
        _ = try service.endSession(outcome: .resolved)

        let reloaded = FieldSessionService(sessionsRoot: tempRoot)
        XCTAssertFalse(reloaded.history.isEmpty)
        XCTAssertEqual(reloaded.history.first?.vaultId, "refrigeration")
        XCTAssertEqual(reloaded.history.first?.assetId, "Unit X")
    }
}

/// Reproduces the chat path with an installed custom vault and the real entitlement boundary.
@MainActor
final class FieldVaultSelectionTests: XCTestCase {
    private var root: URL!
    private var registryFile: URL!
    private var previousDefault: Any?
    private var previousEnabled: Any?
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var service: FieldSessionService!
    private var tool: FieldSessionTool!
    private var lennox: VaultManifest!

    override func setUpWithError() throws {
        previousDefault = UserDefaults.standard.object(forKey: "fieldAssistDefaultVaultId")
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        lennox = VaultManifest(id: "test_lennox_\(UUID().uuidString)",
                               name: "Lennox SLP99 Furnace Service", version: "1.0.0",
                               files: [], gating: .init(iap: "enterprise"))
        try FileManager.default.createDirectory(at: VaultImporter.registryDirectory, withIntermediateDirectories: true)
        registryFile = VaultImporter.registryDirectory.appendingPathComponent("\(lennox.id).json")
        try JSONEncoder().encode(lennox).write(to: registryFile)
        VaultRegistry.shared.reloadUserManifests()
        UserDefaults.standard.set(lennox.id, forKey: "fieldAssistDefaultVaultId")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        service = FieldSessionService(sessionsRoot: root)
        tool = FieldSessionTool(service: service)
    }

    override func tearDownWithError() throws {
        if let registryFile { try FileManager.default.removeItem(at: registryFile) }
        VaultRegistry.shared.reloadUserManifests()
        if let root { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.set(previousDefault, forKey: "fieldAssistDefaultVaultId")
        UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
    }

    func testDefaultAliasesStartConfiguredCustomVault() async throws {
        for selection: Any? in [nil, NSNull(), "", "  ", "default", " Default Vault ", "configured default"] {
            var args: [String: Any] = ["action": "start"]
            if let selection { args["vault"] = selection }
            let result = try await tool.execute(args: args)
            XCTAssertEqual(service.activeSession?.vaultId, lennox.id, result)
            _ = try service.endSession()
        }
    }

    func testExactIDAndSpokenFullNameResolve() async throws {
        for selection in [lennox.id, "Lennox SLP99 Furnace Service", " lennox SLP 99 furnace service "] {
            let result = try await tool.execute(args: ["action": "start", "vault": selection])
            XCTAssertEqual(service.activeSession?.vaultId, lennox.id, result)
            XCTAssertTrue(result.contains(lennox.name))
            _ = try service.endSession()
        }
    }

    func testUnknownSelectionDoesNotFallBackAndListsCustomVault() async throws {
        let result = try await tool.execute(args: ["action": "start", "vault": "unknown furnace"])
        XCTAssertNil(service.activeSession)
        XCTAssertTrue(result.contains(lennox.id))
        XCTAssertTrue(result.contains("Do not substitute"))
        XCTAssertEqual(Config.fieldAssistDefaultVaultId, lennox.id)
    }

    func testMissingDefaultDoesNotFallBack() async throws {
        UserDefaults.standard.set("removed_vault", forKey: "fieldAssistDefaultVaultId")
        let result = try await tool.execute(args: ["action": "start", "vault": "default"])
        XCTAssertNil(service.activeSession)
        XCTAssertTrue(result.contains("configured default vault [removed_vault] is not installed"))
    }

    func testMalformedArgumentDoesNotStartDefault() async throws {
        _ = try await tool.execute(args: ["action": "start", "vault": 42])
        XCTAssertNil(service.activeSession)
    }

    func testLockedCustomVaultCannotBypassEntitlementWithNameOrDefault() async throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .solo)
        for selection in ["default", lennox.name] {
            _ = try await tool.execute(args: ["action": "start", "vault": selection])
            XCTAssertNil(service.activeSession)
        }
    }

    func testExistingJobIsNotReplacedByNewDefault() async throws {
        let original = try service.startSession(vaultId: "refrigeration", assetId: "Unit A")
        let result = try await tool.execute(args: ["action": "start", "vault": "default"])
        XCTAssertEqual(service.activeSession?.id, original.id)
        XCTAssertEqual(service.activeSession?.vaultId, "refrigeration")
        XCTAssertTrue(result.contains("active job uses Refrigeration Service"))
        XCTAssertTrue(result.contains(lennox.id))
        XCTAssertTrue(result.contains("do not end it automatically"))
    }

    func testRestartRetainsCustomVaultAndDetectsRestoredActiveJob() async throws {
        _ = try await tool.execute(args: ["action": "start", "vault": "default"])
        let originalID = try XCTUnwrap(service.activeSession?.id)
        VaultRegistry.shared.reloadUserManifests()
        let restored = FieldSessionService(sessionsRoot: root)
        let restoredTool = FieldSessionTool(service: restored)
        XCTAssertEqual(restored.activeSession?.vaultId, lennox.id)
        let result = try await restoredTool.execute(args: ["action": "start", "vault": "default"])
        XCTAssertEqual(restored.activeSession?.id, originalID)
        XCTAssertTrue(result.contains("No new session was started"))
        XCTAssertTrue(result.contains(lennox.name))
        XCTAssertEqual(Config.fieldAssistDefaultVaultId, lennox.id)
    }

    func testStatusDistinguishesActiveVaultAndDefault() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let result = try await tool.execute(args: ["action": "status"])
        XCTAssertTrue(result.contains("Active session: Refrigeration Service [refrigeration]"))
        XCTAssertTrue(result.contains("Configured default for new jobs: \(lennox.name) [\(lennox.id)]"))
    }

    func testVaultDiscoveryIncludesCustomDefault() async throws {
        let result = try await tool.execute(args: ["action": "vaults"])
        XCTAssertTrue(result.contains("\(lennox.name) [\(lennox.id)]"))
        XCTAssertTrue(result.contains("Configured default for new jobs:"))
        XCTAssertNil(service.activeSession)
    }

    func testAmbiguousNamesRequireExactID() throws {
        let duplicate = VaultManifest(id: "other", name: lennox.name, version: "1", files: [])
        XCTAssertThrowsError(try VaultSelection.resolve(lennox.name, defaultId: lennox.id,
                                                       manifests: [lennox, duplicate]))
        XCTAssertEqual(try VaultSelection.resolve(duplicate.id, defaultId: lennox.id,
                                                  manifests: [lennox, duplicate]), duplicate.id)
    }

    func testPartialNamesAndPunctuationDoNotGuess() {
        for value in ["Lennox", "furnace", "!!!"] {
            XCTAssertThrowsError(try VaultSelection.resolve(value, defaultId: lennox.id, manifests: [lennox]))
        }
    }

    func testNormalizedIDCollisionRequiresExactID() {
        let a = VaultManifest(id: "a-b", name: "First", version: "1", files: [])
        let b = VaultManifest(id: "a_b", name: "Second", version: "1", files: [])
        XCTAssertThrowsError(try VaultSelection.resolve("A B", defaultId: a.id, manifests: [a, b]))
    }

    func testMissingDefaultCannotResolveViaDisplayName() {
        let renamed = VaultManifest(id: "other", name: "removed_vault", version: "1", files: [])
        XCTAssertThrowsError(try VaultSelection.resolve(nil, defaultId: "removed_vault", manifests: [renamed]))
    }
}
