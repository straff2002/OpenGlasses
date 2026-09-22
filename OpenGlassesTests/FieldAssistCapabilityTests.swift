import XCTest
@testable import OpenGlasses

/// Plan FS PR1 — capabilities, not tiers. The evidence × capability table, the gates that ask it,
/// and the Custom Vaults screen's states. Pure pieces run against an injected clock; the gates run
/// against the shared entitlement with an injected provider.
@MainActor
final class FieldAssistCapabilityTests: XCTestCase {

    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var tempRoot: URL!

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var past: Date { now.addingTimeInterval(-1) }
    private var future: Date { now.addingTimeInterval(86_400) }

    override func setUp() {
        super.setUp()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldAssistCapabilityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        EntitlementTestScope.restore(previousEntitlement)
        VaultImporter.uninstall(id: "capability_test")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func capabilities(_ evidence: FieldAssistEntitlementEvidence...) -> Set<FieldAssistCapability> {
        FieldAssistCapability.capabilities(for: FieldAssistEntitlementEvidenceSet(evidence: evidence), now: now)
    }

    private func use(_ provider: FieldAssistEntitlementProvider) {
        FieldAssistEntitlement.shared.provider = provider
        FieldAssistEntitlement.shared.clock = { [now] in now }
    }

    private static let bundled: Set<FieldAssistCapability> = [.bundledVaults]
    private static let subscription: Set<FieldAssistCapability> = [.bundledVaults, .ownVaults]
    private static let team: Set<FieldAssistCapability> = [.bundledVaults, .ownVaults, .auditedExport, .orgConfiguration]
    private static let enterprise: Set<FieldAssistCapability> = Set(FieldAssistCapability.allCases)

    // MARK: - The table

    func testEveryEvidenceKindMapsToItsCapabilities() {
        // The two store products that are both `solo` and are not the same entitlement.
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistId, expiration: nil)),
                       Self.bundled, "the retired one-time unlock buys the bundled vaults and nothing more")
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistMonthlyId, expiration: future)),
                       Self.subscription)
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistAnnualId, expiration: future)),
                       Self.subscription)
        // A product id this build does not know is treated as the weakest thing it could be.
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: "com.openglasses.some_future_product", expiration: nil)),
                       Self.bundled)

        XCTAssertEqual(capabilities(.verifiedOrganizationLicense(licenseIDHash: "s", expiration: nil, tier: .solo)),
                       Self.bundled)
        XCTAssertEqual(capabilities(.verifiedOrganizationLicense(licenseIDHash: "t", expiration: future, tier: .team)),
                       Self.team)
        XCTAssertEqual(capabilities(.verifiedOrganizationLicense(licenseIDHash: "e", expiration: nil, tier: .enterprise)),
                       Self.enterprise)
        #if DEBUG
        XCTAssertEqual(capabilities(.internalDeveloper), Self.enterprise)
        #endif
    }

    func testLapsedAndAbsentEvidenceGrantNothing() {
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistMonthlyId, expiration: past)), [])
        XCTAssertEqual(capabilities(.verifiedOrganizationLicense(licenseIDHash: "t", expiration: past, tier: .team)), [])
        XCTAssertEqual(FieldAssistCapability.capabilities(for: .empty, now: now), [])
        XCTAssertEqual(FieldAssistCapability.capabilities(
            for: FieldAssistEntitlementEvidenceSet(hasUnverifiableLicense: true), now: now), [])
        // Expiry is exclusive, exactly as the evaluator reads it.
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistMonthlyId, expiration: now)), [])
    }

    func testCapabilitiesUnionEveryLivePieceRatherThanPickingAWinner() {
        // A technician's own subscription beside the firm's lapsed team code: he keeps what he pays
        // for, and the lapsed code contributes nothing — the same rule the evaluator applies to tiers.
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistAnnualId, expiration: future),
                                    .verifiedOrganizationLicense(licenseIDHash: "t", expiration: past, tier: .team)),
                       Self.subscription)
        // Both live: everything either one includes.
        XCTAssertEqual(capabilities(.verifiedStoreProduct(productID: StoreKitService.fieldAssistId, expiration: nil),
                                    .verifiedOrganizationLicense(licenseIDHash: "t", expiration: future, tier: .team)),
                       Self.team)
    }

    /// Exhaustiveness: no capability is unreachable, none is free, and a granted decision always
    /// carries at least one capability — the invariant every screen's "entitled but not this"
    /// state depends on.
    func testEveryCapabilityIsGrantedBySomeEvidenceAndWithheldBySomeOther() {
        let kinds: [FieldAssistEntitlementEvidence] = [
            .verifiedStoreProduct(productID: StoreKitService.fieldAssistId, expiration: nil),
            .verifiedStoreProduct(productID: StoreKitService.fieldAssistMonthlyId, expiration: future),
            .verifiedStoreProduct(productID: StoreKitService.fieldAssistAnnualId, expiration: future),
            .verifiedOrganizationLicense(licenseIDHash: "s", expiration: nil, tier: .solo),
            .verifiedOrganizationLicense(licenseIDHash: "t", expiration: nil, tier: .team),
            .verifiedOrganizationLicense(licenseIDHash: "e", expiration: nil, tier: .enterprise)
        ]
        for capability in FieldAssistCapability.allCases {
            XCTAssertTrue(kinds.contains { FieldAssistCapability.capabilities(for: $0).contains(capability) },
                          "\(capability.rawValue) is granted by no evidence kind — a gate asking for it can never open")
            guard capability != .bundledVaults else { continue }
            XCTAssertTrue(kinds.contains { !FieldAssistCapability.capabilities(for: $0).contains(capability) },
                          "\(capability.rawValue) is granted by every evidence kind — it is not a gate")
        }
        // The one capability every entitlement carries, and the reason "entitled but not this" is a
        // state at all: whatever someone holds, the bundled vaults are in it.
        XCTAssertTrue(kinds.allSatisfy { FieldAssistCapability.capabilities(for: $0).contains(.bundledVaults) })
        for kind in kinds {
            let granted = FieldAssistCapability.capabilities(for: kind)
            XCTAssertFalse(granted.isEmpty, "\(kind) grants a tier but no capability")
            let decision = FieldAssistEntitlementEvaluator.decide(
                FieldAssistEntitlementEvidenceSet(evidence: [kind]), now: now)
            XCTAssertTrue(decision.isGranted)
        }
    }

    func testCheckSeparatesNotIncludedFromNotEntitled() {
        XCTAssertEqual(FieldAssistCapabilityCheck.resolve(.ownVaults, capabilities: Self.subscription,
                                                          decision: .granted(source: .storeProduct(productID: "x"), tier: .solo, expiresAt: nil)),
                       .granted)
        XCTAssertEqual(FieldAssistCapabilityCheck.resolve(.ownVaults, capabilities: Self.bundled,
                                                          decision: .granted(source: .storeProduct(productID: "x"), tier: .solo, expiresAt: nil)),
                       .notIncluded(held: Self.bundled))
        XCTAssertEqual(FieldAssistCapabilityCheck.resolve(.ownVaults, capabilities: [],
                                                          decision: .denied(.expired(past))),
                       .denied(.expired(past)))
        XCTAssertFalse(FieldAssistCapabilityCheck.notIncluded(held: Self.bundled).isGranted)
    }

    // MARK: - The Custom Vaults screen, per evidence kind

    func testCustomVaultGateStatePerEvidenceKind() {
        use(StubEntitlementProvider.subscriber(expiring: future))
        XCTAssertEqual(CustomVaultGateState.current(), .allowed)
        XCTAssertNil(CustomVaultGateState.current().explanation)
        XCTAssertTrue(CustomVaultGateState.current().allowsImport)

        use(StubEntitlementProvider.retiredUnlock())
        XCTAssertEqual(CustomVaultGateState.current(), .bundledOnly)
        XCTAssertEqual(CustomVaultGateState.current().explanation, FieldAssistPaywallCopy.bundledVaultsOnly)
        XCTAssertFalse(CustomVaultGateState.current().allowsImport)

        use(StubEntitlementProvider.subscriber(expiring: past))
        XCTAssertEqual(CustomVaultGateState.current(), .lapsed(past))
        XCTAssertEqual(CustomVaultGateState.current().explanation, FieldAssistPaywallCopy.ownVaultsLapsed)

        use(DeniedEntitlementProvider(hasUnverifiableLicense: true))
        XCTAssertEqual(CustomVaultGateState.current(), .unverifiableLicence)

        use(DeniedEntitlementProvider())
        XCTAssertEqual(CustomVaultGateState.current(), .locked)
        XCTAssertEqual(CustomVaultGateState.current().explanation, FieldAssistPaywallCopy.ownVaultsLocked)

        use(AlwaysGrantedEntitlementProvider(tier: .team))
        XCTAssertEqual(CustomVaultGateState.current(), .allowed)
    }

    func testCopyNamesTheSubscriptionAndCarriesNoPrice() {
        XCTAssertTrue(FieldAssistPaywallCopy.bundledVaultsOnly.contains("subscription"))
        XCTAssertTrue(VaultImporter.ImportError.notEntitled.localizedDescription.contains("subscription"),
                      "the importer's refusal has to name what would fix it")
        let priced = ["$", "£", "€", "per month", "a month", "a year", "99"]
        for line in FieldAssistPaywallCopy.all + FieldAssistTier.allCases.map(\.capabilitySummary)
            + [VaultImporter.ImportError.notEntitled.localizedDescription] {
            for needle in priced {
                XCTAssertFalse(line.contains(needle), "\"\(line)\" carries a price; prices come from the store")
            }
        }
    }

    // MARK: - The importer gate

    private func writeVault(documents: [VaultDocument]) -> URL {
        let dir = tempRoot.appendingPathComponent("source", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("documents"),
                                                 withIntermediateDirectories: true)
        let manifest = VaultManifest(id: "capability_test", name: "Capability Test", version: "1.0.0",
                                     files: ["info.md"], documentsDir: "documents", documents: documents,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source file."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? "# Info\n\nCore content.".write(to: dir.appendingPathComponent("info.md"), atomically: true, encoding: .utf8)
        for document in documents {
            try? "Fault code ZX9 indicates a low charge on the RTU-500."
                .write(to: dir.appendingPathComponent("documents/\(document.file)"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func store() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    private func namespace() -> String { DocumentStore.vaultNamespace("capability_test") }

    func testSubscriberIngestsManualsAndRetiredUnlockCannot() async throws {
        let manual = VaultDocument(file: "manual.txt", title: "RTU-500 Service Manual")
        let source = writeVault(documents: [manual])

        // The retired one-time unlock: the folder still installs — an import is a file operation —
        // but the manual does not go into the index, and the refusal names the subscription.
        use(StubEntitlementProvider.retiredUnlock())
        let manifest = try VaultImporter.install(from: source)
        VaultRegistry.shared.reloadUserManifests()
        let documentStore = store()
        do {
            _ = try await VaultImporter.syncDocuments(manifest: manifest, into: documentStore)
            XCTFail("expected notEntitled")
        } catch VaultImporter.ImportError.notEntitled {
            XCTAssertTrue(VaultImporter.ImportError.notEntitled.localizedDescription.lowercased().contains("subscription"))
        }
        XCTAssertEqual(documentStore.documentCount(namespace: namespace()), 0)
        XCTAssertFalse(VaultRegistry.shared.isUnlocked(manifest), "nor does the vault itself read")

        // The same phone, a subscription: the manual indexes and the vault reads.
        use(StubEntitlementProvider.subscriber(expiring: future))
        let ledger = try await VaultImporter.syncDocuments(manifest: manifest, into: documentStore)
        XCTAssertEqual(ledger.entries.map(\.file), ["manual.txt"])
        XCTAssertEqual(documentStore.documentCount(namespace: namespace()), 1)
        XCTAssertTrue(VaultRegistry.shared.isUnlocked(manifest))
    }

    func testLapsedSubscriberCannotIngestButCanStillCleanUpAndRemove() async throws {
        let manual = VaultDocument(file: "manual.txt", title: "RTU-500 Service Manual")
        let source = writeVault(documents: [manual])
        use(StubEntitlementProvider.subscriber(expiring: future))
        let manifest = try VaultImporter.install(from: source)
        VaultRegistry.shared.reloadUserManifests()
        let documentStore = store()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: documentStore)
        XCTAssertEqual(documentStore.documentCount(namespace: namespace()), 1)

        use(StubEntitlementProvider.subscriber(expiring: past))
        // Removal is permitted at any entitlement (Plan FN) and takes the manual out for good.
        XCTAssertTrue(VaultManualRemoval.isPermittedByEntitlement)
        let result = try await VaultManualRemoval.remove(file: "manual.txt", fromVault: manifest.id,
                                                         documentStore: documentStore)
        XCTAssertEqual(result.file, "manual.txt")
        XCTAssertEqual(documentStore.documentCount(namespace: namespace()), 0)

        // A cleanup-only sync still runs: a lapsed licence must never leave indexed passages the
        // vault no longer lists and the reader can no longer get rid of.
        let reduced = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == manifest.id })
        let cleaned = try await VaultImporter.syncDocuments(manifest: reduced, into: documentStore)
        XCTAssertTrue(cleaned.entries.isEmpty)

        // Putting the manual back is an ingest, and that is what stops.
        let restored = try VaultImporter.install(from: source)
        VaultRegistry.shared.reloadUserManifests()
        do {
            _ = try await VaultImporter.syncDocuments(manifest: restored, into: documentStore)
            XCTFail("expected notEntitled")
        } catch VaultImporter.ImportError.notEntitled {
            // expected
        }
        XCTAssertEqual(documentStore.documentCount(namespace: namespace()), 0)
    }

    func testTeamAndEnterpriseAreUnchanged() async throws {
        let manual = VaultDocument(file: "manual.txt", title: "RTU-500 Service Manual")
        use(AlwaysGrantedEntitlementProvider(tier: .team))
        let manifest = try VaultImporter.install(from: writeVault(documents: [manual]))
        VaultRegistry.shared.reloadUserManifests()
        let documentStore = store()
        let ledger = try await VaultImporter.syncDocuments(manifest: manifest, into: documentStore)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertTrue(FieldAssistEntitlement.shared.has(.auditedExport))
        XCTAssertFalse(FieldAssistEntitlement.shared.has(.everyVaultPack))

        use(AlwaysGrantedEntitlementProvider(tier: .enterprise))
        XCTAssertTrue(FieldAssistEntitlement.shared.has(.everyVaultPack))
        XCTAssertTrue(VaultPackAccess.isUnlocked(productId: "com.openglasses.pack.hvac_rtu", licensePack: "hvac_rtu",
                                                 purchasedProducts: [], licensedPacks: [],
                                                 capabilities: FieldAssistEntitlement.shared.capabilities()))
    }

    func testAuditedExportStaysTeamOnlyForASubscriber() {
        use(StubEntitlementProvider.subscriber(expiring: future))
        XCTAssertTrue(FieldAssistEntitlement.shared.has(.ownVaults))
        XCTAssertFalse(FieldAssistEntitlement.shared.has(.auditedExport))
        XCTAssertFalse(FieldAssistEntitlement.shared.has(.orgConfiguration))
        XCTAssertThrowsError(try SessionExporter.export(sessionDir: tempRoot, formats: [.json])) { error in
            guard case SessionExporter.ExportError.notEntitled = error else { return XCTFail("\(error)") }
        }
    }
}
