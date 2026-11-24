import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan ND P3 — a synthetic Managed App Configuration dictionary, read the way an MDM's would be,
/// through enrolment, a change, one empty read (nothing happens), absence twice (the phone leaves),
/// and another company's profile under management (the managed layer wins).
@MainActor
final class ManagedConfigIngressTests: XCTestCase {

    private var vendorKey: Curve25519.Signing.PrivateKey!
    private var stored: OrgEnrolmentRecord?
    private var storedLicence: String?
    private var settings: [SettingKey: ProfileValue] = [:]
    private var departures: [(reason: OrgDeparture.Reason, enrolmentId: String)] = []
    private var enrolments = 0
    private var documents: [String: String] = [:]
    private var fetches = 0
    private var absence = ManagedConfigAbsence()
    private var feedback: [String: Any]?
    private var feedbackWrites = 0
    private var secret: Data?
    private var now = Date(timeIntervalSince1970: 1_790_000_000 + 86_400)
    private var launchId = "launch-1"
    private var jobOpen = false
    private let issued = Date(timeIntervalSince1970: 1_790_000_000)

    private let northbridge = "https://config.northbridge.example/profile.txt"
    private let harbour = "https://config.harbour.example/profile.txt"

    override func setUp() {
        super.setUp()
        vendorKey = Curve25519.Signing.PrivateKey()
        stored = nil
        storedLicence = nil
        settings = [:]
        departures = []
        enrolments = 0
        documents = [:]
        fetches = 0
        absence = ManagedConfigAbsence()
        feedback = nil
        feedbackWrites = 0
        secret = nil
        now = issued.addingTimeInterval(86_400)
        launchId = "launch-1"
        jobOpen = false
    }

    private var privateKeyBase64: String { vendorKey.rawRepresentation.base64EncodedString() }
    private var publicKeyBase64: String { vendorKey.publicKey.rawRepresentation.base64EncodedString() }

