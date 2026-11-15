import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan LV P1 — a published vault on a real install, end to end: an in-memory transport, a fixture
/// company enrolled through `OrgProfileManager`, the company vault pass, and the live installer
/// writing the vault, its company layer and its manuals to this test host's Documents.
///
/// Every name is invented: the partner is "Fixture Partner", the vault "Fixture Split Systems".
@MainActor
final class PublishedVaultServiceTests: XCTestCase {
    private let profileKey = Curve25519.Signing.PrivateKey()
    private let licenceKey = Curve25519.Signing.PrivateKey()
    private let packKey = Curve25519.Signing.PrivateKey()
    private let companySecret = ProfileContract.Credential.newSecret()
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var saved: OrgEnrolmentRecord?
    private var profileResponse = Data()
    private var catalogResponse = Data()
    private var served: [String: Data] = [:]
    private var downloads: [String] = []
    private var activeJob: String?
    private var service: CompanyVaultService!
    private var stagingRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private let profileId = "fixture-company"
    private let profileURL = URL(string: "https://licence.example.test/p/fixture-company")!
    private let catalogURL = "https://licence.example.test/c/opaque/vaults.json"
    static let base = "fixture-split-systems"
    static let layer = "fixture-split-systems-company"
    private var base: String { Self.base }
    private var layer: String { Self.layer }

