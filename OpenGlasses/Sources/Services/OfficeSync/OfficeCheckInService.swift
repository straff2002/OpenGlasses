import Foundation

/// Keeps a phone that joined an office by its code joined, and ends it when the office says so
/// (Contracts/office-check-in.md).
///
/// On each pass over what the office has put in the managed folders:
///
/// - a **removal** that verifies revokes the enrolment exactly as a signed revocation does, its
///   receipt is signed and published, and nothing else is taken in for that enrolment;
/// - the **result** for the one check-in this phone is waiting on goes through the pairing gate,
///   which commits the generation high-water mark, the saved binding and then the lease; the
///   check-in's nonce is then forgotten, so the same result later changes nothing;
/// - the live **challenge** is answered once: the exact bytes of the check-in and its nonce are
///   kept until a result arrives or the challenge expires, and the same bytes are published again
///   rather than a second check-in.
///
/// A file that does not verify is left where it is and recorded once with a bounded reason; one
/// that is only not valid yet waits. No engine, key or trust chain of its own: everything it
/// touches is a seam, so it runs headless.
@MainActor
final class OfficeCheckInService: ObservableObject {

    /// The one check-in this phone is waiting on.
    struct WaitingCheckIn: Codable, Equatable, Sendable {
        let enrolmentID: String
        let challengeID: String
        /// The message digest of the challenge answered.
        let challengeSHA256: String
        let expiresAt: Int64
        /// The binding the check-in names.
        let generation: Int64
        let bindingSHA256: String
        /// The exact bytes signed, and the phone's nonce inside them.
        let payload: Data
        let nonce: String
        /// The signature, standard base64, kept so the same check-in is published again.
        var signature: String?
        /// The message digest of the check-in as published. Nil until it is.
        var checkInSHA256: String?
    }

    struct RemovalRecord: Codable, Equatable, Sendable {
        let enrolmentID: String
        let removalID: String
        let removalSHA256: String
        let reason: String
        /// Phone clock when the enrolment was marked revoked.
        let actedAt: Int64
        var signature: String?
        var receiptPublished: Bool
    }

    struct Refused: Codable, Equatable, Sendable {
        /// The message digest of the file refused.
        let digest: String
        let reason: String
    }

