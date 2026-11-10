import Foundation
import Combine

/// The seat service, as the phone sees it: a nonce, then one signed request (Plan JS P2).
/// Injected, so tests run the whole claim → renew → release path against a stub.
protocol DeviceSeatServer: Sendable {
    func nonce(origin: URL) async throws -> String
    func send(_ action: DeviceSeatLease.Action, envelope: DeviceSeatLease.Envelope, origin: URL) async throws -> DeviceSeatLease.Reply
}

/// The production transport. The address is the origin of the licence's **signed** `profile`
/// claim, so the host is the vendor's statement rather than anything a page or a link chose; an
/// ephemeral session with no cookies, cache or credentials carries a few hundred bytes each way.
struct DeviceSeatHTTPClient: DeviceSeatServer {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let maximumReplyBytes = 8 * 1024

    func nonce(origin: URL) async throws -> String {
        let data = try await post(origin.appendingPathComponent(String(DeviceSeatLease.noncePath.dropFirst())), body: Data("{}".utf8))
        return try LicenseService.decoder.decode(DeviceSeatLease.NonceReply.self, from: data).nonce
    }

    func send(_ action: DeviceSeatLease.Action, envelope: DeviceSeatLease.Envelope, origin: URL) async throws -> DeviceSeatLease.Reply {
        let data = try await post(origin.appendingPathComponent(String(action.path.dropFirst())),
                                  body: try DeviceSeatLease.encode(envelope))
        return try LicenseService.decoder.decode(DeviceSeatLease.Reply.self, from: data)
    }

    private func post(_ url: URL, body: Data) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        try MedicalEgressGuard.check(.licenceSeatLease)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= Self.maximumReplyBytes else {
            throw URLError(.badServerResponse)
        }
        // Refusals come back as JSON with a 4xx status; anything else is a failed attempt.
        guard (200...499).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}

/// What a check-in needs to know about the enrolment it belongs to.
struct DeviceSeatEnrolment: Equatable, Sendable {
    let profileId: String
    let enrolmentId: String
}

/// Claims, renews and releases this phone's seat (Plan JS P2).
///
/// **Only a lease changes what the phone may do.** A refusal or a failed attempt never removes a
/// lease the phone holds: the service's refusals are unsigned, so they only word a lock that
/// already exists for want of a live lease. A freed phone keeps working until its lease runs out.
@MainActor
final class DeviceSeatService: ObservableObject {
    struct Seams {
        var server: DeviceSeatServer = DeviceSeatHTTPClient()
        var keys: DeviceSeatKeyStore = DeviceSeatKeychainStore.shared
        var loadRecord: () -> DeviceSeatRecord? = { DeviceSeatRecord.load() }
        var saveRecord: (DeviceSeatRecord?) -> Void = { DeviceSeatRecord.save($0) }
        var leaseKeys: [String] = DeviceSeatLease.productionPublicKeys
        var licenceKey: String = LicenseService.productionPublicKeyBase64
        var storedCode: () -> String? = { UserDefaults.standard.string(forKey: LicenseService.storageKey) }
        var build: () -> String = { AppBuildIdentity.current.build }
        var now: () -> Date = Date.init
        /// Tells the screens the entitlement may have changed.
        var entitlementChanged: @MainActor () -> Void = { LicenseService.shared.objectWillChange.send() }
    }

    static let shared = DeviceSeatService()

    /// A live lease is renewed about once a day, on the profile fetch.
    nonisolated static let renewalInterval: TimeInterval = 86_400
    /// Without a live lease, a check-in is retried at most this often (launch, foreground, fetch).
    nonisolated static let retryInterval: TimeInterval = 600

    /// The last verdict seen, for the licence screen.
    @Published private(set) var verdict: DeviceSeatLease.Verdict?

    private var seams: Seams
    private var inFlight = false
    /// A check-in asked for while one was out: run next, so a forced claim (a move) is never dropped.
    private var pending: (enrolment: DeviceSeatEnrolment, force: Bool)?
    /// Bumped by every release, so an answer that arrives after it is thrown away.
    private var generation = 0
    /// The release still on its way; a claim waits for it, so a move into a full licence on the same
    /// seat service does not race its own seat.
    private var releaseTask: Task<Void, Never>?

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// The seat-checked licence in force, with its code, or nil when none is.
    private func seatCheckedLicence() -> (code: String, payload: LicenseService.LicensePayload)? {
        guard let raw = seams.storedCode()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let payload = try? LicenseService.decode(code: raw, publicKeyBase64: seams.licenceKey),
              payload.isSeatChecked else { return nil }
        return (raw, payload)
    }

    /// Claim or renew this phone's seat when one is due. Called on enrolment (forced), and after
    /// each profile renewal attempt at launch and on foreground. Does nothing for a licence that
    /// does not count seats, so no other phone ever makes this call.
    func checkIn(_ enrolment: DeviceSeatEnrolment?, force: Bool = false) async {
        guard let enrolment else { return }
        if inFlight {
            pending = (enrolment, force || (pending?.force ?? false))
            return
        }
        inFlight = true
        var next: (enrolment: DeviceSeatEnrolment, force: Bool)? = (enrolment, force)
        while let run = next {
            pending = nil
            await checkInOnce(run.enrolment, force: run.force)
            next = pending
        }
        inFlight = false
    }

