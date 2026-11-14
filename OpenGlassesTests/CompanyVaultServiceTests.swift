import CryptoKit
import XCTest
@testable import OpenGlasses

/// The phone, as far as the company vault pass can tell: vaults by id, and the bytes of each
/// manual laid into them.
@MainActor
final class InMemoryCompanyVaults: CompanyVaultInstalling {
    var vaults: [String: CompanyVaultPlan.InstalledVault] = [:]
    var manuals: [String: [String: Data]] = [:]
    var installs: [String] = []
    var relays: [(vaultId: String, adding: [String], removing: Set<String>)] = []
    var uninstalled: [String] = []
    var installFailure: String?
    /// The job's vault while a change is laid in, to prove nothing changes under an open job.
    var jobVault: () -> String? = { nil }
    var changedUnderJob = false

    func installedPack(vaultId: String) -> CompanyVaultPlan.InstalledVault? { vaults[vaultId] }

    func install(_ vault: CompanyVaultCatalog.Vault, fetch: @escaping (URL) async throws -> Data,
                 publicKeyBase64: String, currentBuild: Int) async -> String? {
        if jobVault() == vault.vaultId && vaults[vault.vaultId] != nil { changedUnderJob = true }
        do {
            let zip = try await fetch(try XCTUnwrap(URL(string: vault.downloadURL)))
            guard VaultPackArchive.sha256Hex(zip) == vault.sha256 else { return "download doesn't match the catalog's checksum" }
        } catch {
            return "download failed"
        }
        if let installFailure { return installFailure }
        vaults[vault.vaultId] = .init(packId: vault.id, version: vault.version)
        installs.append("\(vault.vaultId)@\(vault.version)")
        return nil
    }

    func applyManuals(vaultId: String, adding: [StagedCompanyManual], removing: Set<String>) async throws {
        if jobVault() == vaultId { changedUnderJob = true }
        var held = manuals[vaultId] ?? [:]
        for name in removing { held[name] = nil }
        for item in adding { held[item.manual.fileName] = try Data(contentsOf: item.file) }
        manuals[vaultId] = held
        relays.append((vaultId, adding.map(\.manual.fileName), removing))
    }

    func uninstall(vaultId: String) async {
        if jobVault() == vaultId { changedUnderJob = true }
        vaults[vaultId] = nil
        manuals[vaultId] = nil
        uninstalled.append(vaultId)
    }
}

/// Plan LR P1 — the company vault pass against an in-memory transport, a fixture company and an
/// in-memory phone: the plan's exit cases, end to end through `OrgProfileManager`'s renewal.
@MainActor
final class CompanyVaultServiceTests: XCTestCase {
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
    private var catalogFetches = 0
    /// The vault list's host can't be reached (no signal, the host down).
    private var catalogUnreachable = false
    private var activeJob: String?
    private var network = CompanyVaultPlan.Network.unmetered
    private var freeBytes: Int64 = 100 * 1_073_741_824
    private var build = 680
    private var phone: InMemoryCompanyVaults!
    private var service: CompanyVaultService!
    private var stagingRoot: URL!

    private let profileId = "fixture-company"
    private let profileURL = URL(string: "https://licence.example.test/p/fixture-company")!
    private let catalogURL = "https://licence.example.test/c/opaque/vaults.json"

