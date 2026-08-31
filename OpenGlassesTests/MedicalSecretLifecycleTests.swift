import XCTest
@testable import OpenGlasses

// MARK: - Test doubles

/// In-memory stand-in for the Keychain-backed store. `loadError`/`saveError` let a test drive the
/// locked-device and write-failure paths without depending on the device state.
final class InMemoryFHIRSecretStore: FHIRCredentialStore, FHIRPrivateContextStore {
    var credentials: [String: FHIRCredential] = [:]
    var contexts: [String: FHIRPrivateContext] = [:]
    var loadError: Error?
    var saveError: Error?
    /// When set, saves are accepted but reads return this instead — a store that swallows writes.
    var readBackOverride: FHIRCredential?
    private(set) var deletedCredentialIDs: [String] = []
    private(set) var deletedContextIDs: [String] = []

    func load(serverID: String) throws -> FHIRCredential? {
        if let loadError { throw loadError }
        if let readBackOverride { return readBackOverride }
        return credentials[serverID]
    }

    func save(_ credential: FHIRCredential, serverID: String) throws {
        if let saveError { throw saveError }
        credentials[serverID] = credential.isEmpty ? nil : credential
    }

    func delete(serverID: String) throws {
        credentials[serverID] = nil
        deletedCredentialIDs.append(serverID)
    }

    func loadContext(serverID: String) throws -> FHIRPrivateContext? {
        if let loadError { throw loadError }
        return contexts[serverID]
    }

    func saveContext(_ context: FHIRPrivateContext, serverID: String) throws {
        if let saveError { throw saveError }
        contexts[serverID] = context.isEmpty ? nil : context
    }

    func deleteContext(serverID: String) throws {
        contexts[serverID] = nil
        deletedContextIDs.append(serverID)
    }
}

/// Records every URL the file store asked to protect, and can be told to fail on the directory or
/// on the finished file — the simulator does not reliably report file protection back, so the
/// observable contract is that the applier ran for both, and that a failure removes the session.
final class RecordingProtector: MedicalExportProtecting {
    enum Failure { case none, directory, file }

    private let inner = FileProtectionApplier()
    private(set) var protected: [URL] = []
    var failure: Failure = .none
    /// Apply the real attributes as well, so a test can also inspect what the platform reports.
    var applyRealAttributes = true

    func protect(_ url: URL) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        switch failure {
        case .directory where isDirectory, .file where !isDirectory:
            throw MedicalExportError.exportSetupFailed
        default:
            break
        }
        protected.append(url)
        if applyRealAttributes { try inner.protect(url) }
    }
}

// MARK: - P0: split configuration and credential migration

