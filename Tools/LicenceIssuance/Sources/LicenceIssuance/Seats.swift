import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif

// Plan JS P2 — device seats. The wire contract between a phone and the seat service, and the one
// rule that counts seats. The phone app verifies leases with its own copy of the format
// (`SeatLease` in the app), held to these bytes by `SeatLeaseContractTests`; the service builds
// against this file at the commit in its `core.lock`.
//
// A seat-checked licence (`seatCheck: true`, signed) is live on a phone only while the phone holds
// a seat lease that verifies, names that phone's Secure Enclave key and the licence in force, and
// has not passed `notAfter` plus the grace. The phone claims a seat on enrolment and renews it on
// the daily profile fetch; the service counts the seats a licence's phones hold against its
// signed `seats`.

/// What the phone and the service exchange. Every request is a `SeatEnvelope`: the request's JSON,
/// a single-use nonce the service issued, and the phone's ECDSA P-256 signature over both.
public enum SeatWire {
    /// Domain prefix of a seat lease's Ed25519 signature: a third vendor key, never the licence or
    /// profile key, and a prefix no other signed document uses.
    public static let leaseDomain = "openglasses.seat-lease.v1\n"
    /// Domain prefix of a phone's request signature.
    public static let requestDomain = "openglasses.seat-request.v1\n"

    /// A lease runs this long from the moment the service signs it (owner decision 2026-11-09).
    public static let leaseDays = 30
    /// …and is still honoured this long past `notAfter`, so a phone out of signal for a holiday and
    /// a fortnight in a plant room keeps working. A freed or lost phone stops within the two.
    public static let graceDays = 14
    public static let day: TimeInterval = 86_400
    public static var leaseLength: TimeInterval { TimeInterval(leaseDays) * day }
    public static var grace: TimeInterval { TimeInterval(graceDays) * day }

    /// How long a nonce may be used for, and the most a request's JSON may weigh.
    public static let nonceLifetime: TimeInterval = 300
    public static let maximumRequestBytes = 4_096

    /// The endpoints, under the origin of the licence's signed `profile` address.
    public enum Action: String, Codable, CaseIterable, Sendable {
        case claim, renew, release
        public var path: String { "/seats/" + rawValue }
    }
    public static let noncePath = "/seats/nonce"

