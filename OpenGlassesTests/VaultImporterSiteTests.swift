import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan HV P0 — site documents through install and export: the listed files are copied and
/// exported, `VaultStore.siteDocuments()` reads them, a pack carrying `sites` is refused, and a
/// manifest without them installs and records exactly as before.
@MainActor
final class VaultImporterSiteTests: XCTestCase {

    private typealias F = SiteSystemFixtures
    private var root: URL!
    private let ids = ["site_import_test", "site_plain_test", "site_pack_test"]

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultImporterSiteTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in ids { VaultImporter.uninstall(id: id) }
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testListedSiteFilesAreCopiedAndRead() throws {
        let dir = try F.copyVault(to: root, id: "site_import_test")
        // A file the manifest does not list is not installed.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("sites/unlisted.json"))
        let manifest = try VaultImporter.install(from: dir)
        XCTAssertEqual(manifest.sites, [F.siteFile])
        let baseline = VaultImporter.baselineDirectory(for: manifest.id)
        XCTAssertEqual(try Data(contentsOf: baseline.appendingPathComponent(F.siteFile)), try F.exampleData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseline.appendingPathComponent("sites/unlisted.json").path))

        let store = VaultStore(manifest: manifest, bundleRoot: baseline,
                               overlayRoot: root.appendingPathComponent("overlay", isDirectory: true))
        XCTAssertEqual(store.siteDocuments(), [try F.exampleDocument()])
        XCTAssertEqual(store.siteDocument(id: "hillside-house")?.name, "Hillside house, whole-home system")
        XCTAssertNil(store.siteDocument(id: "nowhere"))
        // The registry's copy of the manifest keeps the list.
        XCTAssertEqual(VaultImporter.installedManifest(id: manifest.id)?.sites, [F.siteFile])
    }

    func testAnInvalidSiteDocumentRefusesTheWholeInstall() throws {
        var object = try F.exampleObject()
        object["notes"] = "Call https://example.test"
        let dir = try F.copyVault(to: root, id: "site_import_test", sites: [F.siteFile: object])
        XCTAssertThrowsError(try VaultImporter.install(from: dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("notes contains a link"), error.localizedDescription)
        }
        XCTAssertNil(VaultImporter.installedManifest(id: "site_import_test"))
    }

    func testExportCarriesTheSiteFilesAndReimports() throws {
        let manifest = try VaultImporter.install(from: F.copyVault(to: root, id: "site_import_test"))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let exported = try VaultExporter.export(id: manifest.id, learnings: { _ in nil })
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent(F.siteFile)), try F.exampleData())
        let result = VaultValidator.validate(directory: exported)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.manifest?.sites, [F.siteFile])
    }

    func testAVaultWithoutSitesInstallsAndExportsExactlyAsBefore() throws {
        let dir = try F.copyVault(to: root, id: "site_plain_test", withoutSites: true)
        let manifest = try VaultImporter.install(from: dir)
        XCTAssertNil(manifest.sites)
        let baseline = VaultImporter.baselineDirectory(for: manifest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseline.appendingPathComponent("sites").path))
        let registry = try String(contentsOf: VaultImporter.registryDirectory.appendingPathComponent("\(manifest.id).json"),
                                  encoding: .utf8)
        XCTAssertFalse(registry.contains("sites"), "the recorded manifest has no sites key at all")
        let store = VaultStore(manifest: manifest, bundleRoot: baseline,
                               overlayRoot: root.appendingPathComponent("overlay", isDirectory: true))
        XCTAssertEqual(store.siteDocuments(), [])

        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let exported = try VaultExporter.export(id: manifest.id, learnings: { _ in nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("sites").path))
        let exportedManifest = try String(contentsOf: exported.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(exportedManifest.contains("sites"))
    }

    func testRemovingAManualKeepsTheSitesList() throws {
        let manifest = try JSONDecoder().decode(VaultManifest.self,
                                                from: Data(contentsOf: F.vaultDirectory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(VaultManualRemoval.reducedManifest(manifest, removing: "x.pdf").sites, [F.siteFile])
        XCTAssertEqual(manifest.markingDocumentsNotIncluded().sites, [F.siteFile])
    }

    // MARK: - Packs

    func testAPackCarryingSitesIsRefused() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let packId = "com.openglasses.vault.site_pack_test"
        let pack = VaultPackManifest(id: packId, vaultId: "site_pack_test", version: "1.0.0", name: "Site pack",
                                     summary: "s", author: "Example author", minAppBuild: nil, licensePack: nil)
        func files(sites: [String]?) throws -> [String: Data] {
            let manifest = VaultManifest(id: "site_pack_test", name: "Site pack", version: "1.0.0",
                                         files: ["safety.md", "models.md"], gating: .init(iap: packId),
                                         promptRules: ["Never fabricate.", "Cite the source."], sites: sites)
            var files: [String: Data] = [
                "manifest.json": try JSONEncoder().encode(manifest),
                "safety.md": try Data(contentsOf: F.vaultDirectory.appendingPathComponent("safety.md")),
                "models.md": try Data(contentsOf: F.vaultDirectory.appendingPathComponent("models.md")),
            ]
            if sites != nil { files[F.siteFile] = try F.exampleData() }
            return files
        }
        let service = VaultPackCatalogService(catalogURL: { nil }, fetch: { _ in Data() },
                                              publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                                              currentBuild: 400)
        func install(_ files: [String: Data]) async throws -> Result<[String], VaultPackCatalogService.InstallFailure> {
            let packData = try JSONEncoder().encode(pack)
            let signature = try VaultPackSignature.sign(packManifestData: packData, files: files,
                                                        privateKeyBase64: key.rawRepresentation.base64EncodedString())
            var entries = files
            entries[VaultPackManifest.filename] = packData
            return await service.installPack(zipData: VaultPackTests.makeZip(entries), signatureBase64: signature, expectedId: packId)
        }
        guard case .failure(let failure) = try await install(files(sites: [F.siteFile])) else {
            return XCTFail("a pack with sites must not install")
        }
        XCTAssertEqual(failure.reason, "a pack must not carry site documents; sites belong in a customer's own vault")
        XCTAssertNil(VaultImporter.installedManifest(id: "site_pack_test"))
        // Even an empty list: a pack has no sites key at all.
        guard case .failure = try await install(files(sites: [])) else { return XCTFail("an empty sites list is still sites") }
        // Without the key, the same pack installs.
        guard case .success = try await install(files(sites: nil)) else { return XCTFail("the pack without sites installs") }
    }
}