@MainActor
final class FHIRSecretMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: InMemoryFHIRSecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "FHIRSecretMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemoryFHIRSecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> FHIRConfigurationStore {
        FHIRConfigurationStore(defaults: defaults, credentials: secrets, contexts: secrets)
    }

    /// The shipped legacy encoding, written by hand so the test does not depend on the retired type.
    private func seedLegacyBlob(bearerToken: String = "legacy-token",
                                clientSecret: String = "legacy-secret",
                                patientID: String = "patient-7",
                                practitionerID: String = "dr-legacy") {
        let blob: [String: String] = [
            "baseURL": "https://legacy.example.com/r4",
            "bearerToken": bearerToken,
            "clientId": "client-9",
            "clientSecret": clientSecret,
            "patientId": patientID,
            "practitionerId": practitionerID,
            "platformType": MedicalPlatform.epic.rawValue,
        ]
        defaults.set(try! JSONEncoder().encode(blob), forKey: FHIRConfigurationStore.legacyConfigurationKey)
    }

    func testMigrationMovesSecretsAndRemovesLegacyKey() throws {
        seedLegacyBlob()
        let store = makeStore()

        XCTAssertEqual(store.migrateIfNeeded(), .migrated)

        let config = store.configuration
        XCTAssertEqual(config.baseURL, "https://legacy.example.com/r4")
        XCTAssertEqual(config.platform, .epic)
        XCTAssertEqual(config.clientID, "client-9")
        XCTAssertEqual(try store.loadCredential().bearerToken, "legacy-token")
        XCTAssertEqual(try store.loadCredential().clientSecret, "legacy-secret")
        XCTAssertEqual(try store.loadPrivateContext().patientID, "patient-7")
        XCTAssertEqual(try store.loadPrivateContext().practitionerID, "dr-legacy")

        XCTAssertNil(defaults.data(forKey: FHIRConfigurationStore.legacyConfigurationKey),
                     "legacy blob must not survive a verified migration")
        XCTAssertFalse(store.isMigrationPending)
    }

    func testMigratedSecretsAreAbsentFromPreferences() throws {
        seedLegacyBlob()
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .migrated)

        // Scan the whole preference domain, not just the keys we know about: the point is that no
        // preference anywhere still carries the token, the client secret, or an identifier.
        let dump = defaults.dictionaryRepresentation()
        let rendered = dump.map { "\($0.key)=\(String(describing: $0.value))" }.joined(separator: "\n")
            + (dump.values.compactMap { $0 as? Data }.compactMap { String(data: $0, encoding: .utf8) }.joined())
        for secret in ["legacy-token", "legacy-secret", "patient-7", "dr-legacy"] {
            XCTAssertFalse(rendered.contains(secret), "\(secret) must not remain in preferences")
        }
    }

    func testMigrationIsIdempotent() {
        seedLegacyBlob()
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .migrated)
        XCTAssertEqual(store.migrateIfNeeded(), .notNeeded)
    }

    func testLockedKeychainDefersMigrationAndBlocksSend() {
        seedLegacyBlob()
        secrets.saveError = KeychainService.KeychainError.unavailable(errSecInteractionNotAllowed)
        let store = makeStore()

        XCTAssertEqual(store.migrateIfNeeded(), .deferred)
        XCTAssertNotNil(defaults.data(forKey: FHIRConfigurationStore.legacyConfigurationKey),
                        "a deferred migration must keep the only copy")
        XCTAssertTrue(store.isMigrationPending)

        XCTAssertThrowsError(try store.requestContext()) { error in
            XCTAssertEqual(error as? MedicalExportError, .migrationPending)
        }
    }

    func testDeferredMigrationSucceedsOnRetry() throws {
        seedLegacyBlob()
        secrets.saveError = KeychainService.KeychainError.unavailable(errSecInteractionNotAllowed)
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .deferred)

        secrets.saveError = nil
        XCTAssertEqual(store.migrateIfNeeded(), .migrated)
        XCTAssertEqual(try store.loadCredential().bearerToken, "legacy-token")
    }

    func testFailedVerificationRetainsRecoverabilityWithoutUsingLegacySecret() {
        seedLegacyBlob()
        // The store accepts the write but returns something else — verification must catch it.
        secrets.readBackOverride = FHIRCredential(bearerToken: "not-what-we-wrote")
        let store = makeStore()

        XCTAssertEqual(store.migrateIfNeeded(), .failed)
        XCTAssertNotNil(defaults.data(forKey: FHIRConfigurationStore.legacyConfigurationKey),
                        "a failed migration must keep the legacy value for the retry")
        XCTAssertTrue(store.isMigrationPending)

        // Recoverable, but not usable: the legacy secret must not reach a request.
        XCTAssertThrowsError(try store.requestContext()) { error in
            XCTAssertEqual(error as? MedicalExportError, .migrationPending)
        }
    }

    func testMigrationWithNoLegacyBlobStampsVersion() {
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .notNeeded)
        XCTAssertFalse(store.isMigrationPending)
    }

    func testUndecodableLegacyBlobIsRemoved() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: FHIRConfigurationStore.legacyConfigurationKey)
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .notNeeded)
        XCTAssertNil(defaults.data(forKey: FHIRConfigurationStore.legacyConfigurationKey))
    }

    func testServerIDIsStableAcrossURLChanges() throws {
        seedLegacyBlob()
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .migrated)

        let originalID = store.configuration.serverID
        var config = store.configuration
        config.baseURL = "https://moved.example.com/r4"
        store.save(config)

        XCTAssertEqual(store.configuration.serverID, originalID)
        XCTAssertEqual(try store.loadCredential().bearerToken, "legacy-token",
                       "changing the URL must not orphan the protected values")
    }

    func testServerDeletionClearsBothProtectedStores() throws {
        seedLegacyBlob()
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .migrated)
        let serverID = store.configuration.serverID

        store.deleteServer()

        XCTAssertTrue(secrets.deletedCredentialIDs.contains(serverID))
        XCTAssertTrue(secrets.deletedContextIDs.contains(serverID))
        XCTAssertTrue(secrets.credentials.isEmpty)
        XCTAssertTrue(secrets.contexts.isEmpty)
        XCTAssertNil(defaults.data(forKey: FHIRConfigurationStore.configurationKey))
    }

    func testAuthModeChangeAwayFromSecretAuthClearsCredential() throws {
        let store = makeStore()
        var config = store.configuration
        config.baseURL = "https://fhir.example.com/r4"
        config.authMode = .bearerToken
        store.save(config)
        try store.storeCredential(FHIRCredential(bearerToken: "token"))
        XCTAssertTrue(store.hasStoredCredential())

        store.applyAuthMode(.none)

        XCTAssertFalse(store.hasStoredCredential())
        XCTAssertEqual(store.configuration.authMode, .none)
    }

    func testAuthModeChangeBetweenSecretModesKeepsCredential() throws {
        let store = makeStore()
        try store.storeCredential(FHIRCredential(bearerToken: "token"))
        store.applyAuthMode(.clientSecret)
        XCTAssertTrue(store.hasStoredCredential())
    }

    func testRequestContextRequiresConfiguredServer() {
        let store = makeStore()
        XCTAssertThrowsError(try store.requestContext()) { error in
            XCTAssertEqual(error as? MedicalExportError, .serverNotConfigured)
        }
    }

    func testRequestContextRequiresStoredCredentialForSecretAuth() {
        let store = makeStore()
        var config = store.configuration
        config.baseURL = "https://fhir.example.com/r4"
        config.authMode = .bearerToken
        store.save(config)

        XCTAssertThrowsError(try store.requestContext()) { error in
            XCTAssertEqual(error as? MedicalExportError, .credentialMissing)
        }
    }

    func testLockedKeychainSurfacesAsCredentialLocked() {
        let store = makeStore()
        var config = store.configuration
        config.baseURL = "https://fhir.example.com/r4"
        store.save(config)
        secrets.loadError = KeychainService.KeychainError.unavailable(errSecInteractionNotAllowed)

        XCTAssertThrowsError(try store.requestContext()) { error in
            XCTAssertEqual(error as? MedicalExportError, .credentialLocked)
        }
        XCTAssertFalse(store.hasStoredCredential(),
                       "an unreadable store must not be reported as holding a credential")
    }

    func testPublicConfigurationEncodesNoSecretOrIdentifierFields() throws {
        var config = FHIRServerConfiguration(baseURL: "https://fhir.example.com/r4")
        config.clientID = "client-9"
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys.map { $0 } ?? [])

        XCTAssertEqual(keys, FHIRServerConfiguration.encodedKeys,
                       "the public config's encoded shape is fixed — a new field must be reviewed here")
        for forbidden in ["bearerToken", "clientSecret", "token", "secret", "patientID", "patientId",
                          "practitionerID", "practitionerId"] {
            XCTAssertFalse(keys.contains(forbidden))
        }
    }

    func testCredentialAndContextUseSeparateNamespaces() throws {
        let store = makeStore()
        try store.storeCredential(FHIRCredential(bearerToken: "token"))
        try store.storePrivateContext(FHIRPrivateContext(patientID: "patient-1"))
        let serverID = store.configuration.serverID

        // Distinct dictionaries in the fake mirror distinct Keychain accounts in production: one
        // cannot be returned by a query for the other.
        XCTAssertEqual(secrets.credentials[serverID]?.bearerToken, "token")
        XCTAssertNil(secrets.credentials[serverID]?.clientSecret)
        XCTAssertEqual(secrets.contexts[serverID]?.patientID, "patient-1")
    }

    func testBlankCredentialValuesCollapseToCleared() throws {
        let store = makeStore()
        try store.storeCredential(FHIRCredential(bearerToken: "   "))
        XCTAssertFalse(store.hasStoredCredential())
    }
}