    /// The durable record. It lives outside the transport.
    struct Ledger: Codable, Equatable, Sendable {
        var version = 1
        var waiting: WaitingCheckIn?
        var lastRenewedAt: Date?
        var removal: RemovalRecord?
        var refused: [Refused] = []
    }

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        /// The binding held, from the pairing gate passing at this moment.
        var held: @MainActor () async throws -> OfficeCheckIn.Held
        /// Contract §7: the result through the pairing gate, committing in its order.
        var renew: @MainActor (Data, OfficeCheckIn.Waiting) async throws -> Void
        /// Contract §8: the removal verified, and the enrolment revoked.
        var revoke: @MainActor (Data) async throws -> OfficeCheckIn.VerifiedRemoval
        var signCheckIn: (Data) async throws -> Data = { try await OfficePhoneIdentity.shared.signCheckIn($0) }
        var signRemovalReceipt: (Data) async throws -> Data = {
            try await OfficePhoneIdentity.shared.signRemovalReceipt($0)
        }
        /// This phone's enrolment with an office, when it has one.
        var enrolmentID: @MainActor () -> String? = { nil }
        /// When the lease ends as it stands. Informational: the office lists it.
        var leaseRenewBy: @MainActor () -> Date? = { nil }
        var appVersion: () -> String = { "" }
        var appBuild: () -> String = { "" }
        /// The saved binding has been replaced: the folders start again under the new generation.
        var bindingChanged: @MainActor () -> Void = {}
        var clock: () -> Date = Date.init
        var load: () -> Ledger = { Ledger() }
        var save: (Ledger) throws -> Void = { _ in }
    }

    enum State: Equatable, Sendable {
        /// Nothing to say: no check-in is waiting and the office has not removed this phone.
        case idle
        /// A check-in has been published and the office has not answered yet.
        case checkedIn
        /// The office removed this phone; `reason` is the removal's.
        case removed(reason: String)
    }

    /// What a pass did, for the caller that decides what else may be taken in.
    enum Outcome: Equatable, Sendable {
        case nothing, answered, renewed, removed
    }

    enum Failure: Error, Equatable {
        /// The transport offered bytes that are not the check-in or receipt asked for.
        case notWhatWasAskedFor
    }

    static let maximumReasonCharacters = 200
    static let maximumRefused = 64

    @Published private(set) var state: State = .idle
    private(set) var ledger: Ledger

    private let seams: Seams
    private var sweeping = false
    /// Challenges whose check-in the transport has confirmed published since this was made.
    private var confirmed: Set<String> = []

    init(seams: Seams) {
        self.seams = seams
        ledger = seams.load()
        state = Self.state(of: ledger)
    }

    // MARK: - Taking in

    /// One pass. Safe to repeat: a pass that is still running is not joined by a second.
    @discardableResult
    func sweep() async throws -> Outcome {
        guard !sweeping else { return .nothing }
        sweeping = true
        defer { sweeping = false }
        let pending = try OfficeManagedFolders.decodeCheckInPending(try await seams.transport.checkInPending())
        // A removal ends one enrolment. A phone that has since joined again is another.
        if let removal = ledger.removal, let current = seams.enrolmentID(), current != removal.enrolmentID {
            try update { $0.removal = nil }
        }
        // A removal is final: nothing else is taken in once one has been acted on.
        for removal in pending.removals {
            if try await takeIn(removal: removal) { return .removed }
        }
        if ledger.removal != nil {
            try await giveRemovalReceipt()
            return .removed
        }
        if let waiting = ledger.waiting, let digest = waiting.checkInSHA256,
           let result = pending.results.first(where: { $0.id == waiting.challengeID }),
           try await takeIn(result: result, waiting: waiting, checkInSHA256: digest) {
            return .renewed
        }
        return try await answer(pending.challenges) ? .answered : .nothing
    }

    // MARK: Removal

    private func takeIn(removal item: OfficeManagedFolders.PendingEnvelope) async throws -> Bool {
        guard let data = Data(base64Encoded: item.envelope) else { return false }
        let digest = OfficeCheckIn.digest(data)
        if let acted = ledger.removal {
            guard acted.removalSHA256 == digest else { return false }
            try await giveRemovalReceipt()
            return true
        }
        guard !isRefused(digest) else { return false }
        let verified: OfficeCheckIn.VerifiedRemoval
        do {
            verified = try await seams.revoke(data)
        } catch let refusal as OfficeCheckIn.Refusal {
            try refuse(digest, refusal)
            return false
        }
        guard verified.payload.removalID == item.id else {
            try refuse(digest, OfficeCheckIn.Refusal.wrongBinding)
            return false
        }
        var next = ledger
        next.waiting = nil
        next.removal = RemovalRecord(
            enrolmentID: verified.payload.enrolmentID, removalID: verified.payload.removalID,
            removalSHA256: verified.messageSHA256, reason: verified.payload.reason,
            actedAt: Int64(seams.clock().timeIntervalSince1970), signature: nil, receiptPublished: false)
        try commit(next)
        try await giveRemovalReceipt()
        return true
    }

    /// Sign and publish the receipt for the removal acted on, on the connection that brought it.
    /// Nothing opens a connection for it afterwards.
    private func giveRemovalReceipt() async throws {
        guard let removal = ledger.removal, !removal.receiptPublished else { return }
        guard let payload = Data(base64Encoded: try await seams.transport.removalReceiptPayload(
                  removalID: removal.removalID, actedAt: removal.actedAt)),
              let receipt = OfficeCheckIn.removalReceiptPayload(payload),
              receipt.removalID == removal.removalID, receipt.removalSHA256 == removal.removalSHA256,
              receipt.enrolmentID == removal.enrolmentID else { throw Failure.notWhatWasAskedFor }
        let signature: String
        if let kept = removal.signature {
            signature = kept
        } else {
            signature = try await seams.signRemovalReceipt(payload).base64EncodedString()
            try update { $0.removal?.signature = signature }
        }
        _ = try await seams.transport.publishRemovalReceipt(removalID: removal.removalID,
                                                            signatureBase64: signature)
        try update { $0.removal?.receiptPublished = true }
    }

    // MARK: Result

    private func takeIn(result item: OfficeManagedFolders.PendingEnvelope, waiting: WaitingCheckIn,
                        checkInSHA256: String) async throws -> Bool {
        guard let data = Data(base64Encoded: item.envelope) else { return false }
        let digest = OfficeCheckIn.digest(data)
        guard !isRefused(digest) else { return false }
        do {
            try await seams.renew(data, OfficeCheckIn.Waiting(
                challengeID: waiting.challengeID, checkInSHA256: checkInSHA256,
                generation: waiting.generation, bindingSHA256: waiting.bindingSHA256))
        } catch let refusal as OfficeCheckIn.Refusal {
            try refuse(digest, refusal)
            return false
        } catch let refusal as OfficePeerBinding.Refusal {
            // Not yet valid on this phone's clock waits; anything else about the binding is final.
            if refusal != .notCurrentlyValid { try refuse(digest, refusal) }
            return false
        } catch let refusal as OfficePeerHighWaterStore.Refusal {
            try refuse(digest, refusal)
            return false
        }
        // Renewed. The nonce is forgotten: this result, taken in again, fits no check-in.
        try update {
            $0.waiting = nil
            $0.lastRenewedAt = self.seams.clock()
        }
        seams.bindingChanged()
        return true
    }

    // MARK: Challenge

    private func answer(_ challenges: [OfficeManagedFolders.PendingEnvelope]) async throws -> Bool {
        let now = Int64(seams.clock().timeIntervalSince1970)
        if let waiting = ledger.waiting, now >= waiting.expiresAt {
            try update { $0.waiting = nil }
        }
        guard !challenges.isEmpty else { return false }
        // The gate first: no challenge is answered on a pairing that does not verify now.
        let held = try await seams.held()
        if let waiting = ledger.waiting,
           waiting.enrolmentID != held.enrolmentID || waiting.generation != held.generation
            || waiting.bindingSHA256 != held.bindingSHA256 {
            try update { $0.waiting = nil }
        }
        var live: [(OfficeCheckIn.VerifiedChallenge, String)] = []
        for item in challenges {
            guard let data = Data(base64Encoded: item.envelope) else { continue }
            let digest = OfficeCheckIn.digest(data)
            guard !isRefused(digest) else { continue }
            do {
                let challenge = try OfficeCheckIn.challenge(data, held: held, now: now)
                guard challenge.payload.challengeID == item.id else {
                    try refuse(digest, OfficeCheckIn.Refusal.wrongBinding)
                    continue
                }
                live.append((challenge, item.id))
            } catch let refusal as OfficeCheckIn.Refusal {
                try refuse(digest, refusal)
            }
        }
        // The live challenge with the latest issuedAt, and no other.
        guard let (challenge, id) = live.max(by: {
            ($0.0.payload.issuedAt, $1.1) < ($1.0.payload.issuedAt, $0.1)
        }) else { return false }

        if let waiting = ledger.waiting, waiting.challengeID == id,
           waiting.challengeSHA256 == challenge.messageSHA256 {
            // Answered already. The same bytes are published again if they never were, and once
            // more after a relaunch in case the transport lost them: never a second check-in.
            let first = waiting.checkInSHA256 == nil
            guard first || !confirmed.contains(id) else { return false }
            try await publishCheckIn(held: held)
            return first
        }
        let offered = try await seams.transport.checkInPayload(
            challengeID: id, leaseRenewBy: Self.leaseRenewBy(seams.leaseRenewBy(), now: now),
            appVersion: seams.appVersion(), appBuild: seams.appBuild())
        guard let payload = Data(base64Encoded: offered),
              let checkIn = OfficeCheckIn.checkInPayload(payload),
              OfficeCheckIn.answers(checkIn, challenge: challenge, held: held) else {
            throw Failure.notWhatWasAskedFor
        }
        // Kept before anything is signed: one challenge, one check-in.
        try update {
            $0.waiting = WaitingCheckIn(
                enrolmentID: held.enrolmentID, challengeID: id, challengeSHA256: challenge.messageSHA256,
                expiresAt: challenge.payload.expiresAt, generation: held.generation,
                bindingSHA256: held.bindingSHA256, payload: payload, nonce: checkIn.nonce,
                signature: nil, checkInSHA256: nil)
        }
        try await publishCheckIn(held: held)
        return true
    }

    private func publishCheckIn(held: OfficeCheckIn.Held) async throws {
        guard let waiting = ledger.waiting else { return }
        // The transport must still hold the bytes this phone kept; it never signs others for the
        // same challenge.
        let offered = try await seams.transport.checkInPayload(
            challengeID: waiting.challengeID,
            leaseRenewBy: Self.leaseRenewBy(seams.leaseRenewBy(), now: Int64(seams.clock().timeIntervalSince1970)),
            appVersion: seams.appVersion(), appBuild: seams.appBuild())
        guard Data(base64Encoded: offered) == waiting.payload else { throw Failure.notWhatWasAskedFor }
        let signature: String
        if let kept = waiting.signature {
            signature = kept
        } else {
            signature = try await seams.signCheckIn(waiting.payload).base64EncodedString()
            try update { $0.waiting?.signature = signature }
        }
        let published = Data(try await seams.transport.publishCheckIn(
            challengeID: waiting.challengeID, signatureBase64: signature).utf8)
        // What was published is this check-in, signed by this phone: its digest is what a result
        // must name.
        guard let envelope = try? JSONDecoder().decode(OfficeCheckIn.Envelope.self, from: published),
              envelope.payload == waiting.payload.base64EncodedString(),
              (try? OfficeCheckIn.checkIn(published, phoneApplicationKey: held.phoneApplicationKey)) != nil else {
            throw Failure.notWhatWasAskedFor
        }
        try update { $0.waiting?.checkInSHA256 = OfficeCheckIn.digest(published) }
        confirmed.insert(waiting.challengeID)
    }

    // MARK: - The record

    private func isRefused(_ digest: String) -> Bool {
        ledger.refused.contains { $0.digest == digest }
    }

    /// Recorded once, with a bounded reason. A file that is only not valid yet is not recorded.
    private func refuse(_ digest: String, _ error: Error) throws {
        if let refusal = error as? OfficeCheckIn.Refusal, refusal == .notCurrentlyValid { return }
        guard !isRefused(digest) else { return }
        try update {
            $0.refused.append(Refused(digest: digest, reason: Self.bounded(String(describing: error))))
            if $0.refused.count > Self.maximumRefused {
                $0.refused.removeFirst($0.refused.count - Self.maximumRefused)
            }
        }
    }

    private func update(_ change: (inout Ledger) -> Void) throws {
        var next = ledger
        change(&next)
        try commit(next)
    }

    /// Saved first: what is in memory is never ahead of what is on disk.
    private func commit(_ next: Ledger) throws {
        guard next != ledger else { return }
        try seams.save(next)
        ledger = next
        state = Self.state(of: next)
    }

    // MARK: - Pure

    static func bounded(_ reason: String) -> String {
        String(reason.prefix(maximumReasonCharacters))
    }

    /// The check-in's `leaseRenewBy`: informational, but a positive instant all the same.
    static func leaseRenewBy(_ date: Date?, now: Int64) -> Int64 {
        guard let date, date.timeIntervalSince1970 >= 1,
              date.timeIntervalSince1970 <= TimeInterval(OfficeCheckIn.maximumSafeInteger) else { return now }
        return Int64(date.timeIntervalSince1970)
    }

    static func state(of ledger: Ledger) -> State {
        if let removal = ledger.removal { return .removed(reason: removal.reason) }
        if ledger.waiting?.checkInSHA256 != nil { return .checkedIn }
        return .idle
    }

    /// The words for each state. Nil when nothing is shown: a check-in and its renewal need
    /// nobody, so only a removal is said.
    static func status(_ state: State) -> OfficeFieldConnectionPolicy.Status? {
        switch state {
        case .idle, .checkedIn:
            return nil
        case .removed(let reason):
            return .init(title: "Removed by your organisation",
                         detail: reason == OfficeCheckIn.reasonRevoked
                            ? "Your organisation has withdrawn this phone's access to its office."
                            : "Your organisation has removed this phone from its office.",
                         systemImage: "person.crop.circle.badge.xmark")
        }
    }
}

