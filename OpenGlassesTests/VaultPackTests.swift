import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan EG — authored vaults as signed, downloadable, individually entitled packs.
@MainActor
final class VaultPackTests: XCTestCase {

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
            .appendingPathComponent("VaultPackTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        VerifiedStorePurchaseRecorder.shared.recordPackProducts([])
    }

    override func tearDown() {
        EntitlementTestScope.restore(previousEntitlement)
        VerifiedStorePurchaseRecorder.shared.recordPackProducts([])
        VaultImporter.uninstall(id: "hvac_rtu")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Committed catalog

    /// Byte-for-byte copy of the committed `vaultpacks/catalog.json`. Signed by the same vendor
    /// key as the skill-pack catalog, so if either the published envelope or
    /// `SkillPackSignature.productionPublicKeyBase64` moves without the other, this fails — the
    /// drift a key rotation must not leave behind.
    static let committedVaultCatalog = #"{"payload":"eyJ2ZXJzaW9uIjoxLCJwYWNrcyI6W119Cg==","signature":"9+bfCHEy2NeIMm5bQseb3LbvSBddU9G5K05ogQgWGRB1FL2ArvnibgYpFIrxVAcDHEpwlYKet4jPymrgPXQFDw=="}"#

    func testCommittedVaultCatalogVerifiesAgainstProductionKey() {
        guard case .success(let packs) = VaultPackCatalog.parse(
            envelopeData: Data(Self.committedVaultCatalog.utf8)) else {
            return XCTFail("the committed vault catalog must verify against the embedded production key")
        }
        XCTAssertTrue(packs.isEmpty, "no vault packs are published yet — the index is an empty, signed shell")
    }

    // MARK: - Fixtures

    static let packId = "com.openglasses.vault.hvac_rtu"

    private func packManifest(version: String = "1.0.0", minAppBuild: Int? = nil, vaultId: String = "hvac_rtu",
                              id: String = packId) -> VaultPackManifest {
        VaultPackManifest(id: id, vaultId: vaultId, version: version, name: "HVAC Rooftop Units",
                          summary: "Fault codes and diagnostics for packaged rooftop units.",
                          author: "Prairie Mechanical", minAppBuild: minAppBuild, licensePack: "hvac_rtu")
    }

    private func vaultFiles(gating: String = packId, withDocuments: Bool = false) -> [String: Data] {
        let manifest = VaultManifest(id: "hvac_rtu", name: "HVAC Rooftop Units", version: "1.0.0",
                                     files: ["safety.md", "error_codes.md"],
                                     documents: withDocuments ? [VaultDocument(file: "x.txt", title: "X")] : [],
                                     gating: .init(iap: gating),
                                     promptRules: ["Never fabricate.", "Cite the source."])
        var files: [String: Data] = [
            "manifest.json": try! JSONEncoder().encode(manifest),
            "safety.md": Data("# Safety\n\nLock out power.".utf8),
            "error_codes.md": Data("# Fault Codes\n\n## RTU-500\n\n| Code | Meaning |\n|---|---|\n| ZX9 | Low charge |".utf8)
        ]
        if withDocuments { files["x.txt"] = Data("manual text".utf8) }
        return files
    }

    /// A stored (uncompressed) zip: local headers, central directory, end record. Enough for the
    /// app's reader, which handles methods 0 and 8.
    static func makeZip(_ entries: [String: Data]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func crc32(_ data: Data) -> UInt32 {
            var table = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                var c = UInt32(i)
                for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
                table[i] = c
            }
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            return crc ^ 0xFFFFFFFF
        }
        var body = Data()
        var central = Data()
        for name in entries.keys.sorted() {
            let data = entries[name]!
            let nameBytes = Array(name.utf8)
            let offset = UInt32(body.count)
            let crc = crc32(data)
            body.append(contentsOf: le32(0x04034B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                        + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0))
            body.append(contentsOf: nameBytes)
            body.append(data)
            central.append(contentsOf: le32(0x02014B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count)
                           + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: nameBytes)
        }
        var zip = body
        let centralOffset = UInt32(zip.count)
        zip.append(central)
        zip.append(contentsOf: le32(0x06054B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                   + le32(UInt32(central.count)) + le32(centralOffset) + le16(0))
        return zip
    }

    private func signedPack(pack: VaultPackManifest? = nil, files: [String: Data]? = nil)
    throws -> (zip: Data, signature: String, packData: Data, files: [String: Data]) {
        let packData = try JSONEncoder().encode(pack ?? packManifest())
        let files = files ?? vaultFiles()
        let signature = try VaultPackSignature.sign(packManifestData: packData, files: files, privateKeyBase64: privateKeyBase64)
        var entries = files
        entries[VaultPackManifest.filename] = packData
        return (Self.makeZip(entries), signature, packData, files)
    }

    private func entry(for pack: (zip: Data, signature: String, packData: Data, files: [String: Data]),
                       version: String = "1.0.0", minAppBuild: Int? = nil, id: String = packId) -> VaultPackCatalogEntry {
        VaultPackCatalogEntry(id: id, vaultId: "hvac_rtu", version: version, name: "HVAC Rooftop Units",
                              summary: "s", author: "Prairie Mechanical", minAppBuild: minAppBuild,
                              downloadURL: "https://example.test/hvac_rtu.zip",
                              sha256: VaultPackArchive.sha256Hex(pack.zip), packSignature: pack.signature)
    }

    private func service(zip: Data, entries: [VaultPackCatalogEntry], currentBuild: Int = 400) throws -> VaultPackCatalogService {
        let envelope = try VaultPackCatalog.makeEnvelope(index: .init(version: 1, packs: entries), privateKeyBase64: privateKeyBase64)
        return VaultPackCatalogService(
            catalogURL: { URL(string: "https://example.test/catalog.json") },
            fetch: { url in url.lastPathComponent == "catalog.json" ? envelope : zip },
            publicKeyBase64: publicKeyBase64,
            currentBuild: currentBuild)
    }

    // MARK: - Format and signature

    func testArchiveExtractsPackAndVaultFiles() throws {
        let pack = try signedPack()
        guard case .success(let (packData, files)) = VaultPackArchive.extract(zipData: pack.zip) else { return XCTFail() }
        XCTAssertEqual(packData, pack.packData)
        XCTAssertEqual(Set(files.keys), ["manifest.json", "safety.md", "error_codes.md"])
        XCTAssertEqual(VaultPackArchive.extract(zipData: Data("nope".utf8)).error, .notAZip)
        XCTAssertEqual(VaultPackArchive.extract(zipData: Self.makeZip(["a.md": Data()])).error, .missingPackManifest)
        XCTAssertEqual(VaultPackArchive.extract(zipData: Self.makeZip(["pack.json": Data("{}".utf8)])).error, .missingVaultManifest)
    }

    func testSignatureCoversEveryFile() throws {
        let pack = try signedPack()
        XCTAssertTrue(VaultPackSignature.verify(signatureBase64: pack.signature, packManifestData: pack.packData,
                                                files: pack.files, publicKeyBase64: publicKeyBase64))
        var altered = pack.files; altered["safety.md"] = Data("changed".utf8)
        XCTAssertFalse(VaultPackSignature.verify(signatureBase64: pack.signature, packManifestData: pack.packData,
                                                 files: altered, publicKeyBase64: publicKeyBase64))
        var added = pack.files; added["extra.md"] = Data("x".utf8)
        XCTAssertFalse(VaultPackSignature.verify(signatureBase64: pack.signature, packManifestData: pack.packData,
                                                 files: added, publicKeyBase64: publicKeyBase64))
        let otherPack = try JSONEncoder().encode(packManifest(version: "9.9.9"))
        XCTAssertFalse(VaultPackSignature.verify(signatureBase64: pack.signature, packManifestData: otherPack,
                                                 files: pack.files, publicKeyBase64: publicKeyBase64))
        XCTAssertFalse(VaultPackSignature.verify(signatureBase64: pack.signature, packManifestData: pack.packData,
                                                 files: pack.files), "the production key did not sign this")
    }

    func testCatalogEnvelopeParsesAndRefusesTamperingAndNewerVersions() throws {
        let pack = try signedPack()
        let index = VaultPackCatalog.Index(version: 1, packs: [entry(for: pack)])
        let envelope = try VaultPackCatalog.makeEnvelope(index: index, privateKeyBase64: privateKeyBase64)
        guard case .success(let entries) = VaultPackCatalog.parse(envelopeData: envelope, publicKeyBase64: publicKeyBase64) else { return XCTFail() }
        XCTAssertEqual(entries.map(\.id), [Self.packId])

        XCTAssertEqual(VaultPackCatalog.parse(envelopeData: envelope).error, .badSignature, "production key did not sign it")
        let newer = try VaultPackCatalog.makeEnvelope(index: .init(version: 2, packs: []), privateKeyBase64: privateKeyBase64)
        XCTAssertEqual(VaultPackCatalog.parse(envelopeData: newer, publicKeyBase64: publicKeyBase64).error, .unsupportedVersion(2))
        XCTAssertEqual(VaultPackCatalog.parse(envelopeData: Data("{}".utf8), publicKeyBase64: publicKeyBase64).error, .notAnEnvelope)
    }

    // MARK: - Access table

    func testAccessTable() {
        let id = Self.packId
        XCTAssertFalse(VaultPackAccess.isUnlocked(productId: id, licensePack: "hvac_rtu", purchasedProducts: [], licensedPacks: [], tier: .solo))
        XCTAssertTrue(VaultPackAccess.isUnlocked(productId: id, licensePack: "hvac_rtu", purchasedProducts: [id], licensedPacks: [], tier: .solo))
        XCTAssertTrue(VaultPackAccess.isUnlocked(productId: id, licensePack: "hvac_rtu", purchasedProducts: [], licensedPacks: ["hvac_rtu"], tier: .team))
        XCTAssertFalse(VaultPackAccess.isUnlocked(productId: id, licensePack: "hvac_rtu", purchasedProducts: [], licensedPacks: ["other"], tier: .team))
        XCTAssertTrue(VaultPackAccess.isUnlocked(productId: id, licensePack: "hvac_rtu", purchasedProducts: [], licensedPacks: [], tier: .enterprise))
        XCTAssertFalse(VaultPackAccess.isUnlocked(productId: id, licensePack: "hvac_rtu", purchasedProducts: [], licensedPacks: [], tier: nil))
    }

    func testLicencePacksClaimFlowsThroughEvidence() throws {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "Acme", issued: Date(timeIntervalSince1970: 0),
                                                    expires: Date(timeIntervalSince1970: 1_000), tier: "team", packs: ["hvac_rtu", "electrical"])
        let code = try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
        let provider = LiveFieldAssistEntitlementProvider(storePurchases: VerifiedStorePurchaseRecorder(),
                                                          licensePublicKeyBase64: publicKeyBase64, licenseCode: { code })
        XCTAssertEqual(FieldAssistEntitlementEvaluator.livePacks(provider.evidence(), now: Date(timeIntervalSince1970: 10)), ["hvac_rtu", "electrical"])
        XCTAssertEqual(FieldAssistEntitlementEvaluator.livePacks(provider.evidence(), now: Date(timeIntervalSince1970: 2_000)), [], "a lapsed code contributes no packs")

        let decoded = try LicenseService.decode(code: code, publicKeyBase64: publicKeyBase64)
        XCTAssertEqual(decoded.packs, ["hvac_rtu", "electrical"])
        let legacy = try LicenseService.decode(code: LicenseService.makeCode(
            payload: .init(feature: "field_assist", licensee: "Old", issued: Date(), expires: nil), privateKeyBase64: privateKeyBase64),
            publicKeyBase64: publicKeyBase64)
        XCTAssertNil(legacy.packs)
    }

