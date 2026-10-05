import Foundation

/// Takes the manuals an organisation's office assigns to this phone (Contracts/office-bulk.md).
///
/// On each pass over what the office has put in the managed folders:
///
/// - a **publisher grant** that verifies under the administrator key of this phone's own
///   vendor-verified profile is kept, by publisher, with its sequence: a later one replaces it, an
///   earlier one never does, and a revocation is kept like any other;
/// - a **manual assignment** that verifies against the binding held, and moves its set forward, is
///   committed and receipted as *received*, and its archive — and only its archive — is asked of
///   the `bulk` folder;
/// - an archive that has arrived as exactly the bytes assigned goes through the existing import
///   preflight: the publisher's signature (the vendor's catalogue, or a live grant for a publisher
///   under this organisation's own prefix) and the archive's own contents. Then the existing
///   installer installs it, and the assignment is receipted as *installed*.
///
/// Large content moves only when the route allows it: the folder is paused otherwise, and that
/// is a state shown as waiting, never a failure. An assignment that cannot be installed is
/// recorded once with a bounded reason and gets no further receipt.
///
/// No engine, key or trust chain of its own: everything it touches is a seam, so it runs
/// headless.
@MainActor
final class OfficeManualService: ObservableObject {

    struct GrantRecord: Codable, Equatable, Sendable {
        let publisherID: String
        let sequence: Int64
        let payloadSHA256: String
        /// The exact envelope, verified again whenever it is relied on.
        let envelope: Data
    }