/// The app's wiring: the pairing gate, and a file for the record.
extension OfficeCheckInService.Seams {
    @MainActor
    static func app(transport: any OfficeManagedFolderTransport,
                    pairing: @escaping @MainActor () -> OfficePairingService = { OfficePairingService() },
                    manager: OrgProfileManager = .shared,
                    ledgerFile: URL? = OfficeCheckInService.defaultLedgerFile()) -> Self {
        var seams = Self(
            transport: transport,
            held: {
                guard let held = OfficeCheckIn.Held(try await pairing().currentApprovedPeer()) else {
                    throw OfficePeerBinding.Refusal.invalidFields
                }
                return held
            },
            renew: { _ = try await pairing().renew(withResult: $0, waiting: $1) },
            revoke: { try await pairing().remove(withRemoval: $0) })
        seams.enrolmentID = { manager.record.flatMap { $0.source == .office ? $0.enrolmentId : nil } }
        seams.leaseRenewBy = {
            switch manager.lease {
            case .live(let renewBy)?, .renewSoon(let renewBy)?: return renewBy
            default: return nil
            }
        }
        seams.appVersion = { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
        seams.appBuild = { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
        if let ledgerFile {
            seams.load = { OfficeCheckInService.readLedger(ledgerFile) }
            seams.save = { try OfficeCheckInService.writeLedger($0, to: ledgerFile) }
        }
        return seams
    }
}

extension OfficeCheckInService {
    nonisolated static func defaultLedgerFile() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("check-in.json")
    }

    /// A missing or unreadable record reads as empty. A check-in that was waiting is then no
    /// longer answered by its result, and the office sets a new challenge.
    nonisolated static func readLedger(_ file: URL) -> Ledger {
        guard let data = try? Data(contentsOf: file),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.version == 1 else { return Ledger() }
        return ledger
    }

    nonisolated static func writeLedger(_ ledger: Ledger, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(
            to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
