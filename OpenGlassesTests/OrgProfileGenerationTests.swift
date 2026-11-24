import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan ND P1 — a phone follows the company's settings: a newer generation applies, an older copy is
/// refused, a default the person never touched follows and one they chose stays, a change waits for
/// the open job, and a `304` changes and renews nothing. In-memory seams, as in `OrgProfileLeaseTests`.
@MainActor
final class OrgProfileGenerationTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let url = URL(string: "https://licence.fixture.example/p/northbridge")!

    private var signingKey: Curve25519.Signing.PrivateKey!
    private var now = Date()
    private var stored: OrgEnrolmentRecord?
    private var settings: [SettingKey: ProfileValue] = [:]
    private var envelope: ProfileApplier.Result?
    private var fetchResult: Result<Data, Error> = .failure(URLError(.notConnectedToInternet))
    private var conditionalResult: ProfileConditionalFetch = .unavailable
    private var fetches = 0
    private var conditionalFetches: [Int] = []
    private var activeJob: String?

    override func setUp() {
        super.setUp()
        signingKey = Curve25519.Signing.PrivateKey()
        now = start
        stored = nil
        settings = [:]
        envelope = nil
        fetchResult = .failure(URLError(.notConnectedToInternet))
        conditionalResult = .unavailable
        fetches = 0
        conditionalFetches = []
        activeJob = nil
    }

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
        seams.activateLicence = { _ in }
        seams.storedLicenceCode = { nil }
        seams.clearLicence = {}
        seams.installEnvelope = { [unowned self] result, _ in self.envelope = result }
        seams.clearEnvelope = { [unowned self] in self.envelope = nil }
        seams.newEnrolmentId = { "enrol-a" }
        seams.fetch = { [unowned self] _ in
            self.fetches += 1
            return try self.fetchResult.get()
        }
        seams.fetchIfChanged = { [unowned self] _, generation in
            self.conditionalFetches.append(generation)
            return self.conditionalResult
        }
        seams.activeJobId = { [unowned self] in self.activeJob }
        return OrgProfileManager(seams: seams)
    }

    private func document(generation: Int?, units: String = "kPa,C,kg",
                          extra: [String: RawSetting] = [:], revoked: [String]? = nil) throws -> String {
        var settings: [String: RawSetting] = [
            "refrigerationUnits": RawSetting(.string(units), .default),
            "remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling),
        ]
        settings.merge(extra) { _, new in new }
        let profile = ConfigProfile(keyId: "k", profileId: "northbridge", organizationName: "Northbridge",
                                    issued: start, leaseDays: 30, revokedEnrolmentIds: revoked,
                                    profileGeneration: generation, settings: settings)
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: signingKey.rawRepresentation.base64EncodedString())
    }

    private func enrolled(generation: Int? = 12) throws -> OrgProfileManager {
        let manager = makeManager()
        let review = try manager.review(document: try document(generation: generation), source: .link, sourceURL: url).get()
        try manager.apply(review).get()
        return manager
    }

    private func serveFull(_ text: String) {
        fetchResult = .success(Data(text.utf8))
    }

    // MARK: - Enrolment

    func testEnrolmentRecordsTheGenerationAndWhatItWrote() throws {
        let manager = try enrolled()
        XCTAssertEqual(stored?.profileGenerationHighWater, 12)
        XCTAssertEqual(manager.profileGeneration, 12)
        XCTAssertEqual(stored?.lastWrittenStartingValues?["refrigerationUnits"], .string("kPa,C,kg"))
        XCTAssertEqual(settings[.refrigerationUnits], .string("kPa,C,kg"))
    }

    func testAnOlderCopyOfTheSameProfileIsRefusedAtReview() throws {
        let manager = try enrolled()
        let review = try manager.review(document: try document(generation: 11), source: .link, sourceURL: url).get()
        guard case .failure(.staleProfile) = manager.apply(review) else { return XCTFail("expected a stale refusal") }
        XCTAssertEqual(stored?.profileGenerationHighWater, 12)
    }

    // MARK: - Following a change

    func testAnUntouchedDefaultFollows() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 13, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.refrigerationUnits], .string("psi,C,kg"), "the default the person never touched follows")
        XCTAssertEqual(stored?.profileGenerationHighWater, 13)
        XCTAssertTrue(manager.keptChoices.isEmpty)
    }

    func testAPersonsChoiceIsKeptListedAndCanBeHandedBack() async throws {
        let manager = try enrolled()
        settings[.refrigerationUnits] = .string("bar,C,kg")   // the person chose bar
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 13, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.refrigerationUnits], .string("bar,C,kg"), "the person's choice stays")
        XCTAssertEqual(manager.keptChoices,
                       [.init(key: .refrigerationUnits, personsValue: .string("bar,C,kg"), companyValue: .string("psi,C,kg"))])

        manager.useCompanyDefault(.refrigerationUnits)
        XCTAssertEqual(settings[.refrigerationUnits], .string("psi,C,kg"))
        XCTAssertTrue(manager.keptChoices.isEmpty)
        XCTAssertEqual(stored?.lastWrittenStartingValues?["refrigerationUnits"], .string("psi,C,kg"),
                       "from here the key follows the company again")

        // Removing the profile still restores what the person had before enrolment (nothing).
        XCTAssertNil(stored?.priorStartingValues["refrigerationUnits"])
    }

    func testARecordFromBeforeTheFollowRuleIsMigratedSafely() async throws {
        let manager = try enrolled(generation: nil)
        stored?.lastWrittenStartingValues = nil           // as written by a build before ND
        manager.loadAtLaunch()
        settings[.refrigerationUnits] = .string("bar,C,kg")
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 1, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.refrigerationUnits], .string("bar,C,kg"))
        XCTAssertEqual(stored?.profileGenerationHighWater, 1)
    }

    func testAMigratedUntouchedDefaultFollows() async throws {
        let manager = try enrolled(generation: nil)
        stored?.lastWrittenStartingValues = nil
        manager.loadAtLaunch()
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 1, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.refrigerationUnits], .string("psi,C,kg"))
    }

    // MARK: - Stale copies

    func testAStaleCopyRenewsNothingAndChangesNothing() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(20 * day)
        serveFull(try document(generation: 11, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(settings[.refrigerationUnits], .string("kPa,C,kg"))
        XCTAssertEqual(stored?.lastRenewedAt, start, "an older copy does not renew the lease")
        XCTAssertEqual(stored?.profileGenerationHighWater, 12)
    }

    func testAStaleCopyCannotLiftARevocationOrRevokeFromThePast() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 10, revoked: ["enrol-a"]))
        await manager.renewIfDue()
        XCTAssertNotEqual(stored?.revoked, true, "nothing in an older copy is used")
        XCTAssertNotEqual(manager.lease, .revoked)
    }

    func testACopyWithoutAGenerationAfterOneWasSeenIsStale() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: nil, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.refrigerationUnits], .string("kPa,C,kg"))
    }

    // MARK: - Between jobs

    func testANewerGenerationWaitsForTheOpenJob() async throws {
        let manager = try enrolled()
        activeJob = "job-1"
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 13, units: "psi,C,kg"))
        await manager.renewIfDue()
        XCTAssertEqual(settings[.refrigerationUnits], .string("kPa,C,kg"), "nothing changes under the job")
        XCTAssertNotNil(stored?.heldProfileDocument)
        XCTAssertEqual(manager.heldGeneration, 13)
        XCTAssertEqual(stored?.lastRenewedAt, now, "the lease renews from the verified copy")
        XCTAssertEqual(stored?.profileGenerationHighWater, 12)

        manager.applyHeldProfileIfFree()
        XCTAssertNotNil(stored?.heldProfileDocument, "still waiting while the job is open")

        activeJob = nil
        manager.applyHeldProfileIfFree()
        XCTAssertNil(stored?.heldProfileDocument)
        XCTAssertEqual(settings[.refrigerationUnits], .string("psi,C,kg"))
        XCTAssertEqual(stored?.profileGenerationHighWater, 13)
    }

    func testARevocationDoesNotWaitForTheJob() async throws {
        let manager = try enrolled()
        activeJob = "job-1"
        now = start.addingTimeInterval(2 * day)
        serveFull(try document(generation: 13, revoked: ["enrol-a"]))
        await manager.renewIfDue()
        XCTAssertEqual(stored?.revoked, true)
        XCTAssertNil(stored?.heldProfileDocument)
    }

    // MARK: - The conditional fetch

    func testBetweenDailyFetchesThePhoneAsksIfTheGenerationChanged() async throws {
        let manager = try enrolled()
        now = start.addingTimeInterval(3_600)
        conditionalResult = .notModified
        await manager.renewIfDue()
        XCTAssertEqual(conditionalFetches, [12])
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(stored?.lastRenewedAt, start, "a 304 is unsigned: it renews nothing")
        XCTAssertEqual(stored?.lastConditionalCheck, now)

        now = start.addingTimeInterval(3_600 + 600)
        await manager.renewIfDue()
        XCTAssertEqual(conditionalFetches, [12], "at most every fifteen minutes")

        now = start.addingTimeInterval(3_600 + 900)
        conditionalResult = .document(Data(try document(generation: 13, units: "psi,C,kg").utf8))
        await manager.renewIfDue()
        XCTAssertEqual(conditionalFetches, [12, 12])
        XCTAssertEqual(settings[.refrigerationUnits], .string("psi,C,kg"), "an edit arrives the next time the app is opened")
        XCTAssertEqual(stored?.profileGenerationHighWater, 13)
        XCTAssertEqual(stored?.lastRenewedAt, now, "a whole verified copy renews the lease")
    }

    func testAProfileWithoutAGenerationIsNeverAskedConditionally() async throws {
        let manager = try enrolled(generation: nil)
        now = start.addingTimeInterval(3_600)
        await manager.renewIfDue()
        XCTAssertTrue(conditionalFetches.isEmpty)
        XCTAssertEqual(fetches, 0)
    }
}