    override func setUp() async throws {
        try await super.setUp()
        PolicyEnvelope.clear()
        phone = InMemoryCompanyVaults()
        phone.jobVault = { [unowned self] in self.activeJob }
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyVaultServiceTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: stagingRoot)
        try await super.tearDown()
    }

    // MARK: - The fixture company

    private func pack(_ vaultId: String, _ version: String) -> (row: CompanyVaultContract.Vault, zip: Data) {
        let zip = Data("pack \(vaultId) \(version)".utf8)
        let url = "https://licence.example.test/v/\(vaultId)-\(version).zip"
        served[url] = zip
        return (.init(id: "com.openglasses.vault." + vaultId, vaultId: vaultId, version: version,
                      name: vaultId == "lennox" ? "Lennox" : vaultId.capitalized, sizeBytes: zip.count, downloadURL: url,
                      sha256: VaultPackArchive.sha256Hex(zip), packSignature: "c2lnbmF0dXJl"), zip)
    }

    private func manual(_ name: String, in vaultId: String = "lennox", text: String,
                        tamper: Bool = false) throws -> CompanyVaultContract.Manual {
        let plain = Data(text.utf8)
        let revision = VaultPackArchive.sha256Hex(plain)
        var sealed = try CompanyVaultContract.ManualSeal.seal(
            plain, context: .init(profileId: profileId, vaultId: vaultId, fileName: name, revision: revision),
            companySecret: companySecret)
        let digest = VaultPackArchive.sha256Hex(sealed)
        if tamper { sealed[sealed.count - 3] ^= 0x40 }
        let url = "https://licence.example.test/m/\(vaultId)/\(revision.prefix(12))"
        served[url] = sealed
        return .init(vaultId: vaultId, fileName: name, revision: revision, sizeBytes: plain.count,
                     sealedSha256: tamper ? VaultPackArchive.sha256Hex(sealed) : digest, downloadURL: url,
                     kind: name.hasSuffix(".pdf") ? .pdf : .md)
    }

    /// Publish generation `generation` of the company's list, and the profile pointing at it.
    private func publish(generation: Int, vaults: [CompanyVaultContract.Vault], manuals: [CompanyVaultContract.Manual],
                         anyNetwork: Bool = false, pointerGeneration: Int? = nil, minAppBuild: Int? = nil) throws {
        catalogResponse = try CompanyVaultContract.sign(
            .init(profileId: profileId, generation: generation, issued: clock, manualsOnAnyNetwork: anyNetwork,
                  vaults: vaults, manuals: manuals),
            signer: packKey.signature(for:))
        profileResponse = Data(try document(generation: pointerGeneration ?? generation, minAppBuild: minAppBuild).utf8)
    }

    private func document(generation: Int, minAppBuild: Int? = nil) throws -> String {
        let profile = ConfigProfile(keyId: "fixture-profile", profileId: profileId, organizationName: "Fixture Mechanical",
                                    issued: clock, leaseDays: 30,
                                    companyVaults: .init(catalog: catalogURL, generation: generation, minAppBuild: minAppBuild))
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: profileKey.rawRepresentation.base64EncodedString())
    }

    private func manager() -> OrgProfileManager {
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
        vs.fetchCatalog = { url in
            XCTAssertEqual(url.absoluteString, self.catalogURL)
            self.catalogFetches += 1
            if self.catalogUnreachable { throw URLError(.notConnectedToInternet) }
            return self.catalogResponse
        }
        vs.download = { url, bytes, staging in
            self.downloads.append(url.absoluteString)
            let data = try XCTUnwrap(self.served[url.absoluteString])
            guard data.count <= bytes else { throw VaultLinkStagingError.tooLarge }
            let archive = try staging.create()
            try staging.append(data, to: archive)
            return archive
        }
        vs.publicKeyBase64 = packKey.publicKey.rawRepresentation.base64EncodedString()
        vs.companySecret = { self.companySecret }
        vs.currentBuild = { self.build }
        vs.network = { self.network }
        vs.freeBytes = { self.freeBytes }
        vs.activeJob = { self.activeJob.map { .open(vaultId: $0) } ?? .none }
        vs.now = { self.clock }
        vs.staging = { VaultLinkStagingStore(root: self.stagingRoot, maximumBytes: VaultLinkStagingStore.companyVaultMaximumBytes) }
        vs.vaults = { self.phone }
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
        // What the app runs after an enrolment, and nothing else: no renewal, no foreground. The
        // vaults used to arrive only with the next foreground's routine pass.
        await m.completeEnrolment()
    }

    /// The app coming forward within a day of its last renewal: the profile is not fetched again.
    private func foreground(_ m: OrgProfileManager) async {
        clock = clock.addingTimeInterval(60)
        await m.renewIfDue()
    }

    private func renew(_ m: OrgProfileManager) async {
        clock = clock.addingTimeInterval(2 * 86_400)
        await m.renewIfDue(force: true)
    }

    private var state: CompanyVaultState? { saved?.companyVaults }

    // MARK: - Arrives by itself

    func testEnrolmentBringsEveryVaultAndManual() async throws {
        let lennox = pack("lennox", "1")
        let wiring = try manual("Wiring.md", text: "Invented fixture wiring, page 1.")
        try publish(generation: 1, vaults: [lennox.row], manuals: [wiring])
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(phone.installs, ["lennox@1"])
        XCTAssertEqual(phone.manuals["lennox"]?["Wiring.md"], Data("Invented fixture wiring, page 1.".utf8),
                       "the manual arrives opened, exactly as uploaded")
        XCTAssertEqual(state?.vaults["lennox"]?.version, "1")
        XCTAssertEqual(state?.manuals["lennox"]?["Wiring.md"], wiring.revision)
        XCTAssertEqual(state?.highWater, 1)
        XCTAssertEqual(state?.appliedGeneration, 1)
        XCTAssertEqual(state?.downloading, [:])
        XCTAssertEqual(service.rows().map(\.name), ["Lennox"])
        XCTAssertNil(service.rows().first?.status)

        // Nothing changed: the list is read again, and nothing is downloaded or installed.
        let fetches = catalogFetches, downloaded = downloads.count
        await renew(m)
        XCTAssertEqual(catalogFetches, fetches + 1)
        XCTAssertEqual(downloads.count, downloaded)
        XCTAssertEqual(phone.installs.count, 1)
    }

    // MARK: - Every foreground

    func testAnUploadArrivesAtTheNextForegroundWithoutAProfileRenewal() async throws {
        let v1 = pack("lennox", "1"), v2 = pack("lennox", "2")
        try publish(generation: 1, vaults: [v1.row], manuals: [])
        let m = manager()
        try await enrol(m)

        // The partner uploads version 2 and a manual. The phone still holds the profile that
        // points at generation 1, and its renewal is not due for a day.
        let wiring = try manual("Wiring.md", text: "Invented fixture wiring.")
        try publish(generation: 2, vaults: [v2.row], manuals: [wiring], pointerGeneration: 1)
        await foreground(m)
        XCTAssertEqual(phone.vaults["lennox"]?.version, "2")
        XCTAssertNotNil(phone.manuals["lennox"]?["Wiring.md"])
        XCTAssertEqual(state?.highWater, 2)
        XCTAssertNil(service.listProblem())

        // The profile catching up later changes nothing.
        try publish(generation: 2, vaults: [v2.row], manuals: [wiring])
        await renew(m)
        XCTAssertEqual(phone.installs, ["lennox@1", "lennox@2"])
    }

    func testAForegroundThatCannotReachTheListCarriesOnWithTheVerifiedOne() async throws {
        let lennox = pack("lennox", "1")
        let wiring = try manual("Wiring.md", text: "Invented wiring.")
        try publish(generation: 1, vaults: [lennox.row], manuals: [wiring])
        network = .metered
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(state?.waits["lennox"], .wifi(bytes: Int64(wiring.sizeBytes)))

        // Back on Wi-Fi, but the list's host can't be reached: the manual still arrives from the
        // list already verified, and nothing is named as wrong.
        network = .unmetered
        catalogUnreachable = true
        await foreground(m)
        XCTAssertNotNil(phone.manuals["lennox"]?["Wiring.md"])
        XCTAssertNil(service.listProblem())
    }

    func testAForegroundThatCannotReachANewerListTheProfileNamesSaysSo() async throws {
        try publish(generation: 1, vaults: [pack("lennox", "1").row], manuals: [])
        let m = manager()
        try await enrol(m)
        try publish(generation: 2, vaults: [pack("lennox", "2").row], manuals: [])
        catalogUnreachable = true
        await renew(m)
        XCTAssertEqual(phone.vaults["lennox"]?.version, "1")
        XCTAssertEqual(service.listProblem(),
                       "Couldn't reach your organisation's vault list. It tries again when the app opens.")
    }

    func testVersionTwoWaitsForTheOpenJobThenInstalls() async throws {
        let v1 = pack("lennox", "1")
        try publish(generation: 1, vaults: [v1.row], manuals: [])
        let m = manager()
        try await enrol(m)

        activeJob = "lennox"
        let v2 = pack("lennox", "2")
        try publish(generation: 2, vaults: [v2.row], manuals: [])
        await renew(m)
        XCTAssertEqual(phone.vaults["lennox"]?.version, "1", "nothing changes under an open job")
        XCTAssertEqual(state?.waits["lennox"], .job(version: "2", removal: false))
        XCTAssertEqual(service.rows().first?.status, "Version 2 ready — installs after this job.")
        XCTAssertEqual(state?.appliedGeneration, 1)

        activeJob = nil
        await service.sync(.jobClosed)
        XCTAssertEqual(phone.vaults["lennox"]?.version, "2")
        XCTAssertEqual(state?.appliedGeneration, 2)
        XCTAssertNil(state?.waits["lennox"])
        XCTAssertFalse(phone.changedUnderJob)
    }

    func testAManualAddedMovesOnlyThatFileAndAReplacedOneMovesOnlyItself() async throws {
        let lennox = pack("lennox", "1")
        let a = try manual("A.md", text: "Invented A.")
        let b = try manual("B.md", text: "Invented B.")
        try publish(generation: 1, vaults: [lennox.row], manuals: [a, b])
        let m = manager()
        try await enrol(m)
        downloads = []

        let c = try manual("C.md", text: "Invented C.")
        try publish(generation: 2, vaults: [lennox.row], manuals: [a, b, c])
        await renew(m)
        XCTAssertEqual(downloads, [c.downloadURL], "only the new manual moves")
        XCTAssertEqual(phone.installs, ["lennox@1"], "the vault's core files are left alone")
        XCTAssertEqual(phone.manuals["lennox"]?.keys.sorted(), ["A.md", "B.md", "C.md"])

        downloads = []
        let b2 = try manual("B.md", text: "Invented B, second revision.")
        try publish(generation: 3, vaults: [lennox.row], manuals: [a, b2, c])
        await renew(m)
        XCTAssertEqual(downloads, [b2.downloadURL])
        XCTAssertEqual(phone.manuals["lennox"]?["B.md"], Data("Invented B, second revision.".utf8))
        XCTAssertEqual(state?.manuals["lennox"]?["B.md"], b2.revision)

        try publish(generation: 4, vaults: [lennox.row], manuals: [a, c])
        await renew(m)
        XCTAssertNil(phone.manuals["lennox"]?["B.md"], "a manual the partner deleted leaves")
        XCTAssertEqual(phone.relays.last?.removing, ["B.md"])
        XCTAssertEqual(state?.appliedGeneration, 4)
    }

    func testAVaultTheCompanyRemovedLeavesWithANotice() async throws {
        let lennox = pack("lennox", "1"), trane = pack("trane", "1")
        try publish(generation: 1, vaults: [lennox.row, trane.row], manuals: [])
        let m = manager()
        try await enrol(m)
        try publish(generation: 2, vaults: [lennox.row], manuals: [])
        activeJob = "trane"
        await renew(m)
        XCTAssertEqual(phone.uninstalled, [], "it leaves after the current job")
        XCTAssertEqual(service.rows().first { $0.vaultId == "trane" }?.status,
                       "Removed by your organisation — leaves this phone after this job.")
        activeJob = nil
        await service.sync(.jobClosed)
        XCTAssertEqual(phone.uninstalled, ["trane"])
        XCTAssertNil(state?.vaults["trane"])
        XCTAssertEqual(state?.removedNames, ["Trane"])
    }

    // MARK: - Refused

    func testATamperedManualIsRefusedAndNamed() async throws {
        let lennox = pack("lennox", "1")
        let good = try manual("Good.md", text: "Invented good.")
        let altered = try manual("Altered.md", text: "Invented altered.", tamper: true)
        try publish(generation: 1, vaults: [lennox.row], manuals: [good, altered])
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(phone.manuals["lennox"]?.keys.sorted(), ["Good.md"], "the good manual still lands")
        XCTAssertEqual(service.rows().first?.status, "Altered doesn't match your organisation's vault list, so it was refused.")
        XCTAssertNil(state?.manuals["lennox"]?["Altered.md"])
        XCTAssertEqual(state?.downloading["lennox"], ["Altered"])
        XCTAssertNotEqual(state?.appliedGeneration, 1, "retried at the next launch or foreground")

        // A manual whose checksum was moved with it but was not sealed for this company does not open.
        let otherCompany = try CompanyVaultContract.ManualSeal.seal(
            Data("Invented.".utf8), context: .init(profileId: "another-company", vaultId: "lennox", fileName: "X.md",
                                                   revision: VaultPackArchive.sha256Hex(Data("Invented.".utf8))),
            companySecret: companySecret)
        served["https://licence.example.test/m/x"] = otherCompany
        let moved = CompanyVaultContract.Manual(vaultId: "lennox", fileName: "X.md",
                                                revision: VaultPackArchive.sha256Hex(Data("Invented.".utf8)),
                                                sizeBytes: 9, sealedSha256: VaultPackArchive.sha256Hex(otherCompany),
                                                downloadURL: "https://licence.example.test/m/x", kind: .md)
        try publish(generation: 2, vaults: [lennox.row], manuals: [good, moved])
        await renew(m)
        XCTAssertNil(phone.manuals["lennox"]?["X.md"])
        XCTAssertEqual(service.rows().first?.status, "X doesn't match your organisation's vault list, so it was refused.")
    }

    func testAReplayedCatalogIsRefusedAndChangesNothing() async throws {
        let v1 = pack("lennox", "1"), v3 = pack("lennox", "3")
        try publish(generation: 1, vaults: [v1.row], manuals: [])
        let old = catalogResponse
        let m = manager()
        try await enrol(m)
        try publish(generation: 3, vaults: [v3.row], manuals: [])
        await renew(m)
        XCTAssertEqual(phone.vaults["lennox"]?.version, "3")

        // The profile moves on, and an older signed list is served in its place.
        try publish(generation: 4, vaults: [v1.row], manuals: [])
        catalogResponse = old
        await renew(m)
        XCTAssertEqual(phone.vaults["lennox"]?.version, "3", "the replay installs nothing")
        XCTAssertEqual(state?.highWater, 3)
        XCTAssertEqual(service.listProblem(), "An older vault list was served, so nothing in it was used.")
    }

    func testAnotherCompanysCatalogIsRefused() async throws {
        try publish(generation: 1, vaults: [pack("lennox", "1").row], manuals: [])
        catalogResponse = try CompanyVaultContract.sign(
            .init(profileId: "another-company", generation: 1, issued: clock, vaults: [pack("lennox", "1").row], manuals: []),
            signer: packKey.signature(for:))
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(phone.installs, [])
        XCTAssertEqual(service.listProblem(), "The vault list is for another company, so nothing in it was used.")
    }

    func testNotEnoughSpaceIsNamed() async throws {
        let lennox = pack("lennox", "1")
        let big = try manual("Big.md", text: String(repeating: "x", count: 2_000))
        try publish(generation: 1, vaults: [lennox.row], manuals: [big])
        freeBytes = CompanyVaultPlan.spaceMargin + 3_000
        let m = manager()
        try await enrol(m)
        let shortfall = CompanyVaultPlan.needed(for: 2_000) - (freeBytes - Int64(lennox.zip.count))
        XCTAssertEqual(state?.waits["lennox"], .space(shortfall: shortfall))
        XCTAssertEqual(service.rows().first?.status,
                       "Not enough space for the Lennox manuals: \(ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file)) needed.")
        XCTAssertNil(phone.manuals["lennox"])
        freeBytes = 100 * 1_073_741_824
        await m.renewIfDue()
        XCTAssertNotNil(phone.manuals["lennox"]?["Big.md"], "retried at the next launch or foreground")
    }

    func testManualsWaitForWiFiAndDownloadNowUsesCellularOnce() async throws {
        let lennox = pack("lennox", "1")
        let wiring = try manual("Wiring.md", text: "Invented wiring.")
        try publish(generation: 1, vaults: [lennox.row], manuals: [wiring])
        network = .metered
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(phone.installs, ["lennox@1"], "the core files use any network")
        XCTAssertEqual(state?.waits["lennox"], .wifi(bytes: Int64(wiring.sizeBytes)))
        XCTAssertEqual(service.rows().first?.offersDownloadNow, true)
        XCTAssertEqual(CompanyVaultDownloads.promptNote(vaultId: "lennox", manager: m)?.contains("Wiring"), true,
                       "an answer that would cite it says it is still downloading")

        await service.downloadNow("lennox")
        XCTAssertNotNil(phone.manuals["lennox"]?["Wiring.md"])
        XCTAssertNil(CompanyVaultDownloads.promptNote(vaultId: "lennox", manager: m))

        // Once: the next manual waits for Wi-Fi again.
        let more = try manual("More.md", text: "Invented more.")
        try publish(generation: 2, vaults: [lennox.row], manuals: [wiring, more])
        await renew(m)
        XCTAssertEqual(state?.waits["lennox"], .wifi(bytes: Int64(more.sizeBytes)))
    }

    func testTheCompanysAnyNetworkSettingLiftsTheWiFiWait() async throws {
        let lennox = pack("lennox", "1")
        let wiring = try manual("Wiring.md", text: "Invented wiring.")
        try publish(generation: 1, vaults: [lennox.row], manuals: [wiring], anyNetwork: true)
        network = .metered
        let m = manager()
        try await enrol(m)
        XCTAssertNotNil(phone.manuals["lennox"]?["Wiring.md"])
    }

    func testBelowTheCatalogsBuildNothingIsFetched() async throws {
        try publish(generation: 1, vaults: [pack("lennox", "1").row], manuals: [], minAppBuild: 700)
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(catalogFetches, 0)
        XCTAssertEqual(phone.installs, [])
        XCTAssertEqual(service.listProblem(), "Your organisation's vaults need a newer version of the app (build 700 or later).")
    }

    func testAFailedInstallIsNamedAndRetried() async throws {
        try publish(generation: 1, vaults: [pack("lennox", "1").row], manuals: [])
        phone.installFailure = "pack signature invalid — refusing to install"
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(service.rows().first?.status, "Couldn't install Lennox: pack signature invalid — refusing to install.")
        XCTAssertEqual(service.rows().first?.isProblem, true)
        phone.installFailure = nil
        await m.renewIfDue()
        XCTAssertEqual(phone.vaults["lennox"]?.version, "1")
        XCTAssertNil(service.rows().first?.status)
    }

    func testCheckForUpdatesFetchesWhateverTheGeneration() async throws {
        try publish(generation: 1, vaults: [pack("lennox", "1").row], manuals: [])
        let m = manager()
        try await enrol(m)
        let before = catalogFetches
        await m.checkForUpdates()
        XCTAssertEqual(catalogFetches, before + 1)
    }

    func testAProfileWithoutAPointerTouchesNothing() async throws {
        profileResponse = Data(try ProfileVerification.makeDocument(
            ConfigProfile(keyId: "fixture-profile", profileId: profileId, organizationName: "Fixture Mechanical",
                          issued: clock, leaseDays: 30),
            privateKeyBase64: profileKey.rawRepresentation.base64EncodedString()).utf8)
        let m = manager()
        try await enrol(m)
        await m.checkForUpdates()
        XCTAssertEqual(catalogFetches, 0)
        XCTAssertNil(state)
        XCTAssertEqual(service.rows(), [])
    }

    func testTheStateGoesWithTheEnrolment() async throws {
        try publish(generation: 1, vaults: [pack("lennox", "1").row], manuals: [])
        let m = manager()
        try await enrol(m)
        XCTAssertNotNil(state)
        _ = m.remove()
        XCTAssertNil(saved, "leaving removes the record, and the company vault state with it")
    }
}

