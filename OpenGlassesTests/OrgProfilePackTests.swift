import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT PR 3b — enrolment's pack step: the pack is installed before the default vault is
/// written, a failure is retried rather than blocking the profile, and a pack that turns out to
/// provide a different vault never leaves the default pointing at nothing.
@MainActor
final class OrgProfilePackTests: XCTestCase {

    private var signingKey: Curve25519.Signing.PrivateKey!
    private var stored: OrgEnrolmentRecord?
    private var settings: [SettingKey: ProfileValue] = [:]
    private var installed: Set<String> = []
    private var envelope: ProfileApplier.Result?
    private var installOutcome: OrgPackInstaller.Outcome = .failed("offline")
    private var installAttempts: [String] = []
    private var fetchText: String?

    override func setUp() {
        super.setUp()
        signingKey = Curve25519.Signing.PrivateKey()
        stored = nil
        settings = [:]
        installed = ["refrigeration"]
        envelope = nil
        installOutcome = .failed("offline")
        installAttempts = []
        fetchText = nil
    }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": signingKey.publicKey.rawRepresentation.base64EncodedString()]
        seams.now = { Date(timeIntervalSince1970: 1_790_000_000) }
        seams.resolvableVaultIds = { [unowned self] in self.installed }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        seams.readSetting = { [unowned self] in self.settings[$0] }
        seams.writeSetting = { [unowned self] in self.settings[$0] = $1 }
        seams.activateLicence = { _ in }
        seams.storedLicenceCode = { nil }
        seams.clearLicence = {}
        seams.installEnvelope = { [unowned self] result, _ in self.envelope = result }
        seams.clearEnvelope = { [unowned self] in self.envelope = nil }
        seams.fetch = { [unowned self] _ in
            guard let text = self.fetchText else { throw URLError(.notConnectedToInternet) }
            return Data(text.utf8)
        }
        seams.activeJobId = { nil }
        seams.withholdLicence = { _ in }
        seams.installPack = { [unowned self] packId in
            self.installAttempts.append(packId)
            if case .installed(let vaultId) = self.installOutcome { self.installed.insert(vaultId) }
            return self.installOutcome
        }
        return OrgProfileManager(seams: seams)
    }

    private func document(pack: String? = "hvac_rtu_pack", defaultVault: String = "hvac_rtu") throws -> String {
        let profile = ConfigProfile(
            keyId: "k", profileId: "northbridge", organizationName: "Northbridge",
            issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: 30,
            vaultPack: pack.map { ConfigProfile.VaultPackReference(packId: $0) },
            settings: [
                "fieldAssistEnabled": RawSetting(.bool(true), .default),
                "fieldAssistDefaultVaultId": RawSetting(.string(defaultVault), .default),
                "fieldAssistDefaultMode": RawSetting(.string("ai_only"), .default),
                "privacyFilterEnabled": RawSetting(.bool(true), .ceiling),
            ])
        return try ProfileVerification.makeDocument(profile,
                                                    privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
    }

    private func enrol(_ manager: OrgProfileManager, _ text: String) throws -> OrgProfileReview {
        let review = try manager.review(document: text, source: .scan).get()
        try manager.apply(review).get()
        return review
    }

    func testTheReviewCountsThePacksVaultAndNamesThePack() throws {
        let review = try makeManager().review(document: try document(), source: .scan).get()
        XCTAssertEqual(review.packId, "hvac_rtu_pack")
        XCTAssertEqual(review.result.startingValues[.fieldAssistDefaultVaultId], .string("hvac_rtu"),
                       "not dropped as unresolvable: the pack is expected to provide it")
        XCTAssertTrue(review.dropLines.isEmpty)
    }

    func testTheCeilingAppliesAtOnceAndTheVaultWaitsForThePack() throws {
        let manager = makeManager()
        _ = try enrol(manager, try document())
        XCTAssertEqual(envelope?.ceilings[.privacyFilterEnabled], .bool(true), "the bounds never wait on a download")
        XCTAssertEqual(settings[.fieldAssistDefaultMode], .string("ai_only"))
        XCTAssertNil(settings[.fieldAssistDefaultVaultId], "not before the pack is on the phone")
        XCTAssertNil(settings[.fieldAssistEnabled])
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack")
    }

    func testAFailedInstallIsNamedAndRetried() async throws {
        let manager = makeManager()
        _ = try enrol(manager, try document())
        await manager.completePendingPack()
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack")
        XCTAssertEqual(stored?.packInstallError, "offline")
        XCTAssertNil(settings[.fieldAssistEnabled])

        installOutcome = .installed(vaultId: "hvac_rtu")
        await manager.renewIfDue()          // launch and foreground retry through here
        XCTAssertEqual(installAttempts, ["hvac_rtu_pack", "hvac_rtu_pack"])
        XCTAssertNil(stored?.pendingPackId)
        XCTAssertNil(stored?.packInstallError)
        XCTAssertEqual(settings[.fieldAssistDefaultVaultId], .string("hvac_rtu"))
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))
    }

    func testAPackProvidingADifferentVaultLeavesTheDefaultAlone() async throws {
        settings[.fieldAssistDefaultVaultId] = .string("refrigeration")
        let manager = makeManager()
        _ = try enrol(manager, try document())
        installOutcome = .installed(vaultId: "some_other_vault")
        await manager.completePendingPack()
        XCTAssertEqual(settings[.fieldAssistDefaultVaultId], .string("refrigeration"),
                       "a default pointing at a vault that is not there is a broken home screen")
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))
        XCTAssertNil(stored?.pendingPackId)
    }

    func testRemovalPutsBackValuesWrittenAfterThePackLanded() async throws {
        settings[.fieldAssistEnabled] = .bool(false)
        let manager = makeManager()
        _ = try enrol(manager, try document())
        installOutcome = .installed(vaultId: "hvac_rtu")
        await manager.completePendingPack()
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))

        try manager.remove().get()
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(false))
        XCTAssertNil(settings[.fieldAssistDefaultVaultId])
    }

    func testARenewalKeepsThePendingPackAndDoesNotWriteWhatWaitsForIt() async throws {
        let manager = makeManager()
        let text = try document()
        let review = try manager.review(document: text, source: .link,
                                        sourceURL: URL(string: "https://config.northbridge.example/p")).get()
        try manager.apply(review).get()
        fetchText = text
        await manager.renewIfDue(force: true)
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack", "a renewal must not drop the pack still to install")
        XCTAssertNil(settings[.fieldAssistEnabled], "nor write what waits for it")
        XCTAssertNotNil(stored?.heldStartingValues?["fieldAssistEnabled"])
    }

    func testAProfileWithoutAPackWritesEverythingAtOnce() throws {
        let manager = makeManager()
        _ = try enrol(manager, try document(pack: nil, defaultVault: "refrigeration"))
        XCTAssertEqual(settings[.fieldAssistDefaultVaultId], .string("refrigeration"))
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))
        XCTAssertNil(stored?.pendingPackId)
    }
}