    /// The identifier a lease names a licence by: the first 16 hex characters of the SHA-256 of the
    /// code as the phone stores it (trimmed). The same value the app's entitlement decision and the
    /// portal's code view show, so no lease or log line ever carries a redistributable code.
    public static func licenseIDHash(code: String) -> String {
        String(IssuanceWire.digest(Data(code.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).prefix(16))
    }

    /// The identifier a lease names a phone by: the SHA-256 (hex) of its P-256 public key in X9.63
    /// form. The key itself is sent only in a claim.
    public static func deviceKeyHash(publicKeyX963: Data) -> String {
        IssuanceWire.digest(publicKeyX963)
    }

    /// The bytes the phone signs: domain, action, nonce, then the request's JSON exactly as sent.
    /// The action is inside the signature, so a claim cannot be replayed as a release.
    public static func signedBytes(action: Action, nonce: String, request: Data) -> Data {
        Data((requestDomain + action.rawValue + "\n" + nonce + "\n").utf8) + request
    }

    public static func encoder() -> JSONEncoder { IssuanceWire.encoder() }
    public static func decoder() -> JSONDecoder { IssuanceWire.decoder() }

    // MARK: Leases

    /// Sign a lease with the seat-lease key. Vendor side only.
    public static func lease(_ payload: SeatLeasePayload, signer: ByteSigner) throws -> String {
        try IssuanceWire.sign(encoder().encode(payload), domain: leaseDomain, signer: signer)
    }

    /// Read a lease the service signed: signature and format only. Whether it is still in force
    /// is `SeatPolicy`'s question, asked with a clock.
    public static func openLease(_ lease: String, publicKeys: [Curve25519.Signing.PublicKey]) throws -> SeatLeasePayload {
        let parts = lease.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard lease.utf8.count <= 2_048, parts.count == 2,
              let payload = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])) else { throw SeatWireError.malformed }
        let signed = Data(leaseDomain.utf8) + payload
        guard publicKeys.contains(where: { $0.isValidSignature(signature, for: signed) }) else {
            throw SeatWireError.badSignature
        }
        guard let decoded = try? decoder().decode(SeatLeasePayload.self, from: payload) else { throw SeatWireError.malformed }
        return decoded
    }

    // MARK: Requests

    /// Open an envelope: the request's JSON, signed by `publicKeyX963` over this action and nonce.
    /// For a claim the key is the one the request carries; for a renewal or release it is the key
    /// on the seat the lease names. The nonce's freshness is the service's to check.
    public static func openEnvelope(_ envelope: SeatEnvelope, action: Action, publicKeyX963: Data) throws -> Data {
        guard let request = Data(base64Encoded: envelope.request), request.count <= maximumRequestBytes,
              let signature = Data(base64Encoded: envelope.signature),
              !envelope.nonce.isEmpty, envelope.nonce.utf8.count <= 128 else { throw SeatWireError.malformed }
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            throw SeatWireError.badSignature
        }
        guard key.isValidSignature(ecdsa, for: signedBytes(action: action, nonce: envelope.nonce, request: request)) else {
            throw SeatWireError.badSignature
        }
        return request
    }

    /// The public key a claim carries, checked to be a P-256 key.
    public static func devicePublicKey(of claim: SeatClaimRequest) throws -> Data {
        guard let raw = Data(base64Encoded: claim.devicePublicKey),
              (try? P256.Signing.PublicKey(x963Representation: raw)) != nil else { throw SeatWireError.malformed }
        return raw
    }
}

public enum SeatWireError: Error, Equatable { case malformed, badSignature }

/// What a lease says. Five fields, no more: no name, no device model, no location.
public struct SeatLeasePayload: Codable, Equatable, Sendable {
    public let deviceKeyHash: String
    public let enrolmentId: String
    public let issued: Date
    public let licenseIDHash: String
    public let notAfter: Date
    public init(deviceKeyHash: String, enrolmentId: String, issued: Date, licenseIDHash: String, notAfter: Date) {
        self.deviceKeyHash = deviceKeyHash; self.enrolmentId = enrolmentId; self.issued = issued
        self.licenseIDHash = licenseIDHash; self.notAfter = notAfter
    }
}

/// The claim: exactly the four fields Plan JS P2 discloses. Adding one is a privacy change — the
/// manifest, the in-app copy and `SeatRequestShapeTests` move with it.
public struct SeatClaimRequest: Codable, Equatable, Sendable {
    /// The app's build number (`CFBundleVersion`), so the vendor can see which builds hold seats.
    public let build: String
    /// The phone's P-256 public key, X9.63, base64.
    public let devicePublicKey: String
    /// The enrolment id the phone made when it joined the organisation (eight hex characters).
    public let enrolmentId: String
    /// The organisation profile the phone is enrolled in.
    public let profileId: String
    public init(build: String, devicePublicKey: String, enrolmentId: String, profileId: String) {
        self.build = build; self.devicePublicKey = devicePublicKey; self.enrolmentId = enrolmentId; self.profileId = profileId
    }
}

/// A renewal presents the lease the phone holds; the service finds the seat by its key hash.
public struct SeatRenewRequest: Codable, Equatable, Sendable {
    public let build: String
    public let lease: String
    public init(build: String, lease: String) { self.build = build; self.lease = lease }
}

/// Giving a seat back: the phone's owner removed the organisation from it.
public struct SeatReleaseRequest: Codable, Equatable, Sendable {
    public let lease: String
    public init(lease: String) { self.lease = lease }
}

