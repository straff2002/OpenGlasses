import XCTest
import CryptoKit
@testable import OpenGlasses

// MARK: - Shared doubles

/// The checkpoint, held in memory. The production home is the keychain, which a suite must not
/// share with another suite's audit file — and which a headless run cannot rely on at all.
final class InMemoryAuditCheckpointStore: AuditCheckpointStore {
    private let key = SymmetricKey(size: .bits256)
    private(set) var stored: AuditCheckpoint?
    var saveError: Error?
    var loadError: Error?
    private(set) var saveCount = 0

    func load() throws -> AuditCheckpoint? {
        if let loadError { throw loadError }
        return stored
    }

    func save(sequence: Int, headDigest: String, at: Date) throws {
        if let saveError { throw saveError }
        saveCount += 1
        stored = AuditCheckpoint(sequence: sequence, headDigest: headDigest, at: at, key: key)
    }

    func clear() throws {
        if let saveError { throw saveError }
        stored = nil
    }

    /// Seal a checkpoint of our own — for the "someone put an older one back" cases.
    func plant(sequence: Int, headDigest: String, at: Date = Date()) {
        stored = AuditCheckpoint(sequence: sequence, headDigest: headDigest, at: at, key: key)
    }
}

/// All-or-nothing in-memory audit store whose bytes a test can inspect and rewrite, which is what
/// makes an on-disk tamper reproducible without a filesystem.
final class MemoryAuditLogStore: AuditLogStore {
    var stored: Data?
    private(set) var quarantined: Data?
    var saveError: Error?

    var protectedFileURL: URL? { nil }

    func load() throws -> Data? { stored }

    func save(_ data: Data) throws {
        if let saveError { throw saveError }
        stored = data
    }

    func quarantineUnreadable() throws {
        quarantined = stored
        stored = nil
    }
}

/// W05.3 — sequence-and-digest chaining, and the checkpoint that catches what chaining alone
/// cannot.
///
/// The pure verifier is exercised directly, and then wired through the service so the verdict a
/// reviewer would actually see on launch is the one under test.
@MainActor
final class AuditChainIntegrityTests: XCTestCase {

    private var originalMode = false
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

    // MARK: - Fixtures

