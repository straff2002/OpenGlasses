import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan LV P3 — a shared manual on a real install, end to end: an in-memory transport serving one
/// shared file, a fixture company enrolled through `OrgProfileManager`, the company vault pass, and
/// the live installer laying the manual into this test host's Documents as a company manual.
///
/// Every name is invented: the companies are `fixture-company` and `fixture-other-company`, the vault
/// "Fixture Split Systems", the manual "Installation manual".
@MainActor
final class SharedManualServiceTests: XCTestCase {
    private let profileKey = Curve25519.Signing.PrivateKey()
    private let licenceKey = Curve25519.Signing.PrivateKey()
    private let packKey = Curve25519.Signing.PrivateKey()
    private var profileId = "fixture-company"
    private var companySecret = ProfileContract.Credential.newSecret()
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var saved: OrgEnrolmentRecord?
    private var profileResponse = Data()
    private var catalogResponse = Data()
    private var served: [String: Data] = [:]
    private var downloads: [String] = []
    private var service: CompanyVaultService!
    private var stagingRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private let profileURL = URL(string: "https://licence.example.test/p/fixture-company")!
    private let catalogURL = "https://licence.example.test/c/opaque/vaults.json"
    static let vaultId = "fixture-split-systems"
    private var vaultId: String { Self.vaultId }
    private let contentId = "c-fixture-installation-manual"
    private let fileName = "Installation manual.md"
    private let installText = "# Installation manual (invented fixture)\n\nPage 4\n\nQX1: check the invented interlock. One shared copy."