    struct Entry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            /// Committed; its archive is not installed yet.
            case received
            case installed
            /// It could not be installed, or a later assignment for its set replaced it.
            case refused
        }
        let assignmentID: String
        let enrolmentID: String
        let setID: String
        let sequence: Int64
        /// The exact assignment, and the SHA-256 of its decoded payload.
        let envelope: Data
        let payloadSHA256: String
        let archiveSHA256: String
        let archiveBytes: Int64
        let publisherID: String
        let vaultID: String
        let vaultVersion: String
        /// The set's mark before this assignment was accepted. Verifying the kept envelope
        /// against it gives the assignment again, not a replay of itself.
        let previous: OfficeManualAssignment.HighWater?
        var state: State
        var reason: String?
        let receivedAt: Int64
        var installedAt: Int64?
        /// Receipt signatures by outcome, kept so the same receipt is published again.
        var signatures: [String: String]
        var receiptsPublished: [String]
    }

    struct Refused: Codable, Equatable, Sendable {
        let digest: String
        let reason: String
    }

    /// The durable record. It lives outside the transport and outside every installed vault, so
    /// removing a manual does not let an old assignment bring it back.
    struct Ledger: Codable, Equatable, Sendable {
        var version = 1
        var grants: [GrantRecord] = []
        /// The highest assignment accepted for each set, by organisation, enrolment and set.
        var highWater: [String: OfficeManualAssignment.HighWater] = [:]
        var entries: [Entry] = []
        var refused: [Refused] = []
    }

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        /// The binding held, from the pairing gate passing at this moment.
        var held: @MainActor () async throws -> OfficeCheckIn.Held
        /// The vendor-signed profile's own term: no grant is relied on past it.
        var policyExpiry: @MainActor () -> Date? = { nil }
        /// The publishers the vendor's signed catalogue lists.
        var cataloguePublishers: @MainActor () -> [VaultPublisher] = { [] }
        /// The existing installer. It keeps the previous version of a vault until the new one is
        /// committed.
        var install: @MainActor (OfficeManualImport.Prepared) async throws -> Void
        var sign: (Data) async throws -> Data = { try await OfficePhoneIdentity.shared.signAssignmentReceipt($0) }
        /// Whether the route is one large content may use now.
        var bulkAllowed: @MainActor () -> Bool = { false }
        /// This phone's ceiling on an assigned archive, which no assignment can raise.
        var maximumArchiveBytes: Int64 = 200 * 1_048_576
        var maximumInflatedBytes = 400 * 1_048_576
        /// The job attachments still to come from the same folder. This service is the only one
        /// that tells the folder what to take, so a second owner cannot undo what the first asked.
        var attachmentsWanted: @MainActor () -> [JobNeeds.Attachment] = { [] }
        /// Where each wanted attachment is after a pass, by digest (`ready`, `offered` or
        /// `waiting`), and whether the route allows large content now.
        var attachmentsStatus: @MainActor ([String: String], Bool) async -> Void = { _, _ in }
        /// Free space on the volume a manual is taken to and installed on, when the system will
        /// say.
        var freeBytes: () -> Int64? = { nil }
        var clock: () -> Date = Date.init
        var load: () -> Ledger = { Ledger() }
        var save: (Ledger) throws -> Void = { _ in }
    }

    /// Where one assigned manual is, for a screen.
    struct Row: Equatable, Sendable, Identifiable {
        enum State: Equatable, Sendable {
            /// The office has not put the archive in the folder yet.
            case waitingForOffice
            /// It is there, and the route is one large content does not use unasked.
            case waitingForWiFi
            case downloading
            /// The office has it and this phone has no room to take and unpack it.
            case notEnoughSpace
            case installed
            case notInstalled(String)
        }
        let id: String
        let vaultID: String
        let vaultVersion: String
        let state: State
    }

    enum Failure: Error, Equatable {
        /// The transport offered bytes that are not the receipt asked for.
        case notWhatWasAskedFor
    }

    static let maximumReasonCharacters = 200
    static let maximumEntries = 100
    static let maximumRefused = 64

    @Published private(set) var rows: [Row] = []
    private(set) var ledger: Ledger

    private let seams: Seams
    private var sweeping = false
    /// Whether the last pass asked the folder for attachments, so the pass after the last one
    /// has arrived still tells the folder to let it go.
    private var askedForAttachments = false
    /// The archives the folder had taken at the last pass. One already here is installed, not
    /// let go, however little space is left.
    private var arrivedArchives: Set<String> = []

    init(seams: Seams) {
        self.seams = seams
        ledger = seams.load()
        rows = Self.rows(ledger, offered: [], allowed: false)
    }

    // MARK: - Taking in

    /// One pass. Safe to repeat: a pass that is still running is not joined by a second.
    func sweep() async throws {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let pending = try OfficeManagedFolders.decodeBulkPending(try await seams.transport.bulkPending())
        let unfinished = ledger.entries.contains { $0.state == .received }
        let attachments = seams.attachmentsWanted()
        guard unfinished || !pending.grants.isEmpty || !pending.assignments.isEmpty
                || !attachments.isEmpty || askedForAttachments else {
            // Nothing to ask the folder. The attachment store still lets go of what no held job
            // names any more; that needs no office.
            await seams.attachmentsStatus([:], seams.bulkAllowed())
            return
        }
        // The gate first: nothing is taken in on a pairing that does not verify now.
        let held = try await seams.held()
        let now = Int64(seams.clock().timeIntervalSince1970)
        var firstFailure: Error?
        func attempt(_ body: () async throws -> Void) async {
            do { try await body() } catch { firstFailure = firstFailure ?? error }
        }

        for item in pending.grants { await attempt { try self.take(grant: item, held: held) } }
        for item in pending.assignments { await attempt { try await self.take(assignment: item, held: held, now: now) } }
        for entry in ledger.entries where entry.enrolmentID == held.enrolmentID && entry.state != .refused {
            await attempt { try await self.giveReceipts(entry.assignmentID) }
        }

        // Only the archives of assignments this phone has accepted, and the attachments of jobs
        // it holds, are asked of the folder, and only while the route allows large content.
        let accepted = ledger.entries.filter { $0.state == .received && $0.enrolmentID == held.enrolmentID }
        // And only the archives this phone has room to take and unpack. One that does not fit is
        // not asked for; it says so, and is asked for on a later pass when there is room.
        let free = seams.freeBytes()
        let noRoom = Set(accepted.filter {
            !arrivedArchives.contains($0.archiveSHA256) && !Self.fits(archiveBytes: $0.archiveBytes, free: free)
        }.map(\.archiveSHA256))
        let wanted = accepted.filter { !noRoom.contains($0.archiveSHA256) }
        let archives = Set(accepted.map(\.archiveSHA256))
        let wantedAttachments = attachments.filter { !archives.contains($0.sha256) }
        let allowed = seams.bulkAllowed()
        var offered: Set<String> = []
        var ready: [String] = []
        var attachmentStates: [String: String] = [:]
        await attempt {
            try await self.seams.transport.setBulkWanted(Self.wantedJSON(wanted, attachments: wantedAttachments))
            try await self.seams.transport.setBulkPaused(!allowed || (wanted.isEmpty && wantedAttachments.isEmpty))
            self.askedForAttachments = !wantedAttachments.isEmpty
            let status = try OfficeManagedFolders.decodeBulkStatus(try await self.seams.transport.bulkStatus())
            offered = Set(status.filter { $0.state == "offered" }.map(\.sha256))
            let arrived = Set(status.filter { $0.state == "ready" }.map(\.sha256))
            self.arrivedArchives = arrived.intersection(archives)
            ready = wanted.filter { arrived.contains($0.archiveSHA256) }.map(\.assignmentID)
            for attachment in wantedAttachments {
                attachmentStates[attachment.sha256] = status.first { $0.sha256 == attachment.sha256 }?.state ?? "waiting"
            }
        }
        // Small things first: a job's attachments before a manual archive is installed.
        await seams.attachmentsStatus(attachmentStates, allowed)
        for assignmentID in ready {
            await attempt { try await self.install(assignmentID, held: held, now: now) }
        }
        rows = Self.rows(ledger, offered: offered, allowed: allowed, noRoom: noRoom)
        if let firstFailure { throw firstFailure }
    }

    // MARK: Grants

    private func take(grant item: OfficeManagedFolders.PendingEnvelope, held: OfficeCheckIn.Held) throws {
        guard let data = Data(base64Encoded: item.envelope) else { return }
        let digest = OfficeBulk.digest(data)
        guard !isRefused(digest) else { return }
        let grant: OfficeBulk.VerifiedGrant
        do {
            grant = try OfficeBulk.grant(data, administratorKey: held.administratorKey,
                                         organizationID: held.organizationID, profileID: held.profileID)
        } catch {
            try refuse(digest, error)
            return
        }
        guard grant.payload.grantID == item.id else { return try refuse(digest, OfficeBulk.Refusal.invalidFields) }
        if let known = ledger.grants.first(where: { $0.publisherID == grant.payload.publisherID }) {
            switch OfficeBulk.standing(heldSequence: known.sequence, heldSHA256: known.payloadSHA256, arriving: grant) {
            case .same: return
            case .older, .conflict: return try refuse(digest, OfficeBulk.Refusal.invalidFields)
            case .newer: break
            }
        }
        var next = ledger
        next.grants.removeAll { $0.publisherID == grant.payload.publisherID }
        next.grants.append(GrantRecord(publisherID: grant.payload.publisherID, sequence: grant.payload.sequence,
                                       payloadSHA256: grant.payloadSHA256, envelope: data))
        try commit(next)
    }

    /// The organisation's own publisher for an archive an assignment names, when a grant for it
    /// is held, verifies again now, and is live. Never a publisher outside the organisation's own
    /// prefix, and never added to anything.
    private func grantedPublisher(_ publisherID: String, held: OfficeCheckIn.Held, now: Int64) -> VaultPublisher? {
        guard OfficeBulk.isOrganisationPublisher(publisherID, organizationID: held.organizationID),
              let record = ledger.grants.first(where: { $0.publisherID == publisherID }),
              let grant = try? OfficeBulk.grant(record.envelope, administratorKey: held.administratorKey,
                                                organizationID: held.organizationID, profileID: held.profileID),
              grant.payload.publisherID == publisherID, grant.payload.sequence == record.sequence,
              grant.payload.isLive(now: now, policyExpiry: seams.policyExpiry()) else { return nil }
        return VaultPublisher(id: publisherID, name: grant.payload.publisherName,
                              publicKey: grant.payload.publisherKey, status: .active)
    }

    // MARK: Assignments

    private func trust(_ held: OfficeCheckIn.Held, setID: String) -> OfficeManualAssignment.Trust {
        .init(organizationID: held.organizationID, enrolmentID: held.enrolmentID, officeID: held.officeID,
              generation: held.generation, setID: setID, publicKey: held.officeApplicationKey,
              maximumArchiveBytes: seams.maximumArchiveBytes)
    }

    private func take(assignment item: OfficeManagedFolders.PendingEnvelope, held: OfficeCheckIn.Held,
                      now: Int64) async throws {
        guard let data = Data(base64Encoded: item.envelope) else { return }
        if ledger.entries.contains(where: { $0.assignmentID == item.id && $0.envelope == data }) { return }
        let digest = OfficeBulk.digest(data)
        guard !isRefused(digest) else { return }
        // The set is the assignment's own; that the office may assign it is the binding's.
        guard let envelope = try? JSONDecoder().decode(OfficeManualAssignment.Envelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payload),
              let named = try? JSONDecoder().decode(OfficeManualAssignment.Payload.self, from: payload) else {
            return try refuse(digest, OfficeManualAssignment.Refusal.malformed)
        }
        let scope = Self.scope(held, setID: named.setID)
        let previous = ledger.highWater[scope]
        let verified: OfficeManualAssignment.Verified
        do {
            verified = try OfficeManualAssignment.verify(data, trust: trust(held, setID: named.setID), now: now,
                                                         highWater: previous)
        } catch OfficeManualAssignment.Refusal.notCurrentlyValid {
            return   // not yet valid, or expired: it waits, and is not remembered as refused
        } catch {
            return try refuse(digest, error)
        }
        // The set's own mark again with no entry behind it: nothing to take in a second time.
        guard !verified.isReplay else { return }
        guard verified.payload.assignmentID == item.id else {
            return try refuse(digest, OfficeManualAssignment.Refusal.invalidFields)
        }
        let p = verified.payload
        var next = ledger
        next.highWater[scope] = verified.highWater
        // An earlier assignment for the set that never installed is replaced by this one.
        for index in next.entries.indices
        where next.entries[index].setID == p.setID && next.entries[index].enrolmentID == p.enrolmentID
            && next.entries[index].state == .received {
            next.entries[index].state = .refused
            next.entries[index].reason = "A later assignment for this manual set replaced it."
        }
        next.entries.append(Entry(
            assignmentID: p.assignmentID, enrolmentID: p.enrolmentID, setID: p.setID, sequence: p.sequence,
            envelope: data, payloadSHA256: verified.payloadSHA256, archiveSHA256: p.archiveSHA256,
            archiveBytes: p.archiveBytes, publisherID: p.publisherID, vaultID: p.vaultID,
            vaultVersion: p.vaultVersion, previous: previous, state: .received, reason: nil, receivedAt: now,
            installedAt: nil, signatures: [:], receiptsPublished: []))
        while next.entries.count > Self.maximumEntries,
              let settled = next.entries.firstIndex(where: { $0.state != .received }) {
            next.entries.remove(at: settled)
        }
        // Committed before it is receipted, and before its archive is asked for.
        try commit(next)
        try await giveReceipts(p.assignmentID)
    }

    private func install(_ assignmentID: String, held: OfficeCheckIn.Held, now: Int64) async throws {
        guard let entry = ledger.entries.first(where: { $0.assignmentID == assignmentID }),
              entry.state == .received else { return }
        do {
            // The kept assignment, verified again now against the set's mark before it.
            let verified = try OfficeManualAssignment.verify(
                entry.envelope, trust: trust(held, setID: entry.setID), now: now, highWater: entry.previous)
            let path = try await seams.transport.bulkFile(sha256: entry.archiveSHA256)
            let archive = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            // The vendor's catalogue never speaks for an organisation's own prefix; a grant never
            // speaks for anything else.
            var publishers = seams.cataloguePublishers().filter { !$0.id.hasPrefix(OfficeBulk.publisherPrefix) }
            if let granted = grantedPublisher(entry.publisherID, held: held, now: now) { publishers.append(granted) }
            let prepared = try OfficeManualImport.prepare(
                assignment: verified, archive: archive, publishers: publishers,
                maximumInflatedBytes: seams.maximumInflatedBytes, receivedAt: seams.clock())
            try await seams.install(prepared)
        } catch {
            // Installed nothing: left where it is, recorded once, and no further receipt.
            try update(assignmentID) {
                $0.state = .refused
                $0.reason = Self.bounded(Self.reason(error))
            }
            return
        }
        try update(assignmentID) {
            $0.state = .installed
            $0.installedAt = now
        }
        try await giveReceipts(assignmentID)
    }

    // MARK: Receipts

    /// Publish the receipts an assignment is owed and does not have: *received* once it is
    /// committed, *installed* once its archive is.
    private func giveReceipts(_ assignmentID: String) async throws {
        guard let entry = ledger.entries.first(where: { $0.assignmentID == assignmentID }) else { return }
        var owed: [(OfficeBulk.Outcome, Int64)] = [(.received, entry.receivedAt)]
        if entry.state == .installed, let at = entry.installedAt { owed.append((.installed, at)) }
        for (outcome, at) in owed where !entry.receiptsPublished.contains(outcome.rawValue) {
            guard let payload = Data(base64Encoded: try await seams.transport.assignmentReceiptPayload(
                      assignmentID: assignmentID, outcome: outcome.rawValue, at: at)),
                  let receipt = OfficeBulk.receiptPayload(payload),
                  receipt.assignmentID == entry.assignmentID, receipt.assignmentSHA256 == entry.payloadSHA256,
                  receipt.enrolmentID == entry.enrolmentID, receipt.setID == entry.setID,
                  receipt.sequence == entry.sequence, receipt.archiveSHA256 == entry.archiveSHA256,
                  receipt.outcome == outcome.rawValue else { throw Failure.notWhatWasAskedFor }
            let signature: String
            if let kept = ledger.entries.first(where: { $0.assignmentID == assignmentID })?.signatures[outcome.rawValue] {
                signature = kept
            } else {
                signature = try await seams.sign(payload).base64EncodedString()
                try update(assignmentID) { $0.signatures[outcome.rawValue] = signature }
            }
            _ = try await seams.transport.publishAssignmentReceipt(
                assignmentID: assignmentID, outcome: outcome.rawValue, signatureBase64: signature)
            try update(assignmentID) { $0.receiptsPublished.append(outcome.rawValue) }
        }
    }

    // MARK: - The record

    private func isRefused(_ digest: String) -> Bool { ledger.refused.contains { $0.digest == digest } }

    private func refuse(_ digest: String, _ error: Error) throws {
        guard !isRefused(digest) else { return }
        var next = ledger
        next.refused.append(Refused(digest: digest, reason: Self.bounded(String(describing: error))))
        if next.refused.count > Self.maximumRefused {
            next.refused.removeFirst(next.refused.count - Self.maximumRefused)
        }
        try commit(next)
    }

    private func update(_ assignmentID: String, _ change: (inout Entry) -> Void) throws {
        guard let index = ledger.entries.firstIndex(where: { $0.assignmentID == assignmentID }) else { return }
        var next = ledger
        change(&next.entries[index])
        try commit(next)
    }

    /// Saved first: what is in memory is never ahead of what is on disk.
    private func commit(_ next: Ledger) throws {
        guard next != ledger else { return }
        try seams.save(next)
        ledger = next
    }

    // MARK: - Pure

    /// Whether large content may move now: straight to the office, on a network the system does
    /// not call expensive (cellular, a personal hotspot). A relayed route never carries it unasked.
    static func bulkAllowed(route: OfficeFieldConnectionPolicy.Route, expensive: Bool) -> Bool {
        route == .direct && !expensive
    }

    static func scope(_ held: OfficeCheckIn.Held, setID: String) -> String {
        [held.organizationID, held.enrolmentID, setID].joined(separator: "\u{0}")
    }

    static func bounded(_ reason: String) -> String { String(reason.prefix(maximumReasonCharacters)) }

    /// Why a manual was not installed, in words for the technician. Never the archive's own.
    static func reason(_ error: Error) -> String {
        switch error {
        case OfficeManualImport.Refusal.publisherNotVerified:
            return "The manual isn't signed by a publisher this phone can check."
        case OfficeManualImport.Refusal.archiveDoesNotMatchAssignment:
            return "What arrived isn't the manual the office assigned."
        case OfficeManualImport.Refusal.assignmentNotCurrentlyValid, OfficeManualAssignment.Refusal.notCurrentlyValid:
            return "The assignment ran out before the manual arrived. The office can assign it again."
        case is OfficeManualImport.Refusal, is OfficeManualAssignment.Refusal:
            return "The manual the office assigned can't be opened safely."
        default:
            return "The manual couldn't be installed on this phone."
        }
    }

    private static func wantedJSON(_ entries: [Entry], attachments: [JobNeeds.Attachment]) throws -> String {
        // Attachments first: within the folder, small things before a manual archive.
        let items = attachments.map { ["kind": "attachment", "sha256": $0.sha256, "bytes": $0.bytes] as [String: Any] }
            + entries.map { ["kind": "vault", "sha256": $0.archiveSHA256, "bytes": $0.archiveBytes] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: items), as: UTF8.self)
    }

    /// Space left alone beyond the manual itself, so taking one never fills the phone.
    static let spaceMargin: Int64 = 100 * 1_048_576

    /// Whether there is room for a manual: its archive, and the same twice over for what it
    /// unpacks to — the proportion this phone's own ceilings on a manual allow. A phone that
    /// will not say how much is free is not held back.
    static func fits(archiveBytes: Int64, free: Int64?) -> Bool {
        guard let free else { return true }
        return free - spaceMargin >= archiveBytes * 3
    }

    static func rows(_ ledger: Ledger, offered: Set<String>, allowed: Bool, noRoom: Set<String> = []) -> [Row] {
        ledger.entries.map { entry in
            let state: Row.State
            switch entry.state {
            case .installed: state = .installed
            case .refused: state = .notInstalled(entry.reason ?? "")
            case .received:
                if noRoom.contains(entry.archiveSHA256) {
                    state = .notEnoughSpace
                } else if !offered.contains(entry.archiveSHA256) {
                    state = .waitingForOffice
                } else {
                    state = allowed ? .downloading : .waitingForWiFi
                }
            }
            return Row(id: entry.assignmentID, vaultID: entry.vaultID, vaultVersion: entry.vaultVersion, state: state)
        }
    }

    /// Where a manual set a job names stands: installed under an assignment, on its way, or
    /// assigned by nobody yet. A job never authorises a manual; it only says it needs one.
    enum SetStanding: Equatable, Sendable {
        case ready
        case onItsWay
        case notYetAvailable
    }

    func standing(ofSet setID: String) -> SetStanding {
        let entries = ledger.entries.filter { $0.setID == setID }
        if entries.contains(where: { $0.state == .installed }) { return .ready }
        if entries.contains(where: { $0.state == .received }) { return .onItsWay }
        return .notYetAvailable
    }

    /// The words for one assigned manual. A manual is "ready" only once it is installed; nothing
    /// here says delivered for a finished transfer.
    static func status(_ row: Row) -> OfficeFieldConnectionPolicy.Status {
        let name = "Manual \(row.vaultID) \(row.vaultVersion)"
        switch row.state {
        case .waitingForOffice:
            return .init(title: name, detail: "Waiting for the office to send it.", systemImage: "clock")
        case .waitingForWiFi:
            return .init(title: name, detail: "Waiting for Wi-Fi.", systemImage: "wifi.exclamationmark")
        case .downloading:
            return .init(title: name, detail: "Still downloading.", systemImage: "arrow.down.circle")
        case .notEnoughSpace:
            return .init(title: name, detail: "Not enough space on this phone. Free some space and it will download.",
                         systemImage: "externaldrive.badge.exclamationmark")
        case .installed:
            return .init(title: name, detail: "Ready.", systemImage: "checkmark.circle")
        case .notInstalled(let reason):
            return .init(title: name, detail: reason.isEmpty ? "Not installed." : reason,
                         systemImage: "exclamationmark.triangle")
        }
    }
}

