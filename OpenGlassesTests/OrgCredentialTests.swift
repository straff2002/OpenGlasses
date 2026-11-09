import Foundation
import CryptoKit
import XCTest
@testable import OpenGlasses

/// The sealed company credential: a partner sets the company's Workiz key once, centrally, and
/// replaces or removes it; phones receive it on enrolment and every profile refresh, with no prompt,
/// and never show it. The vendor package sources are compiled into this bundle, so the boxes and
/// activation files here are the ones the licence service writes.
@MainActor
final class OrgCredentialTests: XCTestCase {
    private let licenceKey = Curve25519.Signing.PrivateKey()
    private let profileKey = Curve25519.Signing.PrivateKey()
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var saved: OrgEnrolmentRecord?
    private var storedCode: String?
    private var response = Data()
    private var settings: [SettingKey: ProfileValue] = [:]
    private var secret: Data?
    private var workizData: Data?
    private var arrivals = 0
    private var removals = 0
    private let workizKey = "wz_fixture_0123456789abcdefa1b2"
    private let replacedKey = "wz_fixture_fedcba9876543210c3d4"
    private let url = URL(string: "https://fixture.invalid/p/customer")!
    private var publicKey: String { licenceKey.publicKey.rawRepresentation.base64EncodedString() }
    private var profileKeys: [String: String] { ["fixture-profile": profileKey.publicKey.rawRepresentation.base64EncodedString()] }

    private lazy var connection = WorkizConnection(
        storage: .init(read: { self.workizData }, write: { self.workizData = $0 }, erase: { self.workizData = nil },
                       needsNewKey: { false }, setNeedsNewKey: { _ in }),
        licensed: { true })
    private lazy var sync = OrgCredentialSync(seams: .init(
        secrets: CompanySecretStore(read: { self.secret }, write: { self.secret = $0 }, erase: { self.secret = nil }),
        connection: { self.connection },
        keyArrived: { self.arrivals += 1 },
        keyRemoved: { self.removals += 1 }))

    override func setUp() {
        super.setUp()
        PolicyEnvelope.clear()
        for key in ["workizEnabled", "workizReportFieldName", "workizClientNotes"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        PolicyEnvelope.clear()
        super.tearDown()
    }

    private func manager() -> OrgProfileManager {
        var s = OrgProfileManager.Seams()
        s.verificationKeys = profileKeys; s.licenceKey = publicKey
        s.now = { self.clock }; s.loadRecord = { self.saved }; s.saveRecord = { self.saved = $0 }
        s.readSetting = { self.settings[$0] }; s.writeSetting = { self.settings[$0] = $1 }
        s.storedLicenceCode = { self.storedCode }
        s.activateLicence = { code in _ = try LicenseService.decode(code: code, publicKeyBase64: self.publicKey); self.storedCode = code }
        s.clearLicence = { self.storedCode = nil }
        s.resolvableVaultIds = { [] }; s.installEnvelope = { _, _ in }; s.clearEnvelope = {}
        s.fetch = { _ in self.response }; s.activeJobId = { nil }; s.withholdLicence = { _ in }
        s.closeManagedAccess = { _ in }
        s.loadModels = { [] }; s.saveModels = { _ in }; s.activeModelId = { "" }; s.setActiveModelId = { _ in }
        s.forgetAdminCard = {}
        s.syncCredentials = { self.sync.apply($0) }
        s.beginDeparture = { _, _, _ in self.sync.forget() }
        return OrgProfileManager(seams: s)
    }

    private func box(_ value: String, secret: Data, profileId: String = "customer") throws -> String {
        try ProfileContract.Credential.seal(value, name: "workiz", profileId: profileId, companySecret: secret)
    }

    private func document(workiz box: String?) throws -> String {
        let profile = ConfigProfile(keyId: "fixture-profile", profileId: "customer", organizationName: "Fixture Ltd",
                                    issued: clock, leaseDays: 30,
                                    credentials: box.map { ConfigProfile.SealedCredentials(["workiz": $0]) })
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: profileKey.rawRepresentation.base64EncodedString())
    }

