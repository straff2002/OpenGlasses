import XCTest
import CryptoKit
@testable import OpenGlasses

// Plan JS P2 — device seats, headless: ephemeral keys, an in-memory phone, and a stub seat service
// that runs the licence core's own rules (`SeatPolicy`, `SeatWire`, compiled into this bundle), so
// the phone and the service are held to one contract.

/// A software P-256 key in place of the Secure Enclave.
final class EphemeralSeatKeyStore: DeviceSeatKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: P256.Signing.PrivateKey?
    var created = 0
    /// The Keychain cannot be read (before first unlock): `existing()` throws.
    var unreadable = false

    struct Key: DeviceSeatKey, @unchecked Sendable {
        let software: P256.Signing.PrivateKey
        var publicKeyX963: Data { software.publicKey.x963Representation }
        func sign(_ data: Data) throws -> Data { try software.signature(for: data).derRepresentation }
    }

    struct Unreadable: Error {}
    func existing() throws -> DeviceSeatKey? {
        try lock.withLock {
            if unreadable { throw Unreadable() }
            return held.map(Key.init(software:))
        }
    }
    func create() throws -> DeviceSeatKey {
        lock.withLock {
            let made = P256.Signing.PrivateKey()
            held = made
            created += 1
            return Key(software: made)
        }
    }
    func remove() { lock.withLock { held = nil } }
}

/// The seat service, reduced to the core's rules and an in-memory ledger.
actor StubSeatService: DeviceSeatServer {
    let leaseKey = Curve25519.Signing.PrivateKey()
    var licence: SeatLicence
    var profileId: String
    var seats: [SeatRecord] = []
    var nonces: Set<String> = []
    var now: Date
    var reachable = true
    /// Every request the phone sent, as the JSON it signed.
    var received: [(DeviceSeatLease.Action, Data)] = []
    /// Answer every nonce request with a stale one first, to exercise the retry.
    var staleNonceOnce = false
    /// Run once, while the next request is out (before its answer), to race the phone against itself.
    var whileOut: (@Sendable () async -> Void)?
    /// Answer the next request with this reply instead (a replayed or forged answer).
    var replayOnce: DeviceSeatLease.Reply?

    init(licence: SeatLicence, profileId: String, now: Date) {
        self.licence = licence
        self.profileId = profileId
        self.now = now
    }

    var leasePublicKey: String { leaseKey.publicKey.rawRepresentation.base64EncodedString() }
    func set(now: Date) { self.now = now }
    func set(reachable: Bool) { self.reachable = reachable }
    func set(licence: SeatLicence) { self.licence = licence }
    func set(staleNonceOnce: Bool) { self.staleNonceOnce = staleNonceOnce }
    func set(whileOut: (@Sendable () async -> Void)?) { self.whileOut = whileOut }
    func set(replayOnce: DeviceSeatLease.Reply?) { self.replayOnce = replayOnce }
    /// A lease the service's key signs, for any payload: what an old answer replayed looks like.
    func signedLease(_ payload: SeatLeasePayload) throws -> String { try SeatWire.lease(payload, signer: leaseKey.signature(for:)) }
    func free(all: Bool = true) { for i in seats.indices { seats[i].freedAt = now } }
    func occupy(_ count: Int) {
        for _ in 0..<count {
            let other = P256.Signing.PrivateKey().publicKey.x963Representation
            seats.append(SeatRecord(profileId: profileId, deviceKeyHash: SeatWire.deviceKeyHash(publicKeyX963: other),
                                    devicePublicKey: other.base64EncodedString(), enrolmentId: "other000",
                                    claimedAt: now, leaseNotAfter: now.addingTimeInterval(SeatWire.leaseLength),
                                    lastSeenAt: now, build: "660"))
        }
    }

    func nonce(origin: URL) async throws -> String {
        guard reachable else { throw URLError(.notConnectedToInternet) }
        let nonce = UUID().uuidString
        if staleNonceOnce { staleNonceOnce = false; return "stale-" + nonce }
        nonces.insert(nonce)
        return nonce
    }

    func send(_ action: DeviceSeatLease.Action, envelope: DeviceSeatLease.Envelope, origin: URL) async throws -> DeviceSeatLease.Reply {
        guard reachable else { throw URLError(.notConnectedToInternet) }
        guard nonces.remove(envelope.nonce) != nil else { return reply(.refuse(.badNonce)) }
        let wire = SeatEnvelope(nonce: envelope.nonce, request: envelope.request, signature: envelope.signature)
        guard let body = Data(base64Encoded: envelope.request), let coreAction = SeatWire.Action(rawValue: action.rawValue) else {
            return reply(.refuse(.badRequest))
        }
        received.append((action, body))
        if let replay = replayOnce {
            replayOnce = nil
            return replay
        }
        if let hook = whileOut {
            whileOut = nil
            await hook()
        }
        let decoder = SeatWire.decoder()
        switch coreAction {
        case .claim:
            guard let claim = try? decoder.decode(SeatClaimRequest.self, from: body),
                  let key = try? SeatWire.devicePublicKey(of: claim),
                  (try? SeatWire.openEnvelope(wire, action: .claim, publicKeyX963: key)) != nil else { return reply(.refuse(.badRequest)) }
            return record(SeatPolicy.claim(claim, deviceKeyHash: SeatWire.deviceKeyHash(publicKeyX963: key),
                                           licence: licence, seats: seats, now: now))
        case .renew:
            guard let renew = try? decoder.decode(SeatRenewRequest.self, from: body),
                  let lease = try? SeatWire.openLease(renew.lease, publicKeys: [leaseKey.publicKey]) else { return reply(.refuse(.badRequest)) }
            guard let seat = seats.last(where: { $0.deviceKeyHash == lease.deviceKeyHash }),
                  let key = Data(base64Encoded: seat.devicePublicKey),
                  (try? SeatWire.openEnvelope(wire, action: .renew, publicKeyX963: key)) != nil else { return reply(.refuse(.freed)) }
            return record(SeatPolicy.renew(lease, build: renew.build, profileId: profileId, licence: licence, seats: seats, now: now))
        case .release:
            guard let release = try? decoder.decode(SeatReleaseRequest.self, from: body),
                  let lease = try? SeatWire.openLease(release.lease, publicKeys: [leaseKey.publicKey]),
                  let index = seats.lastIndex(where: { $0.deviceKeyHash == lease.deviceKeyHash }),
                  let key = Data(base64Encoded: seats[index].devicePublicKey),
                  (try? SeatWire.openEnvelope(wire, action: .release, publicKeyX963: key)) != nil else { return reply(.refuse(.badRequest)) }
            seats[index].freedAt = now
            seats[index].freedBy = "phone"
            return DeviceSeatLease.Reply(lease: nil, refusal: nil, seats: nil)
        }
    }

    private func record(_ outcome: SeatPolicy.Outcome) -> DeviceSeatLease.Reply {
        if case .grant(let seat, _) = outcome {
            if let index = seats.firstIndex(where: { $0.deviceKeyHash == seat.deviceKeyHash && $0.freedAt == nil }) {
                seats[index] = seat
            } else {
                seats.append(seat)
            }
        }
        return reply(outcome)
    }

    private func reply(_ outcome: SeatPolicy.Outcome) -> DeviceSeatLease.Reply {
        switch outcome {
        case .grant(_, let payload):
            return DeviceSeatLease.Reply(lease: try? SeatWire.lease(payload, signer: leaseKey.signature(for:)), refusal: nil, seats: nil)
        case .refuse(let code, let seats):
            return DeviceSeatLease.Reply(lease: nil, refusal: DeviceSeatLease.Refusal(rawValue: code.rawValue), seats: seats)
        }
    }
}