public struct SeatEnvelope: Codable, Equatable, Sendable {
    public let nonce: String
    /// The request's JSON, base64, exactly the bytes that were signed.
    public let request: String
    /// ECDSA P-256 over `SeatWire.signedBytes`, DER, base64.
    public let signature: String
    public init(nonce: String, request: String, signature: String) {
        self.nonce = nonce; self.request = request; self.signature = signature
    }
}

public struct SeatNonceReply: Codable, Equatable, Sendable {
    public let nonce: String
    public let expires: Date
    public init(nonce: String, expires: Date) { self.nonce = nonce; self.expires = expires }
}

/// Why the service gave no lease. Unsigned, so a phone only ever *describes* a lock with it: a
/// refusal never takes away a lease the phone already holds.
public enum SeatRefusalCode: String, Codable, Equatable, Sendable {
    /// Every seat the licence bought is held by another phone.
    case full
    /// The seat this lease named was freed, in the portal or by a release.
    case freed
    /// The licence in force for the profile has run out, or the profile has none.
    case licenceLapsed
    /// The profile's licence does not count seats.
    case notSeatChecked
    case unknownProfile
    /// The nonce was unknown, used or stale: ask for another and try again.
    case badNonce
    case badRequest
}

/// Every answer, whatever the HTTP status: a lease, or a refusal and (for `full`) the seat count.
public struct SeatReply: Codable, Equatable, Sendable {
    public let lease: String?
    public let refusal: SeatRefusalCode?
    public let seats: Int?
    public init(lease: String? = nil, refusal: SeatRefusalCode? = nil, seats: Int? = nil) {
        self.lease = lease; self.refusal = refusal; self.seats = seats
    }
}

// MARK: - Counting seats

/// One phone's seat on one profile, as the service's ledger keeps it.
public struct SeatRecord: Codable, Equatable, Sendable {
    public let profileId: String
    public let deviceKeyHash: String
    /// X9.63, base64: what renewals and releases are verified against.
    public let devicePublicKey: String
    public var enrolmentId: String
    public let claimedAt: Date
    public var leaseNotAfter: Date
    public var lastSeenAt: Date
    public var build: String
    /// Set when the seat was freed (portal, console or the phone's release). A freed seat no longer
    /// counts, though the phone keeps working until the lease it holds runs out.
    public var freedAt: Date?
    public var freedBy: String?
    public init(profileId: String, deviceKeyHash: String, devicePublicKey: String, enrolmentId: String,
                claimedAt: Date, leaseNotAfter: Date, lastSeenAt: Date, build: String,
                freedAt: Date? = nil, freedBy: String? = nil) {
        self.profileId = profileId; self.deviceKeyHash = deviceKeyHash; self.devicePublicKey = devicePublicKey
        self.enrolmentId = enrolmentId; self.claimedAt = claimedAt; self.leaseNotAfter = leaseNotAfter
        self.lastSeenAt = lastSeenAt; self.build = build; self.freedAt = freedAt; self.freedBy = freedBy
    }
}

/// The licence a seat is counted against, as the service knows it from its ledger.
public struct SeatLicence: Equatable, Sendable {
    public let licenseIDHash: String
    public let seats: Int
    public let seatCheck: Bool
    public let expires: Date?
    public init(licenseIDHash: String, seats: Int, seatCheck: Bool, expires: Date?) {
        self.licenseIDHash = licenseIDHash; self.seats = seats; self.seatCheck = seatCheck; self.expires = expires
    }
}

public enum SeatPolicy {
    /// A seat counts while it is not freed and the phone could still be working on its lease.
    public static func isHeld(_ seat: SeatRecord, now: Date) -> Bool {
        seat.freedAt == nil && now < seat.leaseNotAfter.addingTimeInterval(SeatWire.grace)
    }

