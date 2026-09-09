import XCTest
@testable import OpenGlasses

/// W05.1 — authorization and durability for the medical-compliance audit log.
///
/// `MedicalComplianceTests` covers mode transitions and clearing behaviour. These tests cover the
/// two things it could not: that clearing is authorized at all, and that the log survives the
/// storage failures an audit record has to survive — a restart, a write refused because protected
/// data is locked, and a writer that commits only part of a record.
@MainActor
final class AuditLogIntegrityTests: XCTestCase {

    // MARK: - Doubles

    /// All-or-nothing in-memory store, matching the production contract.
    private final class InMemoryAuditLogStore: AuditLogStore {
        var stored: Data?
        var quarantined: Data?
        var quarantineCount = 0
        /// When set, `save` throws instead of committing.
        var saveError: Error?

        struct ProtectedDataUnavailable: Error {}

        var protectedFileURL: URL? { nil }

        func load() throws -> Data? { stored }

        func save(_ data: Data) throws {
            if let saveError { throw saveError }
            stored = data
        }

        func quarantineUnreadable() throws {
            quarantineCount += 1
            quarantined = stored
            stored = nil
        }
    }

    /// A deliberately non-atomic writer: it commits the first half of the bytes and then fails.
    /// Production must never behave this way; the double exists to prove the service does not
    /// present the result of such a writer as a complete log.
    private final class PartialWriteAuditLogStore: AuditLogStore {
        var stored: Data?
        var quarantined: Data?
        var quarantineCount = 0
        var failsPartway = false

        struct TornWrite: Error {}

        var protectedFileURL: URL? { nil }

        func load() throws -> Data? { stored }

        func save(_ data: Data) throws {
            guard failsPartway else {
                stored = data
                return
            }
            stored = data.prefix(data.count / 2)
            throw TornWrite()
        }

        func quarantineUnreadable() throws {
            quarantineCount += 1
            quarantined = stored
            stored = nil
        }
    }

    private var originalMode: Bool = false
    /// Isolated from the production keychain checkpoint so these tests neither read nor leave a
    /// checkpoint that another suite's audit file would then disagree with.
    private let checkpoints = InMemoryAuditCheckpointStore()

    override func setUp() {
        super.setUp()
        originalMode = Config.hipaaMode
        Config.hipaaMode = true
    }

    override func tearDown() {
        Config.hipaaMode = originalMode
        super.tearDown()
    }

    private func actions(_ service: HIPAAComplianceService) -> [String] {
        service.auditLog.map(\.action)
    }

    // MARK: - Authorization

    func testGrantedClearRemovesHistoryAndRecordsTheClear() {
        let store = InMemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service.log(action: "BEFORE_CLEAR", detail: "should go away")

        XCTAssertEqual(service.clearAuditLog(authorization: .granted), .cleared)

        XCTAssertEqual(actions(service), ["AUDIT_LOG_CLEARED"])
        XCTAssertNil(service.lastPersistenceFailure)
    }

    func testDeniedClearKeepsHistoryAndRecordsTheRefusal() {
        let store = InMemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service.log(action: "BEFORE_CLEAR", detail: "must survive an unauthorized attempt")

        XCTAssertEqual(service.clearAuditLog(authorization: .denied), .refused(.denied))

        XCTAssertEqual(actions(service), ["BEFORE_CLEAR", "AUDIT_CLEAR_REFUSED"])
        XCTAssertEqual(service.auditLog.last?.decision, .denied)
        XCTAssertEqual(service.auditLog.last?.result, .refused)
    }

    func testUnavailableAuthorizationRefusesRatherThanFallingOpen() {
        let store = InMemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service.log(action: "BEFORE_CLEAR", detail: "no decision is not a grant")

        XCTAssertEqual(service.clearAuditLog(authorization: .unavailable), .refused(.unavailable))

        XCTAssertEqual(actions(service), ["BEFORE_CLEAR", "AUDIT_CLEAR_REFUSED"])
        XCTAssertEqual(service.auditLog.last?.decision, .unavailable)
        XCTAssertEqual(service.auditLog.last?.result, .refused)
    }

    func testRefusalIsRecordedEvenWhenComplianceModeIsOff() {
        Config.hipaaMode = false
        let store = InMemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        XCTAssertEqual(service.clearAuditLog(authorization: .denied), .refused(.denied))

        XCTAssertEqual(actions(service), ["AUDIT_CLEAR_REFUSED"],
                       "an attempt to destroy the log is a control event about the log itself")
    }