    private func checkInOnce(_ enrolment: DeviceSeatEnrolment, force: Bool) async {
        guard let (code, payload) = seatCheckedLicence(),
              let origin = DeviceSeatLease.seatOrigin(profileAddress: payload.profile) else { return }
        let startedIn = generation

        var record = seams.loadRecord()
        if record?.enrolmentId != enrolment.enrolmentId || record?.profileId != enrolment.profileId {
            record = DeviceSeatRecord(enrolmentId: enrolment.enrolmentId, profileId: enrolment.profileId)
        }
        guard var current = record else { return }
        let now = wholeSeconds(seams.now())
        let licenseIDHash = LiveFieldAssistEntitlementProvider.licenseIDHash(for: code)
        let before = DeviceSeatLease.verdict(lease: current.lease, keys: seams.leaseKeys,
                                             deviceKeyHash: (try? seams.keys.existing()).map { DeviceSeatLease.deviceKeyHash(publicKeyX963: $0.publicKeyX963) },
                                             enrolmentId: current.enrolmentId, licenseIDHash: licenseIDHash,
                                             previousLicenseIDHash: current.previousLicenseIDHash,
                                             clockHighWater: current.clockHighWater, now: now)
        if before != .clockWoundBack { current.clockHighWater = max(current.clockHighWater ?? now, now) }

        if !force, let last = current.lastAttempt, last <= now {
            // A lease still honoured for a code that has been replaced is renewed at the next
            // retry, not a day later: it is a bridge to the new code's lease, not a lease for it.
            let forThisCode = current.lease.flatMap { DeviceSeatLease.open($0, keys: seams.leaseKeys) }?
                .licenseIDHash == licenseIDHash
            let wait = before.isLive && forThisCode ? Self.renewalInterval : Self.retryInterval
            if now.timeIntervalSince(last) < wait {
                save(current, verdict: before)
                return
            }
        }
        current.lastAttempt = now
        current.origin = origin.absoluteString
        save(current, verdict: before)

        // A key is made only when the Keychain says there is none: a read that fails (locked, or
        // unavailable) must not replace the key and orphan the seat it holds.
        let key: DeviceSeatKey
        do { key = try seams.keys.existing() ?? seams.keys.create() } catch { return }
        if let releasing = releaseTask { await releasing.value }
        guard generation == startedIn else { return }
        // A stored lease that names this phone's key is renewed (the service finds the seat by
        // it, whichever licence it named); anything else claims.
        let ownLease = current.lease.flatMap { DeviceSeatLease.open($0, keys: seams.leaseKeys) }
            .map { $0.deviceKeyHash == DeviceSeatLease.deviceKeyHash(publicKeyX963: key.publicKeyX963) } ?? false
        var reply = ownLease
            ? await exchange(.renew, DeviceSeatLease.RenewRequest(build: seams.build(), lease: current.lease ?? ""), key: key, origin: origin)
            : await exchange(.claim, claimRequest(enrolment, key: key), key: key, origin: origin)
        // The seat was freed: ask for one again, which there may or may not be room for — unless
        // the phone itself let the seat go (a release) while the renewal was out, which a claim
        // now would undo on the service.
        if ownLease, reply?.refusal == .freed, generation == startedIn {
            reply = await exchange(.claim, claimRequest(enrolment, key: key), key: key, origin: origin)
        }

        // The phone may have left (a release) or re-enrolled while the request was out: then the
        // answer belongs to an enrolment that is gone, and is dropped.
        guard generation == startedIn,
              seams.loadRecord().map({ $0.enrolmentId == current.enrolmentId }) ?? false else { return }
        if let reply {
            if let lease = reply.lease,
               let opened = DeviceSeatLease.open(lease, keys: seams.leaseKeys),
               DeviceSeatLease.verdict(lease: lease, keys: seams.leaseKeys,
                                       deviceKeyHash: DeviceSeatLease.deviceKeyHash(publicKeyX963: key.publicKeyX963),
                                       enrolmentId: current.enrolmentId, licenseIDHash: licenseIDHash,
                                       now: wholeSeconds(seams.now())).isLive {
                // The service's clock signed the lease: it, not a clock once set ahead, is the
                // latest time seen. A phone whose clock jumped forward recovers here — but only
                // from a lease newer than the one it holds: an older one (a replay, with the clock
                // wound back to fit it) must never lower the mark.
                let storedIssued = current.lease.flatMap { DeviceSeatLease.open($0, keys: seams.leaseKeys) }?.issued
                if let storedIssued, opened.issued < storedIssued {
                    // Older than the lease already held: the service never signs backwards, so
                    // this is a replay. It is not stored either — held, it would become the
                    // lease the next replay only has to be newer than, and the mark could be
                    // walked down a step at a time.
                } else {
                    if storedIssued.map({ opened.issued > $0 }) ?? true {
                        current.clockHighWater = opened.issued
                    } else {
                        current.clockHighWater = max(current.clockHighWater ?? opened.issued, opened.issued)
                    }
                    current.lease = lease
                    current.lastRenewed = wholeSeconds(seams.now())
                    current.refusal = nil
                    current.refusedSeats = nil
                    // The new lease names the code in force: the bridge for the replaced one ends.
                    current.previousLicenseIDHash = nil
                }
            } else if let refusal = reply.refusal, refusal != .badNonce, refusal != .badRequest {
                current.refusal = refusal
                current.refusedSeats = reply.seats
            }
        }
        let after = DeviceSeatLease.verdict(lease: current.lease, keys: seams.leaseKeys,
                                            deviceKeyHash: DeviceSeatLease.deviceKeyHash(publicKeyX963: key.publicKeyX963),
                                            enrolmentId: current.enrolmentId, licenseIDHash: licenseIDHash,
                                            clockHighWater: current.clockHighWater, now: wholeSeconds(seams.now()))
        save(current, verdict: after)
    }