    /// Whether a lease, read and verified, is still honoured at `now`. The phone asks this with its
    /// own clock, never earlier than the latest time it has seen.
    public static func leaseIsLive(_ lease: SeatLeasePayload, now: Date) -> Bool {
        now < lease.notAfter.addingTimeInterval(SeatWire.grace)
    }

    public enum Outcome: Equatable, Sendable {
        /// Sign a lease from these fields and store `seat` (new, or the same seat extended).
        case grant(seat: SeatRecord, lease: SeatLeasePayload)
        case refuse(SeatRefusalCode, seats: Int? = nil)
    }

    /// A claim. The same phone (key) claiming again keeps its seat; a phone whose seat was freed,
    /// or whose lease ran out unheard, claims afresh and needs room like any other.
    public static func claim(_ request: SeatClaimRequest, deviceKeyHash: String, licence: SeatLicence?,
                             seats: [SeatRecord], now: Date) -> Outcome {
        guard let licence else { return .refuse(.unknownProfile) }
        guard licence.seatCheck else { return .refuse(.notSeatChecked) }
        guard licence.expires.map({ now < $0 }) ?? true else { return .refuse(.licenceLapsed) }
        let mine = seats.first { $0.profileId == request.profileId && $0.deviceKeyHash == deviceKeyHash && isHeld($0, now: now) }
        if mine == nil {
            let held = seats.filter { $0.profileId == request.profileId && isHeld($0, now: now) }.count
            guard held < licence.seats else { return .refuse(.full, seats: licence.seats) }
        }
        let notAfter = now.addingTimeInterval(SeatWire.leaseLength)
        var seat = mine ?? SeatRecord(profileId: request.profileId, deviceKeyHash: deviceKeyHash,
                                      devicePublicKey: request.devicePublicKey, enrolmentId: request.enrolmentId,
                                      claimedAt: now, leaseNotAfter: notAfter, lastSeenAt: now, build: request.build)
        seat.enrolmentId = request.enrolmentId
        seat.leaseNotAfter = notAfter
        seat.lastSeenAt = now
        seat.build = request.build
        return .grant(seat: seat, lease: SeatLeasePayload(deviceKeyHash: deviceKeyHash, enrolmentId: seat.enrolmentId,
                                                          issued: now, licenseIDHash: licence.licenseIDHash, notAfter: notAfter))
    }

    /// A renewal of the seat a verified lease names. A freed seat is refused (the phone then
    /// claims, and gets a seat only if there is room); a seat that lapsed unheard is claimed afresh.
    public static func renew(_ lease: SeatLeasePayload, build: String, profileId: String, licence: SeatLicence?,
                             seats: [SeatRecord], now: Date) -> Outcome {
        guard let licence else { return .refuse(.unknownProfile) }
        guard licence.seatCheck else { return .refuse(.notSeatChecked) }
        guard licence.expires.map({ now < $0 }) ?? true else { return .refuse(.licenceLapsed) }
        guard let seat = seats.last(where: { $0.profileId == profileId && $0.deviceKeyHash == lease.deviceKeyHash }) else {
            return .refuse(.freed)
        }
        if seat.freedAt != nil { return .refuse(.freed) }
        return claim(SeatClaimRequest(build: build, devicePublicKey: seat.devicePublicKey, enrolmentId: lease.enrolmentId,
                                      profileId: profileId),
                     deviceKeyHash: lease.deviceKeyHash, licence: licence, seats: seats, now: now)
    }

    /// The seats a portal lists for a profile: held ones first, newest first.
    public static func listed(_ seats: [SeatRecord], profileId: String, now: Date) -> [SeatRecord] {
        seats.filter { $0.profileId == profileId && $0.freedAt == nil }
            .sorted { (isHeld($0, now: now) ? 0 : 1, -$0.lastSeenAt.timeIntervalSince1970)
                    < (isHeld($1, now: now) ? 0 : 1, -$1.lastSeenAt.timeIntervalSince1970) }
    }
}