    func testRefusalRecordSurvivesARestart() {
        let store = InMemoryAuditLogStore()
        var service: HIPAAComplianceService? = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service?.log(action: "BEFORE_CLEAR", detail: "kept")
        _ = service?.clearAuditLog(authorization: .unavailable)
        service = nil

        let reloaded = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        XCTAssertEqual(actions(reloaded), ["BEFORE_CLEAR", "AUDIT_CLEAR_REFUSED"])
    }

    func testDestructiveAuthorizationFailsClosedWhileTheSimpleModeGateStillFailsOpen() {
        // F12 (the Simple Mode gate failing open with no device authentication) is a separate task
        // and is deliberately left alone; the destructive path takes the opposite default.
        XCTAssertFalse(OwnerAuthorization.unavailable.isGranted)
        XCTAssertFalse(OwnerAuthorization.denied.isGranted)
        XCTAssertTrue(OwnerAuthorization.granted.isGranted)
        XCTAssertTrue(OwnerGatePolicy.grantWithoutPrompt(authAvailable: false))
    }

    // MARK: - Durability

    func testAuditLogContinuesAcrossARestartOverTheSameStore() {
        let store = InMemoryAuditLogStore()
        var service: HIPAAComplianceService? = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertTrue(service!.log(action: "FIRST", detail: "before restart"))
        service = nil

        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertEqual(actions(restarted), ["FIRST"])
        XCTAssertTrue(restarted.log(action: "SECOND", detail: "after restart"))

        let restartedAgain = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertEqual(actions(restartedAgain), ["FIRST", "SECOND"],
                       "a restart must append to the existing log, not begin a new one")
    }

    func testLockedStorageKeepsThePreviousLogAndReportsTheFailure() throws {
        let store = InMemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertTrue(service.log(action: "PERSISTED", detail: "written while unlocked"))
        let persistedBefore = try XCTUnwrap(store.stored)

        store.saveError = InMemoryAuditLogStore.ProtectedDataUnavailable()
        XCTAssertFalse(service.log(action: "WHILE_LOCKED", detail: "must not look recorded"),
                       "a write the store refused must be reported, not swallowed")

        XCTAssertEqual(service.lastPersistenceFailure, .save)
        XCTAssertEqual(actions(service), ["PERSISTED"],
                       "the in-memory log must not keep an entry that never reached storage")
        XCTAssertEqual(store.stored, persistedBefore)

        store.saveError = nil
        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertEqual(actions(restarted), ["PERSISTED"])
    }

    func testATornWriteIsNeverPresentedAsACompleteLog() {
        let store = PartialWriteAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertTrue(service.log(action: "FIRST", detail: "committed"))
        XCTAssertTrue(service.log(action: "SECOND", detail: "committed"))

        store.failsPartway = true
        XCTAssertFalse(service.log(action: "TORN", detail: "half written"))
        XCTAssertEqual(service.lastPersistenceFailure, .save)
        XCTAssertEqual(actions(service), ["FIRST", "SECOND"])

        // Reloading the truncated bytes must not silently yield an empty or partial log: the
        // unreadable bytes are quarantined and the failure is reported.
        store.failsPartway = false
        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertEqual(restarted.lastPersistenceFailure, .load)
        XCTAssertTrue(restarted.auditLog.isEmpty)
        XCTAssertEqual(store.quarantineCount, 1)
        XCTAssertNotNil(store.quarantined, "unreadable evidence is kept, not overwritten")

        XCTAssertTrue(restarted.log(action: "AFTER_RECOVERY", detail: "new log"))
        XCTAssertNotNil(store.quarantined, "a later append must not reclaim the quarantined bytes")
    }

    func testProductionFileStoreCommitsAtomicallyAndKeepsThePreviousLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditLogIntegrityTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("hipaa_audit_log.json")
        let store = FileAuditLogStore(url: url)
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertTrue(service.log(action: "PERSISTED", detail: "written while writable"))
        let bytesBefore = try Data(contentsOf: url)

        // A read-only directory blocks the temporary file `.atomic` writes through, which is the
        // mechanism that makes the commit all-or-nothing.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertFalse(service.log(action: "BLOCKED", detail: "must not reach the file"))
        XCTAssertEqual(service.lastPersistenceFailure, .save)

        XCTAssertEqual(try Data(contentsOf: url), bytesBefore,
                       "a failed write must leave the previous log byte-identical")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        let restarted = HIPAAComplianceService(store: FileAuditLogStore(url: url), checkpoints: checkpoints)
        XCTAssertEqual(actions(restarted), ["PERSISTED"])
        XCTAssertNil(restarted.lastPersistenceFailure)
    }
}