    private func enrolled(workiz box: String?) throws -> OrgProfileManager {
        let m = manager()
        let review = try m.review(document: try document(workiz: box), source: .link, sourceURL: url).get()
        try m.apply(review).get()
        return m
    }

    private func refresh(_ m: OrgProfileManager, workiz box: String?) async throws {
        response = Data(try document(workiz: box).utf8)
        clock = clock.addingTimeInterval(2 * 86_400)
        await m.renewIfDue(force: true)
    }

    // MARK: - Sealing

    func testTheAppOpensWhatTheServiceSealsAndNothingElse() throws {
        XCTAssertEqual(OrgCredentialSeal.sealingSigningDomain, ProfileContract.Credential.sealingDomain)
        XCTAssertEqual(OrgCredentialSeal.sealingSigningDomain, "openglasses.org-credential.v1",
                       "Changing it stops every published Workiz key from opening on phones.")
        let secret = Data((0..<32).map { UInt8($0) })
        let fromService = try box(workizKey, secret: secret)
        XCTAssertEqual(OrgCredentialSeal.open(fromService, name: "workiz", profileId: "customer", companySecret: secret), workizKey)
        let fromApp = try OrgCredentialSeal.seal(workizKey, name: "workiz", profileId: "customer", companySecret: secret)
        XCTAssertEqual(try ProfileContract.Credential.open(fromApp, name: "workiz", profileId: "customer", companySecret: secret), workizKey)
        XCTAssertNil(OrgCredentialSeal.open(fromService, name: "workiz", profileId: "customer", companySecret: Data(repeating: 9, count: 32)))
        XCTAssertNil(OrgCredentialSeal.open(fromService, name: "workiz", profileId: "another", companySecret: secret),
                     "a box moved to another company's profile does not open")
        XCTAssertNil(OrgCredentialSeal.open(fromService, name: "other", profileId: "customer", companySecret: secret))
        XCTAssertNil(OrgCredentialSeal.open("not a box", name: "workiz", profileId: "customer", companySecret: secret))
        // The public profile shows neither the key nor anything it was sealed with.
        let document = try document(workiz: fromService)
        let payload = String(decoding: try XCTUnwrap(Data(base64Encoded: String(document.split(separator: ".")[0]))), as: UTF8.self)
        XCTAssertFalse(payload.contains(workizKey)); XCTAssertFalse(payload.contains(secret.base64EncodedString()))
        guard case .profile(let profile) = try ProfileVerification.verify(document, keys: profileKeys) else { return XCTFail("not a profile") }
        XCTAssertEqual(profile.credentials?.boxes["workiz"], fromService)
    }

    func testAMalformedCredentialsEntryNeverRefusesTheProfile() throws {
        let json = #"{"credentials":{"workiz":7},"format":"openglasses.org-profile","issued":"2027-01-15T08:00:00Z","keyId":"k","leaseDays":30,"organizationName":"O","profileId":"p","schemaVersion":1,"settings":{}}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(ConfigProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.credentials?.boxes, [:])
    }

    func testVersionOneActivationFilesStillOpenAndVersionTwoCarriesTheSecret() async throws {
        let key = ActivationKey.generate()
        let v1 = try key.seal("fixture.licence")
        XCTAssertEqual(key.openContents(Data(v1.utf8)), .init(licenceCode: "fixture.licence", companySecret: nil))
        XCTAssertEqual(key.open(Data(v1.utf8)), "fixture.licence")
        let companySecret = ProfileContract.Credential.newSecret()
        let v2 = try ActivationKeyMint.seal("fixture.licence", companySecret: companySecret, canonical: key.canonical)
        XCTAssertEqual(key.openContents(Data(v2.utf8)), .init(licenceCode: "fixture.licence", companySecret: companySecret))
        XCTAssertEqual(key.open(Data(v2.utf8)), "fixture.licence", "the licence path reads a version 2 file unchanged")
        XCTAssertNil(key.openContents(Data(try key.seal("fixture.licence", companySecret: Data(count: 16)).utf8)))
        XCTAssertNil(ActivationKey.generate().openContents(Data(v2.utf8)))
        for (file, expected) in [(v1, nil), (v2, companySecret)] as [(String, Data?)] {
            let resolver = ActivationKeyResolver(directory: url, fetch: { _ in (200, Data(file.utf8)) })
            let contents = try await resolver.resolveContents(key)
            XCTAssertEqual(contents.licenceCode, "fixture.licence"); XCTAssertEqual(contents.companySecret, expected)
            let code = try await resolver.resolve(key)
            XCTAssertEqual(code, "fixture.licence")
        }
    }