extension OfficeManualService {
    nonisolated static func defaultLedgerFile() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("manuals.json")
    }

    /// A missing or unreadable record reads as empty. The set marks go with it, so an assignment
    /// already taken would be taken again; the installer still refuses what it will not install.
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

/// The app's wiring: the pairing gate, the existing installer, and a file for the record.
extension OfficeManualService.Seams {
    @MainActor
    static func app(transport: any OfficeManagedFolderTransport,
                    pairing: @escaping @MainActor () -> OfficePairingService = { OfficePairingService() },
                    manager: OrgProfileManager = .shared,
                    ledgerFile: URL? = OfficeManualService.defaultLedgerFile()) -> Self {
        var seams = Self(
            transport: transport,
            held: {
                guard let held = OfficeCheckIn.Held(try await pairing().currentApprovedPeer()) else {
                    throw OfficePeerBinding.Refusal.invalidFields
                }
                return held
            },
            install: { _ = try await VaultLinkInstaller.install($0.vaultImportRequest) })
        seams.policyExpiry = { manager.profile?.policyExpiry }
        if let ledgerFile {
            seams.load = { OfficeManualService.readLedger(ledgerFile) }
            seams.save = { try OfficeManualService.writeLedger($0, to: ledgerFile) }
        }
        return seams
    }
}