// MARK: - P1: protected export sessions

@MainActor
final class MedicalExportFileStoreTests: XCTestCase {
    private var root: URL!
    private var protector: RecordingProtector!
    private var store: MedicalExportFileStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicalExportFileStoreTests_\(UUID().uuidString)")
        protector = RecordingProtector()
        store = MedicalExportFileStore(root: root, protector: protector)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testEveryFormatLandsUnderTheExportRootWithGenericName() throws {
        for format in ExportFormat.allCases {
            let lease = try store.createLease(data: Data("clinical".utf8), format: format,
                                              displayName: "clinical_transcript.\(format.fileExtension)")
            XCTAssertTrue(MedicalExportFileStore.isContained(lease.fileURL, within: root))
            XCTAssertEqual(lease.sessionDirectory.deletingLastPathComponent().path,
                           root.standardizedFileURL.path)

            // The on-disk name is a UUID plus the extension — nothing about the recording leaks
            // through the filesystem.
            let stem = lease.fileURL.lastPathComponent
                .replacingOccurrences(of: ".\(format.fileExtension)", with: "")
            XCTAssertNotNil(UUID(uuidString: stem), "on-disk name must be a bare UUID, got \(stem)")
            XCTAssertFalse(lease.fileURL.lastPathComponent.contains("clinical"))
            XCTAssertEqual(lease.displayName, "clinical_transcript.\(format.fileExtension)")
            store.release(lease)
        }
    }

