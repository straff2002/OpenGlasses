import XCTest
import CryptoKit
@testable import OpenGlasses

/// A company's activation card on a phone that has finished onboarding: the Settings scanner reads
/// the card's bare activation key the way the first-run sheet does, and a phone already with one
/// company is offered a move to the next — leaving the first exactly as Remove Profile does — rather
/// than told to remove it first. A profile device management applied still refuses.
@MainActor
final class OrgProfileMoveTests: XCTestCase {

    private var vendorKey: Curve25519.Signing.PrivateKey!
    private var stored: OrgEnrolmentRecord?
    private var storedLicence: String?
    private var activated: [String] = []
    private var settings: [SettingKey: ProfileValue] = [:]
    private var departures: [(reason: OrgDeparture.Reason, enrolmentId: String, packId: String?)] = []
    private var enrolments = 0
    private var documents: [String: String] = [:]
    private let issued = Date(timeIntervalSince1970: 1_790_000_000)

    private let northbridge = "https://config.northbridge.example/profile.txt"
    private let harbour = "https://config.harbour.example/profile.txt"

    override func setUp() {
        super.setUp()
        vendorKey = Curve25519.Signing.PrivateKey()
        stored = nil
        storedLicence = nil
        activated = []
        settings = [:]
        departures = []
        enrolments = 0
        documents = [:]
    }

    private var privateKeyBase64: String { vendorKey.rawRepresentation.base64EncodedString() }
    private var publicKeyBase64: String { vendorKey.publicKey.rawRepresentation.base64EncodedString() }

