import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan NF P1 — a crew experience set through the company vault pass, end to end: a fixture company,
/// an in-memory transport and phone, the service's own seal. The set arrives with its vault, a newer
/// one replaces it whole, anything that fails keeps the last good set, and only a team or enterprise
/// licence receives one. Invented brands, models, codes and people only.
@MainActor
final class CompanyExperienceServiceTests: XCTestCase {
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
    private var capability = FieldAssistCapabilityCheck.granted
    private var publishes = 0
    private var phone: InMemoryCompanyVaults!
    private var service: CompanyVaultService!
    private var experience: CompanyExperienceStore!
    private var root: URL!

    private let profileId = "fixture-company"
    private let vaultId = "fixture-crew-units"
    private let profileURL = URL(string: "https://licence.example.test/p/fixture-company")!
    private let catalogURL = "https://licence.example.test/c/opaque/vaults.json"

    override func setUp() async throws {
        try await super.setUp()
        PolicyEnvelope.clear()
        phone = InMemoryCompanyVaults()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyExperienceServiceTests-\(UUID().uuidString)")
        experience = CompanyExperienceStore(directory: root.appendingPathComponent("experience", isDirectory: true))
    }

    override func tearDown() async throws {
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - The fixture company

    private func pack(_ version: String = "1") -> CompanyVaultContract.Vault {
        let zip = Data("pack \(vaultId) \(version)".utf8)
        let url = "https://licence.example.test/v/\(vaultId)-\(version).zip"
        served[url] = zip
        return .init(id: "com.openglasses.vault." + vaultId, vaultId: vaultId, version: version, name: "Fixture Crew Units",
                     sizeBytes: zip.count, downloadURL: url, sha256: VaultPackArchive.sha256Hex(zip), packSignature: "c2lnbmF0dXJl")
    }

    private func entry(_ n: Int, fix: String = "Reseated the pressure switch harness at the plug") -> CrewExperienceSet.Entry {
        let digits = String(n, radix: 16)
        return .init(entryID: String(repeating: "0", count: 32 - digits.count) + digits,
                     subject: .model(modelToken: "QXRT-990", manufacturer: "Fixturetherm", equipmentType: nil),
                     vaultIDs: [vaultId], finding: "E999: \(fix)", symptom: "E999: Unit trips on start", fix: fix,
                     faultCode: "E999", tried: nil, outcome: "fixed it most times", approvedAt: 1_795_564_800,
                     approvedByRole: "Service manager", authorIsApprover: false)
    }

    private struct Sealing {
        var profileId: String?
        var vaultId: String?
        var tamper = false
        var count: Int?
    }

    /// Seal a set as the portal does and serve it; the returned pointer is the vault row's. `how`
    /// bends one thing for the refusal tests: the seal's company or vault, the bytes, the count.
    private func publishSet(sequence: Int, entries: [CrewExperienceSet.Entry], setProfile: String? = nil,
                            setVault: String? = nil, how: Sealing = Sealing()) throws -> CompanyVaultContract.Experience {
        let set = CrewExperienceSet(profileId: setProfile ?? profileId, vaultId: setVault ?? vaultId, sequence: sequence,
                                    issuedAt: 1_795_564_800 + Int64(sequence) * 86_400, entries: entries)
        let plain = try CrewExperienceSet.encoder().encode(set)
        let revision = VaultPackArchive.sha256Hex(plain)
        var sealed = try CompanyVaultContract.ExperienceSeal.seal(
            plain, context: .init(profileId: how.profileId ?? profileId, vaultId: how.vaultId ?? vaultId,
                                  sequence: sequence, revision: revision),
            companySecret: companySecret)
        let digest = VaultPackArchive.sha256Hex(sealed)
        if how.tamper { sealed[sealed.count - 3] ^= 0x40 }
        let url = "https://licence.example.test/x/\(vaultId)/\(sequence)-\(UUID().uuidString.prefix(6))"
        served[url] = sealed
        return .init(sequence: sequence, count: how.count ?? entries.count, sizeBytes: plain.count, revision: revision,
                     sealedSha256: how.tamper ? VaultPackArchive.sha256Hex(sealed) : digest, downloadURL: url)
    }

    private func publish(generation: Int, experience pointer: CompanyVaultContract.Experience?) throws {
        let base = pack()
        let row = CompanyVaultContract.Vault(id: base.id, vaultId: base.vaultId, version: base.version, name: base.name,
                                             sizeBytes: base.sizeBytes, downloadURL: base.downloadURL, sha256: base.sha256,
                                             packSignature: base.packSignature, experience: pointer)
        catalogResponse = try CompanyVaultContract.sign(
            .init(profileId: profileId, generation: generation, issued: clock, manualsOnAnyNetwork: false,
                  vaults: [row], manuals: []),
            signer: packKey.signature(for:))
        let profile = ConfigProfile(keyId: "fixture-profile", profileId: profileId, organizationName: "Fixture Mechanical",
                                    issued: clock, leaseDays: 30,
                                    companyVaults: .init(catalog: catalogURL, generation: generation, minAppBuild: nil))
        profileResponse = Data(try ProfileVerification.makeDocument(
            profile, privateKeyBase64: profileKey.rawRepresentation.base64EncodedString()).utf8)
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
        vs.companySecret = { self.companySecret }
        vs.currentBuild = { 780 }
        vs.network = { .metered }
        vs.freeBytes = { 100 * 1_073_741_824 }
        vs.activeJob = { self.activeJob.map { .open(vaultId: $0) } ?? .none }
        vs.now = { self.clock }
        vs.staging = { VaultLinkStagingStore(root: self.root.appendingPathComponent("staging", isDirectory: true),
                                             maximumBytes: VaultLinkStagingStore.companyVaultMaximumBytes) }
        vs.vaults = { self.phone }
        vs.experience = { self.experience }
        vs.experienceCapability = { self.capability }
        vs.publishLearnings = { self.publishes += 1 }
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

    private func foreground(_ m: OrgProfileManager) async {
        clock = clock.addingTimeInterval(60)
        await m.renewIfDue()
    }

    private var heldIDs: [String] { experience.set(for: vaultId)?.entries.map(\.id) ?? [] }

    // MARK: - Arrives with its vault

    func testTheSetArrivesWithItsVaultOnAnyNetworkAndIsAppliedWhole() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1), entry(2)]))
        let m = manager()
        try await enrol(m)
        XCTAssertNotNil(phone.vaults[vaultId])
        XCTAssertEqual(heldIDs.count, 2, "fetched on a metered network: smaller than a photo")
        let held = try XCTUnwrap(experience.set(for: vaultId))
        XCTAssertEqual(held.sequence, 1)
        XCTAssertTrue(held.entries.allSatisfy { $0.origin == .recollection })
        XCTAssertEqual(held.entries.first?.citationName, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(publishes, 1, "the corpus is reconciled once the set lands")

        // The same sequence again downloads nothing.
        let fetched = downloads.count
        await foreground(m)
        XCTAssertEqual(downloads.count, fetched)
        XCTAssertEqual(publishes, 1)
    }

    func testANewerSetReplacesTheOldOneWhole() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1), entry(2), entry(3)]))
        let m = manager()
        try await enrol(m)
        try publish(generation: 2, experience: try publishSet(sequence: 2, entries: [entry(1, fix: "Replaced the harness"), entry(4)]))
        await foreground(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID, entry(4).entryID], "applied whole: removed rows go, changed rows change")
        XCTAssertEqual(experience.set(for: vaultId)?.entries.first?.fix, "Replaced the harness")
        XCTAssertEqual(experience.set(for: vaultId)?.sequence, 2)
    }

    // MARK: - A learning approved in the portal (Plan NG P0b)

    private func learning(origin: String = "spoken") -> CrewExperienceSet.Entry {
        .init(entryID: "0000000000000000000000000000000a",
              subject: .model(modelToken: "QXRT-990", manufacturer: "Fixturetherm", equipmentType: nil),
              vaultIDs: [vaultId], finding: "Tighten the condenser fan set screw before replacing the motor",
              symptom: "Fan rattles at start", fix: "Tightened the set screw", faultCode: nil, tried: nil, outcome: nil,
              approvedAt: 1_795_564_800, approvedByRole: "Service manager", authorIsApprover: false, origin: origin,
              candidateID: "c0ffee00000000000000000000000001",
              sourceJobIDs: [String(repeating: "b", count: 31) + "2"], confirmedJobCount: 1)
    }

    func testAPortalLearningArrivesBesideTheSheetsRowsAndIsCitedAsATeamLearning() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1), learning()]))
        let m = manager()
        try await enrol(m)
        let held = try XCTUnwrap(experience.set(for: vaultId)).entries
        XCTAssertEqual(held.map(\.origin), [.recollection, .spoken])
        XCTAssertTrue(held[0].isCrewExperience)
        XCTAssertFalse(held[1].isCrewExperience, "a learning the administrator approved is a team learning")
        XCTAssertEqual(held[1].citationName, "Team learning · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(held[1].candidateID, "c0ffee00000000000000000000000001")
        XCTAssertEqual(held[1].sourceJobIDs, [String(repeating: "b", count: 31) + "2"])
        XCTAssertEqual(held[1].confirmedJobCount, 1)

        // Any other origin is refused whole, and the last good set stays.
        try publish(generation: 2, experience: try publishSet(sequence: 2, entries: [entry(2), learning(origin: "report")]))
        await foreground(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID, learning().entryID])
        XCTAssertEqual(experience.set(for: vaultId)?.sequence, 1)
    }

    // MARK: - The last good set stays

    func testEveryRefusalKeepsTheLastGoodSet() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 2, entries: [entry(1)]))
        let m = manager()
        try await enrol(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID])
        let refusals: [(String, CompanyVaultContract.Experience)] = [
            ("tampered", try publishSet(sequence: 3, entries: [entry(9)], how: .init(tamper: true))),
            ("sealed for another company", try publishSet(sequence: 3, entries: [entry(9)], how: .init(profileId: "fixture-other-company"))),
            ("sealed for another vault", try publishSet(sequence: 3, entries: [entry(9)], how: .init(vaultId: "fixture-other-vault"))),
            ("a set naming another company", try publishSet(sequence: 3, entries: [entry(9)], setProfile: "fixture-other-company")),
            ("a count that does not match", try publishSet(sequence: 3, entries: [entry(9)], how: .init(count: 2))),
        ]
        var generation = 1
        for (name, pointer) in refusals {
            generation += 1
            try publish(generation: generation, experience: pointer)
            await foreground(m)
            XCTAssertEqual(heldIDs, [entry(1).entryID], name)
            XCTAssertEqual(experience.set(for: vaultId)?.sequence, 2, name)
        }
        // A set not newer than the one held is never fetched.
        let fetched = downloads.count
        generation += 1
        try publish(generation: generation, experience: try publishSet(sequence: 2, entries: [entry(7)]))
        await foreground(m)
        XCTAssertEqual(downloads.count, fetched)
        XCTAssertEqual(heldIDs, [entry(1).entryID])
        generation += 1
        try publish(generation: generation, experience: try publishSet(sequence: 1, entries: [entry(7)]))
        await foreground(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID], "an older set never replaces a newer one")
    }

    func testTheSetWaitsForTheOpenJobOnItsVault() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1)]))
        let m = manager()
        try await enrol(m)
        activeJob = vaultId
        try publish(generation: 2, experience: try publishSet(sequence: 2, entries: [entry(2)]))
        await foreground(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID], "nothing changes under an open job")
        activeJob = nil
        await service.sync(.jobClosed)
        XCTAssertEqual(heldIDs, [entry(2).entryID])
    }

    // MARK: - Licence

    func testOnlyATeamOrEnterpriseLicenceReceivesASet() async throws {
        capability = .notIncluded(held: [])
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1)]))
        let m = manager()
        try await enrol(m)
        XCTAssertNotNil(phone.vaults[vaultId], "the vault itself still arrives")
        XCTAssertNil(experience.set(for: vaultId), "a solo licence receives no crew experience")
        XCTAssertFalse(downloads.contains { $0.contains("/x/") }, "and downloads none")
        capability = .granted
        await foreground(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID])
    }

    func testALapsedLicenceKeepsThePublishedSet() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1)]))
        let m = manager()
        try await enrol(m)
        capability = .denied(.expired(clock))
        try publish(generation: 2, experience: try publishSet(sequence: 2, entries: [entry(2)]))
        await foreground(m)
        XCTAssertEqual(heldIDs, [entry(1).entryID], "kept on a lapsed licence, and no newer set is received")
    }

    // MARK: - Removal

    func testASetTheCompanyTookOffLeavesThePhone() async throws {
        try publish(generation: 1, experience: try publishSet(sequence: 1, entries: [entry(1)]))
        let m = manager()
        try await enrol(m)
        let before = publishes
        try publish(generation: 2, experience: nil)
        await foreground(m)
        XCTAssertNil(experience.set(for: vaultId))
        XCTAssertEqual(publishes, before + 1)
    }
}
