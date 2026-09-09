import XCTest
@testable import OpenGlasses

/// W05.2 — the typed audit-event schema.
///
/// The old record was `action: String` plus `detail: String`, which meant a filename, a clinical
/// value or a credential reached compliance evidence simply by being passed in. These tests pin
/// the replacement: a closed vocabulary, classes instead of identities, fingerprints instead of
/// text, and a migration that carries the history forward without carrying its prose.
@MainActor
final class AuditEventSchemaTests: XCTestCase {

    /// Exactly the keys a stored event may have. A new field has to be added here deliberately,
    /// which is the point: the failure mode this schema exists to prevent is a helpful-looking
    /// string field appearing in a later change.
    private static let permittedEventKeys: Set<String> = [
        "eventID", "at", "kind", "actorClass", "targetClass", "purpose", "policyVersion",
        "result", "correlationID", "decision", "count", "subjectDigest", "legacyAction",
        "detailFingerprint",
    ]

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

    private func keys(of event: AuditEvent) throws -> Set<String> {
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - Vocabulary

    func testEveryKindHasAUniqueStableToken() {
        let tokens = AuditEventKind.allCases.map(\.auditToken)
        XCTAssertEqual(Set(tokens).count, tokens.count, "two kinds share a token")
        for token in tokens {
            XCTAssertFalse(token.isEmpty)
            XCTAssertEqual(token, token.uppercased(), "\(token) is not an operation token")
        }
    }

    func testAStoredEventCarriesOnlySchemaFields() throws {
        let event = AuditEvent(kind: .clinicalExport, actorClass: .wearer, targetClass: .export,
                               purpose: .treatment, result: .succeeded, decision: .granted,
                               count: 3, subject: "report.pdf", correlation: "invocation-42")
        let stored = try keys(of: event)
        XCTAssertTrue(stored.isSubset(of: Self.permittedEventKeys),
                      "unexpected field: \(stored.subtracting(Self.permittedEventKeys))")
    }

    func testPurposeComesFromAClosedVocabularyAndAnUnknownOneIsDropped() throws {
        let event = AuditEvent(kind: .clinicalExport, targetClass: .export, purpose: .treatment)
        XCTAssertEqual(event.purpose, AuditPurpose.treatment.rawValue)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(event)) as? [String: Any])
        object["purpose"] = "because the doctor asked about the biopsy"
        let decoded = try JSONDecoder().decode(
            AuditEvent.self, from: try JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.purpose, "a value from outside the vocabulary means nothing to a reviewer")
    }

    // MARK: - Free-text slots are not free text

    func testACorrelationValueIsStoredOnlyAsAFingerprint() {
        let event = AuditEvent(kind: .transcriptSaved, targetClass: .transcript,
                               correlation: PrivacyCanary.secret)

        XCTAssertEqual(event.correlationID, AuditFingerprint.of(PrivacyCanary.secret))
        XCTAssertNotEqual(event.correlationID, PrivacyCanary.secret)
    }

    func testASentenceInTheActionSlotIsFingerprintedNotStored() {
        let event = AuditEvent(kind: .legacy, targetClass: .auditLog,
                               action: PrivacyCanary.medication, detail: PrivacyCanary.transcript)

        XCTAssertEqual(event.legacyAction, AuditFingerprint.of(PrivacyCanary.medication))
        XCTAssertEqual(event.detailFingerprint, AuditFingerprint.of(PrivacyCanary.transcript))
    }

    func testAnOperationTokenSurvivesButAnythingElseDoesNot() {
        XCTAssertEqual(AuditEvent.operationToken("RECORDING_STARTED"), "RECORDING_STARTED")
        for hostile in [PrivacyCanary.secret, PrivacyCanary.person, PrivacyCanary.url,
                        PrivacyCanary.documentTitle, "lowercase_action"] {
            XCTAssertEqual(AuditEvent.operationToken(hostile), AuditFingerprint.of(hostile),
                           "\(hostile) survived the token filter")
        }
    }

    func testNoConstructedEventCarriesACanaryInAnyField() throws {
        let event = AuditEvent(kind: .clinicalExport, actorClass: .wearer, targetClass: .export,
                               purpose: .treatment, subject: PrivacyCanary.documentTitle,
                               correlation: PrivacyCanary.url,
                               action: PrivacyCanary.person, detail: PrivacyCanary.medication)
        let encoded = try String(data: JSONEncoder().encode(event), encoding: .utf8) ?? ""

        XCTAssertFalse(encoded.uppercased().contains(PrivacyCanary.stem),
                       "a canary reached a stored field:\n\(encoded)")
        XCTAssertFalse(event.summary.uppercased().contains(PrivacyCanary.stem),
                       "a canary reached the rendered summary: \(event.summary)")
    }

    // MARK: - Migration

    func testALegacyRowKeepsItsIdentityAndLosesItsProse() throws {
        let id = UUID()
        let row = """
        [{"id":"\(id.uuidString)","timestamp":760000000.25,"action":"RECORDING_STOPPED",
          "detail":"\(PrivacyCanary.medication)"}]
        """
        let decoded = try JSONDecoder().decode([AuditEvent].self, from: Data(row.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].eventID, id)
        XCTAssertEqual(decoded[0].kind, .legacy)
        XCTAssertEqual(decoded[0].action, "RECORDING_STOPPED")
        XCTAssertEqual(decoded[0].at.timeIntervalSinceReferenceDate, 760000000.25, accuracy: 0.001)
        XCTAssertEqual(decoded[0].detailFingerprint, AuditFingerprint.of(PrivacyCanary.medication))
        XCTAssertNil(decoded[0].purpose)
    }

    func testATypedEventRoundTripsUnchanged() throws {
        let event = AuditEvent(kind: .retentionPurgeCompleted, actorClass: .system,
                               targetClass: .transcript, purpose: .retentionPolicy,
                               result: .succeeded, count: 12, subject: "old.m4a",
                               correlation: "sweep-1")
        let decoded = try JSONDecoder().decode(AuditEvent.self,
                                               from: try JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
    }

    // MARK: - The bridge

    func testTheLegacyBridgeLandsKnownActionsInTheTypedVocabulary() {
        let expected: [String: AuditEventKind] = [
            "COMPLIANCE_ENABLED": .complianceModeEnabled,
            "COMPLIANCE_DISABLED": .complianceModeDisabled,
            "APP_LAUNCHED": .appLaunched,
            "RECORDING_STARTED": .recordingStarted,
            "RECORDING_STOPPED": .recordingStopped,
            "TRANSCRIPT_SAVED": .transcriptSaved,
            "FHIR_EXPORT": .clinicalExport,
            "EXPORT_LEASE_CREATED": .exportCreated,
            "EXPORT_SHARE_COMPLETED": .exportReleased,
            "EXPORT_REVOKED": .exportReleased,
            "AUTO_PURGE": .retentionPurgeCompleted,
            "SOMETHING_WE_DO_NOT_NAME": .legacy,
        ]
        for (action, kind) in expected {
            XCTAssertEqual(HIPAAComplianceService.mapping(forLegacyAction: action).kind, kind,
                           "\(action) mapped to the wrong kind")
        }
    }

    func testTheBridgeKeepsTheCallersTokenSoAReviewerReadsTheSameSpelling() {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service.log(action: "RECORDING_STARTED", detail: "Video+audio recording started")

        XCTAssertEqual(service.auditLog.map(\.kind), [.recordingStarted])
        XCTAssertEqual(service.auditLog.map(\.action), ["RECORDING_STARTED"])
        XCTAssertNil(service.auditLog.first?.purpose)
    }

    func testModeTransitionsAndRetentionPurgesAreTypedNotLegacy() {
        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        service.setMode(true)
        service.setMode(false)

        XCTAssertEqual(service.auditLog.map(\.kind),
                       [.complianceModeEnabled, .complianceModeDisabled])
        XCTAssertEqual(service.auditLog.map(\.targetClass), [.complianceMode, .complianceMode])
        XCTAssertEqual(service.auditLog.map(\.actorClass), [.owner, .owner])
        XCTAssertTrue(service.auditLog.allSatisfy { $0.policyVersion == AuditPolicyVersion.current })
    }

    func testARetentionPurgeRecordsACountAndNoFilenames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditPurge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let victim = directory.appendingPathComponent("2019-03-01 biopsy.m4a")
        try Data("x".utf8).write(to: victim)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -100 * 24 * 3600)],
            ofItemAtPath: victim.path)

        let store = MemoryAuditLogStore()
        let service = HIPAAComplianceService(store: store, checkpoints: checkpoints)
        Config.setTranscriptFolderURL(directory)
        let previousRetention = Config.hipaaRetentionDays
        defer {
            Config.clearTranscriptFolder()
            Config.hipaaRetentionDays = previousRetention
        }
        Config.hipaaRetentionDays = 30
        service.enforceRetentionPolicy()

        let kinds = service.auditLog.map(\.kind)
        XCTAssertTrue(kinds.contains(.filePurged))
        XCTAssertTrue(kinds.contains(.retentionPurgeCompleted))
        let purge = try XCTUnwrap(service.auditLog.first { $0.kind == .retentionPurgeCompleted })
        XCTAssertEqual(purge.count, 1)
        let file = try XCTUnwrap(service.auditLog.first { $0.kind == .filePurged })
        XCTAssertEqual(file.subjectDigest, AuditFingerprint.of("2019-03-01 biopsy.m4a"))
        let encoded = try String(data: JSONEncoder().encode(service.chain), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("biopsy"), "a purged filename reached the audit log")
    }
}
