import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan LR P1 — a company vault on a real install: the licence core's fixture pack installs
/// through the EG path, a company manual is laid in beside the technician's own, and an update to
/// the core files keeps both and the technician's overlay.
@MainActor
final class VaultDocumentCarryTests: XCTestCase {
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var temp: URL!
    private let vaultId = "fixture_rtu"

    override func setUp() {
        super.setUp()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("VaultDocumentCarryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        VaultImporter.uninstall(id: vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        EntitlementTestScope.restore(previousEntitlement)
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private var fixtureCatalog: CompanyVaultCatalog.Verified {
        get throws {
            try CompanyVaultCatalog.verify(try CompanyVaultContractTests.fixture("catalog-v7.json"),
                                           publicKeyBase64: CompanyVaultContractTests.publicKey,
                                           profileId: CompanyVaultContractTests.profileId,
                                           highWater: nil, profileGeneration: 7).get()
        }
    }

    private func installFixturePack() async throws {
        let catalog = try fixtureCatalog
        let zip = try CompanyVaultContractTests.fixture("fixture_rtu-1.0.0.zip")
        let failure = await LiveCompanyVaultInstaller.shared.install(
            try XCTUnwrap(catalog.vaults.first), fetch: { _ in zip },
            publicKeyBase64: CompanyVaultContractTests.publicKey, currentBuild: 680)
        XCTAssertNil(failure)
    }

    private func stagedFixtureManual() throws -> StagedCompanyManual {
        let row = try XCTUnwrap(try fixtureCatalog.manuals.first)
        let plain = try CompanyManualSeal.open(try CompanyVaultContractTests.fixture("RTU Wiring.md.sealed"),
                                               context: .init(profileId: CompanyVaultContractTests.profileId, manual: row),
                                               companySecret: CompanyVaultContractTests.companySecret)
        let file = temp.appendingPathComponent("plain-\(UUID().uuidString)")
        try plain.write(to: file)
        return StagedCompanyManual(manual: row, file: file, staged: StagedVaultArchive(id: UUID(), fileURL: file))
    }

    func testTheCoresFixturePackInstallsThroughThePackPath() async throws {
        try await installFixturePack()
        XCTAssertEqual(VaultImporter.installedPack(for: vaultId)?.id, "com.openglasses.vault.fixture_rtu")
        XCTAssertEqual(LiveCompanyVaultInstaller.shared.installedPack(vaultId: vaultId)?.version, "1.0.0")
        XCTAssertEqual(VaultImporter.installedManifest(id: vaultId)?.documents, [])
    }

    func testACompanyManualLandsBesideTheVaultAndAnUpdateKeepsIt() async throws {
        try await installFixturePack()
        try await LiveCompanyVaultInstaller.shared.applyManuals(vaultId: vaultId, adding: [try stagedFixtureManual()],
                                                                removing: [])
        let manifest = try XCTUnwrap(VaultImporter.installedManifest(id: vaultId))
        XCTAssertEqual(manifest.documents.map(\.file), ["RTU Wiring.md"])
        XCTAssertEqual(manifest.documents.first?.title, "RTU Wiring")
        XCTAssertEqual(manifest.documentsDir, "documents")
        let baseline = VaultImporter.baselineDirectory(for: vaultId)
        XCTAssertEqual(try Data(contentsOf: baseline.appendingPathComponent("documents/RTU Wiring.md")),
                       try CompanyVaultContractTests.fixture("RTU Wiring.md"))
        XCTAssertEqual(VaultImporter.installedPack(for: vaultId)?.version, "1.0.0", "the pack record survives a re-lay")

        // A technician's own edit lives in the overlay.
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: vaultId))
        _ = try store.write("safety.md", contents: "# Safety\n\nInvented site rule: two people at the panel.")

        // Version 1.1.0 of the core files: a fresh pack, signed by a key of this test.
        let key = Curve25519.Signing.PrivateKey()
        let manifestJSON = #"{"documents":[],"files":["safety.md","fault_codes.md"],"gating":{"iap":"com.openglasses.vault.fixture_rtu"},"id":"fixture_rtu","name":"Fixture Rooftop Units","prompt_rules":["Never fabricate a value.","Cite the source file for every claim."],"version":"1.1.0"}"#
        let files: [String: Data] = ["manifest.json": Data(manifestJSON.utf8),
                                     "safety.md": Data("# Safety\n\nInvented: isolate first.".utf8),
                                     "fault_codes.md": Data("# Fault codes\n\n| FX2 | Invented second fault |".utf8)]
        let packData = try JSONEncoder().encode(VaultPackManifest(id: "com.openglasses.vault.fixture_rtu", vaultId: vaultId,
                                                                  version: "1.1.0", name: "Fixture Rooftop Units"))
        let signature = try VaultPackSignature.sign(packManifestData: packData, files: files,
                                                    privateKeyBase64: key.rawRepresentation.base64EncodedString())
        var entries = files
        entries[VaultPackManifest.filename] = packData
        let zip = VaultPackTests.makeZip(entries)
        let vault = CompanyVaultCatalog.Vault(id: "com.openglasses.vault.fixture_rtu", vaultId: vaultId, version: "1.1.0",
                                              name: "Fixture Rooftop Units", summary: nil, author: nil, minAppBuild: nil,
                                              sizeBytes: zip.count, downloadURL: "https://licence.example.test/v.zip",
                                              sha256: VaultPackArchive.sha256Hex(zip), packSignature: signature)
        let failure = await LiveCompanyVaultInstaller.shared.install(vault, fetch: { _ in zip },
                                                                     publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                                                                     currentBuild: 680)
        XCTAssertNil(failure)
        XCTAssertEqual(VaultImporter.installedPack(for: vaultId)?.version, "1.1.0")
        let updated = try XCTUnwrap(VaultImporter.installedManifest(id: vaultId))
        XCTAssertEqual(updated.documents.map(\.file), ["RTU Wiring.md"], "the update keeps the vault's manuals")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseline.appendingPathComponent("documents/RTU Wiring.md").path))
        VaultRegistry.shared.resetCache()
        let reread = try XCTUnwrap(VaultRegistry.shared.store(forId: vaultId))
        XCTAssertTrue(reread.read("fault_codes.md")?.contains("FX2") ?? false, "the core files updated")
        XCTAssertTrue(reread.read("safety.md")?.contains("two people") ?? false, "the overlay edit survived")

        // The partner deletes the manual.
        try await LiveCompanyVaultInstaller.shared.applyManuals(vaultId: vaultId, adding: [], removing: ["RTU Wiring.md"])
        XCTAssertEqual(VaultImporter.installedManifest(id: vaultId)?.documents, [])
        XCTAssertEqual(VaultImporter.installedPack(for: vaultId)?.version, "1.1.0")
    }

    func testAManualTheTechnicianAddedIsKeptBesideTheCompanys() async throws {
        try await installFixturePack()
        // The technician's own manual, already in the vault.
        let own = temp.appendingPathComponent("own.md")
        try Data("# Own notes\n\nPage 1\n\nInvented notes of the technician's own.".utf8).write(to: own)
        _ = try VaultDocumentCarry.relay(vaultId: vaultId, removing: [],
                                         adding: [.init(document: VaultDocument(file: "Own notes.md", title: "Own notes"),
                                                        files: ["Own notes.md": own])])
        try await LiveCompanyVaultInstaller.shared.applyManuals(vaultId: vaultId, adding: [try stagedFixtureManual()],
                                                                removing: [])
        XCTAssertEqual(VaultImporter.installedManifest(id: vaultId)?.documents.map(\.file).sorted(),
                       ["Own notes.md", "RTU Wiring.md"])
        XCTAssertEqual(VaultDocumentCarry.current(vaultId: vaultId).count, 2)
    }
}
