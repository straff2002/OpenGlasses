import XCTest
@testable import OpenGlasses

/// W05.4 (repo part) — the audit log leaves the app only as a protected, backup-excluded,
/// TTL-bound file, and the trail records that it left by digest rather than by content.
///
/// The review, alerting and escalation half of W05.4 is a deployment procedure, not code; what is
/// testable here is that the evidence handed to a reviewer is protected on the way out and that
/// producing it is itself an audited event.
@MainActor
final class AuditExportProtectionTests: XCTestCase {

    /// The only keys an exported record may carry, so "typed all the way down" is checked against
    /// the bytes a reviewer receives rather than against the in-memory type.
    private static let permittedEventKeys: Set<String> = [
        "eventID", "at", "kind", "actorClass", "targetClass", "purpose", "policyVersion",
        "result", "correlationID", "decision", "count", "subjectDigest", "legacyAction",
        "detailFingerprint",
    ]

    private var originalMode = false
    private var root: URL!
    private var exportStore: ProtectedExportFileStore!
    private let checkpoints = InMemoryAuditCheckpointStore()

    override func setUp() {
        super.setUp()
        originalMode = Config.hipaaMode
        Config.hipaaMode = true
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditExportTests-\(UUID())", isDirectory: true)
        exportStore = ProtectedExportFileStore(rootDirectoryName: "AuditExportTests", root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        Config.hipaaMode = originalMode
        super.tearDown()
    }

    private func makeService() -> HIPAAComplianceService {
        HIPAAComplianceService(store: MemoryAuditLogStore(), checkpoints: checkpoints,
                               exportStore: exportStore)
    }

    // MARK: - The protected route

    func testTheExportLandsInAProtectedSessionUnderTheExportRoot() throws {
        let service = makeService()
        service.log(action: "RECORDING_STARTED", detail: "kept")

        let export = try service.exportProtectedAuditLog()

        XCTAssertTrue(ProtectedExportFileStore.isContained(export.fileURL, within: root),
                      "the export escaped its session root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: export.session.directory.appendingPathComponent(".complete").path),
                      "the session is only complete once the finished file is protected")
        let values = try export.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTheExportEventRecordsTheDigestOfTheBytesAndNotTheirContent() throws {
        let service = makeService()
        service.log(action: "TRANSCRIPT_SAVED", detail: "kept")

        let export = try service.exportProtectedAuditLog()
        let written = try Data(contentsOf: export.fileURL)

        XCTAssertEqual(export.digest, AuditFingerprint.of(written))
        let record = try XCTUnwrap(service.auditLog.last)
        XCTAssertEqual(record.kind, .auditExportCreated)
        XCTAssertEqual(record.targetClass, .export)
        XCTAssertEqual(record.actorClass, .owner)
        XCTAssertEqual(record.subjectDigest, export.digest)
        XCTAssertEqual(record.count, export.entryCount)
        XCTAssertNil(record.detailFingerprint, "there was no detail string to fingerprint")
    }

    func testTheExportedDocumentContainsOnlyTypedFields() throws {
        let service = makeService()
        service.log(action: "RECORDING_STOPPED", detail: PrivacyCanary.medication)
        service.record(.clinicalExport, target: .export, purpose: .treatment,
                       subject: PrivacyCanary.documentTitle, correlation: PrivacyCanary.secret)

        let export = try service.exportProtectedAuditLog()
        let text = try String(contentsOf: export.fileURL, encoding: .utf8)

        XCTAssertFalse(text.uppercased().contains(PrivacyCanary.stem),
                       "a canary reached the exported evidence:\n\(text)")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8))
                                    as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, AuditLogExportDocument.currentSchema)
        XCTAssertEqual(object["policyVersion"] as? String, AuditPolicyVersion.current)
        XCTAssertEqual(object["integrity"] as? String, AuditChainVerification.intact.auditToken)
        let rows = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(Set(row.keys), ["sequence", "prevDigest", "digest", "event"])
            let event = try XCTUnwrap(row["event"] as? [String: Any])
            XCTAssertTrue(Set(event.keys).isSubset(of: Self.permittedEventKeys),
                          "unexpected exported field: \(Set(event.keys).subtracting(Self.permittedEventKeys))")
        }
    }

    func testAnExportedChainCanBeReWalkedOutsideTheApp() throws {
        let service = makeService()
        for index in 0..<4 { service.log(action: "EVENT_\(index)", detail: "kept") }

        let export = try service.exportProtectedAuditLog()
        let document = try JSONDecoder().decode(AuditLogExportDocument.self,
                                                from: try Data(contentsOf: export.fileURL))

        XCTAssertEqual(AuditChain.verify(events: document.events, checkpoint: nil), .intact)
        XCTAssertEqual(document.headDigest, document.events.last?.digest)
        XCTAssertEqual(document.entryCount, document.events.count)
    }

    // MARK: - The lease ends

    func testReleasingAnExportRemovesItsFilesAndRecordsTheRelease() throws {
        let service = makeService()
        service.log(action: "RECORDING_STARTED", detail: "kept")
        let export = try service.exportProtectedAuditLog()

        service.releaseAuditLogExport(export)

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.session.directory.path))
        let record = try XCTUnwrap(service.auditLog.last)
        XCTAssertEqual(record.kind, .auditExportReleased)
        XCTAssertEqual(record.subjectDigest, export.digest)
    }

    func testAnAbandonedExportIsScavengedWhenTheNextOneIsMade() throws {
        let service = makeService()
        service.log(action: "RECORDING_STARTED", detail: "kept")
        let abandoned = try service.exportProtectedAuditLog()
        // A share that never came back: the process no longer owns the session, and the crash
        // recovery window has passed.
        exportStore.release(id: abandoned.id, directory: abandoned.session.directory)
        try FileManager.default.createDirectory(at: abandoned.session.directory,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: abandoned.session.directory.appendingPathComponent(".complete").path,
            contents: nil)

        let fresh = try service.exportProtectedAuditLog(
            now: Date().addingTimeInterval(ProtectedExportFileStore.completedSessionTTL + 60))

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.session.directory.path),
                       "an export past its window must not survive the next one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.fileURL.path))
    }

    func testAnExportStillInHandIsNotScavengedOutFromUnderTheShare() throws {
        let service = makeService()
        service.log(action: "RECORDING_STARTED", detail: "kept")
        let live = try service.exportProtectedAuditLog()

        _ = try service.exportProtectedAuditLog(
            now: Date().addingTimeInterval(ProtectedExportFileStore.completedSessionTTL + 60))

        XCTAssertTrue(FileManager.default.fileExists(atPath: live.fileURL.path),
                      "a session this process still owns is never scavenged")
    }
}