    func testProtectionAndBackupExclusionAreApplied() throws {
        let lease = try store.createLease(data: Data("clinical".utf8), format: .plainText,
                                          displayName: "note.txt")
        // The directory is protected before it can hold anything, the file once it is complete.
        XCTAssertTrue(protector.protected.contains { $0.path == lease.sessionDirectory.path })
        XCTAssertTrue(protector.protected.contains { $0.path == lease.fileURL.path })
        XCTAssertLessThan(protector.protected.firstIndex { $0.path == lease.sessionDirectory.path }!,
                          protector.protected.firstIndex { $0.path == lease.fileURL.path }!)

        // Backup exclusion is reported back by the simulator; file protection is not, so assert it
        // only where the platform actually answers.
        for url in [lease.sessionDirectory, lease.fileURL] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, "\(url.lastPathComponent) must be backup-excluded")
        }
        if let protection = try FileManager.default.attributesOfItem(atPath: lease.fileURL.path)[.protectionKey]
            as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
        store.release(lease)
    }

    func testDirectoryAttributeFailureRemovesSession() {
        protector.failure = .directory
        XCTAssertThrowsError(try store.createLease(data: Data("x".utf8), format: .plainText,
                                                   displayName: "note.txt")) { error in
            XCTAssertEqual(error as? MedicalExportError, .exportSetupFailed)
        }
        XCTAssertEqual(sessionCount(), 0, "a session that could not be protected must not survive")
    }

    func testFileAttributeFailureRemovesPartialOutput() {
        protector.failure = .file
        XCTAssertThrowsError(try store.createLease(data: Data("clinical".utf8), format: .plainText,
                                                   displayName: "note.txt")) { error in
            XCTAssertEqual(error as? MedicalExportError, .exportSetupFailed)
        }
        XCTAssertEqual(sessionCount(), 0)
    }

    func testWriteFailureRemovesSession() {
        XCTAssertThrowsError(try store.createLease(format: .plainText, displayName: "note.txt") { _ in
            throw MedicalExportError.exportWriteFailed
        })
        XCTAssertEqual(sessionCount(), 0)
    }

    func testTraversalDisplayNamesCannotEscapeTheRoot() throws {
        for hostile in ["../../etc/passwd", "/etc/passwd", "..\\..\\windows", "../"] {
            let lease = try store.createLease(data: Data("x".utf8), format: .plainText, displayName: hostile)
            XCTAssertTrue(MedicalExportFileStore.isContained(lease.fileURL, within: root))
            XCTAssertFalse(lease.displayName.contains("/"))
            XCTAssertFalse(lease.displayName.contains(".."))
            store.release(lease)
        }
    }

    func testReleaseRemovesTheWholeSessionAndIsIdempotent() throws {
        let lease = try store.createLease(data: Data("x".utf8), format: .plainText, displayName: "note.txt")
        store.release(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
        store.release(lease)  // must not throw or resurrect anything
        XCTAssertEqual(sessionCount(), 0)
    }

    func testScavengeSparesFreshActiveLease() throws {
        let lease = try store.createLease(data: Data("x".utf8), format: .plainText, displayName: "note.txt")
        XCTAssertEqual(store.scavenge(now: Date(), ttl: 3600), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))
        store.release(lease)
    }

    func testScavengeRemovesCompletedSessionPastTTL() throws {
        // A session from a previous run: created by this store, then forgotten as a crash would.
        let lease = try store.createLease(data: Data("x".utf8), format: .plainText, displayName: "note.txt")
        let orphaned = MedicalExportFileStore(root: root, protector: RecordingProtector())

        XCTAssertEqual(orphaned.scavenge(now: Date().addingTimeInterval(30), ttl: 3600), 0,
                       "inside the crash-recovery window a completed session is kept")
        XCTAssertEqual(orphaned.scavenge(now: Date().addingTimeInterval(7200), ttl: 3600), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
    }

    func testScavengeRemovesIncompleteSessionImmediately() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stray = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("half-written".utf8).write(to: stray.appendingPathComponent("\(UUID().uuidString).txt"))

        XCTAssertEqual(store.scavenge(now: Date(), ttl: 3600), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testScavengeIgnoresSiblingPaths() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("NotAnExport_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let bystander = sibling.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: bystander)
        defer { try? FileManager.default.removeItem(at: sibling) }

        _ = store.scavenge(now: Date().addingTimeInterval(86_400), ttl: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path),
                      "scavenging must never reach outside the export root")
    }

    func testRevokeAllRemovesActiveSessions() throws {
        let first = try store.createLease(data: Data("x".utf8), format: .plainText, displayName: "a.txt")
        let second = try store.createLease(data: Data("y".utf8), format: .hl7, displayName: "b.hl7")

        XCTAssertEqual(store.revokeAll(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.sessionDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.sessionDirectory.path))
    }

    private func sessionCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.count ?? 0
    }
}

