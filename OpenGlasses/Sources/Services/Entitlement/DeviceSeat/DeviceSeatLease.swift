import Foundation
import CryptoKit

/// Plan JS P2 — a seat lease, read and judged on the phone.
///
/// A seat-checked licence (`seatCheck: true`, signed) is evidence only while this phone holds a
/// lease that verifies under the embedded seat-lease key, names this phone's Secure Enclave key,
/// this enrolment and the licence code in force, and has not passed `notAfter` plus the grace.
/// Everything here is pure: the lease, the key hash, the code and the clock are values, so the
/// whole rule is testable without a keychain, a server or a device.
///
/// The format is the licence core's (`Tools/LicenceIssuance`, `SeatWire`), restated here because
/// no production verifier depends on that package; `DeviceSeatContractTests` holds the two to the
/// same bytes.
enum DeviceSeatLease {
    /// The seat-lease key (Curve25519, raw, base64): a third vendor key beside the licence and
    /// profile keys, with its own signing domain. The private half is held by the vendor's signer.
    /// A list, so a rotation can ship the next key before the signer moves to it.
    nonisolated static let productionPublicKeys = ["Qsubqt4KFKOfQETCLBZorRlJ7dIj1GzpYpVhal6dJYk="]

    nonisolated static let leaseDomain = "openglasses.seat-lease.v1\n"
    nonisolated static let requestDomain = "openglasses.seat-request.v1\n"

    /// A lease runs 30 days from signing and is honoured for 14 more (owner decision 2026-11-09): a
    /// phone away on holiday, then a fortnight out of signal, keeps working; a freed or lost phone
    /// stops within the two. The phone renews about once a day whenever it can.
    nonisolated static let graceDays = 14
    nonisolated static let grace: TimeInterval = TimeInterval(graceDays) * 86_400
    /// How far the device clock may sit behind the latest time seen before it counts as wound
    /// back — the profile lease's day (`ProfileLease.clockSlack`).
    nonisolated static let clockSlack: TimeInterval = 86_400

    struct Payload: Codable, Equatable, Sendable {
        let deviceKeyHash: String
        let enrolmentId: String
        let issued: Date
        let licenseIDHash: String
        let notAfter: Date

        nonisolated var liveUntil: Date { notAfter.addingTimeInterval(DeviceSeatLease.grace) }
    }

    enum Verdict: Equatable, Sendable {
        /// The lease is in force until `until` (`notAfter` plus the grace).
        case live(until: Date)
        /// No lease stored.
        case missing
        /// A lease is stored but did not verify, or could not be read.
        case invalid
        /// The lease names another phone's key, or this phone has no seat key.
        case otherDevice
        /// The lease is for another enrolment (the phone left and joined again).
        case otherEnrolment
        /// The lease is for another licence code (a renewal or replacement arrived).
        case otherLicence
        /// The lease and its grace ran out at `since`.
        case lapsed(since: Date)
        /// The device clock is behind a time the app has already seen.
        case clockWoundBack

        nonisolated var isLive: Bool { if case .live = self { return true } else { return false } }
    }

    // MARK: - Reading a lease