    // MARK: - Row state

    func testRowStateResolution() throws {
        let pack = try signedPack()
        let e = entry(for: pack, version: "1.2.0")
        XCTAssertEqual(VaultPackRowState.resolve(entry: entry(for: pack, minAppBuild: 999), installedVersion: nil, unlocked: true, fieldAssistGranted: true, currentBuild: 400), .needsNewerApp(minBuild: 999))
        XCTAssertEqual(VaultPackRowState.resolve(entry: e, installedVersion: nil, unlocked: false, fieldAssistGranted: false, currentBuild: 400), .needsFieldAssist)
        XCTAssertEqual(VaultPackRowState.resolve(entry: e, installedVersion: nil, unlocked: false, fieldAssistGranted: true, currentBuild: 400), .buy(productId: Self.packId))
        XCTAssertEqual(VaultPackRowState.resolve(entry: e, installedVersion: nil, unlocked: true, fieldAssistGranted: true, currentBuild: 400), .install)
        XCTAssertEqual(VaultPackRowState.resolve(entry: e, installedVersion: "1.1.9", unlocked: true, fieldAssistGranted: true, currentBuild: 400), .update(installed: "1.1.9"))
        XCTAssertEqual(VaultPackRowState.resolve(entry: e, installedVersion: "1.2.0", unlocked: true, fieldAssistGranted: true, currentBuild: 400), .installed)
        XCTAssertTrue(VaultPackRowState.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(VaultPackRowState.isNewer("1.0", than: "1.0.0"))
    }

    // MARK: - Install pipeline

    func testInstallThroughTheCatalogAndUnlockByLicenceOrPurchase() async throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .solo)
        let pack = try signedPack()
        let svc = try service(zip: pack.zip, entries: [entry(for: pack)])
        await svc.loadCatalog()
        guard case .loaded(let entries) = svc.catalogState, let e = entries.first else { return XCTFail("\(svc.catalogState)") }
        XCTAssertEqual(svc.rowState(for: e), .buy(productId: Self.packId), "solo without the purchase")