// MARK: - P2: lease lifecycle

@MainActor
final class MedicalExportLeaseCoordinatorTests: XCTestCase {
    private var root: URL!
    private var coordinator: MedicalExportLeaseCoordinator!
    /// Wall-clock based: the completion marker's timestamp comes from the filesystem, so the
    /// injected clock has to share its epoch to make TTL comparisons meaningful.
    private var now = Date()
    private var events: [MedicalExportLeaseCoordinator.AuditEvent] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicalExportLeaseTests_\(UUID().uuidString)")
        coordinator = MedicalExportLeaseCoordinator(
            store: MedicalExportFileStore(root: root, protector: RecordingProtector()),
            clock: { [unowned self] in self.now }
        )
        now = Date()
        events = []
        coordinator.auditSink = { [unowned self] in self.events.append($0) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeLease(_ format: ExportFormat = .plainText) throws -> MedicalExportLease {
        try coordinator.makeLease(data: Data("clinical".utf8), format: format, displayName: "note.txt")
    }

    func testShareSuccessRemovesTheFile() throws {
        let lease = try makeLease()
        coordinator.beginShare(lease)
        coordinator.finishShare(lease, outcome: .completed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testShareCancelRemovesTheFile() throws {
        let lease = try makeLease()
        coordinator.beginShare(lease)
        coordinator.finishShare(lease, outcome: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
    }

    func testShareErrorRemovesTheFile() throws {
        let lease = try makeLease()
        coordinator.beginShare(lease)
        coordinator.finishShare(lease, outcome: .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
    }

    func testDoubleReleaseIsHarmless() throws {
        let lease = try makeLease()
        coordinator.release(lease)
        coordinator.release(lease)
        coordinator.finishShare(lease, outcome: .completed)
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testBackgroundingReleasesLeasesNotOwnedByAShare() throws {
        let shared = try makeLease()
        let abandoned = try makeLease(.hl7)
        coordinator.beginShare(shared)

        coordinator.handleBackground()

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.fileURL.path),
                      "a lease held by an onscreen share survives backgrounding")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.sessionDirectory.path))
        XCTAssertEqual(coordinator.activeLeaseCount, 1)
    }

    func testRevokeAllClearsEvenSharedLeases() throws {
        let shared = try makeLease()
        coordinator.beginShare(shared)
        coordinator.revokeAll()

        XCTAssertEqual(coordinator.activeLeaseCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.sessionDirectory.path))
    }

    func testScavengeUsesTheInjectedClock() throws {
        let lease = try makeLease()
        // Forget the lease the way a crash would, leaving the completed session on disk.
        let survivor = lease.sessionDirectory
        coordinator = MedicalExportLeaseCoordinator(
            store: MedicalExportFileStore(root: root, protector: RecordingProtector()),
            clock: { [unowned self] in self.now }
        )
        coordinator.auditSink = { [unowned self] in self.events.append($0) }

        coordinator.scavenge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path))