/// A clock and a record the `@Sendable` seams can share.
final class SeatWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRecord: DeviceSeatRecord?
    private var storedNow: Date
    private var storedCode: String?
    private var storedEnrolmentId: String?
    init(now: Date) { storedNow = now }
    /// The organisation enrolment in force, as the gate reads it; nil falls back to the record's.
    var enrolmentId: String? {
        get { lock.withLock { storedEnrolmentId } }
        set { lock.withLock { storedEnrolmentId = newValue } }
    }
    var record: DeviceSeatRecord? {
        get { lock.withLock { storedRecord } }
        set { lock.withLock { storedRecord = newValue } }
    }
    var now: Date {
        get { lock.withLock { storedNow } }
        set { lock.withLock { storedNow = newValue } }
    }
    var code: String? {
        get { lock.withLock { storedCode } }
        set { lock.withLock { storedCode = newValue } }
    }
}

@MainActor
final class DeviceSeatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let licenceKey = Curve25519.Signing.PrivateKey()
    private let enrolment = DeviceSeatEnrolment(profileId: "p-fixture", enrolmentId: "a1b2c3d4")
    private var world: SeatWorld!
    private var keys: EphemeralSeatKeyStore!
    private var server: StubSeatService!
    private var leaseKeys: [String] = []

    private var licenceKeyBase64: String { licenceKey.publicKey.rawRepresentation.base64EncodedString() }

    override func setUp() async throws {
        world = SeatWorld(now: t0)
        keys = EphemeralSeatKeyStore()
        world.code = try code()
        server = StubSeatService(licence: SeatLicence(licenseIDHash: SeatWire.licenseIDHash(code: world.code!), seats: 2,
                                                      seatCheck: true, expires: t0.addingTimeInterval(365 * 86_400)),
                                 profileId: enrolment.profileId, now: t0)
        leaseKeys = [await server.leasePublicKey]
    }

    private func code(seatCheck: Bool = true, seats: Int? = 2, expires: Date? = nil,
                      profile: String? = "https://licence.example.test/p/p-fixture") throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "Fixture Ltd", issued: t0,
                                                    expires: expires ?? t0.addingTimeInterval(365 * 86_400),
                                                    seats: seats, profile: profile, seatCheck: seatCheck ? true : nil)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: licenceKey.rawRepresentation.base64EncodedString())
    }

    private func service() -> DeviceSeatService {
        var seams = DeviceSeatService.Seams()
        seams.server = server
        seams.keys = keys
        let world = world!
        seams.loadRecord = { world.record }
        seams.saveRecord = { world.record = $0 }
        seams.leaseKeys = leaseKeys
        seams.licenceKey = licenceKeyBase64
        seams.storedCode = { world.code }
        seams.build = { "660" }
        seams.now = { world.now }
        seams.entitlementChanged = {}
        return DeviceSeatService(seams: seams)
    }

    private func decision() -> FieldAssistEntitlementDecision {
        let world = world!, keys = keys!
        let provider = LiveFieldAssistEntitlementProvider(
            storePurchases: VerifiedStorePurchaseRecorder(), licensePublicKeyBase64: licenceKeyBase64,
            licenseCode: { world.code },
            seat: .init(record: { world.record }, deviceKeyHash: { keys.currentKeyHash() },
                        enrolmentId: { world.enrolmentId }, leaseKeys: leaseKeys, now: { world.now }))
        return FieldAssistEntitlementEvaluator.decide(provider.evidence(), now: world.now)
    }

    private func advance(days: Double) async {
        world.now = world.now.addingTimeInterval(days * 86_400)
        await server.set(now: world.now)
    }

    // MARK: - Codes without the claim

    func testALicenceWithoutSeatCheckGrantsWithNoLeaseExactlyAsToday() throws {
        world.code = try code(seatCheck: false)
        XCTAssertTrue(decision().isGranted)
        XCTAssertNil(world.record)
    }

    func testALicenceWithoutSeatCheckNeverCallsTheSeatService() async throws {
        world.code = try code(seatCheck: false)
        await service().checkIn(enrolment, force: true)
        let received = await server.received
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(keys.created, 0, "no key is made for a licence that counts nothing")
    }

    // MARK: - Claiming

    func testASeatCheckedLicenceWithNoLeaseIsLockedUntilItChecksIn() {
        guard case .seatUnavailable(let hold)? = decision().denial else {
            return XCTFail("expected a seat hold, got \(decision())")
        }
        XCTAssertEqual(hold.kind, .checkIn)
        XCTAssertTrue(hold.message.contains("Fixture Ltd"))
        XCTAssertTrue(FieldAssistCapability.capabilities(for: provider().evidence(), now: world.now).isEmpty,
                      "no capability is granted on a held licence")
    }

    private func provider() -> LiveFieldAssistEntitlementProvider {
        let world = world!, keys = keys!
        return LiveFieldAssistEntitlementProvider(
            storePurchases: VerifiedStorePurchaseRecorder(), licensePublicKeyBase64: licenceKeyBase64,
            licenseCode: { world.code },
            seat: .init(record: { world.record }, deviceKeyHash: { keys.currentKeyHash() },
                        enrolmentId: { world.enrolmentId }, leaseKeys: leaseKeys, now: { world.now }))
    }

    func testClaimingOnEnrolmentUnlocksTheLicence() async {
        await service().checkIn(enrolment, force: true)
        XCTAssertTrue(decision().isGranted)
        let lease = try? XCTUnwrap(world.record?.lease.flatMap { DeviceSeatLease.open($0, keys: leaseKeys) })
        XCTAssertEqual(lease?.enrolmentId, enrolment.enrolmentId)
        XCTAssertEqual(lease?.notAfter, t0.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(lease?.deviceKeyHash, keys.currentKeyHash())
        XCTAssertEqual(world.record?.origin, "https://licence.example.test")
    }

    func testTheClaimCarriesNoFieldBeyondTheFourListed() async throws {
        await service().checkIn(enrolment, force: true)
        let received = await server.received
        let claim = try XCTUnwrap(received.first { $0.0 == .claim }?.1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: claim) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["profileId", "enrolmentId", "devicePublicKey", "build"])
        XCTAssertEqual(object["build"] as? String, "660")
        XCTAssertEqual(object["profileId"] as? String, enrolment.profileId)
    }

    func testAFullLicenceSaysAllSeatsAreInUse() async {
        await server.occupy(2)
        await service().checkIn(enrolment, force: true)
        guard case .seatUnavailable(let hold)? = decision().denial else { return XCTFail("expected a seat hold") }
        XCTAssertEqual(hold.message, "All 2 seats for Fixture Ltd are in use. Ask your administrator to free one.")
        XCTAssertEqual(FieldAssistEntitlementStatus.make(decision: decision(), now: world.now), .seatUnavailable(hold))
    }

    func testAStaleNonceIsAskedForAgain() async {
        await server.set(staleNonceOnce: true)
        await service().checkIn(enrolment, force: true)
        XCTAssertTrue(decision().isGranted)
    }

    // MARK: - The lease, offline

    func testALeaseNamingAnotherPhonesKeyFails() async {
        await service().checkIn(enrolment, force: true)
        XCTAssertTrue(decision().isGranted)
        keys.remove()
        _ = try? keys.create()   // the record copied to a phone with a different key
        XCTAssertFalse(decision().isGranted)
    }

    func testALeasePastNotAfterPlusGraceFails() async {
        await service().checkIn(enrolment, force: true)
        await server.set(reachable: false)
        world.now = t0.addingTimeInterval(44 * 86_400 - 60)
        XCTAssertTrue(decision().isGranted, "inside the grace a phone out of signal keeps working")
        world.now = t0.addingTimeInterval(44 * 86_400)
        guard case .seatUnavailable(let hold)? = decision().denial else { return XCTFail("expected a seat hold") }
        XCTAssertEqual(hold.kind, .checkIn)
    }

    func testALeaseSignedByAnotherKeyOrUnderAnotherDomainFails() async throws {
        let stranger = Curve25519.Signing.PrivateKey()
        let payload = SeatLeasePayload(deviceKeyHash: try keys.create().publicKeyX963.sha256Hex, enrolmentId: enrolment.enrolmentId,
                                       issued: t0, licenseIDHash: SeatWire.licenseIDHash(code: world.code!),
                                       notAfter: t0.addingTimeInterval(30 * 86_400))
        var record = DeviceSeatRecord(enrolmentId: enrolment.enrolmentId, profileId: enrolment.profileId)
        record.lease = try SeatWire.lease(payload, signer: stranger.signature(for:))
        world.record = record
        XCTAssertFalse(decision().isGranted, "signed by a key the app does not embed")
        // The right key, but a licence-code signature (no domain): not a lease.
        let leaseKey = await server.leaseKey
        record.lease = try IssuanceWire.sign(SeatWire.encoder().encode(payload), signer: leaseKey.signature(for:))
        world.record = record
        XCTAssertFalse(decision().isGranted)
        record.lease = try SeatWire.lease(payload, signer: leaseKey.signature(for:))
        world.record = record
        XCTAssertTrue(decision().isGranted, "the same payload under the seat domain and key")
    }

    func testWindingTheClockBackDoesNotStretchALease() async {
        await service().checkIn(enrolment, force: true)
        world.now = t0.addingTimeInterval(10 * 86_400)
        await service().checkIn(enrolment)   // records the high-water mark
        world.now = t0.addingTimeInterval(-5 * 86_400)
        XCTAssertFalse(decision().isGranted)
    }

    func testAnExpiredSeatCheckedLicenceReadsAsExpiredNotAsASeat() throws {
        let expiry = t0.addingTimeInterval(86_400)
        world.code = try code(expires: expiry)
        world.now = t0.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(decision().denial, .expired(expiry))
    }

    // MARK: - Renewal

    func testRenewalExtendsNotAfter() async {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await advance(days: 2)
        await seats.checkIn(enrolment)
        let lease = world.record?.lease.flatMap { DeviceSeatLease.open($0, keys: leaseKeys) }
        XCTAssertEqual(lease?.notAfter, t0.addingTimeInterval(32 * 86_400))
        let received = await server.received
        XCTAssertEqual(received.map(\.0), [.claim, .renew])
    }

    func testALiveLeaseIsRenewedAtMostOnceADay() async {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await advance(days: 0.5)
        await seats.checkIn(enrolment)
        let received = await server.received
        XCTAssertEqual(received.count, 1)
    }

    func testARefusalNeverTakesAwayALiveLease() async {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await server.free()
        await server.occupy(2)
        await advance(days: 2)
        await seats.checkIn(enrolment)
        XCTAssertTrue(decision().isGranted, "freed, and no room to claim again: the lease it holds still runs")
        XCTAssertEqual(world.record?.refusal, .full)
        let received = await server.received
        XCTAssertEqual(received.map(\.0), [.claim, .renew, .claim])
        await advance(days: 43)
        guard case .seatUnavailable(let hold)? = decision().denial else { return XCTFail("expected a seat hold") }
        XCTAssertEqual(hold.kind, .full(seats: 2))
    }

    /// The paid full-term code arrives in the profile, replacing the code the lease names.
    private func replaceCode(noting seats: DeviceSeatService?) async throws {
        let old = try XCTUnwrap(world.code)
        seats?.noteLicenceReplaced(previousCode: old, enrolment: enrolment)
        world.code = try code(expires: t0.addingTimeInterval(400 * 86_400))
        await server.set(licence: SeatLicence(licenseIDHash: SeatWire.licenseIDHash(code: world.code!), seats: 2,
                                              seatCheck: true, expires: t0.addingTimeInterval(400 * 86_400)))
    }

    // Review follow-up 2026-11-10: a renewal or a seat increase must not lock the phone until its
    // next check-in. The lease for the replaced code stays honoured until a new lease replaces it.
    func testANewLicenceCodeIsRenewedOntoTheSameSeat() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        try await replaceCode(noting: seats)
        XCTAssertTrue(decision().isGranted, "the lease for the replaced code still runs")
        XCTAssertNotNil(world.record?.previousLicenseIDHash)
        await advance(days: 0.01)
        await seats.checkIn(enrolment)   // not yet a day, but the lease is for the old code: retried
        XCTAssertTrue(decision().isGranted)
        let lease = world.record?.lease.flatMap { DeviceSeatLease.open($0, keys: leaseKeys) }
        XCTAssertEqual(lease?.licenseIDHash, SeatWire.licenseIDHash(code: world.code!), "renewed onto the new code")
        XCTAssertNil(world.record?.previousLicenseIDHash, "the bridge ends with the new lease")
        let held = await server.seats.filter { $0.freedAt == nil }.count
        XCTAssertEqual(held, 1, "renewed onto the seat it had, not a second one")
    }

    func testACodeReplacedOutsideARenewalOfThisEnrolmentStillWaitsForACheckIn() async throws {
        await service().checkIn(enrolment, force: true)
        try await replaceCode(noting: nil)
        XCTAssertFalse(decision().isGranted, "only the profile's own renewal bridges the old lease")
    }

    func testACodeReplacedWhileTheSeatServiceIsDownRunsToTheLeasesOwnEnd() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        try await replaceCode(noting: seats)
        await server.set(reachable: false)
        await advance(days: 10)
        await seats.checkIn(enrolment, force: true)
        XCTAssertTrue(decision().isGranted, "no answer, and the old code's lease still runs")
        world.now = t0.addingTimeInterval(44 * 86_400 - 60)
        XCTAssertTrue(decision().isGranted, "to the end of its own grace")
        world.now = t0.addingTimeInterval(44 * 86_400)
        guard case .seatUnavailable(let hold)? = decision().denial else { return XCTFail("expected a seat hold") }
        XCTAssertEqual(hold.kind, .checkIn, "and not a second longer: nothing was extended")
    }

    func testTheBridgeIsNeverNotedForAnUnrelatedCodeOrAnotherEnrolment() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        // An unrelated code named as the one replaced: the lease does not name it, nothing is noted.
        seats.noteLicenceReplaced(previousCode: try code(seats: 9), enrolment: enrolment)
        XCTAssertNil(world.record?.previousLicenseIDHash)
        // Another enrolment's renewal: not this record.
        seats.noteLicenceReplaced(previousCode: try XCTUnwrap(world.code),
                                  enrolment: DeviceSeatEnrolment(profileId: enrolment.profileId, enrolmentId: "e5f6a7b8"))
        XCTAssertNil(world.record?.previousLicenseIDHash)
        try await replaceCode(noting: nil)
        XCTAssertFalse(decision().isGranted, "a lease for an unrelated code is refused")
    }

    func testTheBridgeStillNeedsThisEnrolmentAndThisPhonesKey() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        try await replaceCode(noting: seats)
        world.enrolmentId = enrolment.enrolmentId
        XCTAssertTrue(decision().isGranted)
        world.enrolmentId = "e5f6a7b8"
        XCTAssertFalse(decision().isGranted, "a lease for another enrolment is refused")
        world.enrolmentId = enrolment.enrolmentId
        keys.remove()
        _ = try keys.create()
        XCTAssertFalse(decision().isGranted, "and one naming another phone's key")
    }

    func testARecordWrittenBeforeTheBridgeStillReads() throws {
        let json = #"{"enrolmentId":"a1b2c3d4","profileId":"p-fixture","lease":"x.y","clockHighWater":"2027-01-15T08:00:00Z"}"#
        let record = try LicenseService.decoder.decode(DeviceSeatRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.enrolmentId, "a1b2c3d4")
        XCTAssertNil(record.previousLicenseIDHash)
    }

    func testTheGateChecksTheEnrolmentInForceNotTheRecordAgainstItself() async {
        await service().checkIn(enrolment, force: true)
        world.enrolmentId = enrolment.enrolmentId
        XCTAssertTrue(decision().isGranted)
        world.enrolmentId = "e5f6a7b8"
        XCTAssertFalse(decision().isGranted, "the phone re-enrolled; the lease is for the enrolment it left")
        world.enrolmentId = nil
        XCTAssertTrue(decision().isGranted, "no enrolment record readable: the seat record's own, as before")
    }

    // MARK: - The clock mark (review follow-up 2026-11-10)

    func testAnOlderLeaseReplayedWithTheClockWoundBackNeverLowersTheMark() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await advance(days: 10)
        await seats.checkIn(enrolment)   // renewed: the stored lease was issued at t0 + 10 days
        let mark = try XCTUnwrap(world.record?.clockHighWater)
        XCTAssertEqual(mark, t0.addingTimeInterval(10 * 86_400))
        // An answer from day one, replayed, with the phone's clock wound back to fit inside it.
        let old = SeatLeasePayload(deviceKeyHash: try XCTUnwrap(keys.currentKeyHash()), enrolmentId: enrolment.enrolmentId,
                                   issued: t0.addingTimeInterval(86_400), licenseIDHash: SeatWire.licenseIDHash(code: world.code!),
                                   notAfter: t0.addingTimeInterval(31 * 86_400))
        let replayed = try await server.signedLease(old)
        await server.set(replayOnce: DeviceSeatLease.Reply(lease: replayed, refusal: nil, seats: nil))
        world.now = t0.addingTimeInterval(2 * 86_400)
        await seats.checkIn(enrolment, force: true)
        XCTAssertEqual(world.record?.clockHighWater, mark, "a lease no newer than the stored one keeps the mark")
        XCTAssertFalse(decision().isGranted, "the wound-back clock is still caught")
        // The replay was not stored, so a second one — newer than the first, older than the lease
        // held — cannot walk the mark down a step at a time.
        let held = try XCTUnwrap(world.record?.lease)
        let later = SeatLeasePayload(deviceKeyHash: try XCTUnwrap(keys.currentKeyHash()), enrolmentId: enrolment.enrolmentId,
                                     issued: t0.addingTimeInterval(5 * 86_400), licenseIDHash: SeatWire.licenseIDHash(code: world.code!),
                                     notAfter: t0.addingTimeInterval(35 * 86_400))
        await server.set(replayOnce: DeviceSeatLease.Reply(lease: try await server.signedLease(later), refusal: nil, seats: nil))
        world.now = t0.addingTimeInterval(6 * 86_400)
        await seats.checkIn(enrolment, force: true)
        XCTAssertEqual(world.record?.lease, held, "an older lease never replaces the one held")
        XCTAssertEqual(world.record?.clockHighWater, mark)
        XCTAssertFalse(decision().isGranted)
    }

    func testANewerLeaseCorrectsAMarkAClockSetAheadRaised() async {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await advance(days: 2)
        world.now = t0.addingTimeInterval(12 * 86_400)   // the phone's clock jumps ten days ahead
        await seats.checkIn(enrolment, force: true)       // renewed at the service's own time
        XCTAssertEqual(world.record?.clockHighWater, t0.addingTimeInterval(2 * 86_400))
        world.now = t0.addingTimeInterval(2 * 86_400 + 3_600)   // corrected
        XCTAssertTrue(decision().isGranted)
    }

    // MARK: - A release while a renewal is out (review follow-up 2026-11-10)

    func testAFreedRenewalDoesNotReclaimAfterTheReleaseThatHappenedWhileItWasOut() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await advance(days: 2)
        await server.free()   // the administrator freed it: the renewal will be told .freed
        await server.set(whileOut: { await MainActor.run { _ = seats.release() } })
        await seats.checkIn(enrolment)
        for _ in 0..<20 { await Task.yield() }
        let claims = await server.received.filter { $0.0 == .claim }.count
        XCTAssertEqual(claims, 1, "the phone let the seat go; no claim undoes that")
        XCTAssertNil(world.record)
    }

    // MARK: - Release

    func testRemovalSendsAReleaseAndForgetsTheKey() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        let task = try XCTUnwrap(seats.release())
        await task.value
        XCTAssertNil(world.record)
        XCTAssertNil(try keys.existing())
        let received = await server.received
        XCTAssertEqual(received.last?.0, .release)
        let freed = await server.seats.first?.freedAt
        XCTAssertNotNil(freed)
    }

    // MARK: - Races and failures (review findings)

    func testAReleaseWhileACheckInIsOutIsNotUndoneByItsAnswer() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        await advance(days: 2)
        await server.set(whileOut: { await MainActor.run { _ = seats.release() } })
        await seats.checkIn(enrolment)
        XCTAssertNil(world.record, "the renewal's answer arrived after the release, and is dropped")
        XCTAssertNil(try keys.existing())
    }

    func testAForcedClaimAskedForWhileOneIsOutStillRuns() async throws {
        let seats = service()
        let other = DeviceSeatEnrolment(profileId: enrolment.profileId, enrolmentId: "e5f6a7b8")
        await server.set(whileOut: { await seats.checkIn(other, force: true) })
        await seats.checkIn(enrolment, force: true)
        let claims = await server.received.filter { $0.0 == .claim }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0.1) as? [String: Any])?["enrolmentId"] as? String
        }
        XCTAssertEqual(claims, ["a1b2c3d4", "e5f6a7b8"], "the second, asked for mid-flight, ran after the first")
        XCTAssertEqual(world.record?.enrolmentId, "e5f6a7b8")
    }

    func testAnUnreadableKeychainNeverReplacesTheSeatKey() async throws {
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        let original = try XCTUnwrap(keys.currentKeyHash())
        keys.unreadable = true
        await advance(days: 2)
        await seats.checkIn(enrolment, force: true)
        keys.unreadable = false
        XCTAssertEqual(keys.created, 1)
        XCTAssertEqual(keys.currentKeyHash(), original)
        let received = await server.received
        XCTAssertEqual(received.count, 1, "nothing is sent without the key")
    }

    func testAPhoneWhoseClockRanAheadRecoversOnItsNextLease() async {
        let seats = service()
        world.now = t0.addingTimeInterval(10 * 86_400)   // the phone's clock, ten days ahead of the service's
        await seats.checkIn(enrolment, force: true)
        world.now = t0.addingTimeInterval(3_600)         // corrected
        XCTAssertTrue(decision().isGranted, "the lease the service signed at its own time is the high-water mark")
    }

    func testAMoveWaitsForItsReleaseBeforeClaimingOnAFullLicence() async throws {
        await server.set(licence: SeatLicence(licenseIDHash: SeatWire.licenseIDHash(code: world.code!), seats: 1,
                                              seatCheck: true, expires: t0.addingTimeInterval(365 * 86_400)))
        let seats = service()
        await seats.checkIn(enrolment, force: true)
        seats.release()
        await seats.checkIn(DeviceSeatEnrolment(profileId: enrolment.profileId, enrolmentId: "e5f6a7b8"), force: true)
        XCTAssertTrue(decision().isGranted, "the release reached the service first, so the one seat was free")
    }

    // MARK: - Contract with the licence core

    func testTheAppsLeaseReaderAndRequestBytesMatchTheCore() throws {
        XCTAssertEqual(DeviceSeatLease.leaseDomain, SeatWire.leaseDomain)
        XCTAssertEqual(DeviceSeatLease.requestDomain, SeatWire.requestDomain)
        XCTAssertEqual(DeviceSeatLease.graceDays, SeatWire.graceDays)
        XCTAssertEqual(DeviceSeatLease.noncePath, SeatWire.noncePath)
        for action in DeviceSeatLease.Action.allCases {
            XCTAssertEqual(action.path, SeatWire.Action(rawValue: action.rawValue)?.path)
            XCTAssertEqual(DeviceSeatLease.signedBytes(action: action, nonce: "n", request: Data("{}".utf8)),
                           SeatWire.signedBytes(action: SeatWire.Action(rawValue: action.rawValue)!, nonce: "n", request: Data("{}".utf8)))
        }
        let app = DeviceSeatLease.ClaimRequest(build: "660", devicePublicKey: "k", enrolmentId: "e", profileId: "p")
        let core = SeatClaimRequest(build: "660", devicePublicKey: "k", enrolmentId: "e", profileId: "p")
        XCTAssertEqual(try DeviceSeatLease.encode(app), try SeatWire.encoder().encode(core))
        let key = Curve25519.Signing.PrivateKey()
        let payload = SeatLeasePayload(deviceKeyHash: "d", enrolmentId: "e", issued: t0, licenseIDHash: "l", notAfter: t0)
        let lease = try SeatWire.lease(payload, signer: key.signature(for:))
        let opened = try XCTUnwrap(DeviceSeatLease.open(lease, keys: [key.publicKey.rawRepresentation.base64EncodedString()]))
        XCTAssertEqual(opened.notAfter, payload.notAfter)
        XCTAssertEqual(opened.deviceKeyHash, payload.deviceKeyHash)
        XCTAssertEqual(DeviceSeatLease.deviceKeyHash(publicKeyX963: Data([1, 2, 3])), SeatWire.deviceKeyHash(publicKeyX963: Data([1, 2, 3])))
        XCTAssertEqual(LiveFieldAssistEntitlementProvider.licenseIDHash(for: "abc"), SeatWire.licenseIDHash(code: "abc"))
        for refusal in ["full", "freed", "licenceLapsed", "notSeatChecked", "unknownProfile", "badNonce", "badRequest"] {
            XCTAssertNotNil(DeviceSeatLease.Refusal(rawValue: refusal))
            XCTAssertNotNil(SeatRefusalCode(rawValue: refusal))
        }
    }

    func testTheProductionLeaseKeyIsAValidKeyAndNotTheLicenceOrProfileKey() throws {
        for key in DeviceSeatLease.productionPublicKeys {
            XCTAssertNotNil(try? Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(Data(base64Encoded: key))))
            XCTAssertNotEqual(key, LicenseService.productionPublicKeyBase64)
            XCTAssertFalse(ProfileVerification.productionKeys.values.contains(key))
        }
    }

    func testTheSeatServiceIsTheOriginOfTheSignedProfileAddress() {
        XCTAssertEqual(DeviceSeatLease.seatOrigin(profileAddress: "https://licence.example.test/p/p-1")?.absoluteString,
                       "https://licence.example.test")
        XCTAssertNil(DeviceSeatLease.seatOrigin(profileAddress: "http://licence.example.test/p/p-1"))
        XCTAssertNil(DeviceSeatLease.seatOrigin(profileAddress: "https://user:pw@licence.example.test/p"))
        XCTAssertNil(DeviceSeatLease.seatOrigin(profileAddress: "https://licence.example.test:8443/p"))
        XCTAssertNil(DeviceSeatLease.seatOrigin(profileAddress: nil))
    }

    // MARK: - Treated exactly like a lapse

    func testAHeldLicenceLocksFieldAssistAndTeamFeaturesWithTheSeatMessage() {
        guard case .seatUnavailable(let hold)? = decision().denial else { return XCTFail("expected a seat hold") }
        let check = FieldAssistCapabilityCheck.resolve(.ownVaults, capabilities: [], decision: decision())
        XCTAssertEqual(CustomVaultGateState.resolve(check), .seatUnavailable(hold))
        XCTAssertEqual(CustomVaultGateState.resolve(check).explanation, hold.message)
    }

    func testTheNetworkRouteDisclosesOnlyADeviceIdentifier() {
        XCTAssertEqual(NetworkRoute.licenceSeatLease.dataClasses, [.deviceIdentifier])
        XCTAssertEqual(NetworkRoute.licenceSeatLease.owningTypes, ["DeviceSeatHTTPClient"])
        XCTAssertTrue(NetworkRouteRegistry.requiredPrivacyManifestTypes.contains("NSPrivacyCollectedDataTypeDeviceID"))
    }
}

