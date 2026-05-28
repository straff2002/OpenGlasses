import XCTest
@testable import OpenGlasses

/// Lifecycle and audit-log tests for FieldSessionService + SessionLogger.
///
/// These tests run against a temporary sessions root and use the bundled refrigeration vault
/// (with the developer-unlock flag set) so they exercise the real VaultRegistry gating path.
@MainActor
final class FieldSessionServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var service: FieldSessionService!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldSessionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistDeveloperUnlocked")
        VaultRegistry.shared.resetCache()

        service = FieldSessionService(sessionsRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "fieldAssistDeveloperUnlocked")
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
        UserDefaults.standard.set(false, forKey: "fieldAssistDeveloperUnlocked")
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