    // MARK: - The world

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": publicKeyBase64]
        seams.licenceKey = publicKeyBase64
        seams.now = { [unowned self] in self.now }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        seams.readSetting = { [unowned self] in self.settings[$0] }
        seams.writeSetting = { [unowned self] key, value in self.settings[key] = value }
        seams.activateLicence = { [unowned self] in self.storedLicence = $0 }
        seams.storedLicenceCode = { [unowned self] in self.storedLicence }
        seams.clearLicence = { [unowned self] in self.storedLicence = nil }
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.newEnrolmentId = { [unowned self] in self.enrolments += 1; return "enrol\(self.enrolments)" }
        seams.fetch = { [unowned self] url in try self.serve(url) }
        seams.fetchIfChanged = { _, _ in .unavailable }
        seams.activeJobId = { [unowned self] in self.jobOpen ? "job" : nil }
        seams.withholdLicence = { _ in }
        seams.installPack = { _ in .failed("offline") }
        seams.forgetAdminCard = {}
        seams.beginDeparture = { [unowned self] reason, record, _ in
            self.departures.append((reason, record.enrolmentId))
        }
        return OrgProfileManager(seams: seams)
    }

    private func makeEnrolment(_ manager: OrgProfileManager,
                               resolve: @escaping (ActivationKey) async throws -> ActivationKey.Contents = { _ in
                                   throw ActivationKeyResolver.Failure.unreachable
                               }) -> ManagedConfigEnrolment {
        var seams = ManagedConfigEnrolment.Seams()
        seams.fetch = { [unowned self] url in self.fetches += 1; return try self.serve(url) }
        seams.resolveActivationKey = resolve
        seams.hasCompanySecret = { [unowned self] in self.secret != nil }
        seams.keepCompanySecret = { [unowned self] secret, _ in self.secret = secret }
        seams.loadAbsence = { [unowned self] in self.absence }
        seams.saveAbsence = { [unowned self] in self.absence = $0 }
        seams.readFeedback = { [unowned self] in self.feedback }
        seams.writeFeedback = { [unowned self] in self.feedback = $0; self.feedbackWrites += 1 }
        seams.now = { [unowned self] in self.now }
        seams.launchId = launchId
        seams.build = "766"
        return ManagedConfigEnrolment(manager: manager, seams: seams)
    }

    private func serve(_ url: URL) throws -> Data {
        guard let document = documents[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return Data(document.utf8)
    }

    private func licence(_ licensee: String) throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: licensee, issued: issued,
                                                    expires: issued.addingTimeInterval(400 * 86_400))
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    @discardableResult
    private func publish(profileId: String = "northbridge", name: String = "Northbridge Mechanical",
                         at address: String? = nil, generation: Int? = nil,
                         licensee: String? = nil) throws -> String {
        let profile = ConfigProfile(
            keyId: "k", profileId: profileId, organizationName: name, issued: issued, leaseDays: 30,
            licenceCode: try licensee.map(licence),
            profileGeneration: generation,
            settings: ["privacyFilterEnabled": RawSetting(.bool(true), .ceiling),
                       "fieldAssistEnabled": RawSetting(.bool(true), .default)])
        let document = try ProfileVerification.makeDocument(profile, privateKeyBase64: privateKeyBase64)
        if let address { documents[address] = document }
        return document
    }

    private func read(_ dictionary: [String: Any]?) -> ManagedConfigReading.Reading {
        ManagedConfigReading.read(dictionary)
    }

    // MARK: - Enrol

    func testAnAddressEnrolsThePhoneWithNoReviewAndRenewsLikeALink() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        try publish(at: northbridge, generation: 12)

        await enrolment.handle(read(["orgProfile": northbridge]))

        XCTAssertEqual(manager.profile?.organizationName, "Northbridge Mechanical")
        XCTAssertEqual(stored?.source, .managedConfig)
        XCTAssertEqual(stored?.profileURL, URL(string: northbridge), "the address renews like a link")
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(true))
        XCTAssertEqual(fetches, 1)

        // The same address at the next read is the enrolment in force: nothing is fetched again.
        await enrolment.handle(read(["orgProfile": northbridge]))
        XCTAssertEqual(fetches, 1)
        guard case .failure(.notRemovable) = manager.remove() else {
            return XCTFail("Remove Profile is still not offered")
        }
    }

    func testTheCompanysMDMIsToldTheVersionStateAndBuildOnlyWhenItChanges() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        try publish(at: northbridge, generation: 12)

        await enrolment.handle(read(["orgProfile": northbridge]))
        XCTAssertEqual(feedback?["profileId"] as? String, "northbridge")
        XCTAssertEqual(feedback?["profileGeneration"] as? Int, 12)
        XCTAssertEqual(feedback?["enrolmentState"] as? String, "enrolled")
        XCTAssertEqual(feedback?["build"] as? String, "766")
        let writes = feedbackWrites

        await enrolment.handle(read(["orgProfile": northbridge]))
        XCTAssertEqual(feedbackWrites, writes, "an unchanged report is not rewritten: a write is a change notification")
    }

    func testAPhoneNoMDMConfiguresWritesNoFeedback() async {
        let manager = makeManager()
        await makeEnrolment(manager).handle(read(nil))
        XCTAssertNil(feedback)
        XCTAssertEqual(feedbackWrites, 0)
    }

    // MARK: - Change

    func testAChangedInlineDocumentRenewsAndAnOlderOneIsRefused() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        let v12 = try publish(generation: 12)
        let v13 = try publish(generation: 13)

        await enrolment.handle(read(["orgProfile": v12]))
        XCTAssertEqual(stored?.profileGenerationHighWater, 12)
        XCTAssertNil(stored?.profileURL, "an inline document has no address")
        let enrolmentId = stored?.enrolmentId

        now = now.addingTimeInterval(3_600)
        await enrolment.handle(read(["orgProfile": v13]))
        XCTAssertEqual(stored?.profileGenerationHighWater, 13)
        XCTAssertEqual(stored?.enrolmentId, enrolmentId)
        XCTAssertEqual(stored?.lastRenewedAt, now, "the inline lease runs from each push")

        XCTAssertEqual(manager.receiveManagedDelivery(v12, sourceURL: nil), .refused(.staleProfile))
        XCTAssertEqual(stored?.profileGenerationHighWater, 13)
        XCTAssertEqual(manager.receiveManagedDelivery(v13, sourceURL: nil), .unchanged)
    }

    func testAPhoneEnrolledByKeyKeepsItsEnrolmentWhenTheMDMDeliversTheSameCompany() async throws {
        let manager = makeManager()
        let document = try publish(at: northbridge, generation: 12)
        try manager.apply(try manager.review(document: document, source: .link,
                                             sourceURL: URL(string: northbridge)).get()).get()
        XCTAssertEqual(stored?.enrolmentId, "enrol1")

        await makeEnrolment(manager).handle(read(["orgProfile": northbridge]))

        XCTAssertEqual(stored?.enrolmentId, "enrol1", "the same company keeps its enrolment")
        XCTAssertEqual(stored?.source, .managedConfig)
        XCTAssertTrue(departures.isEmpty)
    }

    func testANewGenerationWaitsForAnOpenJob() throws {
        let manager = makeManager()
        let v12 = try publish(generation: 12)
        let v13 = try publish(generation: 13)
        XCTAssertEqual(manager.receiveManagedDelivery(v12, sourceURL: nil), .enrolled)

        jobOpen = true
        XCTAssertEqual(manager.receiveManagedDelivery(v13, sourceURL: nil), .held)
        XCTAssertEqual(stored?.profileGenerationHighWater, 12, "nothing changes under an open job")
        XCTAssertEqual(manager.receiveManagedDelivery(v13, sourceURL: nil), .unchanged, "held is not asked twice")

        jobOpen = false
        manager.applyHeldProfileIfFree()
        XCTAssertEqual(stored?.profileGenerationHighWater, 13)
    }

    // MARK: - Removal

    func testOneEmptyReadLeavesNothingAndTwoTenMinutesApartLeave() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        try publish(at: northbridge)
        await enrolment.handle(read(["orgProfile": northbridge]))
        XCTAssertTrue(manager.isManaged)

        await enrolment.handle(read([:]))
        XCTAssertTrue(manager.isManaged, "one empty read during an MDM sync erases nothing")
        XCTAssertTrue(departures.isEmpty)

        now = now.addingTimeInterval(5 * 60)
        await enrolment.handle(read([:]))
        XCTAssertTrue(manager.isManaged, "five minutes is not ten")

        now = now.addingTimeInterval(6 * 60)
        await enrolment.handle(read([:]))
        XCTAssertFalse(manager.isManaged)
        XCTAssertEqual(departures.map(\.reason), [.removed], "leaving runs the owner's removal, records first")
        XCTAssertEqual(feedback?["enrolmentState"] as? String, "notEnrolled")
        XCTAssertNil(feedback?["profileId"])
    }

    func testAbsenceAcrossARelaunchLeaves() async throws {
        let manager = makeManager()
        try publish(at: northbridge)
        await makeEnrolment(manager).handle(read(["orgProfile": northbridge]))
        await makeEnrolment(manager).handle(read(nil))
        XCTAssertTrue(manager.isManaged)

        launchId = "launch-2"
        now = now.addingTimeInterval(60)
        await makeEnrolment(manager).handle(read(nil))
        XCTAssertFalse(manager.isManaged)
    }

    func testTheProfileComingBackForgetsTheFirstEmptyRead() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        try publish(at: northbridge)
        await enrolment.handle(read(["orgProfile": northbridge]))
        await enrolment.handle(read([:]))
        await enrolment.handle(read(["orgProfile": northbridge]))
        now = now.addingTimeInterval(20 * 60)
        await enrolment.handle(read([:]))
        XCTAssertTrue(manager.isManaged, "the clock starts again from the new first empty read")
    }

    func testAnUnreadableValueIsNotAbsence() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        try publish(at: northbridge)
        await enrolment.handle(read(["orgProfile": northbridge]))
        await enrolment.handle(read(["orgProfile": 42]))
        now = now.addingTimeInterval(60 * 60)
        await enrolment.handle(read(["orgProfile": "ftp://nowhere"]))
        XCTAssertTrue(manager.isManaged)
    }

    func testAnEmptyDictionaryNeverRemovesAProfileThePersonEnrolled() async throws {
        let manager = makeManager()
        let document = try publish(at: northbridge)
        try manager.apply(try manager.review(document: document, source: .link).get()).get()
        let enrolment = makeEnrolment(manager)
        await enrolment.handle(read(nil))
        now = now.addingTimeInterval(60 * 60)
        await enrolment.handle(read(nil))
        XCTAssertTrue(manager.isManaged)
        XCTAssertTrue(departures.isEmpty)
    }

    // MARK: - Another company under management

    func testAnotherCompanysProfileUnderManagementWinsAndIsReported() async throws {
        let manager = makeManager()
        let harbourDocument = try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)
        try manager.apply(try manager.review(document: harbourDocument, source: .licence).get()).get()
        try publish(at: northbridge)

        XCTAssertEqual(manager.receiveManagedDelivery(try XCTUnwrap(documents[northbridge]),
                                                      sourceURL: URL(string: northbridge)),
                       .moved(from: "Harbour Refrigeration"))
        XCTAssertEqual(manager.profile?.profileId, "northbridge")
        XCTAssertEqual(stored?.source, .managedConfig)
        XCTAssertEqual(departures.map(\.enrolmentId), ["enrol1"], "Harbour was left first")
    }

    func testTheMDMMayMoveItsOwnPhoneToAnotherCompany() async throws {
        let manager = makeManager()
        let enrolment = makeEnrolment(manager)
        try publish(at: northbridge)
        try publish(profileId: "harbour", name: "Harbour Refrigeration", at: harbour)
        await enrolment.handle(read(["orgProfile": northbridge]))

        await enrolment.handle(read(["orgProfile": harbour]))
        XCTAssertEqual(manager.profile?.profileId, "harbour")
        XCTAssertEqual(departures.count, 1)
    }

    func testAnyOtherPathIsStillRefusedOnADeviceManagedPhone() async throws {
        let manager = makeManager()
        try publish(at: northbridge)
        await makeEnrolment(manager).handle(read(["orgProfile": northbridge]))
        let other = try publish(profileId: "harbour", name: "Harbour Refrigeration")
        guard case .failure(.managedByDevice) = manager.review(document: other, source: .link, allowingMove: true) else {
            return XCTFail("only device management moves a device-managed phone")
        }
    }

    // MARK: - The activation key

    func testTheActivationKeyKeepsTheSecretForTheCompanyInForceOnly() async throws {
        let manager = makeManager()
        try publish(at: northbridge, licensee: "Northbridge Mechanical")
        let key = ActivationKey.generate()
        let companySecret = Data(repeating: 4, count: 32)
        let own = try licence("Northbridge Mechanical")
        let enrolment = makeEnrolment(manager) { _ in .init(licenceCode: own, companySecret: companySecret) }

        await enrolment.handle(read(["orgProfile": northbridge, "activationKey": key.display]))
        XCTAssertEqual(secret, companySecret, "nobody typed the key")

        // Another company's key opens nothing here.
        secret = nil
        let foreign = try licence("Harbour Refrigeration")
        let other = makeEnrolment(manager) { _ in .init(licenceCode: foreign, companySecret: companySecret) }
        await other.handle(read(["orgProfile": northbridge, "activationKey": key.display]))
        XCTAssertNil(secret)
    }

    func testIgnoredKeysAreNamedButChangeNothing() {
        let reading = read(["orgProfile": northbridge, "serverURL": "https://x.example", "theme": "dark"])
        XCTAssertEqual(reading.ignoredKeys, ["serverURL", "theme"])
        XCTAssertEqual(reading.delivery, .pointer(try! XCTUnwrap(URL(string: northbridge))))
    }

    // MARK: - The ingress

    func testTheIngressHandsOverAReadingOnlyWhenTheDictionaryChanged() {
        var dictionary: [String: Any]? = ["orgProfile": northbridge]
        let ingress = ManagedConfigIngress(seams: .init(readDictionary: { dictionary }))
        var readings = 0
        ingress.onReading = { _ in readings += 1 }
        ingress.read(force: true)
        ingress.read(force: false)
        XCTAssertEqual(readings, 1, "an unrelated defaults write hands nothing over")
        dictionary = ["orgProfile": harbour]
        ingress.read(force: false)
        XCTAssertEqual(readings, 2)
        ingress.read(force: true)
        XCTAssertEqual(readings, 3, "foreground always reads: removal needs a second read")
        XCTAssertEqual(ingress.source, .managedConfig)
    }
}
