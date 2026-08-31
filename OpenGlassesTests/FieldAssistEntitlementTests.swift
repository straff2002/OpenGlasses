import XCTest
import CryptoKit
@testable import OpenGlasses

/// The Field Assist entitlement boundary: what grants access, what does not, and what a stale
/// preference is worth (nothing).
@MainActor
final class FieldAssistEntitlementTests: XCTestCase {

    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var privateKey: Curve25519.Signing.PrivateKey!

    private var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    private var privateKeyBase64: String { privateKey.rawRepresentation.base64EncodedString() }

    override func setUp() {
        super.setUp()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        privateKey = Curve25519.Signing.PrivateKey()
    }

    override func tearDown() {
        EntitlementTestScope.restore(previousEntitlement)
        UserDefaults.standard.removeObject(forKey: FieldAssistEntitlement.legacyDeveloperUnlockKey)
        UserDefaults.standard.removeObject(forKey: "fieldAssistLicenseValid")
        UserDefaults.standard.removeObject(forKey: "fieldAssistPurchased")
        super.tearDown()
    }

    // MARK: - Helpers

    private func code(feature: String = "field_assist",
                      licensee: String = "Acme Co",
                      expires: Date? = nil) throws -> String {
        let payload = LicenseService.LicensePayload(
            feature: feature, licensee: licensee, issued: Date(timeIntervalSince1970: 0), expires: expires)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    /// A live provider reading a supplied code with this test's verifying key, and an isolated
    /// store recorder so the shared one can't leak in.
    private func provider(code: String?,
                          recorder: VerifiedStorePurchaseRecorder = VerifiedStorePurchaseRecorder())
    -> LiveFieldAssistEntitlementProvider {
        LiveFieldAssistEntitlementProvider(
            storePurchases: recorder,
            licensePublicKeyBase64: publicKeyBase64,
            licenseCode: { code })
    }

    // MARK: - Stale preferences grant nothing

    func testLegacyDeveloperPreferenceGrantsNothing() {
        UserDefaults.standard.set(true, forKey: FieldAssistEntitlement.legacyDeveloperUnlockKey)
        UserDefaults.standard.set(true, forKey: "fieldAssistLicenseValid")
        UserDefaults.standard.set(true, forKey: "fieldAssistPurchased")

        let decision = FieldAssistEntitlementEvaluator.decide(provider(code: nil).evidence())

        XCTAssertFalse(decision.isGranted)
        XCTAssertEqual(decision.denial, .noEvidence)
    }

    func testConfigUnlockedIgnoresStaleMirrors() {
        UserDefaults.standard.set(true, forKey: FieldAssistEntitlement.legacyDeveloperUnlockKey)
        UserDefaults.standard.set(true, forKey: "fieldAssistLicenseValid")
        UserDefaults.standard.set(true, forKey: "fieldAssistPurchased")
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        Config.setFieldAssistEnabled(true)
        defer { Config.setFieldAssistEnabled(false) }

        XCTAssertFalse(Config.fieldAssistUnlocked)
        XCTAssertFalse(Config.fieldAssistActive, "The on/off switch must not stand in for entitlement")
    }

    // MARK: - Store evidence

    func testVerifiedStorePurchaseGrants() {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistId, expiration: nil)

        let decision = FieldAssistEntitlementEvaluator.decide(provider(code: nil, recorder: recorder).evidence())

        XCTAssertTrue(decision.isGranted)
        XCTAssertEqual(decision.source, .storeProduct(productID: StoreKitService.fieldAssistId))
        XCTAssertNil(decision.expiresAt)
    }

    func testRevokedStoreTransactionDenies() {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistId, expiration: nil)
        // What `checkSubscriptionStatus` does when the transaction comes back revoked (or absent).
        recorder.clear()

        let decision = FieldAssistEntitlementEvaluator.decide(provider(code: nil, recorder: recorder).evidence())

