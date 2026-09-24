import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT PR 2 — `openglasses://enrol?url=…`: the link policy, the offer before any fetch, the
/// review, the hold during onboarding, and the refusals, against a fetch that never leaves the
/// process.
@MainActor
final class OrgEnrolmentServiceTests: XCTestCase {

    private let keyId = "test-key"
    private var signingKey: Curve25519.Signing.PrivateKey!
    private var applied: (ProfileApplier.Result, String)?
    private var pastOnboarding = true

    override func setUp() {
        super.setUp()
        signingKey = Curve25519.Signing.PrivateKey()
        applied = nil
        pastOnboarding = true
    }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = [keyId: signingKey.publicKey.rawRepresentation.base64EncodedString()]
        seams.resolvableVaultIds = { [] }
        var record: OrgEnrolmentRecord?
        seams.loadRecord = { record }
        seams.saveRecord = { record = $0 }
        var values: [SettingKey: ProfileValue] = [:]
        seams.readSetting = { values[$0] }
        seams.writeSetting = { values[$0] = $1 }
        seams.activateLicence = { _ in }
        seams.storedLicenceCode = { nil }
        seams.clearLicence = {}
        seams.installEnvelope = { [unowned self] in self.applied = ($0, $1) }
        seams.clearEnvelope = { [unowned self] in self.applied = nil }
        return OrgProfileManager(seams: seams)
    }

    private func signedDocument() throws -> String {
        let profile = ConfigProfile(keyId: keyId, profileId: "northbridge", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30,
                                    settings: ["privacyFilterEnabled": RawSetting(.bool(true), .ceiling)])
        return try ProfileVerification.makeDocument(profile,
                                                    privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
    }

    private func makeService(fetch: @escaping (URL) async throws -> Data) -> OrgEnrolmentService {
        OrgEnrolmentService(manager: makeManager(), fetch: fetch,
                            isPastOnboarding: { [unowned self] in self.pastOnboarding })
    }

    private let link = URL(string: "openglasses://enrol?url=https%3A%2F%2Fconfig.northbridge.example%2Fprofile.txt")!

    // MARK: - Link policy

    func testParseAcceptsAnHTTPSPointerAndNothingElse() {
        XCTAssertEqual(try OrgEnrolmentService.parse(link).get(),
                       URL(string: "https://config.northbridge.example/profile.txt"))
        let refusals: [(String, OrgEnrolmentService.LinkRefusal)] = [
            ("openglasses://vault?url=https%3A%2F%2Fa.example%2Fp", .notAnEnrolmentLink),
            ("openglasses://enrol", .missingURL),
            ("openglasses://enrol?url=http%3A%2F%2Fa.example%2Fp", .insecureSource),
            ("openglasses://enrol?url=https%3A%2F%2Fuser%3Apass%40a.example%2Fp", .insecureSource),
            ("openglasses://enrol?url=https%3A%2F%2Fa.example%2Fp%23frag", .insecureSource),
            ("openglasses://enrol?url=file%3A%2F%2F%2Fetc%2Fpasswd", .insecureSource),
        ]
        for (raw, expected) in refusals {
            guard case .failure(let refusal) = OrgEnrolmentService.parse(URL(string: raw)!) else {
                XCTFail("accepted \(raw)"); continue
            }
            XCTAssertEqual(refusal, expected, raw)
        }
    }

    // MARK: - Offer, fetch, review, apply

    func testNothingIsFetchedBeforeThePersonAgrees() {
        var fetches = 0
        let service = makeService { _ in fetches += 1; return Data() }
        service.open(link)
        XCTAssertEqual(service.stage, .offer(host: "config.northbridge.example"))
        XCTAssertEqual(fetches, 0)
    }

    func testTheWholePathEndsWithTheProfileApplied() async throws {
        let document = try signedDocument()
        let service = makeService { _ in Data(document.utf8) }
        service.open(link)
        await service.approveFetch()
        guard case .reviewing(let review) = service.stage else { return XCTFail("\(service.stage)") }
        XCTAssertEqual(review.organizationName, "Northbridge Mechanical")
        XCTAssertNil(applied, "reviewing changes nothing")

        service.confirm()
        XCTAssertEqual(service.stage, .applied("Northbridge Mechanical"))
        XCTAssertEqual(applied?.0.ceilings[.privacyFilterEnabled], .bool(true))
    }

    func testAProfileSignedByAnotherKeyStopsAtReview() async throws {
        let forged = ConfigProfile(keyId: keyId, profileId: "x", organizationName: "Impostor",
                                   issued: Date(), leaseDays: 30)
        let text = try ProfileVerification.makeDocument(
            forged, privateKeyBase64: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        let service = makeService { _ in Data(text.utf8) }
        service.open(link)
        await service.approveFetch()
        guard case .failed = service.stage else { return XCTFail("\(service.stage)") }
        XCTAssertNil(applied)
    }

    func testAFailedFetchSaysSoAndChangesNothing() async {
        let service = makeService { _ in throw URLError(.notConnectedToInternet) }
        service.open(link)
        await service.approveFetch()
        guard case .failed(let message) = service.stage else { return XCTFail("\(service.stage)") }
        XCTAssertTrue(message.contains("config.northbridge.example"))
        XCTAssertNil(applied)
    }

    func testAnInsecureLinkIsRefusedWithoutAnOffer() {
        let service = makeService { _ in Data() }
        service.open(URL(string: "openglasses://enrol?url=http%3A%2F%2Fa.example%2Fp")!)
        guard case .failed = service.stage else { return XCTFail("\(service.stage)") }
    }

    // MARK: - Onboarding

    func testALinkDuringOnboardingIsHeldThenOffered() {
        pastOnboarding = false
        let service = makeService { _ in Data() }
        service.open(link)
        XCTAssertEqual(service.stage, .idle)
        XCTAssertTrue(service.hasHeldLink)

        service.releaseHeldLink()
        XCTAssertEqual(service.stage, .idle, "still onboarding: nothing to offer yet")

        pastOnboarding = true
        service.releaseHeldLink()
        XCTAssertEqual(service.stage, .offer(host: "config.northbridge.example"))
        XCTAssertFalse(service.hasHeldLink)
    }

    func testBackgroundingEndsAPendingReview() async throws {
        let document = try signedDocument()
        let service = makeService { _ in Data(document.utf8) }
        service.open(link)
        await service.approveFetch()
        service.handleBackground()
        XCTAssertEqual(service.stage, .idle)
        XCTAssertNil(applied)
    }
}
