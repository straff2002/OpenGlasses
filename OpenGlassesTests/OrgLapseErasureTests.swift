import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT PR 4 — `eraseAfterLapseDays`: the organisation's opt-in to erase its content once a lease
/// has been lapsed that long without a renewal. Absent, a lapse only ever locks; never mid-job; and a
/// renewal heard afterwards brings the phone back, reinstalling the pack.
@MainActor
final class OrgLapseErasureTests: XCTestCase {

    private var vendorKey: Curve25519.Signing.PrivateKey!
    private var stored: OrgEnrolmentRecord?
    private var now = Date(timeIntervalSince1970: 1_790_086_400)
    private var activeJob: String?
    private var departures: [OrgDeparture.Reason] = []
    private var endedLapses: [String] = []
    private var installs: [String] = []
    private var fetchResult: Result<Data, Error> = .failure(URLError(.notConnectedToInternet))
    private let issued = Date(timeIntervalSince1970: 1_790_000_000)
    private let address = URL(string: "https://config.northbridge.example/profile.txt")!

    override func setUp() {
        super.setUp()
        vendorKey = Curve25519.Signing.PrivateKey()
        stored = nil
        now = issued.addingTimeInterval(86_400)
        activeJob = nil
        departures = []
        endedLapses = []
        installs = []
        fetchResult = .failure(URLError(.notConnectedToInternet))
    }

    private var privateKeyBase64: String { vendorKey.rawRepresentation.base64EncodedString() }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": vendorKey.publicKey.rawRepresentation.base64EncodedString()]
        seams.licenceKey = vendorKey.publicKey.rawRepresentation.base64EncodedString()
        seams.now = { [unowned self] in self.now }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        var values: [SettingKey: ProfileValue] = [:]
        seams.readSetting = { values[$0] }
        seams.writeSetting = { values[$0] = $1 }
        seams.activateLicence = { _ in }
        seams.storedLicenceCode = { nil }
        seams.clearLicence = {}
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.fetch = { [unowned self] _ in try self.fetchResult.get() }
        seams.activeJobId = { [unowned self] in self.activeJob }
        seams.withholdLicence = { _ in }
        seams.installPack = { [unowned self] packId in
            self.installs.append(packId)
            return .installed(vaultId: "hvac")
        }
        seams.forgetAdminCard = {}
        seams.beginDeparture = { [unowned self] reason, _, _ in self.departures.append(reason) }
        seams.endLapseDeparture = { [unowned self] in self.endedLapses.append($0) }
        return OrgProfileManager(seams: seams)
    }

    /// A 30-day lease, lapsing 31 days after enrolment.
    private func document(eraseAfterLapseDays: Int?) throws -> String {
        let profile = ConfigProfile(keyId: "k", profileId: "northbridge", organizationName: "Northbridge Mechanical",
                                    issued: issued, leaseDays: 30, eraseAfterLapseDays: eraseAfterLapseDays,
                                    vaultPack: .init(packId: "hvac_rtu_pack"))
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: privateKeyBase64)
    }

    private func enrol(_ manager: OrgProfileManager, eraseAfterLapseDays: Int?) async throws {
        let review = try manager.review(document: try document(eraseAfterLapseDays: eraseAfterLapseDays),
                                        source: .link, sourceURL: address).get()
        try manager.apply(review).get()
        await manager.completePendingPack()
        installs = []
    }

    private func days(_ n: Double) { now = now.addingTimeInterval(n * 86_400) }

    // MARK: -

    func testWithoutTheOptInALapseOnlyEverLocks() async throws {
        let manager = makeManager()
        try await enrol(manager, eraseAfterLapseDays: nil)
        days(400)
        manager.evaluateLease()
        XCTAssertTrue(manager.contentLocked)
        XCTAssertEqual(departures, [], "a genuine remote worker does not lose their manuals for being offline")
        XCTAssertNil(stored?.lapseErasedAt)
    }

    func testTheOptInErasesOnceTheWindowHasPassedAndOnlyOnce() async throws {
        let manager = makeManager()
        try await enrol(manager, eraseAfterLapseDays: 14)
        days(30 + 13)
        manager.evaluateLease()
        XCTAssertEqual(departures, [], "lapsed, but not yet for 14 days")

        days(2)
        manager.evaluateLease()
        XCTAssertEqual(departures, [.lapsed])
        XCTAssertNotNil(stored?.lapseErasedAt)
        XCTAssertEqual(stored?.pendingPackId, "hvac_rtu_pack", "the pack comes back if a renewal is heard")

        days(1)
        manager.evaluateLease()
        await manager.completePendingPack()
        XCTAssertEqual(departures, [.lapsed], "once")
        XCTAssertEqual(installs, [], "and not reinstalled while still lapsed")
    }

    func testNeverMidJob() async throws {
        let manager = makeManager()
        try await enrol(manager, eraseAfterLapseDays: 7)
        activeJob = "job-1"
        days(29)
        manager.evaluateLease()
        days(40)
        manager.evaluateLease()
        XCTAssertEqual(departures, [], "the lapse was first seen during a job, so nothing locks or erases until it closes")

        activeJob = nil
        manager.evaluateLease()
        XCTAssertEqual(departures, [.lapsed])
    }

    func testARenewalBringsThePhoneBack() async throws {
        let manager = makeManager()
        try await enrol(manager, eraseAfterLapseDays: 7)
        let enrolmentId = try XCTUnwrap(stored?.enrolmentId)
        days(40)
        manager.evaluateLease()
        XCTAssertEqual(departures, [.lapsed])

        fetchResult = .success(Data(try document(eraseAfterLapseDays: 7).utf8))
        await manager.renewIfDue(force: true)
        XCTAssertNil(stored?.lapseErasedAt)
        XCTAssertEqual(endedLapses, [enrolmentId], "records owed from the erasure are the firm's again, not erased")
        XCTAssertEqual(installs, ["hvac_rtu_pack"])
        XCTAssertFalse(manager.contentLocked)
    }

    func testAWindowOutsideItsBoundsIsIgnored() async throws {
        let manager = makeManager()
        try await enrol(manager, eraseAfterLapseDays: 0)
        days(400)
        manager.evaluateLease()
        XCTAssertEqual(departures, [])
    }

    // MARK: - The departure side

    func testARenewalEndsOnlyALapseDeparture() async {
        var saved: OrgDeparture?
        var seams = OrgDepartureService.Seams()
        seams.now = { [unowned self] in self.now }
        seams.save = { saved = $0 }
        seams.activeJobId = { "job" }
        let service = OrgDepartureService(seams: seams)

        await service.begin(.lapsed, organizationName: "N", enrolmentId: "e1", enrolledAt: issued,
                            packId: nil, undeliveredEraseDays: nil)
        service.cancelLapse(enrolmentId: "e1")
        XCTAssertNil(service.departure)
        XCTAssertNil(saved)

        await service.begin(.revoked, organizationName: "N", enrolmentId: "e1", enrolledAt: issued,
                            packId: nil, undeliveredEraseDays: nil)
        service.cancelLapse(enrolmentId: "e1")
        XCTAssertEqual(service.departure?.reason, .revoked, "a revocation is never undone")
    }
}
