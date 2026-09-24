import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT 3a (re-cut) — a licence key whose signed `profile` claim names its organisation's
/// profile enrols the phone when entered: no host offer, the same-organisation check, and the
/// later-issued licence activated.
@MainActor
final class OrgLicenceEnrolmentTests: XCTestCase {

    private var vendorKey: Curve25519.Signing.PrivateKey!
    private var stored: OrgEnrolmentRecord?
    private var storedLicence: String?
    private var activated: [String] = []
    private var fetchResult: Result<Data, Error> = .failure(URLError(.notConnectedToInternet))
    private let issued = Date(timeIntervalSince1970: 1_790_000_000)
    private let address = "https://config.northbridge.example/profile.txt"

    override func setUp() {
        super.setUp()
        vendorKey = Curve25519.Signing.PrivateKey()
        stored = nil
        storedLicence = nil
        activated = []
        fetchResult = .failure(URLError(.notConnectedToInternet))
    }

    private var privateKeyBase64: String { vendorKey.rawRepresentation.base64EncodedString() }
    private var publicKeyBase64: String { vendorKey.publicKey.rawRepresentation.base64EncodedString() }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": publicKeyBase64]
        seams.licenceKey = publicKeyBase64
        let now = issued.addingTimeInterval(86_400)
        seams.now = { now }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        var values: [SettingKey: ProfileValue] = [:]
        seams.readSetting = { values[$0] }
        seams.writeSetting = { values[$0] = $1 }
        seams.activateLicence = { [unowned self] in self.activated.append($0); self.storedLicence = $0 }
        seams.storedLicenceCode = { [unowned self] in self.storedLicence }
        seams.clearLicence = { [unowned self] in self.storedLicence = nil }
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.fetch = { [unowned self] _ in try self.fetchResult.get() }
        seams.activeJobId = { nil }
        seams.withholdLicence = { _ in }
        seams.installPack = { _ in .failed("offline") }
        return OrgProfileManager(seams: seams)
    }

    private func makeService(_ manager: OrgProfileManager) -> OrgEnrolmentService {
        OrgEnrolmentService(manager: manager, fetch: { [unowned self] _ in try self.fetchResult.get() },
                            isPastOnboarding: { false }, licenceKey: publicKeyBase64)
    }

    private func licence(licensee: String = "Northbridge Mechanical", issued: Date? = nil,
                         profile: String? = "https://config.northbridge.example/profile.txt") throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: licensee,
                                                    issued: issued ?? self.issued,
                                                    expires: self.issued.addingTimeInterval(400 * 86_400),
                                                    profile: profile)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    private func profileDocument(licenceCode: String? = nil, pack: String? = nil) throws -> String {
        let profile = ConfigProfile(
            keyId: "k", profileId: "northbridge", organizationName: "Northbridge Mechanical",
            issued: issued, leaseDays: 30, licenceCode: licenceCode,
            vaultPack: pack.map { ConfigProfile.VaultPackReference(packId: $0) },
            settings: ["privacyFilterEnabled": RawSetting(.bool(true), .ceiling),
                       "fieldAssistEnabled": RawSetting(.bool(true), .default)])
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: privateKeyBase64)
    }

    private func waitForReview(_ service: OrgEnrolmentService) async -> OrgProfileReview? {
        for _ in 0..<200 {
            switch service.stage {
            case .reviewing(let review): return review
            case .failed: return nil
            default: try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return nil
    }

    // MARK: - Routing

    func testALicenceWithoutAProfileActivatesAsItAlwaysHas() throws {
        let service = makeService(makeManager())
        XCTAssertEqual(service.openLicence(try licence(profile: nil)), .plain)
        XCTAssertEqual(service.stage, .idle)
        XCTAssertEqual(service.openLicence("not a licence"), .plain, "LicenseService explains a bad code")
    }

    func testALicenceNamingAProfileFetchesItWithoutAHostOffer() async throws {
        fetchResult = .success(Data(try profileDocument().utf8))
        let service = makeService(makeManager())
        XCTAssertEqual(service.openLicence(try licence()), .enrolling(licensee: "Northbridge Mechanical"))
        XCTAssertEqual(service.settingUpFor, "Northbridge Mechanical")
        let review = await waitForReview(service)
        XCTAssertEqual(review?.source, .licence)
        XCTAssertEqual(review?.sourceURL, URL(string: address))
    }

    func testALicenceNamingAnInsecureAddressIsRefused() throws {
        let service = makeService(makeManager())
        guard case .refused = service.openLicence(try licence(profile: "http://config.northbridge.example/p")) else {
            return XCTFail("expected a refusal")
        }
    }

    func testOfflineSaysTheInternetIsNeededOnce() async throws {
        let service = makeService(makeManager())
        _ = service.openLicence(try licence())
        for _ in 0..<200 {
            if case .failed = service.stage { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .failed(let message) = service.stage else { return XCTFail("\(service.stage)") }
        XCTAssertTrue(message.contains("Northbridge Mechanical"))
    }

    // MARK: - Same organisation, later licence

    func testTheProfileMustNameTheSameOrganisation() async throws {
        let other = try licence(licensee: "Someone Else Ltd", profile: nil)
        fetchResult = .success(Data(try profileDocument(licenceCode: other).utf8))
        let service = makeService(makeManager())
        _ = service.openLicence(try licence())
        let review = await waitForReview(service)
        XCTAssertNil(review)
        guard case .failed(let message) = service.stage else { return XCTFail("\(service.stage)") }
        XCTAssertTrue(message.contains("Someone Else Ltd") && message.contains("Northbridge Mechanical"))
    }

    func testTheLaterIssuedLicenceIsTheOneActivated() throws {
        let manager = makeManager()
        let older = try licence(issued: issued.addingTimeInterval(-86_400), profile: nil)
        let newer = try licence(issued: issued.addingTimeInterval(3_600))

        let enteredNewer = try manager.review(document: try profileDocument(licenceCode: older), source: .licence,
                                              enteredLicence: newer).get()
        XCTAssertEqual(enteredNewer.licenceToActivate, newer)

        let enteredOlder = try manager.review(document: try profileDocument(licenceCode: newer), source: .licence,
                                              enteredLicence: older).get()
        XCTAssertNil(enteredOlder.licenceToActivate, "the profile's own, later code wins")
    }

    func testAProfileWithoutALicenceActivatesTheEnteredKeyAndRemovalClearsIt() throws {
        let manager = makeManager()
        let entered = try licence()
        let review = try manager.review(document: try profileDocument(), source: .licence,
                                        enteredLicence: entered).get()
        XCTAssertTrue(review.carriesLicence)
        try manager.apply(review).get()
        XCTAssertEqual(activated, [entered])
        XCTAssertEqual(stored?.activatedLicenceCode, entered)
        XCTAssertEqual(stored?.source, .licence)

        try manager.remove().get()
        XCTAssertNil(storedLicence, "the key was the organisation's, whoever typed it")
    }

    // MARK: - Renewal keeps what later phases recorded

    func testARenewalKeepsThePendingPackAndTheEnteredLicence() async throws {
        let manager = makeManager()
        let entered = try licence()
        let document = try profileDocument(pack: "hvac_rtu_pack")
        let review = try manager.review(document: document, source: .licence,
                                        sourceURL: URL(string: address), enteredLicence: entered).get()
        try manager.apply(review).get()
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack")

        fetchResult = .success(Data(document.utf8))
        await manager.renewIfDue(force: true)
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack", "a renewal must not drop the pack still to install")
        XCTAssertNotNil(stored?.heldStartingValues?["fieldAssistEnabled"], "nor write what waits for it")
        XCTAssertEqual(stored?.activatedLicenceCode, entered)
    }
}