    override func setUp() async throws {
        try await super.setUp()
        PolicyEnvelope.clear()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        Self.removeInstalled()
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SharedManualServiceTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        Self.removeInstalled()
        EntitlementTestScope.restore(previousEntitlement)
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: stagingRoot)
        try await super.tearDown()
    }

    static func removeInstalled() {
        VaultImporter.uninstall(id: vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
    }

    // MARK: - The partner's file and the company's rows

    /// A signed plain EG pack for the vault the manual belongs to.
    private func vault(minAppBuild: Int? = 692) throws -> CompanyVaultContract.Vault {
        let packId = "com.openglasses.vault." + vaultId
        let manifest: [String: Any] = ["id": vaultId, "name": "Fixture Split Systems", "version": "8", "files": ["safety.md"],
                                       "documents": [], "gating": ["iap": packId],
                                       "prompt_rules": ["Never fabricate a value.", "Cite the source file for every claim."]]
        var entries: [String: Data] = ["manifest.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
                                       "safety.md": Data("# Safety\n\nInvented fixture: isolate the QX-100 first.".utf8)]
        let packData = try JSONEncoder().encode(VaultPackManifest(id: packId, vaultId: vaultId, version: "8", name: "Fixture Split Systems"))
        let signature = try VaultPackSignature.sign(packManifestData: packData, files: entries,
                                                    privateKeyBase64: packKey.rawRepresentation.base64EncodedString())
        entries[VaultPackManifest.filename] = packData
        let zip = VaultPackTests.makeZip(entries)
        let url = "https://licence.example.test/v/\(vaultId)-8.zip"
        served[url] = zip
        return .init(id: packId, vaultId: vaultId, version: "8", name: "Fixture Split Systems", minAppBuild: minAppBuild,
                     sizeBytes: zip.count, downloadURL: url, sha256: VaultPackArchive.sha256Hex(zip), packSignature: signature)
    }

    private struct SharedFile {
        let url: String
        let sealedSha256: String
        let revision: String
        let size: Int
        let key: Data
        let keyId: Int
    }

    /// The service seals the manual once under a new content key and serves it at one address.
    private func sharedFile(text: String? = nil, keyId: Int = 1, tamper: Bool = false) throws -> SharedFile {
        let plain = Data((text ?? installText).utf8)
        let key = CompanyVaultContract.SharedManualSeal.newContentKey()
        var sealed = try CompanyVaultContract.SharedManualSeal.seal(plain, context: .init(contentId: contentId, keyId: keyId),
                                                                    contentKey: key)
        let digest = VaultPackArchive.sha256Hex(sealed)
        if tamper { sealed[sealed.count - 3] ^= 0x10 }
        let url = "https://licence.example.test/s/\(contentId)/\(keyId)-\(digest.prefix(8))"
        served[url] = sealed
        return SharedFile(url: url, sealedSha256: digest, revision: VaultPackArchive.sha256Hex(plain), size: plain.count,
                          key: key, keyId: keyId)
    }

    /// This company's row for `file`: its content key wrapped for `wrapFor` (default: this company).
    private func row(_ file: SharedFile, wrapFor: (profileId: String, secret: Data)? = nil,
                     keyId: Int? = nil) throws -> CompanyVaultContract.Manual {
        let target = wrapFor ?? (profileId, companySecret)
        let named = keyId ?? file.keyId
        let wrapped = try CompanyVaultContract.SharedManualKey.wrap(
            file.key, context: .init(profileId: target.profileId, contentId: contentId, keyId: named), companySecret: target.secret)
        return .init(vaultId: vaultId, fileName: fileName, revision: file.revision, sizeBytes: file.size,
                     sealedSha256: file.sealedSha256, downloadURL: file.url, kind: .md,
                     shared: .init(contentId: contentId, keyId: named, wrappedKey: wrapped))
    }

    /// A company-sealed manual, as before Plan LV P3.
    private func companyManual(_ name: String, text: String) throws -> CompanyVaultContract.Manual {
        let plain = Data(text.utf8)
        let revision = VaultPackArchive.sha256Hex(plain)
        let sealed = try CompanyVaultContract.ManualSeal.seal(
            plain, context: .init(profileId: profileId, vaultId: vaultId, fileName: name, revision: revision), companySecret: companySecret)
        let url = "https://licence.example.test/m/\(vaultId)/\(revision.prefix(12))"
        served[url] = sealed
        return .init(vaultId: vaultId, fileName: name, revision: revision, sizeBytes: plain.count,
                     sealedSha256: VaultPackArchive.sha256Hex(sealed), downloadURL: url, kind: .md)
    }

    /// Sign the catalog. `checked: false` signs what the service would refuse, as a broken host might serve.
    private func publish(generation: Int, vaults: [CompanyVaultContract.Vault], manuals: [CompanyVaultContract.Manual],
                         checked: Bool = true) throws {
        let catalog = CompanyVaultContract.Catalog(profileId: profileId, generation: generation, issued: clock,
                                                   manualsOnAnyNetwork: true, vaults: vaults, manuals: manuals)
        if checked {
            catalogResponse = try CompanyVaultContract.sign(catalog, signer: packKey.signature(for:), sharedManualsMinAppBuild: 692)
        } else {
            let payload = try CompanyVaultContract.encoder().encode(catalog)
            let signature = try packKey.signature(for: Data(CompanyVaultContract.catalogDomain.utf8) + payload)
            catalogResponse = try JSONEncoder().encode(CompanyVaultContract.Envelope(payload: payload.base64EncodedString(),
                                                                                     signature: signature.base64EncodedString()))
        }
        let profile = ConfigProfile(keyId: "fixture-profile", profileId: profileId, organizationName: "Fixture Mechanical",
                                    issued: clock, leaseDays: 30,
                                    companyVaults: .init(catalog: catalogURL, generation: generation, minAppBuild: nil))
        profileResponse = Data(try ProfileVerification.makeDocument(
            profile, privateKeyBase64: profileKey.rawRepresentation.base64EncodedString()).utf8)
    }

    private func manager(secret: (() -> Data?)? = nil, build: Int = 700) -> OrgProfileManager {
        var s = OrgProfileManager.Seams()
        s.verificationKeys = ["fixture-profile": profileKey.publicKey.rawRepresentation.base64EncodedString()]
        s.licenceKey = licenceKey.publicKey.rawRepresentation.base64EncodedString()
        s.now = { self.clock }; s.loadRecord = { self.saved }; s.saveRecord = { self.saved = $0 }
        s.readSetting = { _ in nil }; s.writeSetting = { _, _ in }
        s.storedLicenceCode = { nil }; s.activateLicence = { _ in }; s.clearLicence = {}
        s.resolvableVaultIds = { [] }; s.installEnvelope = { _, _ in }; s.clearEnvelope = {}
        s.fetch = { _ in self.profileResponse }; s.activeJobId = { nil }; s.withholdLicence = { _ in }
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
        vs.companySecret = { secret?() ?? self.companySecret }
        vs.currentBuild = { build }
        vs.network = { .unmetered }
        vs.freeBytes = { 100 * 1_073_741_824 }
        vs.activeJob = { .none }
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
    private var status: String? { service.rows().first { $0.vaultId == vaultId }?.status }
    private var sharedDownloads: [String] { downloads.filter { $0.contains("/s/") } }
    private var documents: [VaultDocument] { VaultImporter.installedManifest(id: vaultId)?.documents ?? [] }
    private func installedText(_ name: String) -> String? {
        let url = VaultImporter.baselineDirectory(for: vaultId).appendingPathComponent("documents/\(name)")
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Forget this phone's enrolment and install, and become another company's phone.
    private func becomeAnotherPhone(profileId: String, secret: Data) {
        Self.removeInstalled()
        saved = nil
        downloads = []
        self.profileId = profileId
        companySecret = secret
    }

    // MARK: - Arrives

    func testASharedManualIsUnwrappedOpenedAndLaidInAsACompanyManual() async throws {
        let file = try sharedFile()
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(file)])
        let m = manager()
        try await enrol(m)

        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(sharedDownloads, [file.url], "one download of the shared file")
        XCTAssertEqual(state?.manuals[vaultId], [fileName: file.revision])
        XCTAssertEqual(documents.map(\.file), [fileName])
        XCTAssertEqual(documents.first?.origin, .company)
        XCTAssertEqual(documents.first?.revision, file.revision)
        XCTAssertEqual(documents.first?.kind, "company_manual")
        XCTAssertEqual(installedText(fileName), installText)
        XCTAssertNil(status)
        XCTAssertEqual(state?.appliedGeneration, 1)
    }

    func testTwoCompaniesPhonesOpenTheSameServedFile() async throws {
        let file = try sharedFile()
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(file)])
        try await enrol(manager())
        XCTAssertEqual(installedText(fileName), installText)

        // The other company's phone: the same file at the same address, its own wrapped key.
        becomeAnotherPhone(profileId: "fixture-other-company", secret: ProfileContract.Credential.newSecret())
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(file)])
        try await enrol(manager())
        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(sharedDownloads, [file.url])
        XCTAssertEqual(installedText(fileName), installText)
        XCTAssertEqual(documents.first?.origin, .company)
    }

    func testACompanySealedManualBesideASharedOneStillArrives() async throws {
        let file = try sharedFile()
        let own = try companyManual("Service manual.md", text: "# Service manual (invented fixture)\n\nPage 12\n\nThe company's own copy.")
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(file), own])
        try await enrol(manager())
        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(documents.map(\.file).sorted(), [fileName, "Service manual.md"])
        XCTAssertEqual(documents.map(\.origin), [.company, .company])
        XCTAssertTrue(installedText("Service manual.md")?.contains("own copy") ?? false)
    }

    // MARK: - Refused

    func testAKeyWrappedWithAnotherCompanysSecretIsRefusedBeforeAnyDownload() async throws {
        let file = try sharedFile()
        try publish(generation: 1, vaults: [try vault()],
                    manuals: [try row(file, wrapFor: (profileId, ProfileContract.Credential.newSecret()))])
        try await enrol(manager())
        XCTAssertEqual(sharedDownloads, [], "a key that isn't this company's costs no download")
        XCTAssertEqual(documents, [])
        XCTAssertNil(state?.manuals[vaultId]?[fileName])
        XCTAssertEqual(status, "Installation manual doesn't match your organisation's vault list, so it was refused.")
        XCTAssertNotEqual(state?.appliedGeneration, 1, "tried again at the next launch or foreground")
        XCTAssertEqual(VaultImporter.installedPack(for: vaultId)?.version, "8", "the vault itself installs")
    }

    func testAKeyWrappedForAnotherProfileIsRefused() async throws {
        let file = try sharedFile()
        try publish(generation: 1, vaults: [try vault()],
                    manuals: [try row(file, wrapFor: ("fixture-other-company", companySecret))])
        try await enrol(manager())
        XCTAssertEqual(sharedDownloads, [])
        XCTAssertEqual(documents, [])
        XCTAssertEqual(status, "Installation manual doesn't match your organisation's vault list, so it was refused.")
    }

    func testASharedFileAlteredOnTheWayIsRefused() async throws {
        let file = try sharedFile(tamper: true)
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(file)])
        try await enrol(manager())
        XCTAssertEqual(sharedDownloads, [file.url])
        XCTAssertEqual(documents, [])
        XCTAssertEqual(status, "Installation manual doesn't match your organisation's vault list, so it was refused.")
    }

    func testWithoutTheCompanysSecretNoSharedFileIsDownloaded() async throws {
        let file = try sharedFile()
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(file)])
        try await enrol(manager(secret: { Data([1, 2, 3]) }))
        XCTAssertEqual(sharedDownloads, [])
        XCTAssertEqual(documents, [])
        XCTAssertEqual(status, "The manuals can't be opened on this phone. Enter your company's activation key again.")
    }

    func testASharedRowUnderAVaultWithoutAMinimumBuildIsLeftOutAndNamed() async throws {
        let file = try sharedFile()
        try publish(generation: 1, vaults: [try vault(minAppBuild: nil)], manuals: [try row(file)], checked: false)
        try await enrol(manager())
        XCTAssertEqual(sharedDownloads, [])
        XCTAssertEqual(documents, [])
        XCTAssertEqual(VaultImporter.installedPack(for: vaultId)?.version, "8", "the vault is kept, the row is left out")
        XCTAssertEqual(status, "A manual can't be downloaded: its entry in the vault list is incomplete.")
    }

    // MARK: - Older builds

    /// A phone below the vault row's `minAppBuild` skips the whole vault, so a shared row in it is
    /// never unwrapped, downloaded or opened.
    func testAPhoneBelowTheVaultsMinimumBuildNeverOpensASharedRow() async throws {
        let file = try sharedFile()
        // A row that would be refused if it were ever opened: its key is another company's.
        try publish(generation: 1, vaults: [try vault(minAppBuild: 692)],
                    manuals: [try row(file, wrapFor: (profileId, ProfileContract.Credential.newSecret()))])
        try await enrol(manager(build: 691))
        XCTAssertEqual(downloads, [], "neither the vault nor its shared manual is fetched")
        XCTAssertNil(VaultImporter.installedManifest(id: vaultId))
        XCTAssertEqual(state?.waits[vaultId], .newerApp(build: 692))
        XCTAssertNil(state?.failures[vaultId], "nothing was opened, so nothing was refused")
        XCTAssertNil(state?.manuals[vaultId])
    }

    // MARK: - Rotation

    /// A rotation re-encrypts the same manual under a new key at a new address. A phone that holds it
    /// at that revision keeps it: nothing is downloaded and nothing changes.
    func testARotationWithTheSameRevisionKeepsTheManualAndDownloadsNothing() async throws {
        let first = try sharedFile(keyId: 1)
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(first)])
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(installedText(fileName), installText)
        downloads = []

        let rotated = try sharedFile(keyId: 2)
        served[first.url] = nil // the old file is deleted
        XCTAssertEqual(rotated.revision, first.revision)
        try publish(generation: 2, vaults: [try vault()], manuals: [try row(rotated)])
        await renew(m)
        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(sharedDownloads, [], "the plaintext is unchanged; the phone keeps what it holds")
        XCTAssertEqual(installedText(fileName), installText)
        XCTAssertEqual(state?.manuals[vaultId], [fileName: first.revision])
        XCTAssertEqual(state?.appliedGeneration, 2)
    }

    /// A phone that did not hold the manual before the rotation downloads the new file; the key it
    /// would have kept from before opens nothing still served.
    func testAPhoneThatJoinsAfterARotationOpensTheNewFileAndTheOldKeyOpensNothing() async throws {
        let first = try sharedFile(keyId: 1)
        let rotated = try sharedFile(keyId: 2)
        served[first.url] = nil
        try publish(generation: 2, vaults: [try vault()], manuals: [try row(rotated)])
        try await enrol(manager())
        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(sharedDownloads, [rotated.url])
        XCTAssertEqual(installedText(fileName), installText)
        let servedRotated = try XCTUnwrap(served[rotated.url])
        XCTAssertThrowsError(try CompanySharedManualSeal.open(servedRotated, context: .init(contentId: contentId, keyId: 1),
                                                              contentKey: first.key, revision: first.revision))
        XCTAssertThrowsError(try CompanySharedManualSeal.open(servedRotated, context: .init(contentId: contentId, keyId: 2),
                                                              contentKey: first.key, revision: first.revision))
    }

    /// A rotation that also carries a new revision replaces the manual as any new revision does.
    func testARotationWithANewRevisionReplacesTheManual() async throws {
        let first = try sharedFile(keyId: 1)
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(first)])
        let m = manager()
        try await enrol(m)
        downloads = []

        let revised = try sharedFile(text: installText + "\n\nRev D: invented fixture correction.", keyId: 2)
        try publish(generation: 2, vaults: [try vault()], manuals: [try row(revised)])
        await renew(m)
        XCTAssertEqual(state?.failures, [:])
        XCTAssertEqual(sharedDownloads, [revised.url])
        XCTAssertTrue(installedText(fileName)?.contains("Rev D") ?? false)
        XCTAssertEqual(state?.manuals[vaultId], [fileName: revised.revision])
        XCTAssertEqual(documents.map(\.revision), [revised.revision])
    }

    /// A row naming the old `keyId` beside the new key, or the old key beside the rotated file, is
    /// refused on the row; nothing already installed is touched.
    func testAStaleKeyAgainstTheRotatedFileIsRefused() async throws {
        let first = try sharedFile(keyId: 1)
        let rotated = try sharedFile(keyId: 2)
        // The new key, but the row names keyId 1: the key unwraps (it was wrapped under that
        // context), and the file, sealed under keyId 2, does not open with it.
        try publish(generation: 1, vaults: [try vault()], manuals: [try row(rotated, keyId: 1)])
        try await enrol(manager())
        XCTAssertEqual(documents, [])
        XCTAssertEqual(status, "Installation manual doesn't match your organisation's vault list, so it was refused.")

        // The old key and keyId, pointed at the rotated file.
        becomeAnotherPhone(profileId: "fixture-company", secret: companySecret)
        let stale = try row(first)
        let mixed = CompanyVaultContract.Manual(vaultId: stale.vaultId, fileName: stale.fileName, revision: stale.revision,
                                                sizeBytes: stale.sizeBytes, sealedSha256: rotated.sealedSha256,
                                                downloadURL: rotated.url, kind: .md, shared: stale.shared)
        try publish(generation: 1, vaults: [try vault()], manuals: [mixed])
        try await enrol(manager())
        XCTAssertEqual(sharedDownloads, [rotated.url])
        XCTAssertEqual(documents, [])
        XCTAssertEqual(status, "Installation manual doesn't match your organisation's vault list, so it was refused.")
    }
}