        // Install regardless of entitlement: the gate is on use, and a purchase may arrive later.
        await svc.install(e)
        guard case .installed? = svc.installStates[e.id] else { return XCTFail("\(String(describing: svc.installStates[e.id]))") }
        XCTAssertEqual(VaultImporter.installedPack(for: "hvac_rtu")?.version, "1.0.0")
        XCTAssertNotNil(VaultRegistry.shared.manifest(id: "hvac_rtu"))
        XCTAssertFalse(VaultRegistry.shared.isUnlocked("hvac_rtu"), "installed but not entitled")
        XCTAssertFalse(VaultExporter.isExportable(VaultRegistry.shared.manifest(id: "hvac_rtu")!), "paid content never exports")

        // A licence that lists the pack unlocks it.
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider(.init(evidence: [
            .verifiedOrganizationLicense(licenseIDHash: "t", expiration: nil, tier: .team, packs: ["hvac_rtu"])
        ]))
        XCTAssertTrue(VaultRegistry.shared.isUnlocked("hvac_rtu"))
        XCTAssertEqual(svc.rowState(for: e), .installed)

        // So does a purchase of the product, on a solo device.
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .solo)
        VerifiedStorePurchaseRecorder.shared.recordPackProducts([Self.packId])
        XCTAssertTrue(VaultRegistry.shared.isUnlocked("hvac_rtu"))
        VerifiedStorePurchaseRecorder.shared.recordPackProducts([])
        XCTAssertFalse(VaultRegistry.shared.isUnlocked("hvac_rtu"))

        // Enterprise includes every pack.
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        XCTAssertTrue(VaultRegistry.shared.isUnlocked("hvac_rtu"))

        // The audit line names the pack and its author.
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        let sessions = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let session = try FieldSessionService(sessionsRoot: sessions).startSession(vaultId: "hvac_rtu", assetId: nil)
        let dir = sessions.appendingPathComponent(session.id, isDirectory: true)
        let joined = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined().replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(joined.contains("pack=\(Self.packId)@1.0.0, author=Prairie Mechanical"), joined)
    }

    func testUpdateKeepsTechnicianEditsAndDetectsVersions() async throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        let v1 = try signedPack()
        let svc1 = try service(zip: v1.zip, entries: [entry(for: v1)])
        await svc1.loadCatalog(); await svc1.install(svc1.entries[0])
        // A technician edits a core file; the edit lives in the overlay.
        let store = VaultRegistry.shared.store(forId: "hvac_rtu")!
        _ = try store.write("safety.md", contents: "# Safety\n\nLock out power. Site rule: two-person panel opens.")

        var files = vaultFiles()
        files["error_codes.md"] = Data("# Fault Codes\n\n## RTU-500\n\n| ZX9 | Low charge |\n| ZX3 | Fan failure |".utf8)
        let v2 = try signedPack(pack: packManifest(version: "1.1.0"), files: files)
        let svc2 = try service(zip: v2.zip, entries: [entry(for: v2, version: "1.1.0")])
        await svc2.loadCatalog()
        XCTAssertEqual(svc2.rowState(for: svc2.entries[0]), .update(installed: "1.0.0"))
        await svc2.install(svc2.entries[0])
        XCTAssertEqual(svc2.rowState(for: svc2.entries[0]), .installed)
        VaultRegistry.shared.resetCache()
        let updated = VaultRegistry.shared.store(forId: "hvac_rtu")!
        XCTAssertTrue(updated.read("error_codes.md")?.contains("ZX3") ?? false, "baseline updated")
        XCTAssertTrue(updated.read("safety.md")?.contains("two-person") ?? false, "overlay edit survived")
    }

    func testInstallRefusesBadChecksumSignatureStructureAndDocuments() async throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        let good = try signedPack()

        var badSum = entry(for: good); badSum = VaultPackCatalogEntry(id: badSum.id, vaultId: badSum.vaultId, version: badSum.version, name: badSum.name, summary: badSum.summary, author: badSum.author, minAppBuild: nil, downloadURL: badSum.downloadURL, sha256: String(repeating: "0", count: 64), packSignature: badSum.packSignature)
        let s1 = try service(zip: good.zip, entries: [badSum]); await s1.loadCatalog(); await s1.install(s1.entries[0])
        XCTAssertEqual(s1.installStates[Self.packId], .failed("download doesn't match the catalog's checksum"))

        let forged = try VaultPackSignature.sign(packManifestData: good.packData, files: good.files,
                                                 privateKeyBase64: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        let e2 = VaultPackCatalogEntry(id: Self.packId, vaultId: "hvac_rtu", version: "1.0.0", name: "x", downloadURL: "https://example.test/z.zip", sha256: VaultPackArchive.sha256Hex(good.zip), packSignature: forged)
        let s2 = try service(zip: good.zip, entries: [e2]); await s2.loadCatalog(); await s2.install(s2.entries[0])
        XCTAssertEqual(s2.installStates[Self.packId], .failed("pack signature invalid — refusing to install"))

        let wrongGating = try signedPack(files: vaultFiles(gating: "enterprise"))
        let s3 = try service(zip: wrongGating.zip, entries: [entry(for: wrongGating)]); await s3.loadCatalog(); await s3.install(s3.entries[0])
        XCTAssertEqual(s3.installStates[Self.packId], .failed("vault gating must name the pack id"))

        let withDocs = try signedPack(files: vaultFiles(withDocuments: true))
        let s4 = try service(zip: withDocs.zip, entries: [entry(for: withDocs)]); await s4.loadCatalog(); await s4.install(s4.entries[0])
        XCTAssertEqual(s4.installStates[Self.packId], .failed("a pack must not ship documents; customers load their own manuals"))

        let old = try signedPack(pack: packManifest(minAppBuild: 999))
        let s5 = try service(zip: old.zip, entries: [entry(for: old, minAppBuild: 999)], currentBuild: 400); await s5.loadCatalog()
        XCTAssertEqual(s5.rowState(for: s5.entries[0]), .needsNewerApp(minBuild: 999))
        await s5.install(s5.entries[0])
        XCTAssertEqual(s5.installStates[Self.packId], .failed("this pack needs app build 999 or newer"))
        XCTAssertNil(VaultImporter.installedPack(for: "hvac_rtu"))
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
