import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT PR 2b — the lease: when a phone stops being the organisation's, how it renews, how it is
/// revoked, and that only a signed answer ever changes anything.
@MainActor
final class OrgProfileLeaseTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Status (pure)

    func testStatusAcrossTheLease() {
        func status(after days: Double, highWater: Date? = nil, expiry: Date? = nil) -> ProfileLease.Status {
            ProfileLease.status(leaseDays: 30, lastRenewed: start, policyExpiry: expiry,
                                clockHighWater: highWater, revoked: false,
                                now: start.addingTimeInterval(days * day))
        }
        let renewBy = start.addingTimeInterval(30 * day)
        XCTAssertEqual(status(after: 1), .live(renewBy: renewBy))
        XCTAssertEqual(status(after: 16.5), .renewSoon(renewBy: renewBy), "inside the 14-day warning")
        XCTAssertEqual(status(after: 30), .lapsed(since: renewBy))
        XCTAssertEqual(status(after: 45), .lapsed(since: renewBy))

        let expiry = start.addingTimeInterval(10 * day)
        XCTAssertEqual(status(after: 11, expiry: expiry), .lapsed(since: expiry),
                       "the organisation's own term ends it sooner")
    }

    func testAClockWoundBackIsALapseAndASmallCorrectionIsNot() {
        let highWater = start.addingTimeInterval(10 * day)
        XCTAssertEqual(ProfileLease.status(leaseDays: 30, lastRenewed: start, policyExpiry: nil,
                                           clockHighWater: highWater, revoked: false,
                                           now: start.addingTimeInterval(2 * day)),
                       .clockWoundBack)
        XCTAssertEqual(ProfileLease.status(leaseDays: 30, lastRenewed: start, policyExpiry: nil,
                                           clockHighWater: highWater, revoked: false,
                                           now: highWater.addingTimeInterval(-3_600)),
                       .live(renewBy: start.addingTimeInterval(30 * day)))
    }

    func testRevokedWinsOverEverything() {
        XCTAssertEqual(ProfileLease.status(leaseDays: 365, lastRenewed: start, policyExpiry: nil,
                                           clockHighWater: nil, revoked: true, now: start),
                       .revoked)
    }

    // MARK: - Mid-job grace (pure)

    func testALapseDuringAJobLocksWhenThatJobCloses() {
        var lock = ProfileLease.Lock()
        let lapsed = ProfileLease.Status.lapsed(since: start)
        XCTAssertFalse(lock.isLocked(status: lapsed, activeJob: "job-1"), "never mid-repair")
        XCTAssertFalse(lock.isLocked(status: lapsed, activeJob: "job-1"))
        XCTAssertTrue(lock.isLocked(status: lapsed, activeJob: nil), "the job closed")
        XCTAssertTrue(lock.isLocked(status: lapsed, activeJob: "job-2"), "a job started after the lapse gets no grace")
    }

    func testALapseWithNoJobLocksAtOnceAndARenewalUnlocks() {
        var lock = ProfileLease.Lock()
        XCTAssertTrue(lock.isLocked(status: .lapsed(since: start), activeJob: nil))
        XCTAssertFalse(lock.isLocked(status: .live(renewBy: start), activeJob: nil))
        // A later lapse is a new one: a job running then gets its grace again.
        XCTAssertFalse(lock.isLocked(status: .lapsed(since: start), activeJob: "job-3"))
    }

    // MARK: - Renewal and revocation (manager)

    private var signingKey: Curve25519.Signing.PrivateKey!
    private var now: Date!
    private var stored: OrgEnrolmentRecord?
    private var settings: [SettingKey: ProfileValue] = [:]
    private var envelopeInstalled: ProfileApplier.Result?
    private var withheld: String??
    private var fetchResult: Result<Data, Error> = .failure(URLError(.notConnectedToInternet))
    private var fetches = 0
    private var activeJob: String?
    private var licenceCode: String?

    override func setUp() {
        super.setUp()
        signingKey = Curve25519.Signing.PrivateKey()
        now = start
        stored = nil
        settings = [:]
        envelopeInstalled = nil
        withheld = nil
        fetchResult = .failure(URLError(.notConnectedToInternet))
        fetches = 0
        activeJob = nil
        licenceCode = nil
    }

    private var privateKeyBase64: String { signingKey.rawRepresentation.base64EncodedString() }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": signingKey.publicKey.rawRepresentation.base64EncodedString()]
        seams.licenceKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        seams.now = { [unowned self] in self.now }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        seams.readSetting = { [unowned self] in self.settings[$0] }
        seams.writeSetting = { [unowned self] in self.settings[$0] = $1 }
        seams.activateLicence = { [unowned self] in self.licenceCode = $0 }
        seams.storedLicenceCode = { [unowned self] in self.licenceCode }
        seams.clearLicence = { [unowned self] in self.licenceCode = nil }
        seams.installEnvelope = { [unowned self] result, _ in self.envelopeInstalled = result }
        seams.clearEnvelope = { [unowned self] in self.envelopeInstalled = nil }
        seams.newEnrolmentId = { "enrol-a" }
        seams.fetch = { [unowned self] _ in
            self.fetches += 1
            return try self.fetchResult.get()
        }
        seams.activeJobId = { [unowned self] in self.activeJob }
        seams.withholdLicence = { [unowned self] in self.withheld = .some($0) }
        return OrgProfileManager(seams: seams)
    }

    private func licence() throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge",
                                                    issued: start, expires: start.addingTimeInterval(400 * day))
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    private func profileDocument(revokedEnrolments: [String]? = nil, leaseDays: Int = 30,
                                 settings: [String: RawSetting] = ["remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling)],
                                 licence: String? = nil) throws -> String {
        let profile = ConfigProfile(keyId: "k", profileId: "northbridge", organizationName: "Northbridge",
                                    issued: start, leaseDays: leaseDays, licenceCode: licence,
                                    revokedEnrolmentIds: revokedEnrolments, settings: settings)
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: privateKeyBase64)
    }

    private let url = URL(string: "https://config.northbridge.example/profile.txt")!

    private func enrolled(licence: String? = nil) throws -> OrgProfileManager {
        let manager = makeManager()
        let review = try manager.review(document: try profileDocument(licence: licence), source: .link,
                                        sourceURL: url).get()
        try manager.apply(review).get()
        return manager
    }

    func testEnrolmentStartsTheLeaseAndRemembersWhereToRenew() throws {
        let manager = try enrolled()
        XCTAssertEqual(stored?.profileURL, url)
        XCTAssertEqual(stored?.lastRenewedAt, start)
        XCTAssertEqual(manager.lease, .live(renewBy: start.addingTimeInterval(30 * day)))
        XCTAssertFalse(manager.contentLocked)
    }

    func testRenewalExtendsTheLease() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(20 * day)
        fetchResult = .success(Data(try profileDocument().utf8))
        await manager.renewIfDue()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(stored?.lastRenewedAt, now)
        XCTAssertEqual(manager.lease, .live(renewBy: now.addingTimeInterval(30 * day)))
    }

    func testRenewalIsTriedAtMostOnceADayUnlessAsked() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(3_600)
        await manager.renewIfDue()
        XCTAssertEqual(fetches, 0, "enrolment itself counts as the day's fetch")
        await manager.renewIfDue(force: true)
        XCTAssertEqual(fetches, 1)
    }

    func testAFailedFetchOrA404OnlyFailsToRenew() async throws {
        let licenceCode = try licence()
        let manager = try enrolled(licence: licenceCode)
        now = start.addingTimeInterval(31 * day)
        fetchResult = .failure(URLError(.badServerResponse))
        await manager.renewIfDue()
        XCTAssertEqual(manager.lease, .lapsed(since: start.addingTimeInterval(30 * day)))
        XCTAssertNotEqual(stored?.revoked, true, "an unsigned failure is not a revocation")
        XCTAssertNotNil(envelopeInstalled, "a lapse keeps the organisation's rules")
        XCTAssertTrue(manager.contentLocked)
        XCTAssertEqual(withheld, .some(licenceCode), "and locks its content by withholding its licence")
        XCTAssertEqual(self.licenceCode, licenceCode, "nothing is deleted")
    }

    func testASignedRevocationLiftsTheRulesAndLocksTheContent() async throws {
        let licenceCode = try licence()
        let manager = try enrolled(licence: licenceCode)
        now = start.addingTimeInterval(2 * day)
        let revocation = ProfileRevocation(keyId: "k", profileId: "northbridge", issued: now)
        fetchResult = .success(Data(try ProfileVerification.makeDocument(revocation, privateKeyBase64: privateKeyBase64).utf8))
        await manager.renewIfDue()
        XCTAssertEqual(manager.lease, .revoked)
        XCTAssertEqual(stored?.revoked, true)
        XCTAssertNil(envelopeInstalled)
        XCTAssertEqual(withheld, .some(licenceCode))
    }

    func testNamingThisEnrolmentRevokesItAndOnlyIt() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(2 * day)
        fetchResult = .success(Data(try profileDocument(revokedEnrolments: ["someone-else"]).utf8))
        await manager.renewIfDue()
        XCTAssertNotEqual(manager.lease, .revoked, "another technician's revocation renews this phone")

        now = start.addingTimeInterval(4 * day)
        fetchResult = .success(Data(try profileDocument(revokedEnrolments: ["enrol-a"]).utf8))
        await manager.renewIfDue()
        XCTAssertEqual(manager.lease, .revoked)
    }

    func testARevocationSignedByAnotherKeyIsIgnored() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(2 * day)
        let forged = try ProfileVerification.makeDocument(
            ProfileRevocation(keyId: "k", profileId: "northbridge", issued: now),
            privateKeyBase64: Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        fetchResult = .success(Data(forged.utf8))
        await manager.renewIfDue()
        XCTAssertNotEqual(manager.lease, .revoked)
        XCTAssertNotNil(envelopeInstalled)
    }

    func testARenewalWritesOnlyNewStartingValues() async throws {
        let manager = makeManager()
        let first = try profileDocument(settings: ["fieldAssistEnabled": RawSetting(.bool(true), .default)])
        try manager.apply(try manager.review(document: first, source: .link, sourceURL: url).get()).get()
        settings[.fieldAssistEnabled] = .bool(false)    // the person turned it off

        now = start.addingTimeInterval(2 * day)
        let renewed = try profileDocument(settings: [
            "fieldAssistEnabled": RawSetting(.bool(true), .default),
            "fieldAssistDefaultMode": RawSetting(.string("ai_only"), .default),
        ])
        fetchResult = .success(Data(renewed.utf8))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.fieldAssistEnabled], .bool(false), "the person's change stands")
        XCTAssertEqual(settings[.fieldAssistDefaultMode], .string("ai_only"), "a key new in the renewal is written")
    }

    func testALapseDuringAJobWaitsForTheJob() throws {
        let manager = try enrolled(licence: try licence())
        activeJob = "job-1"
        now = start.addingTimeInterval(31 * day)
        manager.evaluateLease()
        XCTAssertFalse(manager.contentLocked)
        XCTAssertEqual(withheld, .some(nil))

        activeJob = nil
        manager.evaluateLease()
        XCTAssertTrue(manager.contentLocked)
    }

    func testRemovalStopsWithholding() throws {
        let manager = try enrolled(licence: try licence())
        now = start.addingTimeInterval(31 * day)
        manager.evaluateLease()
        XCTAssertTrue(manager.contentLocked)
        try manager.remove().get()
        XCTAssertEqual(withheld, .some(nil))
        XCTAssertNil(manager.lease)
    }

    // MARK: - The entitlement provider

    func testTheProviderSkipsAWithheldLicenceOnly() throws {
        let code = try licence()
        let provider = LiveFieldAssistEntitlementProvider(
            storePurchases: VerifiedStorePurchaseRecorder(),
            licensePublicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString(),
            licenseCode: { code })
        defer { PolicyEnvelope.withholdLicence(nil) }

        PolicyEnvelope.withholdLicence(nil)
        XCTAssertEqual(provider.evidence().evidence.count, 1)

        PolicyEnvelope.withholdLicence(code)
        XCTAssertTrue(provider.evidence().evidence.isEmpty)

        PolicyEnvelope.withholdLicence("some-other-code")
        XCTAssertEqual(provider.evidence().evidence.count, 1)
    }
}