    private func event(_ kind: AuditEventKind, at seconds: TimeInterval) -> AuditEvent {
        AuditEvent(kind: kind, targetClass: .auditLog,
                   at: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func chainOfThree() -> [AuditChainedEvent] {
        AuditChain.rebuild([event(.complianceModeEnabled, at: 1),
                            event(.transcriptSaved, at: 2),
                            event(.complianceModeDisabled, at: 3)])
    }

    /// Round-trip through JSON, so what is verified is what a reload would actually hold —
    /// including each record's stored digest.
    private func reloaded(_ chain: [AuditChainedEvent]) throws -> [AuditChainedEvent] {
        try HIPAAComplianceService.decodeChain(from: try JSONEncoder().encode(chain))
    }

    // MARK: - The verifier

    func testACleanChainVerifiesIntact() throws {
        XCTAssertEqual(AuditChain.verify(events: try reloaded(chainOfThree()), checkpoint: nil),
                       .intact)
    }

    func testAlteringARecordBreaksTheChain() throws {
        var chain = try reloaded(chainOfThree())
        // Same position, same links, different content: only the digest disagrees.
        chain[1] = AuditChainedEvent(sequence: chain[1].sequence, prevDigest: chain[1].prevDigest,
                                     event: event(.fileSecurelyDeleted, at: 2))

        XCTAssertEqual(AuditChain.verify(events: chain, checkpoint: nil), .broken(at: 2))
    }

    func testAlteringTheLastRecordIsCaughtByItsOwnStoredDigest() throws {
        // Edited in the stored JSON, leaving the written digest as it was — nothing follows the
        // last record, so its own digest is all that is left to disagree with it.
        let data = try JSONEncoder().encode(chainOfThree())
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var last = try XCTUnwrap(rows[2]["event"] as? [String: Any])
        last["result"] = AuditResult.failed.rawValue
        rows[2]["event"] = last

        let tampered = try HIPAAComplianceService.decodeChain(
            from: try JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(AuditChain.verify(events: tampered, checkpoint: nil), .broken(at: 2))
    }

    func testDeletingARecordFromTheMiddleBreaksTheChain() throws {
        var chain = try reloaded(chainOfThree())
        chain.remove(at: 1)

        XCTAssertEqual(AuditChain.verify(events: chain, checkpoint: nil), .broken(at: 2))
    }

    func testReorderingRecordsBreaksTheChain() throws {
        var chain = try reloaded(chainOfThree())
        chain.swapAt(1, 2)

        XCTAssertEqual(AuditChain.verify(events: chain, checkpoint: nil), .broken(at: 2))
    }

    func testDeletingTheWholeLogIsDetectedAsTruncated() throws {
        let chain = try reloaded(chainOfThree())
        checkpoints.plant(sequence: chain[2].sequence, headDigest: chain[2].digest)

        XCTAssertEqual(AuditChain.verify(events: [], checkpoint: try checkpoints.load()),
                       .truncated(expectedCount: 3))
    }

    func testRollingTheLogBackToAnEarlierValidPrefixIsDetected() throws {
        let chain = try reloaded(chainOfThree())
        checkpoints.plant(sequence: chain[2].sequence, headDigest: chain[2].digest)

        // A perfectly self-consistent log — it is simply an older copy of this one.
        let prefix = Array(chain.prefix(2))
        XCTAssertEqual(AuditChain.verify(events: prefix, checkpoint: nil), .intact,
                       "the prefix is internally valid, which is exactly why chaining alone misses it")
        XCTAssertEqual(AuditChain.verify(events: prefix, checkpoint: try checkpoints.load()),
                       .rolledBack)
    }

    func testAlteringAPrefixTheCheckpointCertifiedIsBrokenNotMerelyRolledBack() throws {
        let chain = try reloaded(chainOfThree())
        checkpoints.plant(sequence: chain[1].sequence, headDigest: chain[1].digest)
        var tampered = chain
        tampered[1] = AuditChainedEvent(sequence: chain[1].sequence, prevDigest: chain[1].prevDigest,
                                        event: event(.fileSecurelyDeleted, at: 2))

        // Re-linked so the chain itself is consistent again — the checkpoint is the only witness.
        let relinked = AuditChain.rebuild(tampered.map(\.event))
        XCTAssertEqual(AuditChain.verify(events: relinked, checkpoint: nil), .intact)
        XCTAssertEqual(AuditChain.verify(events: relinked, checkpoint: try checkpoints.load()),
                       .broken(at: 1))
    }

    func testNoCheckpointOnFirstRunIsIntactRatherThanSuspicious() throws {
        XCTAssertNil(try checkpoints.load())
        XCTAssertEqual(AuditChain.verify(events: try reloaded(chainOfThree()),
                                         checkpoint: try checkpoints.load()), .intact)
    }

    func testARetentionTrimmedSuffixStillVerifies() throws {
        let chain = try reloaded(chainOfThree())
        let suffix = Array(chain.suffix(2))
        checkpoints.plant(sequence: chain[2].sequence, headDigest: chain[2].digest)

        XCTAssertEqual(AuditChain.verify(events: suffix, checkpoint: try checkpoints.load()),
                       .intact, "trimming the oldest records is retention, not tampering")
    }

    func testACheckpointSealIsRejectedWhenItsFieldsAreEdited() {
        let key = SymmetricKey(size: .bits256)
        let checkpoint = AuditCheckpoint(sequence: 7, headDigest: "abc", at: Date(), key: key)
        XCTAssertTrue(checkpoint.isSealed(with: key))

        let forged = AuditCheckpoint(sequence: 3, headDigest: "abc", at: checkpoint.at,
                                     key: SymmetricKey(size: .bits256))
        XCTAssertFalse(forged.isSealed(with: key),
                       "a checkpoint sealed with another key must not pass as this device's")
    }

    // MARK: - Wired through the service

    func testARestartOverACleanLogReportsIntactAndRecordsNothingExtra() {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service.log(action: "FIRST", detail: "kept")
        service.log(action: "SECOND", detail: "kept")

        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        XCTAssertEqual(restarted.lastIntegrityVerdict, .intact)
        XCTAssertEqual(restarted.auditLog.map(\.action), ["FIRST", "SECOND"],
                       "an intact log must not grow an 'all fine' row on every launch")
    }

    func testATamperedLogIsReportedAndTheFindingIsRecordedNextToIt() throws {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        for index in 0..<3 { service.log(action: "EVENT_\(index)", detail: "kept") }

        // Edit the persisted bytes the way an attacker with the file would.
        var chain = try HIPAAComplianceService.decodeChain(from: XCTUnwrap(store.stored))
        chain[1] = AuditChainedEvent(sequence: chain[1].sequence, prevDigest: chain[1].prevDigest,
                                     event: AuditEvent(kind: .legacy, targetClass: .auditLog,
                                                       action: "REWRITTEN"))
        store.stored = try JSONEncoder().encode(chain)

        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        // The edited record's own digest was recomputed with it; the record *after* it still
        // points at what used to be there, which is the link that gives the edit away.
        XCTAssertEqual(restarted.lastIntegrityVerdict, .broken(at: 2))
        XCTAssertEqual(restarted.auditLog.map(\.kind).last, .integrityCheck)
        XCTAssertEqual(restarted.auditLog.last?.result, .failed)
        XCTAssertEqual(restarted.auditLog.count, 4,
                       "the damaged records are kept as found; the finding is appended, not merged")
        XCTAssertEqual(restarted.auditLog[1].action, "REWRITTEN",
                       "repairing the log would destroy the evidence")
    }

    func testDeletingTheStoredLogOutrightIsReportedAsTruncatedOnTheNextLaunch() {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        for index in 0..<20 { service.log(action: "EVENT_\(index)", detail: "kept") }
        XCTAssertNotNil(checkpoints.stored, "the interval checkpoint must have been written")

        store.stored = nil  // the file is simply gone
        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        guard case .truncated(let expected) = restarted.lastIntegrityVerdict else {
            return XCTFail("expected a truncation, got \(restarted.lastIntegrityVerdict)")
        }
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(restarted.auditLog.map(\.kind), [.integrityCheck])
    }

    func testACheckpointNewerThanTheLogIsReportedAsARollback() throws {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        for index in 0..<20 { service.log(action: "EVENT_\(index)", detail: "kept") }
        let snapshot = try XCTUnwrap(store.stored)
        for index in 20..<40 { service.log(action: "LATER_\(index)", detail: "kept") }

        // Put the earlier — and internally valid — copy back.
        store.stored = snapshot
        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        XCTAssertEqual(restarted.lastIntegrityVerdict, .rolledBack)
        XCTAssertEqual(restarted.auditLog.last?.kind, .integrityCheck)
    }

    func testAnAuthorizedClearIsNotMistakenForARollback() {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        for index in 0..<20 { service.log(action: "EVENT_\(index)", detail: "kept") }

        XCTAssertEqual(service.clearAuditLog(authorization: .granted), .cleared)
        let restarted = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        XCTAssertEqual(restarted.lastIntegrityVerdict, .intact,
                       "clearing continues the sequence rather than restarting it")
        XCTAssertEqual(restarted.auditLog.map(\.kind), [.auditClearGranted])
    }

    func testAPreSchemaLogIsMigratedIntoTheChainWithoutLookingTampered() throws {
        // Exactly what the previous version wrote: an array of free-text entries.
        let legacy = """
        [{"id":"\(UUID().uuidString)","timestamp":760000000.5,"action":"COMPLIANCE_ENABLED",
          "detail":"Medical compliance mode enabled"},
         {"id":"\(UUID().uuidString)","timestamp":760000001.5,"action":"RECORDING_STARTED",
          "detail":"Video+audio recording started"}]
        """
        let store = MemoryAuditLogStore()
        store.stored = Data(legacy.utf8)

        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        XCTAssertEqual(service.lastIntegrityVerdict, .intact)
        XCTAssertEqual(service.auditLog.prefix(2).map(\.action),
                       ["COMPLIANCE_ENABLED", "RECORDING_STARTED"])
        XCTAssertEqual(service.auditLog.prefix(2).map(\.kind), [.legacy, .legacy])
        XCTAssertEqual(service.auditLog[0].detailFingerprint,
                       AuditFingerprint.of("Medical compliance mode enabled"))
        XCTAssertEqual(service.chain.map(\.sequence), Array(0..<service.chain.count))
        // The policy revision changed underneath the migrated rows, and that is itself an event.
        XCTAssertEqual(service.auditLog.last?.kind, .policyVersionChanged)
    }

    func testAnUnavailableCheckpointIsReportedRatherThanTreatedAsAbsent() {
        let store = MemoryAuditLogStore()
        checkpoints.loadError = AuditCheckpointFault.unavailable

        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)

        XCTAssertEqual(service.lastCheckpointFault, .unavailable)
        XCTAssertEqual(service.lastIntegrityVerdict, .intact,
                       "with no checkpoint to compare against there is nothing to accuse")
    }
}