    override func setUp() async throws {
        try await super.setUp()
        PolicyEnvelope.clear()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        Self.removeInstalled()
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PublishedVaultServiceTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        Self.removeInstalled()
        EntitlementTestScope.restore(previousEntitlement)
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: stagingRoot)
        try await super.tearDown()
    }

    static func removeInstalled() {
        VaultImporter.uninstall(id: base)
        VaultImporter.uninstall(id: layer)
        try? FileManager.default.removeItem(at: VaultCompanyLayer.directory(baseId: base))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
    }

    // MARK: - The fixture partner and company

    private let installText = "# Installation manual (invented fixture)\n\nPage 4\n\nQX1: check the invented interlock."
    private let serviceText = "# Service manual (invented fixture)\n\nPage 12\n\nThe company's copy, at another revision."
    private var installRevision: String { VaultPackArchive.sha256Hex(Data(installText.utf8)) }

    private var expects: [CompanyVaultContract.ExpectedManual] {
        [.init(key: "install-manual", title: "Installation manual", edition: "Rev C", revision: installRevision),
         .init(key: "service-manual", title: "Service manual", edition: "Rev B", revision: String(repeating: "5", count: 64)),
         .init(key: "wiring-diagram", title: "Wiring diagram", edition: "2024")]
    }

    /// A signed EG pack: its zip and its signature by the test's pack key.
    private func signedPack(vaultId: String, name: String, version: String, files: [(String, String)],
                            rules: [String]) throws -> (zip: Data, signature: String) {
        let packId = "com.openglasses.vault." + vaultId
        let manifest: [String: Any] = ["id": vaultId, "name": name, "version": version, "files": files.map(\.0),
                                       "documents": [], "gating": ["iap": packId], "prompt_rules": rules]
        var entries: [String: Data] = ["manifest.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])]
        for (file, text) in files { entries[file] = Data(text.utf8) }
        let packData = try JSONEncoder().encode(VaultPackManifest(id: packId, vaultId: vaultId, version: version, name: name))
        let signature = try VaultPackSignature.sign(packManifestData: packData, files: entries,
                                                    privateKeyBase64: packKey.rawRepresentation.base64EncodedString())
        entries[VaultPackManifest.filename] = packData
        return (VaultPackTests.makeZip(entries), signature)
    }

    /// The partner's vault at `version`, sealed for the company (or for `secret`).
    private func published(version: String, partnerVersion: Int, faultCodes: String? = nil, frozen: Bool? = nil,
                           secret: Data? = nil, tamper: Bool = false,
                           extra: [(String, String)] = []) throws -> CompanyVaultContract.Vault {
        let codes = faultCodes ?? """
            # Fault codes

            | Code | Meaning | Manual |
            |---|---|---|
            | QX1 | Invented fixture fault, version \(partnerVersion) | install-manual p. 4 |
            | QX2 | Invented second fault | service-manual p. 12 |
            | QX3 | Invented wiring fault | wiring-diagram p. 3 |
            """
        let pack = try signedPack(vaultId: base, name: "Fixture Split Systems", version: version,
                                  files: [("fault_codes.md", codes),
                                          ("safety.md", "# Safety\n\nInvented fixture: isolate the QX-100 first.")] + extra,
                                  rules: ["Invented fixture content.", "Never fabricate a value.", "Cite the source file for every claim."])
        var sealed = try CompanyCoreSeal.seal(pack.zip, context: .init(profileId: profileId, vaultId: base,
                                                                         packId: "com.openglasses.vault." + base, version: version),
                                              companySecret: secret ?? companySecret)
        let digest = VaultPackArchive.sha256Hex(sealed)
        if tamper { sealed[sealed.count - 5] ^= 0x20 }
        let url = "https://licence.example.test/v/\(base)-\(version).sealed"
        served[url] = sealed
        return .init(id: "com.openglasses.vault." + base, vaultId: base, version: version, name: "Fixture Split Systems",
                     sizeBytes: sealed.count, downloadURL: url, sha256: digest, packSignature: pack.signature,
                     publisher: .init(id: "p-fixture", name: "Fixture Partner", version: partnerVersion),
                     sealedCore: true, expects: expects, frozen: frozen)
    }

    /// The company's own layer over the partner's vault.
    private func companyLayer(version: String, files: [(String, String)]? = nil) throws -> CompanyVaultContract.Vault {
        let pack = try signedPack(vaultId: layer, name: "Fixture Company Notes", version: version,
                                  files: files ?? [("site_notes.md", "# Site notes\n\nInvented: the company stocks part QX-100-F1.")],
                                  rules: ["Prefer the company's own part numbers from site_notes.md."])
        let url = "https://licence.example.test/v/\(layer)-\(version).zip"
        served[url] = pack.zip
        return .init(id: "com.openglasses.vault." + layer, vaultId: layer, version: version, name: "Fixture Company Notes",
                     sizeBytes: pack.zip.count, downloadURL: url, sha256: VaultPackArchive.sha256Hex(pack.zip),
                     packSignature: pack.signature, extends: base)
    }

    /// A plain company vault, as before Plan LV.
    private func plain(_ vaultId: String, version: String) throws -> CompanyVaultContract.Vault {
        let pack = try signedPack(vaultId: vaultId, name: "Fixture Rooftop", version: version,
                                  files: [("fault_codes.md", "# Fault codes\n\n| QZ1 | Invented |")],
                                  rules: ["Never fabricate a value.", "Cite the source file for every claim."])
        let url = "https://licence.example.test/v/\(vaultId)-\(version).zip"
        served[url] = pack.zip
        return .init(id: "com.openglasses.vault." + vaultId, vaultId: vaultId, version: version, name: "Fixture Rooftop",
                     sizeBytes: pack.zip.count, downloadURL: url, sha256: VaultPackArchive.sha256Hex(pack.zip),
                     packSignature: pack.signature)
    }

    private func manual(_ name: String, text: String, in vaultId: String? = nil) throws -> CompanyVaultContract.Manual {
        let vaultId = vaultId ?? base
        let plain = Data(text.utf8)
        let revision = VaultPackArchive.sha256Hex(plain)
        let sealed = try CompanyVaultContract.ManualSeal.seal(
            plain, context: .init(profileId: profileId, vaultId: vaultId, fileName: name, revision: revision),
            companySecret: companySecret)
        let url = "https://licence.example.test/m/\(vaultId)/\(revision.prefix(12))"
        served[url] = sealed
        return .init(vaultId: vaultId, fileName: name, revision: revision, sizeBytes: plain.count,
                     sealedSha256: VaultPackArchive.sha256Hex(sealed), downloadURL: url, kind: .md)
    }

    private var manuals: [CompanyVaultContract.Manual] {
        get throws { [try manual("Installation manual.md", text: installText), try manual("Service manual.md", text: serviceText)] }
    }

    private func publish(generation: Int, vaults: [CompanyVaultContract.Vault], manuals: [CompanyVaultContract.Manual]) throws {
        catalogResponse = try CompanyVaultContract.sign(
            .init(profileId: profileId, generation: generation, issued: clock, manualsOnAnyNetwork: true,
                  vaults: vaults, manuals: manuals),
            signer: packKey.signature(for:))
        let profile = ConfigProfile(keyId: "fixture-profile", profileId: profileId, organizationName: "Fixture Mechanical",
                                    issued: clock, leaseDays: 30,
                                    companyVaults: .init(catalog: catalogURL, generation: generation, minAppBuild: nil))
        profileResponse = Data(try ProfileVerification.makeDocument(
            profile, privateKeyBase64: profileKey.rawRepresentation.base64EncodedString()).utf8)
    }

    private func manager(secret: @escaping () -> Data? = { nil }) -> OrgProfileManager {
        var s = OrgProfileManager.Seams()
        s.verificationKeys = ["fixture-profile": profileKey.publicKey.rawRepresentation.base64EncodedString()]
        s.licenceKey = licenceKey.publicKey.rawRepresentation.base64EncodedString()
        s.now = { self.clock }; s.loadRecord = { self.saved }; s.saveRecord = { self.saved = $0 }
        s.readSetting = { _ in nil }; s.writeSetting = { _, _ in }
        s.storedLicenceCode = { nil }; s.activateLicence = { _ in }; s.clearLicence = {}
        s.resolvableVaultIds = { [] }; s.installEnvelope = { _, _ in }; s.clearEnvelope = {}
        s.fetch = { _ in self.profileResponse }; s.activeJobId = { self.activeJob }; s.withholdLicence = { _ in }
        s.closeManagedAccess = { _ in }
        s.loadModels = { [] }; s.saveModels = { _ in }; s.activeModelId = { "" }; s.setActiveModelId = { _ in }
        s.forgetAdminCard = {}
        var vs = CompanyVaultService.Seams()
        vs.fetchCatalog = { _ in self.catalogResponse }
        vs.download = { url, bytes, staging in
            self.downloads.append(url.absoluteString)
            let data = try XCTUnwrap(self.served[url.absoluteString])
            guard data.count <= bytes else { throw VaultLinkStagingError.tooLarge }
            let archive = try staging.create()
            try staging.append(data, to: archive)
            return archive
        }
        vs.publicKeyBase64 = packKey.publicKey.rawRepresentation.base64EncodedString()
        vs.companySecret = { secret() ?? self.companySecret }
        vs.currentBuild = { 700 }
        vs.network = { .unmetered }
        vs.freeBytes = { 100 * 1_073_741_824 }
        vs.activeJob = { self.activeJob.map { .open(vaultId: $0) } ?? .none }
        vs.now = { self.clock }
        vs.staging = { VaultLinkStagingStore(root: self.stagingRoot, maximumBytes: VaultLinkStagingStore.companyVaultMaximumBytes) }
        vs.vaults = { LiveCompanyVaultInstaller.shared }
        let vaults = CompanyVaultService(seams: vs)
        service = vaults
        s.syncCompanyVaults = { await vaults.sync($0) }
        let m = OrgProfileManager(seams: s)
        vaults.seams.manager = { m }
        return m
    }

    private func enrol(_ m: OrgProfileManager) async throws {
        let review = try m.review(document: String(decoding: profileResponse, as: UTF8.self), source: .link,
                                  sourceURL: profileURL).get()
        try m.apply(review).get()
        await m.completeEnrolment()
    }

    private func renew(_ m: OrgProfileManager) async {
        clock = clock.addingTimeInterval(2 * 86_400)
        await m.renewIfDue(force: true)
    }

    private var state: CompanyVaultState? { saved?.companyVaults }
    private func row(_ id: String) -> CompanyVaultRow? { service.rows().first { $0.vaultId == id } }
    private func vaultStore() throws -> VaultStore {
        VaultRegistry.shared.resetCache()
        return try XCTUnwrap(VaultRegistry.shared.store(forId: base))
    }

    // MARK: - Subscribe

    func testSubscribingInstallsTheSealedCoreItsLayerAndTheCompanysManuals() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)

        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(VaultImporter.installedPack(for: base)?.version, "1", "the sealed core opened and installed")
        XCTAssertEqual(state?.vaults[base]?.publisherName, "Fixture Partner")
        XCTAssertEqual(state?.vaults[base]?.publisherVersion, 5)
        XCTAssertEqual(state?.vaults[layer]?.extends, base)
        XCTAssertEqual(VaultCompanyLayer.installed(baseId: base)?.pack.version, "1")
        XCTAssertNil(VaultImporter.installedManifest(id: layer), "a layer is never a vault of its own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultImporter.baselineDirectory(for: base)
            .appendingPathComponent("site_notes.md").path), "the layer is its own baseline, not the publisher's")

        let store = try vaultStore()
        XCTAssertEqual(store.manifest.files, ["fault_codes.md", "safety.md", "site_notes.md"])
        XCTAssertTrue(store.manifest.promptRules.contains("Prefer the company's own part numbers from site_notes.md."))
        XCTAssertTrue(store.read("site_notes.md")?.contains("QX-100-F1") ?? false)
        XCTAssertTrue(store.read("safety.md")?.contains("isolate") ?? false)
        XCTAssertEqual(store.layer(of: "site_notes.md"), .company)
        XCTAssertEqual(store.layer(of: "fault_codes.md"), .publisher)

        let documents = try XCTUnwrap(VaultImporter.installedManifest(id: base)?.documents)
        XCTAssertEqual(documents.map(\.file).sorted(), ["Installation manual.md", "Service manual.md"])
        XCTAssertEqual(documents.map(\.origin), [.company, .company])
        XCTAssertEqual(documents.first { $0.file == "Installation manual.md" }?.revision, installRevision)
    }

    func testThePublishedRowSaysWhoseItIsAndNamesEachManual() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)
        let baseRow = try XCTUnwrap(row(base))
        XCTAssertEqual(baseRow.byline, "from Fixture Partner · version 5")
        XCTAssertNil(baseRow.frozenNote)
        XCTAssertNil(baseRow.status)
        let checklist = try XCTUnwrap(baseRow.checklist)
        XCTAssertEqual(checklist.summary, "2 of 3 manuals · 1 a different revision · 1 missing")
        XCTAssertEqual(checklist.entries.map(\.title), ["Installation manual (Rev C)", "Service manual (Rev B)", "Wiring diagram (2024)"])
        XCTAssertEqual(checklist.entries.map(\.status), ["Held", "A different revision", "Missing"])
        XCTAssertTrue(checklist.hasDifferences)
        XCTAssertEqual(service.rows().map(\.vaultId), [base, layer])
        XCTAssertEqual(row(layer)?.layerNote, "Adds to Fixture Split Systems")
        XCTAssertNil(row(layer)?.byline)
        XCTAssertNil(row(layer)?.checklist)
    }

    func testAnAnswerSaysWhoseFilesAndNamesTheRevisionAndTheMissingManual() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)
        let note = try XCTUnwrap(service.answerNote(for: try vaultStore()))
        XCTAssertTrue(note.contains("\"From Fixture Partner's vault\""), note)
        XCTAssertTrue(note.contains("fault_codes.md, safety.md."), "the partner's files, not the company's: \(note)")
        XCTAssertFalse(note.contains("site_notes.md,"))
        XCTAssertTrue(note.contains("\"Your copy of Service manual is a different revision from the one this vault was written for; check page 12.\""), note)
        XCTAssertTrue(note.contains("\"This vault expects Wiring diagram, which isn't on this phone.\""), note)
        XCTAssertFalse(note.contains("Your copy of Installation manual"), "a matched manual says nothing")
    }

    // MARK: - v5 → v6

    func testVersionSixKeepsTheCompanyLayerAndTheTechniciansEdit() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)
        // The technician edits one of the partner's files and one of the company's.
        _ = try vaultStore().write("safety.md", contents: "# Safety\n\nInvented site rule: two people at the panel.")
        _ = try vaultStore().write("site_notes.md", contents: "# Site notes\n\nInvented: our van stocks QX-100-F2 instead.")
        downloads = []

        try publish(generation: 2, vaults: [try published(version: "2", partnerVersion: 6,
                                                          faultCodes: "# Fault codes\n\n| QX9 | Invented version 6 fault | install-manual p. 4 |"),
                                            try companyLayer(version: "1")],
                    manuals: try manuals)
        await renew(m)
        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(VaultImporter.installedPack(for: base)?.version, "2")
        XCTAssertEqual(row(base)?.byline, "from Fixture Partner · version 6")
        XCTAssertTrue(downloads.contains { $0.contains(layer) }, "the layer is laid again over the new base and checked against it")
        XCTAssertFalse(downloads.contains { $0.contains("/m/") }, "the manuals stay; nothing of them moves")

        let store = try vaultStore()
        XCTAssertTrue(store.read("fault_codes.md")?.contains("QX9") ?? false, "the partner's update arrived")
        XCTAssertTrue(store.read("safety.md")?.contains("two people") ?? false, "the technician's edit survived")
        XCTAssertTrue(store.read("site_notes.md")?.contains("QX-100-F2") ?? false, "the technician's edit to the company file survived")
        XCTAssertEqual(store.manifest.files, ["fault_codes.md", "safety.md", "site_notes.md"], "the company layer survived")
        XCTAssertEqual(VaultImporter.installedManifest(id: base)?.documents.map(\.origin), [.company, .company])
        XCTAssertEqual(VaultImporter.installedManifest(id: base)?.documents.compactMap(\.revision).count, 2)

        // The technician's edit to the company's file is theirs; without it the company's own reads.
        try FileManager.default.removeItem(at: store.overlayRoot.appendingPathComponent("site_notes.md"))
        XCTAssertTrue(try self.vaultStore().read("site_notes.md")?.contains("QX-100-F1") ?? false)
    }

    func testTheCompanyRemovingItsLayerLeavesThePartnersVaultAndTheTechniciansEdits() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)
        _ = try vaultStore().write("safety.md", contents: "# Safety\n\nInvented site rule: two people at the panel.")

        try publish(generation: 2, vaults: [try published(version: "1", partnerVersion: 5)], manuals: try manuals)
        await renew(m)
        XCTAssertNil(VaultCompanyLayer.installed(baseId: base))
        XCTAssertNil(state?.vaults[layer])
        XCTAssertEqual(state?.removedNames, ["Fixture Company Notes"])
        let store = try vaultStore()
        XCTAssertEqual(store.manifest.files, ["fault_codes.md", "safety.md"])
        XCTAssertTrue(store.read("safety.md")?.contains("two people") ?? false)
        XCTAssertNil(store.read("site_notes.md"))
        XCTAssertEqual(VaultImporter.installedPack(for: base)?.version, "1")
    }

    func testThePartnerEndingTheSubscriptionRemovesTheVaultAndSaysWho() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1"),
                                            try plain("fixture-rooftop", version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)
        try publish(generation: 2, vaults: [try plain("fixture-rooftop", version: "1")], manuals: [])
        await renew(m)
        XCTAssertNil(VaultImporter.installedManifest(id: base))
        XCTAssertNil(VaultCompanyLayer.installed(baseId: base), "the layer goes with the vault it adds to")
        XCTAssertNil(state?.vaults[layer])
        XCTAssertEqual(state?.removedPublished, [.init(name: "Fixture Split Systems", publisher: "Fixture Partner")])
        XCTAssertEqual(state?.removedNames, [], "the layer leaving with it is not a second notice")
        XCTAssertEqual(CompanyVaultRowList.removalNotices(state?.removedPublished ?? []),
                       ["Fixture Split Systems was removed by Fixture Partner."])
        VaultImporter.uninstall(id: "fixture-rooftop")
    }

    // MARK: - Refused

    func testALayerThatWouldReplaceAPartnersFileIsRefusedAndNamed() async throws {
        let collides = try companyLayer(version: "1", files: [("fault_codes.md", "# Fault codes\n\nThe company's own."),
                                                               ("site_notes.md", "# Site notes\n\nInvented.")])
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), collides], manuals: try manuals)
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(row(layer)?.status,
                       "Couldn't install Fixture Company Notes: it would replace fault_codes.md in Fixture Split Systems, and your company's own files may only be added.")
        XCTAssertEqual(row(layer)?.isProblem, true)
        XCTAssertNil(VaultCompanyLayer.installed(baseId: base), "nothing of it is installed")
        XCTAssertNil(state?.vaults[layer])
        let store = try vaultStore()
        XCTAssertEqual(store.manifest.files, ["fault_codes.md", "safety.md"])
        XCTAssertTrue(store.read("fault_codes.md")?.contains("QX1") ?? false, "the partner's file stands")
        XCTAssertEqual(VaultImporter.installedPack(for: base)?.version, "1", "the vault itself still installs")
    }

    func testAPartnerUpdateThatTakesTheLayersFileNameRefusesTheLayerAndSaysSo() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5), try companyLayer(version: "1")],
                    manuals: try manuals)
        let m = manager()
        try await enrol(m)
        // Version 6 ships a file of the same name as the company's own.
        try publish(generation: 2, vaults: [try published(version: "2", partnerVersion: 6,
                                                          extra: [("Site_Notes.md", "# Site notes\n\nThe partner's own.")]),
                                            try companyLayer(version: "1")],
                    manuals: try manuals)
        await renew(m)
        XCTAssertEqual(VaultImporter.installedPack(for: base)?.version, "2", "the partner's update installs")
        XCTAssertEqual(row(layer)?.status,
                       "Couldn't install Fixture Company Notes: it would replace site_notes.md in Fixture Split Systems, and your company's own files may only be added.")
        XCTAssertNil(VaultCompanyLayer.installed(baseId: base), "a layer that no longer fits is never read")
        XCTAssertEqual(try vaultStore().manifest.files, ["fault_codes.md", "safety.md", "Site_Notes.md"])

        // It is named again on the next pass, not forgotten.
        await renew(m)
        XCTAssertEqual(row(layer)?.isProblem, true)
    }

    func testASealedCoreWithAnotherCompanysSecretIsRefusedAndNamed() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5,
                                                          secret: ProfileContract.Credential.newSecret())],
                    manuals: [])
        let m = manager()
        try await enrol(m)
        XCTAssertNil(VaultImporter.installedManifest(id: base))
        XCTAssertNil(state?.vaults[base])
        XCTAssertEqual(row(base)?.status, "Fixture Split Systems couldn't be opened with your company's key, so it was refused.")
        XCTAssertEqual(row(base)?.isProblem, true)
        XCTAssertNotEqual(state?.appliedGeneration, 1, "tried again at the next launch or foreground")
    }

    func testASealedCoreAlteredOnTheWayIsRefused() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5, tamper: true)], manuals: [])
        let m = manager()
        try await enrol(m)
        XCTAssertNil(VaultImporter.installedManifest(id: base))
        XCTAssertEqual(row(base)?.status, "Fixture Split Systems doesn't match your organisation's vault list, so it was refused.")
    }

    func testWithoutTheCompanysSecretASealedCoreIsNotDownloaded() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5)], manuals: [])
        let m = manager(secret: { Data([1, 2, 3]) })
        try await enrol(m)
        XCTAssertEqual(downloads, [])
        XCTAssertEqual(row(base)?.status,
                       "Fixture Split Systems can't be opened on this phone. Enter your company's activation key again.")
    }

    func testASealedCoreOfALengthNoPackSealsToIsNotDownloaded() async throws {
        let good = try published(version: "1", partnerVersion: 5)
        let impossible = CompanyVaultContract.Vault(
            id: good.id, vaultId: good.vaultId, version: good.version, name: good.name,
            sizeBytes: CompanyChunkedSeal.headerLength + CompanyChunkedSeal.chunkOverhead, downloadURL: good.downloadURL,
            sha256: good.sha256, packSignature: good.packSignature, publisher: good.publisher, sealedCore: true)
        try publish(generation: 1, vaults: [impossible], manuals: [])
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(downloads, [])
        XCTAssertEqual(row(base)?.status, "Fixture Split Systems didn't arrive whole. It tries again when the app opens.")
    }

    // MARK: - Frozen

    func testAFrozenVaultIsKeptAndNeverUpdated() async throws {
        try publish(generation: 1, vaults: [try published(version: "1", partnerVersion: 5)], manuals: try manuals)
        let m = manager()
        try await enrol(m)
        downloads = []
        // The partner ends: the service freezes the row, with a newer per-company version beside it.
        try publish(generation: 2, vaults: [try published(version: "2", partnerVersion: 6, frozen: true)], manuals: try manuals)
        await renew(m)
        XCTAssertEqual(VaultImporter.installedPack(for: base)?.version, "1")
        XCTAssertEqual(downloads, [], "nothing is compared, nothing is downloaded")
        XCTAssertEqual(row(base)?.frozenNote, "No longer updated by Fixture Partner · version 5 kept")
        XCTAssertEqual(row(base)?.byline, "from Fixture Partner · version 5")
        XCTAssertEqual(state?.appliedGeneration, 2)
    }

    // MARK: - Unchanged

    func testAVaultWithNoPublishingFieldsBehavesAsBefore() async throws {
        let vault = try plain("fixture-rooftop", version: "1")
        let wiring = try manual("Wiring.md", text: "# Wiring\n\nPage 1\n\nInvented.", in: "fixture-rooftop")
        try publish(generation: 1, vaults: [vault], manuals: [wiring])
        let m = manager()
        try await enrol(m)
        defer { VaultImporter.uninstall(id: "fixture-rooftop") }
        let plainRow = try XCTUnwrap(service.rows().first)
        XCTAssertEqual(plainRow.name, "Fixture Rooftop")
        XCTAssertEqual(plainRow.version, "1")
        XCTAssertNil(plainRow.byline)
        XCTAssertNil(plainRow.frozenNote)
        XCTAssertNil(plainRow.layerNote)
        XCTAssertNil(plainRow.checklist)
        XCTAssertNil(plainRow.status)
        XCTAssertNil(state?.vaults["fixture-rooftop"]?.publisherName)
        VaultRegistry.shared.resetCache()
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: "fixture-rooftop"))
        XCTAssertNil(store.companyLayer)
        XCTAssertEqual(store.manifest.files, ["fault_codes.md"])
        XCTAssertNil(service.answerNote(for: store))
        XCTAssertEqual(VaultImporter.installedManifest(id: "fixture-rooftop")?.documents.first?.origin, .company)
        // The state it writes carries none of the new keys.
        let encoded = String(decoding: try JSONEncoder().encode(try XCTUnwrap(state)), as: UTF8.self)
        for key in ["publisherName", "publisherVersion", "extends"] { XCTAssertFalse(encoded.contains(key), key) }
    }
}