    // MARK: - The world

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": publicKeyBase64]
        seams.licenceKey = publicKeyBase64
        let now = issued.addingTimeInterval(86_400)
        seams.now = { now }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        seams.readSetting = { [unowned self] in self.settings[$0] }
        seams.writeSetting = { [unowned self] key, value in self.settings[key] = value }
        seams.activateLicence = { [unowned self] in self.activated.append($0); self.storedLicence = $0 }
        seams.storedLicenceCode = { [unowned self] in self.storedLicence }
        seams.clearLicence = { [unowned self] in self.storedLicence = nil }
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.newEnrolmentId = { [unowned self] in self.enrolments += 1; return "enrol\(self.enrolments)" }
        seams.fetch = { [unowned self] url in try self.serve(url) }
        seams.activeJobId = { nil }
        seams.withholdLicence = { _ in }
        seams.installPack = { _ in .failed("offline") }
        seams.forgetAdminCard = {}
        seams.beginDeparture = { [unowned self] reason, record, profile in
            self.departures.append((reason, record.enrolmentId, profile?.vaultPack?.packId))
        }
        return OrgProfileManager(seams: seams)
    }

    private func makeService(_ manager: OrgProfileManager,
                             activationResolver: ActivationKeyResolver = ActivationKeyResolver()) -> OrgEnrolmentService {
        OrgEnrolmentService(manager: manager, fetch: { [unowned self] in try self.serve($0) },
                            isPastOnboarding: { true }, licenceKey: publicKeyBase64,
                            activationResolver: activationResolver)
    }

    /// The profile host: each organisation's signed document at its own address.
    private func serve(_ url: URL) throws -> Data {
        guard let document = documents[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return Data(document.utf8)
    }

    private func licence(_ licensee: String, profile: String?) throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: licensee,
                                                    issued: issued,
                                                    expires: issued.addingTimeInterval(400 * 86_400),
                                                    profile: profile)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    @discardableResult
    private func publish(profileId: String, name: String, at address: String,
                         pack: String? = nil) throws -> String {
        let profile = ConfigProfile(
            keyId: "k", profileId: profileId, organizationName: name,
            issued: issued, leaseDays: 30,
            vaultPack: pack.map { ConfigProfile.VaultPackReference(packId: $0) },
            settings: ["privacyFilterEnabled": RawSetting(.bool(true), .ceiling),
                       "fieldAssistEnabled": RawSetting(.bool(true), .default)])
        let document = try ProfileVerification.makeDocument(profile, privateKeyBase64: privateKeyBase64)
        documents[address] = document
        return document
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

    private func waitForFailure(_ service: OrgEnrolmentService) async -> String? {
        for _ in 0..<200 {
            if case .failed(let message) = service.stage { return message }
            if case .reviewing = service.stage { return nil }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    /// Enrols the phone with Northbridge, as a licence key entered on the welcome page does.
    private func enrolWithNorthbridge(_ service: OrgEnrolmentService) async throws -> String {
        try publish(profileId: "northbridge", name: "Northbridge Mechanical", at: northbridge)
        let code = try licence("Northbridge Mechanical", profile: northbridge)
        XCTAssertEqual(service.openLicence(code), .enrolling(licensee: "Northbridge Mechanical"))
        let review = await waitForReview(service)
        XCTAssertNil(review?.move, "an unmanaged phone enrols; nothing to move from")
        service.confirm()
        XCTAssertEqual(service.stage, .applied("Northbridge Mechanical"))
        return code
    }

    // MARK: - Scanning a bare activation key from Settings

    func testAScannedCodeIsALinkOrAKeyWhereverTheScannerOpened() {
        XCTAssertEqual(OrgEnrolmentService.classifyScan(" K7Q3-X9PD-M2VA-8RTZ\n"), .key("K7Q3-X9PD-M2VA-8RTZ"))
        XCTAssertEqual(OrgEnrolmentService.classifyScan("eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0.c2ln"),
                       .key("eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0.c2ln"), "a full licence code is looked up as typed")
        XCTAssertEqual(OrgEnrolmentService.classifyScan(northbridge), .link(northbridge))
        XCTAssertEqual(OrgEnrolmentService.classifyScan("openglasses://enrol?url=\(northbridge)"),
                       .link("openglasses://enrol?url=\(northbridge)"))
        let office = OfficeCommissioning.qrPrefix + "abc "
        XCTAssertEqual(OrgEnrolmentService.classifyScan(office), .link(office), "an office's code passes exactly as scanned")
    }

    func testABareActivationKeyScannedFromSettingsIsLookedUpAndEnrols() async throws {
        try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)
        let code = try licence("Harbour Refrigeration", profile: harbour)
        let key = ActivationKey.generate()
        let sealed = try key.seal(code)
        let resolver = ActivationKeyResolver(directory: URL(string: "https://keys.example/activation/")!,
                                             fetch: { _ in (200, Data(sealed.utf8)) })
        let service = makeService(makeManager(), activationResolver: resolver)

        // What the activation card's QR carries: the bare key. The link path alone refuses it.
        service.openScanned(key.canonical)
        guard case .failed = service.stage else { return XCTFail("a key is not an enrolment link") }
        service.dismiss()

        // The scanner's route: a key, looked up, then the licence path.
        guard case .key(let scanned) = OrgEnrolmentService.classifyScan(key.canonical) else {
            return XCTFail("expected a key")
        }
        let entry = await service.resolveEntry(scanned)
        XCTAssertEqual(entry, .licence(code))
        XCTAssertEqual(service.openLicence(code), .enrolling(licensee: "Harbour Refrigeration"))
        let review = await waitForReview(service)
        XCTAssertEqual(review?.source, .licence)
        XCTAssertEqual(review?.organizationName, "Harbour Refrigeration")
        service.confirm()
        XCTAssertEqual(service.stage, .applied("Harbour Refrigeration"))
        XCTAssertEqual(stored?.activatedLicenceCode, code)
    }

    // MARK: - Moving a managed phone to another company

    func testAManagedPhoneEnteringAnotherCompanysKeyIsOfferedTheMoveThenMoved() async throws {
        settings[.fieldAssistEnabled] = .bool(false)
        let manager = makeManager()
        let service = makeService(manager)
        let northbridgeLicence = try await enrolWithNorthbridge(service)
        let leftEnrolment = try XCTUnwrap(stored?.enrolmentId)
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))

        try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)
        let harbourLicence = try licence("Harbour Refrigeration", profile: harbour)
        XCTAssertEqual(service.openLicence(harbourLicence), .enrolling(licensee: "Harbour Refrigeration"))
        let offered = await waitForReview(service)
        let review = try XCTUnwrap(offered, "offered, not refused")

        // The review names the move, and nothing has changed yet.
        XCTAssertEqual(review.move?.organizationName, "Northbridge Mechanical")
        XCTAssertEqual(review.move?.enrolmentId, leftEnrolment)
        XCTAssertFalse(review.replacesCurrent, "a move is not a renewal")
        XCTAssertEqual(manager.profile?.profileId, "northbridge")
        XCTAssertEqual(storedLicence, northbridgeLicence)
        XCTAssertTrue(departures.isEmpty)

        // One confirmation: Northbridge is left as Remove Profile leaves it, then Harbour applies.
        service.confirm()
        XCTAssertEqual(service.stage, .applied("Harbour Refrigeration"))
        XCTAssertEqual(manager.profile?.profileId, "harbour")
        XCTAssertEqual(stored?.source, .licence)
        XCTAssertNotEqual(stored?.enrolmentId, leftEnrolment, "a new enrolment, not the one left")
        XCTAssertEqual(departures.map { $0.reason }, [.removed])
        XCTAssertEqual(departures.first?.enrolmentId, leftEnrolment)
        XCTAssertEqual(activated, [northbridgeLicence, harbourLicence])
        XCTAssertEqual(storedLicence, harbourLicence, "leaving clears only the licence Northbridge brought")
        XCTAssertEqual(stored?.priorStartingValues["fieldAssistEnabled"], .bool(false),
                       "what is put back later is the person's own value, not Northbridge's")

        try manager.remove().get()
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(false))
        XCTAssertNil(storedLicence)
    }

    func testAMoveIsRefusedWhenTheEnrolmentItLeavesHasChanged() async throws {
        let manager = makeManager()
        let service = makeService(manager)
        _ = try await enrolWithNorthbridge(service)
        try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)
        _ = service.openLicence(try licence("Harbour Refrigeration", profile: harbour))
        let offered = await waitForReview(service)
        let review = try XCTUnwrap(offered)

        // While the review was open, the phone left Northbridge and joined it again.
        try manager.remove().get()
        let again = try manager.review(document: try XCTUnwrap(documents[northbridge]), source: .link).get()
        try manager.apply(again).get()

        guard case .failure(.moveChanged) = manager.apply(review) else { return XCTFail("expected moveChanged") }
        XCTAssertEqual(manager.profile?.profileId, "northbridge")
        XCTAssertEqual(departures.count, 1, "only the removal itself; the stale move removed nothing")
    }

    func testAMoveKeepsAVaultPackBothCompaniesInstall() throws {
        let manager = makeManager()
        let shared = try publish(profileId: "northbridge", name: "Northbridge Mechanical", at: northbridge,
                                 pack: "hvac_rtu_pack")
        try manager.apply(try manager.review(document: shared, source: .link).get()).get()

        let harbourDocument = try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour,
                                          pack: "hvac_rtu_pack")
        let move = try manager.review(document: harbourDocument, source: .link, allowingMove: true).get()
        XCTAssertEqual(move.move?.keepsPack, true)
        try manager.apply(move).get()
        XCTAssertEqual(departures.count, 1)
        XCTAssertNil(departures[0].packId, "not erased from under Harbour's enrolment")
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack")

        let other = try publish(profileId: "coastal", name: "Coastal Air", at: "https://config.coastal.example/p",
                                pack: "refrigeration_pack")
        let second = try manager.review(document: other, source: .link, allowingMove: true).get()
        XCTAssertEqual(second.move?.keepsPack, false)
        try manager.apply(second).get()
        XCTAssertEqual(departures.last?.packId, "hvac_rtu_pack", "a pack the next company doesn't install goes")
    }

    func testOnlyAReviewThatShowsTheMoveMayMove() throws {
        let manager = makeManager()
        let document = try publish(profileId: "northbridge", name: "Northbridge Mechanical", at: northbridge)
        try manager.apply(try manager.review(document: document, source: .link).get()).get()
        let harbourDocument = try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)

        // Office commissioning's own review sheet does not show a move, so it does not ask for one.
        guard case .failure(.managedByAnother("Northbridge Mechanical")) =
                manager.review(document: harbourDocument, source: .link) else {
            return XCTFail("expected managedByAnother")
        }
        XCTAssertTrue(departures.isEmpty)
    }

    // MARK: - Device management

    func testADeviceManagedProfileStillRefusesAnotherCompanysKey() async throws {
        let manager = makeManager()
        let document = try publish(profileId: "northbridge", name: "Northbridge Mechanical", at: northbridge)
        try manager.apply(try manager.review(document: document, source: .managedConfig).get()).get()
        XCTAssertEqual(stored?.source.isLocallyRemovable, false)

        try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)
        let harbourLicence = try licence("Harbour Refrigeration", profile: harbour)
        let service = makeService(manager)
        _ = service.openLicence(harbourLicence)
        let refusal = await waitForFailure(service)
        let message = try XCTUnwrap(refusal, "refused, not offered a move")
        XCTAssertTrue(message.contains("Northbridge Mechanical") && message.contains("device management"), message)

        guard case .failure(.managedByDevice) =
                manager.review(document: try XCTUnwrap(documents[harbour]), source: .licence, allowingMove: true) else {
            return XCTFail("expected managedByDevice")
        }
        XCTAssertEqual(manager.profile?.profileId, "northbridge")
        XCTAssertFalse(activated.contains(harbourLicence))
        XCTAssertTrue(departures.isEmpty)
    }
}