    // MARK: - Profile refresh

    func testAReplacedKeyArrivesSilentlyOnProfileRefresh() async throws {
        let companySecret = ProfileContract.Credential.newSecret(); secret = companySecret
        let m = try enrolled(workiz: try box(workizKey, secret: companySecret))
        XCTAssertEqual(connection.credential?.key, workizKey)
        XCTAssertEqual(connection.credential?.managedBy, "Fixture Ltd")
        XCTAssertTrue(connection.isManagedKey); XCTAssertEqual(connection.keyEnding, "a1b2")
        XCTAssertEqual(arrivals, 1)
        try connection.select(WorkizUser(id: "USR-jamie", name: "Jamie Lee", emailAddress: "", active: true, fieldTech: true), confirmed: true)

        try await refresh(m, workiz: try box(replacedKey, secret: companySecret))
        XCTAssertEqual(connection.credential?.key, replacedKey, "replaced with no prompt")
        XCTAssertEqual(connection.credential?.technicianID, "USR-jamie", "the technician carries over to the new key")
        XCTAssertTrue(connection.technicianPinned)
        XCTAssertEqual(arrivals, 2)
        // The same key sealed afresh (a new nonce on every publish) changes nothing.
        let generation = connection.credential?.generation
        try await refresh(m, workiz: try box(replacedKey, secret: companySecret))
        XCTAssertEqual(connection.credential?.generation, generation); XCTAssertEqual(arrivals, 2)
    }

    func testARemovedKeyIsDeletedButAPastedKeyStays() async throws {
        let companySecret = ProfileContract.Credential.newSecret(); secret = companySecret
        let m = try enrolled(workiz: try box(workizKey, secret: companySecret))
        XCTAssertNotNil(connection.credential)
        try await refresh(m, workiz: nil)
        XCTAssertNil(connection.credential); XCTAssertNil(workizData, "the Keychain item is gone")
        XCTAssertEqual(removals, 1)
        try connection.pasteKey("wz_pasted_on_this_phone", administrator: true)
        try await refresh(m, workiz: nil)
        XCTAssertEqual(connection.credential?.key, "wz_pasted_on_this_phone"); XCTAssertEqual(removals, 1)
        // A profile key wins over a pasted one once the partner sets it.
        try await refresh(m, workiz: try box(workizKey, secret: companySecret))
        XCTAssertEqual(connection.credential?.key, workizKey); XCTAssertTrue(connection.isManagedKey)
    }

    func testABoxThisPhoneCannotOpenLeavesTheKeyAndAsksForTheActivationKey() async throws {
        let companySecret = ProfileContract.Credential.newSecret()
        let m = try enrolled(workiz: try box(workizKey, secret: companySecret))
        XCTAssertNil(connection.credential); XCTAssertTrue(sync.workizNeedsActivationKey)
        secret = ProfileContract.Credential.newSecret() // another company's secret
        try await refresh(m, workiz: try box(workizKey, secret: companySecret))
        XCTAssertNil(connection.credential); XCTAssertTrue(sync.workizNeedsActivationKey)
        secret = companySecret
        try await refresh(m, workiz: try box(workizKey, secret: companySecret))
        XCTAssertEqual(connection.credential?.key, workizKey); XCTAssertFalse(sync.workizNeedsActivationKey)
        // Leaving the firm takes the secret with it.
        _ = m.remove()
        XCTAssertNil(secret)
    }