    /// Signature and format only: a lease the vendor signed, or nil.
    nonisolated static func open(_ lease: String, keys: [String] = productionPublicKeys) -> Payload? {
        let trimmed = lease.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard trimmed.utf8.count <= 2_048, parts.count == 2,
              let payload = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])) else { return nil }
        let signed = Data(leaseDomain.utf8) + payload
        let verified = keys.contains { key in
            guard let raw = Data(base64Encoded: key),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return publicKey.isValidSignature(signature, for: signed)
        }
        guard verified else { return nil }
        return try? LicenseService.decoder.decode(Payload.self, from: payload)
    }

    /// The whole offline check. `now` is the phone's clock; `clockHighWater` the latest time the
    /// seat check has seen, so winding the clock back cannot stretch a lease.
    ///
    /// `previousLicenseIDHash` is the code this enrolment's lease was issued for, when a renewal
    /// of the same profile has since replaced it (`DeviceSeatRecord.previousLicenseIDHash`): a
    /// lease naming it stays in force until its own `liveUntil`, so a seat increase or a renewal
    /// never locks a phone between the new code arriving and its next check-in. Everything else
    /// — the signature, this phone's key, this enrolment, the clock — is checked as for any lease,
    /// and nothing is extended.
    nonisolated static func verdict(lease: String?, keys: [String] = productionPublicKeys,
                                    deviceKeyHash: String?, enrolmentId: String, licenseIDHash: String,
                                    previousLicenseIDHash: String? = nil,
                                    clockHighWater: Date? = nil, now: Date) -> Verdict {
        guard let lease, !lease.isEmpty else { return .missing }
        guard let payload = open(lease, keys: keys) else { return .invalid }
        guard let deviceKeyHash, payload.deviceKeyHash == deviceKeyHash else { return .otherDevice }
        guard payload.enrolmentId == enrolmentId else { return .otherEnrolment }
        let namesACodeInForce = payload.licenseIDHash == licenseIDHash
            || (previousLicenseIDHash.map { payload.licenseIDHash == $0 } ?? false)
        guard namesACodeInForce else { return .otherLicence }
        if let highWater = clockHighWater, now.addingTimeInterval(clockSlack) < highWater { return .clockWoundBack }
        guard now < payload.liveUntil else { return .lapsed(since: payload.liveUntil) }
        return .live(until: payload.liveUntil)
    }

    // MARK: - Identifiers

    /// SHA-256 (hex) of the phone's P-256 public key in X9.63 form: how a lease names a phone.
    nonisolated static func deviceKeyHash(publicKeyX963: Data) -> String {
        SHA256.hash(data: publicKeyX963).map { String(format: "%02x", $0) }.joined()
    }

    /// The seat service is the origin of the licence's signed `profile` address: HTTPS, the
    /// default port, no credentials. Anything else is no seat service at all.
    nonisolated static func seatOrigin(profileAddress: String?) -> URL? {
        guard let profileAddress, var components = URLComponents(string: profileAddress),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.port == nil || components.port == 443
        else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.port = nil
        return components.url
    }

    // MARK: - The wire (Tools/LicenceIssuance `SeatWire`)

    enum Action: String, Sendable, CaseIterable {
        case claim, renew, release
        nonisolated var path: String { "/seats/" + rawValue }
    }
    nonisolated static let noncePath = "/seats/nonce"

    /// The four fields the claim discloses — and no other. The privacy manifest, the in-app copy and
    /// `DeviceSeatServiceTests` name exactly these.
    struct ClaimRequest: Codable, Equatable, Sendable {
        let build: String
        let devicePublicKey: String
        let enrolmentId: String
        let profileId: String
    }

    /// Plan LR P2: a renewal also carries the company's vaults installed on this phone, by id and
    /// version, so the portal can show which phones have the new version. Nil — and so absent
    /// from the bytes — on a phone with none, so such a renewal is exactly what it was. Nothing
    /// else: no manual's name, nothing the technician added.
    struct RenewRequest: Codable, Equatable, Sendable {
        let build: String
        let lease: String
        var vaults: [InstalledVault]? = nil
    }

    /// One company vault as a renewal reports it (`SeatInstalledVault` in the licence core).
    struct InstalledVault: Codable, Equatable, Sendable {
        let vaultId: String
        let version: String
    }

    /// The most a request may weigh (`SeatWire.maximumRequestBytes`), and the most vaults one
    /// renewal names (`SeatInstalledVault.maximumPerRenewal`).
    nonisolated static let maximumRequestBytes = 4_096
    nonisolated static let maximumVaultsPerRenewal = 16

    /// The renewal for `lease`: with the installed vaults when there are any and they fit, and
    /// without them otherwise, so reporting a version can never make a renewal one the service
    /// refuses.
    nonisolated static func renewRequest(build: String, lease: String, vaults: [InstalledVault]) -> RenewRequest {
        let listed = Array(vaults.sorted { $0.vaultId < $1.vaultId }.prefix(maximumVaultsPerRenewal))
        guard !listed.isEmpty else { return RenewRequest(build: build, lease: lease) }
        let request = RenewRequest(build: build, lease: lease, vaults: listed)
        guard let bytes = try? encode(request), bytes.count <= maximumRequestBytes else {
            return RenewRequest(build: build, lease: lease)
        }
        return request
    }

    struct ReleaseRequest: Codable, Equatable, Sendable {
        let lease: String
    }

    struct Envelope: Codable, Equatable, Sendable {
        let nonce: String
        let request: String
        let signature: String
    }

    struct NonceReply: Codable, Equatable, Sendable {
        let nonce: String
        let expires: Date
    }

    enum Refusal: String, Codable, Equatable, Sendable {
        case full, freed, licenceLapsed, notSeatChecked, unknownProfile, badNonce, badRequest
    }

    struct Reply: Codable, Equatable, Sendable {
        let lease: String?
        let refusal: Refusal?
        let seats: Int?
    }

    /// What the phone signs: domain, action, nonce, then the request's JSON exactly as sent.
    nonisolated static func signedBytes(action: Action, nonce: String, request: Data) -> Data {
        Data((requestDomain + action.rawValue + "\n" + nonce + "\n").utf8) + request
    }

    /// Requests are encoded the licence way: sorted keys, ISO-8601 dates.
    nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data { try LicenseService.encoder.encode(value) }
}

