import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan EE — tiered Field Assist entitlement: which evidence grants which tier, how the evaluator
/// ranks them, what a licence payload carries, where the team gates sit, and what the status
/// screen says about it. Pure pieces run against an injected clock and keypair; the gates run
/// against the shared entitlement with an injected provider.
@MainActor
final class FieldAssistTierTests: XCTestCase {

    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var tempRoot: URL!

    private var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    private var privateKeyBase64: String { privateKey.rawRepresentation.base64EncodedString() }

    override func setUp() {
        super.setUp()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        privateKey = Curve25519.Signing.PrivateKey()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldAssistTierTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        EntitlementTestScope.restore(previousEntitlement)
        VaultImporter.uninstall(id: "tier_test")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func code(licensee: String = "Acme Mechanical", expires: Date? = nil, tier: String? = nil,
                      plan: String? = nil, seats: Int? = nil, reference: String? = nil) throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: licensee,
                                                    issued: Date(timeIntervalSince1970: 0), expires: expires,
                                                    tier: tier, plan: plan, seats: seats, reference: reference)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    private func provider(code: String?, recorder: VerifiedStorePurchaseRecorder = VerifiedStorePurchaseRecorder())
    -> LiveFieldAssistEntitlementProvider {
        LiveFieldAssistEntitlementProvider(storePurchases: recorder, licensePublicKeyBase64: publicKeyBase64,
                                           licenseCode: { code })
    }