        XCTAssertFalse(decision.isGranted)
        XCTAssertEqual(decision.denial, .noEvidence)
    }

    // MARK: - License evidence

    func testValidSignedLicenseGrants() throws {
        let decision = FieldAssistEntitlementEvaluator.decide(provider(code: try code()).evidence())

        XCTAssertTrue(decision.isGranted)
        guard case .organizationLicense(let hash)? = decision.source else {
            return XCTFail("Expected an organization-license source, got \(String(describing: decision.source))")
        }
        XCTAssertEqual(hash.count, 16, "The license id must be a short hash, never the code itself")
    }

    func testExpiredLicenseDenies() throws {
        let expiry = Date(timeIntervalSince1970: 1_000)
        let set = provider(code: try code(expires: expiry)).evidence()

        let decision = FieldAssistEntitlementEvaluator.decide(set, now: expiry.addingTimeInterval(1))

        XCTAssertFalse(decision.isGranted)
        XCTAssertEqual(decision.denial, .expired(expiry))
    }

    func testClockBoundaryAtExpiryDenies() throws {
        let expiry = Date(timeIntervalSince1970: 1_000)
        let set = provider(code: try code(expires: expiry)).evidence()

        XCTAssertTrue(FieldAssistEntitlementEvaluator.decide(set, now: expiry.addingTimeInterval(-1)).isGranted)
        XCTAssertFalse(FieldAssistEntitlementEvaluator.decide(set, now: expiry).isGranted,
                       "Expiry is exclusive — a license is spent at the instant it expires")
    }

    func testForgedLicenseDenies() throws {
        let foreign = Curve25519.Signing.PrivateKey()
        let payload = LicenseService.LicensePayload(
            feature: "field_assist", licensee: "Impostor", issued: Date(), expires: nil)
        let forged = try LicenseService.makeCode(
            payload: payload, privateKeyBase64: foreign.rawRepresentation.base64EncodedString())

        let decision = FieldAssistEntitlementEvaluator.decide(provider(code: forged).evidence())

        XCTAssertFalse(decision.isGranted)
        XCTAssertEqual(decision.denial, .unverifiableLicense)
    }

    func testMalformedLicenseDenies() {
        let decision = FieldAssistEntitlementEvaluator.decide(provider(code: "not-a-license").evidence())

        XCTAssertFalse(decision.isGranted)
        XCTAssertEqual(decision.denial, .unverifiableLicense)
    }

    func testWrongFeatureLicenseDenies() throws {
        let decision = FieldAssistEntitlementEvaluator.decide(
            provider(code: try code(feature: "some_other_product")).evidence())

        XCTAssertFalse(decision.isGranted)
        XCTAssertEqual(decision.denial, .unverifiableLicense)
    }

    // MARK: - Evaluator preferences

    func testPerpetualEvidenceOutlastsDatedEvidence() throws {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistId, expiration: nil)
        let set = provider(code: try code(expires: Date(timeIntervalSince1970: 10_000)), recorder: recorder).evidence()

        let decision = FieldAssistEntitlementEvaluator.decide(set, now: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(decision.isGranted)
        XCTAssertNil(decision.expiresAt, "A perpetual grant must not report a nearer expiry")
    }

    func testExpiredEvidenceDoesNotMaskALiveGrant() throws {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistId, expiration: Date(timeIntervalSince1970: 100))
        let set = provider(code: try code(expires: Date(timeIntervalSince1970: 10_000)), recorder: recorder).evidence()

        let decision = FieldAssistEntitlementEvaluator.decide(set, now: Date(timeIntervalSince1970: 500))

        XCTAssertTrue(decision.isGranted)
        XCTAssertEqual(decision.expiresAt, Date(timeIntervalSince1970: 10_000))
    }

    // MARK: - Internal developer source

    func testInternalDeveloperGrantIsDebugOnly() {
        #if DEBUG
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        FieldAssistEntitlement.shared.setInternalDeveloperGrant(true)
        XCTAssertTrue(FieldAssistEntitlement.shared.isGranted)
        FieldAssistEntitlement.shared.setInternalDeveloperGrant(false)
        XCTAssertFalse(FieldAssistEntitlement.shared.isGranted)
        #else
        // `.internalDeveloper` does not exist in a Release compilation; there is nothing to grant.
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        XCTAssertFalse(FieldAssistEntitlement.shared.isGranted)
        #endif
    }

    // MARK: - Migration

    func testMigrationRemovesOnlyTheLegacyKey() throws {
        let name = "EntitlementMigration-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(true, forKey: FieldAssistEntitlement.legacyDeveloperUnlockKey)
        suite.set("SIGNED-CODE", forKey: LicenseService.storageKey)
        suite.set(true, forKey: "fieldAssistPurchased")
        suite.set(true, forKey: "fieldAssistEnabled")

        FieldAssistEntitlement.removeLegacyPreferenceKeys(from: suite)

        XCTAssertNil(suite.object(forKey: FieldAssistEntitlement.legacyDeveloperUnlockKey))
        XCTAssertEqual(suite.string(forKey: LicenseService.storageKey), "SIGNED-CODE")
        XCTAssertTrue(suite.bool(forKey: "fieldAssistPurchased"))
        XCTAssertTrue(suite.bool(forKey: "fieldAssistEnabled"))
    }

    func testMigrationIsIdempotent() throws {
        let name = "EntitlementMigrationRepeat-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        FieldAssistEntitlement.removeLegacyPreferenceKeys(from: suite)
        FieldAssistEntitlement.removeLegacyPreferenceKeys(from: suite)

        XCTAssertNil(suite.object(forKey: FieldAssistEntitlement.legacyDeveloperUnlockKey))
    }

    // MARK: - Service boundaries fail closed without UI

    func testVaultRegistryLocksFieldAssistVaultsWhenDenied() {
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        VaultRegistry.shared.resetCache()

        XCTAssertFalse(VaultRegistry.shared.isUnlocked("refrigeration"))
        XCTAssertFalse(VaultRegistry.shared.isUnlocked("it_network"))
        XCTAssertTrue(VaultRegistry.shared.isUnlocked("notes"), "Free vaults stay open")
    }

    func testSessionStartFailsClosedWhenDenied() throws {
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        VaultRegistry.shared.resetCache()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = FieldSessionService(sessionsRoot: root)
        XCTAssertThrowsError(try service.startSession(vaultId: "refrigeration", assetId: nil)) { error in
            guard case FieldSessionError.vaultLocked = error else {
                return XCTFail("Expected .vaultLocked, got \(error)")
            }
        }
    }

    func testSessionExportFailsClosedWhenDenied() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        XCTAssertThrowsError(try SessionExporter.export(sessionDir: root, formats: [.json])) { error in
            guard case SessionExporter.ExportError.notEntitled = error else {
                return XCTFail("Expected .notEntitled, got \(error)")
            }
        }
    }

    func testEscalationFailsClosedWhenDenied() async {
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        let coordinator = EscalationCoordinator()
        coordinator.notifier = StubExpertNotifier()
        coordinator.bridge = PendingExpertBridge()

        let state = await coordinator.requestExpert(reason: "no entitlement")

        guard case .failed = state else {
            return XCTFail("Expected .failed, got \(state)")
        }
        XCTAssertFalse(coordinator.isEscalationActive)
    }
}