/// Plan JS P2 — enrolment claims, removal releases, through `OrgProfileManager`'s seams.
@MainActor
final class OrgProfileSeatSeamTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var stored: OrgEnrolmentRecord?
    private var licence: String?
    private var events: [String] = []
    private var licenceEvents: [String] = []
    private var fetched: Data?

    private func manager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        seams.verificationKeys = ["k": publicKey]
        seams.licenceKey = publicKey
        let fixed = now
        seams.now = { fixed }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        seams.readSetting = { _ in nil }
        seams.writeSetting = { _, _ in }
        seams.activateLicence = { [unowned self] in self.licenceEvents.append("activate"); self.licence = $0 }
        seams.fetch = { [unowned self] _ in
            guard let data = self.fetched else { throw URLError(.notConnectedToInternet) }
            return data
        }
        seams.noteLicenceReplaced = { [unowned self] previous, enrolment in
            self.licenceEvents.append("replaced \(previous == self.licence) \(enrolment.enrolmentId)")
        }
        seams.storedLicenceCode = { [unowned self] in self.licence }
        seams.clearLicence = { [unowned self] in self.events.append("clearLicence"); self.licence = nil }
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.newEnrolmentId = { "enrol123" }
        seams.withholdLicence = { _ in }
        seams.seatCheckIn = { [unowned self] enrolment, force in
            self.events.append("checkIn \(enrolment.profileId) \(enrolment.enrolmentId) \(force)")
        }
        seams.releaseSeat = { [unowned self] in self.events.append("release") }
        return OrgProfileManager(seams: seams)
    }

    func testEnrolmentClaimsAtOnceAndRemovalReleasesBeforeTheLicenceIsCleared() async throws {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "Fixture Ltd", issued: now,
                                                    expires: now.addingTimeInterval(365 * 86_400), seats: 2,
                                                    profile: "https://licence.example.test/p/fixture", seatCheck: true)
        let code = try LicenseService.makeCode(payload: payload, privateKeyBase64: key.rawRepresentation.base64EncodedString())
        let profile = ConfigProfile(keyId: "k", profileId: "fixture", organizationName: "Fixture Ltd",
                                    issued: now, leaseDays: 60, licenceCode: code, settings: [:])
        let document = try ProfileVerification.makeDocument(profile, privateKeyBase64: key.rawRepresentation.base64EncodedString())
        let manager = manager()
        let review = try manager.review(document: document, source: .link).get()
        try manager.apply(review).get()
        for _ in 0..<20 where events.isEmpty { await Task.yield() }
        XCTAssertEqual(events, ["checkIn fixture enrol123 true"])
        try manager.remove().get()
        XCTAssertEqual(events.suffix(2), ["release", "clearLicence"])
    }

    private func seatCheckedCode(days: Double) throws -> String {
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "Fixture Ltd", issued: now,
                                                    expires: now.addingTimeInterval(days * 86_400), seats: 2,
                                                    profile: "https://licence.example.test/p/fixture", seatCheck: true)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: key.rawRepresentation.base64EncodedString())
    }

    private func document(code: String) throws -> String {
        let profile = ConfigProfile(keyId: "k", profileId: "fixture", organizationName: "Fixture Ltd",
                                    issued: now, leaseDays: 60, licenceCode: code, settings: [:])
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: key.rawRepresentation.base64EncodedString())
    }

    // Review follow-up 2026-11-10: the seat check learns which code the lease was for before the
    // renewal replaces it, so the phone is not locked until its next check-in.
    func testARenewalThatReplacesTheCodeTellsTheSeatCheckFirst() async throws {
        let manager = manager()
        let review = try manager.review(document: try document(code: try seatCheckedCode(days: 30)), source: .link,
                                        sourceURL: URL(string: "https://licence.example.test/p/fixture")).get()
        try manager.apply(review).get()
        licenceEvents = []
        fetched = Data(try document(code: try seatCheckedCode(days: 400)).utf8)
        await manager.renewIfDue(force: true)
        XCTAssertEqual(licenceEvents, ["replaced true enrol123", "activate"])

        licenceEvents = []
        await manager.renewIfDue(force: true)   // the same code again: nothing replaced
        XCTAssertEqual(licenceEvents, [])
    }
}

private extension Data {
    var sha256Hex: String { DeviceSeatLease.deviceKeyHash(publicKeyX963: self) }
}