        now = now.addingTimeInterval(7200)
        coordinator.scavenge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: survivor.path))
    }

    func testAuditEventsAreContentFree() throws {
        let transcript = "Patient Jane Doe presented with chest pain"
        let lease = try coordinator.makeLease(data: Data(transcript.utf8), format: .plainText,
                                              displayName: "clinical_transcript_2026-08-31.txt")
        coordinator.beginShare(lease)
        coordinator.finishShare(lease, outcome: .completed)
        coordinator.scavenge()

        XCTAssertFalse(events.isEmpty)
        for event in events {
            let rendered = "\(event.action) \(event.detail)"
            XCTAssertFalse(rendered.contains("Jane"))
            XCTAssertFalse(rendered.contains("chest pain"))
            XCTAssertFalse(rendered.contains(root.path))
            XCTAssertFalse(rendered.contains(lease.fileURL.lastPathComponent))
            XCTAssertFalse(rendered.contains(lease.displayName))
            XCTAssertFalse(rendered.contains("/"), "an audit event must never carry a path")
        }
        XCTAssertTrue(events.contains { $0.action == "EXPORT_LEASE_CREATED" && $0.format == .plainText })
        XCTAssertTrue(events.contains { $0.action == "EXPORT_SHARE_COMPLETED" })
    }
}

// MARK: - Service-level lifecycle

@MainActor
final class MedicalExportServiceLifecycleTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: InMemoryFHIRSecretStore!
    private var service: MedicalExportService!
    private var configStore: FHIRConfigurationStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicalExportServiceTests_\(UUID().uuidString)")
        suiteName = "MedicalExportServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemoryFHIRSecretStore()
        configStore = FHIRConfigurationStore(defaults: defaults, credentials: secrets, contexts: secrets)
        service = MedicalExportService(
            configurationStore: configStore,
            leases: MedicalExportLeaseCoordinator(store: MedicalExportFileStore(root: root))
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFHIRSubmissionCreatesNoFile() async {
        var config = configStore.configuration
        // Reserved TEST-NET-1 address: the request fails fast without leaving the device's network.
        config.baseURL = "http://192.0.2.1:9/r4"
        configStore.save(config)
        try? configStore.storeCredential(FHIRCredential(bearerToken: "token"))

        let result = await service.exportToFHIR(transcript: "clinical", duration: "01:00", date: Date())

        XCTAssertFalse(result.success)
        XCTAssertEqual(service.leases.activeLeaseCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "a network submission must not create an export root at all")
    }

    func testFHIRSubmissionWithoutCredentialFailsWithoutTouchingDisk() async {
        var config = configStore.configuration
        config.baseURL = "https://fhir.example.com/r4"
        config.authMode = .bearerToken
        configStore.save(config)

        let result = await service.exportToFHIR(transcript: "clinical", duration: "01:00", date: Date())

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, MedicalExportError.credentialMissing.errorDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLockedStoreBlocksFHIRJsonExport() {
        secrets.loadError = KeychainService.KeychainError.unavailable(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try service.createExportLease(
            transcript: "clinical", duration: "01:00", date: Date(), format: .fhirJson
        )) { error in
            XCTAssertEqual(error as? MedicalExportError, .credentialLocked)
        }
    }

    func testExportLeaseTracksThroughTheCoordinator() throws {
        let lease = try service.createExportLease(
            transcript: "clinical", duration: "01:00", date: Date(), format: .plainText
        )
        XCTAssertEqual(service.leases.activeLeaseCount, 1)
        service.leases.finishShare(lease, outcome: .completed)
        XCTAssertEqual(service.leases.activeLeaseCount, 0)
    }
}