/// Why a seat-checked licence is not unlocking Field Assist on this phone. Shown exactly where an
/// expired licence's message is shown, and handled exactly like a lapse: no office or job-system
/// connection, Field Assist locked, nothing on the phone removed.
struct DeviceSeatHold: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The seat service said every seat is held by another phone.
        case full(seats: Int?)
        /// No live lease and no answer saying why: the phone has not checked in (never, or not for
        /// longer than the lease and its grace).
        case checkIn
    }

    let kind: Kind
    let licensee: String
    /// The licence's own signed expiry. A licence that has run out reads as expired, not as a seat.
    let licenceExpires: Date?

    var message: String {
        switch kind {
        case .full(let seats?):
            return "All \(seats) seats for \(licensee) are in use. Ask your administrator to free one."
        case .full(nil):
            return "All the seats for \(licensee) are in use. Ask your administrator to free one."
        case .checkIn:
            return "This phone needs to check its seat on \(licensee)'s licence. Connect to the internet and open the app; nothing on the phone has been removed."
        }
    }
}

/// What is stored about this phone's seat: the lease the service last signed, and what the last
/// attempt was told. No content: ids, a signed lease, dates. Written by `DeviceSeatService`, read by the
/// entitlement gate; registered as `SensitiveStore.licenceSeat`.
struct DeviceSeatRecord: Codable, Equatable, Sendable {
    let enrolmentId: String
    let profileId: String
    /// The seat service the lease came from (the origin of the licence's signed `profile`), kept
    /// so a release reaches it even when a move has already put another licence in place.
    var origin: String?
    var lease: String?
    var lastAttempt: Date?
    /// When the service last answered with a lease.
    var lastRenewed: Date?
    /// The service's last refusal, kept only to word the lock when there is no live lease.
    var refusal: DeviceSeatLease.Refusal?
    var refusedSeats: Int?
    var clockHighWater: Date?
    /// The licence code the stored lease was issued for, once a renewal of the same enrolment's
    /// profile replaced that code (`DeviceSeatService.noteLicenceReplaced`). The gate honours the
    /// lease for it until the lease's own end; the next accepted lease clears it. Optional, so a
    /// record written before it existed reads.
    var previousLicenseIDHash: String?

    init(enrolmentId: String, profileId: String) {
        self.enrolmentId = enrolmentId
        self.profileId = profileId
    }

    nonisolated static let storageKey = "licenceSeat"

    nonisolated static func load(_ defaults: UserDefaults = .standard) -> DeviceSeatRecord? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? LicenseService.decoder.decode(DeviceSeatRecord.self, from: data)
    }

    nonisolated static func save(_ record: DeviceSeatRecord?, _ defaults: UserDefaults = .standard) {
        guard let record, let data = try? LicenseService.encoder.encode(record) else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}

/// The gate the entitlement provider asks on every read of a seat-checked licence.
enum DeviceSeatGate {
    /// Nil when the code may be used as evidence (not seat-checked, or seat-checked with a live
    /// lease); otherwise the hold that explains the lock.
    ///
    /// `enrolmentId` is the organisation enrolment in force on this phone. A lease must name it;
    /// nil (no enrolment record could be read) falls back to the seat record's own.
    nonisolated static func hold(for payload: LicenseService.LicensePayload, code: String,
                                 record: DeviceSeatRecord?, deviceKeyHash: String?,
                                 enrolmentId: String? = nil,
                                 keys: [String] = DeviceSeatLease.productionPublicKeys,
                                 now: Date) -> DeviceSeatHold? {
        guard payload.isSeatChecked else { return nil }
        let hold = { (kind: DeviceSeatHold.Kind) in
            DeviceSeatHold(kind: kind, licensee: payload.licensee, licenceExpires: payload.expires)
        }
        guard let record else { return hold(.checkIn) }
        let verdict = DeviceSeatLease.verdict(
            lease: record.lease, keys: keys, deviceKeyHash: deviceKeyHash,
            enrolmentId: enrolmentId ?? record.enrolmentId,
            licenseIDHash: LiveFieldAssistEntitlementProvider.licenseIDHash(for: code),
            previousLicenseIDHash: record.previousLicenseIDHash,
            clockHighWater: record.clockHighWater, now: now)
        if verdict.isLive { return nil }
        if record.refusal == .full { return hold(.full(seats: payload.seats ?? record.refusedSeats)) }
        return hold(.checkIn)
    }
}