    // MARK: - Which one are you?

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: OrgCredentialTests.self).url(forResource: "workiz-" + name, withExtension: "json",
                                                                                subdirectory: "workiz-v2")))
    }

    func testTheTechnicianIsConfirmedOnceAndAskedAgainWhenTheAccountChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spy = CredentialWorkizSpy()
        let controller = WorkizController(connection: connection, jobs: UpcomingJobStore(directory: folder),
                                          client: WorkizAPIClient(connection: connection, transport: { spy }))
        var filled: [WorkizUser] = []
        controller.fillIdentity = { filled.append($0) }
        try connection.setManagedKey(workizKey, organization: "Fixture Ltd")
        XCTAssertTrue(connection.needsTechnicianConfirmation)

        let users = try fixture("users")
        spy.replies = [(users, 200), (try fixture("jobs-page"), 200), (try fixture("customfields"), 200), (users, 200)]
        await controller.testConnection()
        XCTAssertEqual(controller.users.map(\.id), ["USR-jamie", "USR-other"])
        XCTAssertNil(connection.credential?.technicianID, "a company key's technician is asked, never guessed")
        let jamie = try XCTUnwrap(controller.users.first)
        try await controller.confirm(jamie)
        XCTAssertTrue(connection.technicianPinned); XCTAssertFalse(connection.needsTechnicianConfirmation)
        XCTAssertEqual(filled, [jamie], "the Field Assist name and technician ID are filled once")
        let alex = controller.users[1]
        XCTAssertThrowsError(try connection.select(alex), "only an administrator changes a confirmed technician")
        XCTAssertEqual(connection.credential?.technicianID, "USR-jamie")

        // A replaced key for the same account keeps the technician.
        try connection.setManagedKey(replacedKey, organization: "Fixture Ltd")
        XCTAssertTrue(connection.technicianPinned)
        // A key for another Workiz account, where Jamie's ID does not exist: ask again.
        let otherAccount = Data(#"{"pageSize":100,"page":1,"totalResults":1,"hasMore":false,"data":[{"id":"USR-sam","name":"Sam Ortiz","emailAddress":"sam@example.invalid","role":"tech","fieldTech":true,"active":true}]}"#.utf8)
        try connection.setManagedKey("wz_fixture_other_account_e5f6", organization: "Fixture Ltd")
        spy.replies = [(otherAccount, 200), (try fixture("jobs-page"), 200), (try fixture("customfields"), 200), (otherAccount, 200)]
        await controller.testConnection()
        XCTAssertNil(connection.credential?.technicianID)
        XCTAssertFalse(connection.technicianPinned); XCTAssertTrue(connection.needsTechnicianConfirmation)
        XCTAssertEqual(controller.users.map(\.id), ["USR-sam"])
        XCTAssertEqual(filled.count, 1, "nothing is filled until the technician confirms again")
        // An administrator may choose for the technician.
        try await controller.confirm(controller.users[0], administrator: true)
        try controller.chooseAgain()
        XCTAssertTrue(connection.needsTechnicianConfirmation)
    }

    // MARK: - End to end

    private var grant: PartnerGrant {
        PartnerGrant(partnerId: "fixture", packs: ["hvac_rtu"], maxTermDays: 365, maxSeatsPerCode: 10, seatQuota: 100,
                     pilotsAllowed: true, maxPilotDays: 14, validFrom: clock.addingTimeInterval(-86_400),
                     validUntil: clock.addingTimeInterval(400 * 86_400),
                     prices: PriceTable(currency: "XXX", taxTreatment: "fictional", perSeatByTermDays: [365: 100]), maxUnpaidSeats: 10)
    }

    /// Sign-up's activation key carries the secret; the profile carries the key sealed under it; enrolling
    /// with the key puts the Workiz key in the Keychain. A version 1 file enrols too, without the key.
    func testEnrollingWithTheActivationKeyDeliversTheWorkizKey() async throws {
        let preset = ProfilePreset(id: "fixture-preset", version: 1, leaseDays: 365,
                                   settings: ["privacyFilterEnabled": .init(value: .bool(true), disposition: "ceiling")])
        var book = try SalesBook()
        let signUp = try book.signUp(NewCustomer(customerId: "fixture-customer", licensee: "Fixture Ltd", organizationID: "fixture-org",
                                                 profileId: "customer"),
                                     orderId: "fixture-order", order: .init(seats: 2, termDays: 365, packs: ["hvac_rtu"], reference: "fixture"),
                                     preset: preset, profileBase: "https://fixture.invalid", grant: grant,
                                     catalog: VerifiedPackCatalog(verifiedKeys: grant.packs), bankDetails: "FIXTURE", operatorId: "fixture",
                                     now: clock, signer: licenceKey.signature(for:))
        let sealedKey = try book.sealCredential(workizKey, name: "workiz", customerId: "fixture-customer", companySecret: signUp.companySecret)
        let profileText = try book.profileDocument(customerId: "fixture-customer", code: signUp.code.code, preset: preset, grant: grant,
                                                   credentials: ["workiz": sealedKey], keyID: "fixture-profile", issued: clock,
                                                   signer: profileKey.signature(for:))
        XCTAssertFalse(profileText.contains(workizKey))
        response = Data(profileText.utf8)
        let canonical = signUp.activationKey.replacingOccurrences(of: "-", with: "")
        let v1 = try ActivationKeyMint.seal(signUp.code.code, canonical: canonical)

        for (file, delivers) in [(v1, false), (signUp.sealedFile, true)] {
            saved = nil; storedCode = nil; secret = nil; workizData = nil
            connection = WorkizConnection(storage: .init(read: { self.workizData }, write: { self.workizData = $0 }, erase: { self.workizData = nil },
                                                         needsNewKey: { false }, setNeedsNewKey: { _ in }), licensed: { true })
            let resolver = ActivationKeyResolver(directory: url, fetch: { address in
                (address.lastPathComponent == signUp.customer.activationFile ? 200 : 404, Data(file.utf8))
            })
            let m = manager()
            let service = OrgEnrolmentService(manager: m, fetch: { _ in self.response }, isPastOnboarding: { false },
                                              licenceKey: publicKey, profileKeys: profileKeys, now: { self.clock },
                                              activationResolver: resolver, credentials: sync)
            guard case .licence(let entered) = await service.resolveEntry(signUp.activationKey) else { return XCTFail("the key did not resolve") }
            XCTAssertEqual(entered, signUp.code.code)
            XCTAssertEqual(service.openLicence(entered), .enrolling(licensee: "Fixture Ltd"))
            for _ in 0..<200 {
                if case .reviewing = service.stage { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard case .reviewing = service.stage else { return XCTFail("profile enrolment failed: \(service.stage)") }
            service.confirm()
            XCTAssertEqual(storedCode, signUp.code.code)
            if delivers {
                XCTAssertEqual(secret, signUp.companySecret)
                XCTAssertEqual(connection.credential?.key, workizKey); XCTAssertEqual(connection.credential?.managedBy, "Fixture Ltd")
                XCTAssertFalse(sync.workizNeedsActivationKey)
            } else {
                XCTAssertNil(secret); XCTAssertNil(connection.credential)
                XCTAssertTrue(sync.workizNeedsActivationKey, "an older file enrols, and the administrator is told why Workiz is not connected")
            }
        }
    }
}

@MainActor
private final class CredentialWorkizSpy: WorkizTransport {
    var replies: [(Data, Int)] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard !replies.isEmpty else { throw WorkizFailure.malformed }
        return replies.removeFirst()
    }
    func cancel() {}
}