    /// A renewal of the same profile replaced the licence code in force (`OrgProfileManager`). The
    /// stored lease was issued for the old code; it stays in force until its own end, or until a
    /// check-in brings a lease for the new code, so the technician is not locked out in between.
    /// Recorded only for this enrolment's own record, and only when the lease does name the code
    /// being replaced; nothing about the lease itself changes.
    func noteLicenceReplaced(previousCode: String, enrolment: DeviceSeatEnrolment) {
        guard var record = seams.loadRecord(), record.enrolmentId == enrolment.enrolmentId,
              record.profileId == enrolment.profileId,
              let payload = record.lease.flatMap({ DeviceSeatLease.open($0, keys: seams.leaseKeys) }),
              payload.enrolmentId == enrolment.enrolmentId else { return }
        let previous = LiveFieldAssistEntitlementProvider.licenseIDHash(for:
            previousCode.trimmingCharacters(in: .whitespacesAndNewlines))
        guard payload.licenseIDHash == previous, record.previousLicenseIDHash != previous else { return }
        record.previousLicenseIDHash = previous
        seams.saveRecord(record)
        seams.entitlementChanged()
    }

    /// Records keep whole seconds (ISO-8601), so a time compares equal after a round trip.
    private func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Give the seat back and forget the key: the phone's owner removed the organisation (or moved
    /// the phone to another). Sent once, to the seat service the lease came from; if it never
    /// arrives the seat frees when its lease and grace run out.
    @discardableResult
    func release() -> Task<Void, Never>? {
        generation += 1
        let record = seams.loadRecord()
        let key = try? seams.keys.existing()
        let origin = record?.origin.flatMap { DeviceSeatLease.seatOrigin(profileAddress: $0) }
        seams.saveRecord(nil)
        seams.keys.remove()
        if verdict != nil || record != nil {
            verdict = nil
            seams.entitlementChanged()
        }
        guard let lease = record?.lease, let key, let origin,
              let payload = DeviceSeatLease.open(lease, keys: seams.leaseKeys),
              payload.deviceKeyHash == DeviceSeatLease.deviceKeyHash(publicKeyX963: key.publicKeyX963) else { return nil }
        let task = Task { [weak self] in
            _ = await self?.exchange(.release, DeviceSeatLease.ReleaseRequest(lease: lease), key: key, origin: origin)
        }
        releaseTask = task
        return task
    }

    // MARK: - One exchange

    private func claimRequest(_ enrolment: DeviceSeatEnrolment, key: DeviceSeatKey) -> DeviceSeatLease.ClaimRequest {
        DeviceSeatLease.ClaimRequest(build: seams.build(), devicePublicKey: key.publicKeyX963.base64EncodedString(),
                                     enrolmentId: enrolment.enrolmentId, profileId: enrolment.profileId)
    }

    /// Nonce, sign, send. A stale nonce is asked for once more. Nil when nothing usable came back.
    private func exchange<Request: Encodable>(_ action: DeviceSeatLease.Action, _ request: Request, key: DeviceSeatKey,
                                              origin: URL) async -> DeviceSeatLease.Reply? {
        let server = seams.server
        guard let body = try? DeviceSeatLease.encode(request) else { return nil }
        for _ in 0..<2 {
            guard let nonce = try? await server.nonce(origin: origin),
                  let signature = try? key.sign(DeviceSeatLease.signedBytes(action: action, nonce: nonce, request: body))
            else { return nil }
            let envelope = DeviceSeatLease.Envelope(nonce: nonce, request: body.base64EncodedString(),
                                                    signature: signature.base64EncodedString())
            guard let reply = try? await server.send(action, envelope: envelope, origin: origin) else { return nil }
            if reply.refusal != .badNonce { return reply }
        }
        return nil
    }

    private func save(_ record: DeviceSeatRecord, verdict: DeviceSeatLease.Verdict) {
        let changed = record != seams.loadRecord()
        if changed { seams.saveRecord(record) }
        if self.verdict != verdict || changed {
            self.verdict = verdict
            seams.entitlementChanged()
        }
    }
}