/// Plan LR — leaving the firm takes the company's vaults with the rest of its content.
@MainActor
final class CompanyVaultDepartureTests: XCTestCase {
    func testADepartureErasesTheCompanyVaultsItWasGiven() async {
        var erased: [[String]] = []
        var stored: OrgDeparture?
        var seams = OrgDepartureService.Seams()
        seams.load = { stored }
        seams.save = { stored = $0 }
        seams.eraseCompanyVaults = { erased.append($0) }
        let service = OrgDepartureService(seams: seams)
        await service.begin(.removed, organizationName: "Fixture Mechanical", enrolmentId: "e1",
                            enrolledAt: Date(timeIntervalSince1970: 1_800_000_000), packId: nil, undeliveredEraseDays: nil,
                            companyVaultIds: ["lennox", "trane"])
        XCTAssertEqual(erased, [["lennox", "trane"]])
        XCTAssertEqual(stored?.companyVaultIds, ["lennox", "trane"], "kept until cleanup, across a crash")
        XCTAssertNotNil(stored?.contentErasedAt)
    }

    func testADepartureRecordedBeforeCompanyVaultsStillReads() throws {
        let json = #"{"organizationName":"O","enrolmentId":"e","reason":"removed","startedAt":"2027-01-15T08:00:00Z","eraseBy":"2027-02-14T08:00:00Z","sessionIds":[]}"#
        let departure = try ProfileVerification.decoder.decode(OrgDeparture.self, from: Data(json.utf8))
        XCTAssertNil(departure.companyVaultIds)
    }
}