    private func decide(_ p: LiveFieldAssistEntitlementProvider, at seconds: TimeInterval) -> FieldAssistEntitlementDecision {
        FieldAssistEntitlementEvaluator.decide(p.evidence(), now: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - Tier ordering

    func testTierOrderAndLabels() {
        XCTAssertLessThan(FieldAssistTier.solo, .team)
        XCTAssertLessThan(FieldAssistTier.team, .enterprise)
        XCTAssertEqual(FieldAssistTier(rawValue: "team"), .team)
        XCTAssertEqual(FieldAssistTier.enterprise.label, "Enterprise")
    }

    func testStoreProductsAreAlwaysSolo() {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistAnnualId, expiration: Date(timeIntervalSince1970: 1_000))
        let decision = decide(provider(code: nil, recorder: recorder), at: 10)
        XCTAssertTrue(decision.isGranted)
        XCTAssertEqual(decision.tier, .solo)
        XCTAssertEqual(decision.expiresAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(decision.auditLabel, "store:\(StoreKitService.fieldAssistAnnualId)/solo")
    }

    func testLiveTeamCodeOutranksSoloPurchaseAndReportsItsOwnExpiry() throws {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistId, expiration: nil)
        let p = provider(code: try code(expires: Date(timeIntervalSince1970: 5_000), tier: "team"), recorder: recorder)

        let live = decide(p, at: 100)
        XCTAssertEqual(live.tier, .team)
        XCTAssertEqual(live.expiresAt, Date(timeIntervalSince1970: 5_000), "the granted tier's lapse, not the perpetual solo's")
        guard case .organizationLicense? = live.source else { return XCTFail("\(String(describing: live.source))") }
        XCTAssertTrue(live.satisfies(.team))
        XCTAssertFalse(live.satisfies(.enterprise))
    }

    func testLapsedTeamCodeLeavesSoloPerpetual() throws {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(productID: StoreKitService.fieldAssistId, expiration: nil)
        let p = provider(code: try code(expires: Date(timeIntervalSince1970: 5_000), tier: "team"), recorder: recorder)

        let later = decide(p, at: 6_000)
        XCTAssertTrue(later.isGranted)
        XCTAssertEqual(later.tier, .solo)
        XCTAssertNil(later.expiresAt)
        XCTAssertFalse(later.satisfies(.team))
    }

    func testLegacyCodeWithoutTierReadsAsTeam() throws {
        let decision = decide(provider(code: try code()), at: 0)
        XCTAssertEqual(decision.tier, .team)
    }

    func testEnterpriseOutranksTeamRegardlessOfExpiry() {
        let set = FieldAssistEntitlementEvidenceSet(evidence: [
            .verifiedOrganizationLicense(licenseIDHash: "t", expiration: nil, tier: .team),
            .verifiedOrganizationLicense(licenseIDHash: "e", expiration: Date(timeIntervalSince1970: 100), tier: .enterprise)
        ])
        let decision = FieldAssistEntitlementEvaluator.decide(set, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(decision.tier, .enterprise)
        XCTAssertEqual(decision.expiresAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(decision.source, .organizationLicense(licenseIDHash: "e"))
    }

    func testSoloCodeClaimIsNeverBelowTeam() throws {
        // A code is issued to an organisation; a mistyped "solo" tier must not create a weaker
        // licence than the legacy default.
        let decision = decide(provider(code: try code(tier: "solo")), at: 0)
        XCTAssertEqual(decision.tier, .team)
    }

    // MARK: - Payload v2

    func testPayloadV2RoundTripsAndLegacyJSONDecodes() throws {
        let signed = try code(expires: Date(timeIntervalSince1970: 86_400 * 90), tier: "team", plan: "pilot",
                              seats: 10, reference: "PO-2026-0142")
        let payload = try LicenseService.decode(code: signed, publicKeyBase64: publicKeyBase64)
        XCTAssertEqual(payload.resolvedTier, .team)
        XCTAssertEqual(payload.plan, "pilot")
        XCTAssertEqual(payload.planLabel, "Pilot")
        XCTAssertEqual(payload.seats, 10)
        XCTAssertEqual(payload.reference, "PO-2026-0142")

        let legacy = """
        {"expires":null,"feature":"field_assist","issued":"1970-01-01T00:00:00Z","licensee":"Old Co"}
        """
        let decoded = try LicenseService.decoder.decode(LicenseService.LicensePayload.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.tier)
        XCTAssertEqual(decoded.resolvedTier, .team)
        XCTAssertNil(decoded.planLabel)
    }

    func testTamperingWithTierBreaksTheSignature() throws {
        let signed = try code(tier: "team")
        let parts = signed.split(separator: ".").map(String.init)
        var json = String(decoding: Data(base64Encoded: parts[0])!, as: UTF8.self)
        json = json.replacingOccurrences(of: "\"team\"", with: "\"enterprise\"")
        let forged = Data(json.utf8).base64EncodedString() + "." + parts[1]
        XCTAssertThrowsError(try LicenseService.decode(code: forged, publicKeyBase64: publicKeyBase64))
    }

    // MARK: - Subscription evidence

    func testRecorderKeepsEveryProductAndPerpetualOutlastsLapsedSubscription() {
        let recorder = VerifiedStorePurchaseRecorder()
        recorder.record(products: [
            (StoreKitService.fieldAssistMonthlyId, Date(timeIntervalSince1970: 100)),
            (StoreKitService.fieldAssistId, nil)
        ])
        XCTAssertEqual(recorder.allEvidence.count, 2)
        let p = provider(code: nil, recorder: recorder)
        let before = decide(p, at: 50)
        XCTAssertNil(before.expiresAt, "perpetual unlock wins over a dated subscription at equal tier")
        let after = decide(p, at: 500)
        XCTAssertTrue(after.isGranted)
        XCTAssertEqual(after.source, .storeProduct(productID: StoreKitService.fieldAssistId))

        recorder.record(products: [(StoreKitService.fieldAssistMonthlyId, Date(timeIntervalSince1970: 100))])
        let lapsed = decide(p, at: 500)
        XCTAssertFalse(lapsed.isGranted)
        XCTAssertEqual(lapsed.denial, .expired(Date(timeIntervalSince1970: 100)))
    }

    // MARK: - Gates

    private func customManifest() -> VaultManifest {
        VaultManifest(id: "tier_test", name: "Tier Test", version: "1.0.0", files: ["info.md"],
                      gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite sources."])
    }

    func testSoloUnlocksBundledVaultsButNotCustomOnes() {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .solo)
        XCTAssertTrue(VaultRegistry.shared.isUnlocked("refrigeration"))
        XCTAssertFalse(VaultRegistry.shared.isUnlocked(customManifest()))
        XCTAssertEqual(FieldAssistEntitlement.shared.check(atLeast: .team), .insufficientTier(required: .team, held: .solo))
        XCTAssertEqual(FieldAssistEntitlement.shared.check(atLeast: .solo), .granted(.solo))

        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .team)
        XCTAssertTrue(VaultRegistry.shared.isUnlocked(customManifest()))
        XCTAssertEqual(FieldAssistEntitlement.shared.check(atLeast: .team), .granted(.team))

        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        XCTAssertEqual(FieldAssistEntitlement.shared.check(atLeast: .team), .denied(.noEvidence))
    }

    func testExportAndManualSyncNeedTeam() async throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .solo)
        XCTAssertThrowsError(try SessionExporter.export(sessionDir: tempRoot, formats: [.json])) { error in
            guard case SessionExporter.ExportError.notEntitled = error else { return XCTFail("\(error)") }
        }
        let store = DocumentStore(directory: tempRoot)
        do {
            _ = try await VaultImporter.syncDocuments(manifest: customManifest(), into: store, baseline: tempRoot, ledgerDirectory: tempRoot)
            XCTFail("expected notEntitled")
        } catch VaultImporter.ImportError.notEntitled {
            // expected
        }

        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .team)
        // A team grant passes the gate; with no documents listed the sync is a no-op.
        let ledger = try await VaultImporter.syncDocuments(manifest: customManifest(), into: store, baseline: tempRoot, ledgerDirectory: tempRoot)
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testSessionStartRecordsTheEntitlementSource() throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .team)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let log = tempRoot.appendingPathComponent("sessions/\(session.id)", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: log, includingPropertiesForKeys: nil)) ?? []
        // JSONEncoder escapes "/" as "\/" by default; compare on the unescaped text.
        let joined = contents.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(joined.contains("entitlement=license:test-grant/team"), joined)
    }

    // MARK: - Status

    private func granted(expiresIn seconds: TimeInterval?, tier: FieldAssistTier = .team) -> FieldAssistEntitlementStatus.State {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let decision = FieldAssistEntitlementDecision.granted(
            source: .organizationLicense(licenseIDHash: "h"), tier: tier,
            expiresAt: seconds.map { now.addingTimeInterval($0) })
        return FieldAssistEntitlementStatus.make(decision: decision, now: now)
    }

    func testStatusStates() {
        XCTAssertEqual(FieldAssistEntitlementStatus.make(decision: .denied(.noEvidence)), .none)
        XCTAssertEqual(FieldAssistEntitlementStatus.make(decision: .denied(.unverifiableLicense)), .unverifiableLicense)
        XCTAssertEqual(FieldAssistEntitlementStatus.make(decision: .denied(.expired(Date(timeIntervalSince1970: 5)))),
                       .expired(Date(timeIntervalSince1970: 5)))

        guard case .granted(let perpetual) = granted(expiresIn: nil) else { return XCTFail() }
        XCTAssertNil(perpetual.warning)
        XCTAssertEqual(perpetual.sourceLabel, "Organisation licence")

        guard case .granted(let far) = granted(expiresIn: 31 * 86_400 + 60) else { return XCTFail() }
        XCTAssertNil(far.warning)

        guard case .granted(let month) = granted(expiresIn: 30 * 86_400) else { return XCTFail() }
        XCTAssertEqual(month.warning, .expiring(daysRemaining: 30, threshold: 30))

        guard case .granted(let week) = granted(expiresIn: 7 * 86_400 - 1) else { return XCTFail() }
        XCTAssertEqual(week.warning, .expiring(daysRemaining: 6, threshold: 7))

        guard case .granted(let today) = granted(expiresIn: 3_600) else { return XCTFail() }
        XCTAssertEqual(today.warning, .expiring(daysRemaining: 0, threshold: 7))
        XCTAssertTrue(FieldAssistPaywallCopy.expiring(today.warning!).hasPrefix("Expires today"))
    }

    func testSubscriptionSourceLabel() {
        let decision = FieldAssistEntitlementDecision.granted(
            source: .storeProduct(productID: StoreKitService.fieldAssistMonthlyId), tier: .solo, expiresAt: nil)
        guard case .granted(let grant) = FieldAssistEntitlementStatus.make(decision: decision) else { return XCTFail() }
        XCTAssertEqual(grant.sourceLabel, "App Store subscription")
    }

    // MARK: - Copy guard

    func testPaywallCopyNeverSteersOutsideTheStore() {
        let forbidden = ["http", "www.", ".com", ".kiwi", "email", "website", "contact us", "purchase order", "invoice"]
        for line in FieldAssistPaywallCopy.all {
            for needle in forbidden {
                XCTAssertFalse(line.lowercased().contains(needle), "\"\(line)\" contains \"\(needle)\"")
            }
        }
        XCTAssertTrue(FieldAssistPaywallCopy.all.count >= 14)
    }
}
