import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import LicenceIssuance

/// Plan JS P2 — the seat contract and the rule that counts seats. Ephemeral keys only.
final class SeatTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let leaseKey = Curve25519.Signing.PrivateKey()
    let phone = P256.Signing.PrivateKey()

    func licence(seats: Int = 2, seatCheck: Bool = true, expires: Date? = nil) -> SeatLicence {
        SeatLicence(licenseIDHash: "0123456789abcdef", seats: seats, seatCheck: seatCheck, expires: expires)
    }

    func claim(_ key: P256.Signing.PrivateKey, enrolment: String = "a1b2c3d4", profile: String = "p-1") -> (SeatClaimRequest, String) {
        let raw = key.publicKey.x963Representation
        return (SeatClaimRequest(build: "660", devicePublicKey: raw.base64EncodedString(), enrolmentId: enrolment, profileId: profile),
                SeatWire.deviceKeyHash(publicKeyX963: raw))
    }

    func grant(_ outcome: SeatPolicy.Outcome, file: StaticString = #filePath, line: UInt = #line) -> (SeatRecord, SeatLeasePayload)? {
        guard case .grant(let seat, let lease) = outcome else { XCTFail("expected a grant, got \(outcome)", file: file, line: line); return nil }
        return (seat, lease)
    }

    // MARK: Wire

    func testALeaseVerifiesOnlyUnderItsOwnDomainAndKey() throws {
        let payload = SeatLeasePayload(deviceKeyHash: "d", enrolmentId: "e", issued: t0, licenseIDHash: "l", notAfter: t0 + 86_400)
        let lease = try SeatWire.lease(payload, signer: leaseKey.signature(for:))
        XCTAssertEqual(try SeatWire.openLease(lease, publicKeys: [leaseKey.publicKey]), payload)
        XCTAssertThrowsError(try SeatWire.openLease(lease, publicKeys: [Curve25519.Signing.PrivateKey().publicKey]))
        // The same payload signed as a licence code (no domain) or a profile is not a lease.
        let undomained = try IssuanceWire.sign(SeatWire.encoder().encode(payload), signer: leaseKey.signature(for:))
        XCTAssertThrowsError(try SeatWire.openLease(undomained, publicKeys: [leaseKey.publicKey]))
        let asProfile = try IssuanceWire.profile(payload, signer: leaseKey.signature(for:))
        XCTAssertThrowsError(try SeatWire.openLease(asProfile, publicKeys: [leaseKey.publicKey]))
    }

    func testTheLeaseCarriesExactlyItsFiveFields() throws {
        let payload = SeatLeasePayload(deviceKeyHash: "d", enrolmentId: "e", issued: t0, licenseIDHash: "l", notAfter: t0)
        let object = try JSONSerialization.jsonObject(with: SeatWire.encoder().encode(payload)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys ?? [:].keys), ["deviceKeyHash", "enrolmentId", "issued", "licenseIDHash", "notAfter"])
    }

    func testTheClaimCarriesExactlyTheFourDisclosedFields() throws {
        let (request, _) = claim(phone)
        let object = try JSONSerialization.jsonObject(with: SeatWire.encoder().encode(request)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys ?? [:].keys), ["profileId", "enrolmentId", "devicePublicKey", "build"])
    }

    func testAnEnvelopeOpensOnlyForItsActionNonceAndKey() throws {
        let (request, _) = claim(phone)
        let body = try SeatWire.encoder().encode(request)
        let signature = try phone.signature(for: SeatWire.signedBytes(action: .claim, nonce: "n-1", request: body))
        let envelope = SeatEnvelope(nonce: "n-1", request: body.base64EncodedString(), signature: signature.derRepresentation.base64EncodedString())
        let raw = phone.publicKey.x963Representation
        XCTAssertEqual(try SeatWire.openEnvelope(envelope, action: .claim, publicKeyX963: raw), body)
        XCTAssertThrowsError(try SeatWire.openEnvelope(envelope, action: .release, publicKeyX963: raw), "a claim is not a release")
        let otherNonce = SeatEnvelope(nonce: "n-2", request: envelope.request, signature: envelope.signature)
        XCTAssertThrowsError(try SeatWire.openEnvelope(otherNonce, action: .claim, publicKeyX963: raw))
        XCTAssertThrowsError(try SeatWire.openEnvelope(envelope, action: .claim,
                                                       publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertEqual(try SeatWire.devicePublicKey(of: request), raw)
    }

    func testTheLicenceHashMatchesTheAppsEntitlementHash() {
        // `LiveFieldAssistEntitlementProvider.licenseIDHash`: first 16 hex of SHA-256 of the trimmed code.
        let code = "eyJhIjoxfQ==.c2ln"
        XCTAssertEqual(SeatWire.licenseIDHash(code: code), String(IssuanceWire.digest(Data(code.utf8)).prefix(16)))
        XCTAssertEqual(SeatWire.licenseIDHash(code: " \(code)\n"), SeatWire.licenseIDHash(code: code))
    }

    // MARK: Counting

    func testSeatsAreGrantedUntilFullThenRefusedWithTheCount() {
        var seats: [SeatRecord] = []
        for _ in 0..<2 {
            let (request, hash) = claim(P256.Signing.PrivateKey())
            guard let (seat, lease) = grant(SeatPolicy.claim(request, deviceKeyHash: hash, licence: licence(), seats: seats, now: t0)) else { return }
            XCTAssertEqual(lease.notAfter, t0 + 30 * 86_400)
            XCTAssertEqual(lease.licenseIDHash, "0123456789abcdef")
            seats.append(seat)
        }
        let (third, hash) = claim(P256.Signing.PrivateKey())
        XCTAssertEqual(SeatPolicy.claim(third, deviceKeyHash: hash, licence: licence(), seats: seats, now: t0), .refuse(.full, seats: 2))
    }

    func testTheSamePhoneClaimingAgainKeepsItsSeat() {
        let (request, hash) = claim(phone)
        guard let (seat, _) = grant(SeatPolicy.claim(request, deviceKeyHash: hash, licence: licence(seats: 1), seats: [], now: t0)),
              let (again, lease) = grant(SeatPolicy.claim(request, deviceKeyHash: hash, licence: licence(seats: 1), seats: [seat], now: t0 + 86_400))
        else { return }
        XCTAssertEqual(again.claimedAt, t0)
        XCTAssertEqual(lease.notAfter, t0 + 86_400 + 30 * 86_400)
    }

    func testAFreedSeatOrOneThatLapsedUnheardMakesRoom() {
        let (first, firstHash) = claim(P256.Signing.PrivateKey())
        guard var (seat, _) = grant(SeatPolicy.claim(first, deviceKeyHash: firstHash, licence: licence(seats: 1), seats: [], now: t0)) else { return }
        let (second, secondHash) = claim(phone)
        XCTAssertEqual(SeatPolicy.claim(second, deviceKeyHash: secondHash, licence: licence(seats: 1), seats: [seat], now: t0),
                       .refuse(.full, seats: 1))
        // Past notAfter but inside the grace, the first phone may still be working: still held.
        let inGrace = t0 + (30 + 13) * 86_400
        XCTAssertTrue(SeatPolicy.isHeld(seat, now: inGrace))
        XCTAssertNotNil(grant(SeatPolicy.claim(second, deviceKeyHash: secondHash, licence: licence(seats: 1), seats: [seat],
                                               now: t0 + (30 + 14) * 86_400)), "lease plus grace over: the seat is free")
        seat.freedAt = t0 + 60
        XCTAssertNotNil(grant(SeatPolicy.claim(second, deviceKeyHash: secondHash, licence: licence(seats: 1), seats: [seat], now: t0 + 120)))
    }

    func testRenewalExtendsAndAFreedSeatIsRefused() {
        let (request, hash) = claim(phone)
        guard var (seat, lease) = grant(SeatPolicy.claim(request, deviceKeyHash: hash, licence: licence(), seats: [], now: t0)) else { return }
        guard let (_, renewed) = grant(SeatPolicy.renew(lease, build: "661", profileId: "p-1", licence: licence(), seats: [seat], now: t0 + 86_400))
        else { return }
        XCTAssertGreaterThan(renewed.notAfter, lease.notAfter)
        seat.freedAt = t0 + 3_600
        XCTAssertEqual(SeatPolicy.renew(lease, build: "661", profileId: "p-1", licence: licence(), seats: [seat], now: t0 + 7_200), .refuse(.freed))
        lease = renewed
        XCTAssertEqual(SeatPolicy.renew(lease, build: "661", profileId: "p-2", licence: licence(), seats: [seat], now: t0), .refuse(.freed),
                       "a lease for another profile names no seat there")
    }

    func testALapsedOrUncountedLicenceGetsNoLease() {
        let (request, hash) = claim(phone)
        XCTAssertEqual(SeatPolicy.claim(request, deviceKeyHash: hash, licence: licence(expires: t0), seats: [], now: t0), .refuse(.licenceLapsed))
        XCTAssertEqual(SeatPolicy.claim(request, deviceKeyHash: hash, licence: licence(seatCheck: false), seats: [], now: t0), .refuse(.notSeatChecked))
        XCTAssertEqual(SeatPolicy.claim(request, deviceKeyHash: hash, licence: nil, seats: [], now: t0), .refuse(.unknownProfile))
    }

    func testALeaseIsLiveUntilNotAfterPlusFourteenDays() {
        let lease = SeatLeasePayload(deviceKeyHash: "d", enrolmentId: "e", issued: t0, licenseIDHash: "l", notAfter: t0 + 30 * 86_400)
        XCTAssertTrue(SeatPolicy.leaseIsLive(lease, now: t0 + 44 * 86_400 - 1))
        XCTAssertFalse(SeatPolicy.leaseIsLive(lease, now: t0 + 44 * 86_400))
    }

    // MARK: Issuance

    func testTheSeatCheckClaimIsSignedOnlyWhenAsked() throws {
        let payload = IssuedLicensePayload(licensee: "Example Co", issued: t0, expires: nil, seats: 3,
                                           profile: "https://licence.example.test/p/p-1", seatCheck: true)
        XCTAssertTrue(String(decoding: try IssuanceWire.encoder().encode(payload), as: UTF8.self).contains("\"seatCheck\":true"))
        // A code without the claim encodes exactly as before P2.
        let plain = try IssuanceWire.encoder().encode(IssuedLicensePayload(licensee: "x", issued: t0, expires: nil))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("seatCheck"))
    }
}
