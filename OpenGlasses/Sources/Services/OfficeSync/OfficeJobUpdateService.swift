import Foundation

/// Keeps the updates an office sends about jobs this phone has (Contracts/job-updates.md).
///
/// On each pass over what the office has put in the managed folders, an update that verifies
/// against the binding held now is committed to this phone's own record, under its job and
/// sequence, and receipted. The receipt says the phone has it; nothing here says anyone read
/// it. An update is shown on its job when the technician opens the job, newest first.
///
/// **Information only.** An update never edits a job, starts or pauses one, raises anything
/// that interrupts, or reaches a model: its text is the office's words, shown as such.
///
/// No engine, key or trust chain of its own: everything it touches is a seam, so it runs
/// headless.
@MainActor
final class OfficeJobUpdateService: ObservableObject {

    struct Entry: Codable, Equatable, Sendable, Identifiable {
        let update: OfficeJobUpdate.Update
        /// SHA-256 of the decoded payload: what the receipt names, and what a second update at
        /// the same job and sequence is compared with.
        let payloadSHA256: String
        /// SHA-256 of the envelope file, so the same file is not read twice.
        let envelopeSHA256: String
        /// The exact envelope, kept so what was shown can be shown to be what was signed.
        let envelope: Data
        /// What this phone held for the job when it committed the update.
        let jobState: OfficeJobUpdate.JobState
        let receivedAt: Int64
        /// When the technician first had the job open with this update on it.
        var openedAt: Int64?
        /// The receipt's signature, kept so the same receipt is published again.
        var signature: String?
        var receiptPublished = false

        var id: String { update.updateID }
    }

    struct Refused: Codable, Equatable, Sendable {
        let digest: String
        let reason: String
    }

    struct Ledger: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry] = []
        var refused: [Refused] = []
    }

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        /// The binding held, from the pairing gate passing at this moment.
        var trust: @MainActor () async throws -> OfficeJobUpdate.Trust
        /// What this phone holds for an office job identifier now.
        var jobState: @MainActor (String) -> OfficeJobUpdate.JobState = { _ in .unknown }
        var sign: (Data) async throws -> Data = { try await OfficePhoneIdentity.shared.signJobUpdateReceipt($0) }
        var clock: () -> Date = Date.init
        var load: () -> Ledger = { Ledger() }
        var save: (Ledger) throws -> Void = { _ in }
    }

    enum Failure: Error, Equatable {
        /// The transport offered bytes that are not the receipt asked for.
        case notWhatWasAskedFor
    }

    static let maximumEntries = 200
    static let maximumPerJob = 50
    static let maximumRefused = 64
    static let maximumReasonCharacters = 200

    /// Every update kept, for a screen to watch.
    @Published private(set) var entries: [Entry] = []
    private var ledger: Ledger { didSet { entries = ledger.entries } }

    private let seams: Seams
    private var sweeping = false

    init(seams: Seams) {
        self.seams = seams
        ledger = seams.load()
        entries = ledger.entries
    }

    // MARK: - Taking in

    /// One pass. Safe to repeat: a pass that is still running is not joined by a second.
    func sweep() async throws {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let now = Int64(seams.clock().timeIntervalSince1970)
        try? prune(now: now)
        let pending = try OfficeManagedFolders.decodeUpdatesPending(try await seams.transport.jobUpdatesPending())
        // What is still to do: a file not seen before, or an update kept and not yet receipted.
        let work = pending.compactMap { item -> (item: OfficeManagedFolders.PendingEnvelope, data: Data)? in
            guard let data = Data(base64Encoded: item.envelope) else { return nil }
            let digest = OfficeJobUpdate.digest(data)
            if isRefused(digest) { return nil }
            if let known = ledger.entries.first(where: { $0.envelopeSHA256 == digest }), known.receiptPublished {
                return nil
            }
            return (item, data)
        }
        guard !work.isEmpty else { return }
        // The gate first: nothing is taken in on a pairing that does not verify now.
        let trust = try await seams.trust()
        var firstFailure: Error?
        for (item, data) in work {
            do {
                if let updateID = try take(item, data: data, trust: trust, now: now) {
                    try await giveReceipt(updateID)
                }
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// Commits one update, or finds it already kept. Returns its identifier when a receipt is
    /// owed, nil when it was refused or is waiting.
    private func take(_ item: OfficeManagedFolders.PendingEnvelope, data: Data,
                      trust: OfficeJobUpdate.Trust, now: Int64) throws -> String? {
        let digest = OfficeJobUpdate.digest(data)
        let verified: OfficeJobUpdate.Verified
        do {
            verified = try OfficeJobUpdate.read(data, trust: trust, now: now)
        } catch OfficeJobUpdate.Refusal.notCurrentlyValid {
            return nil   // it waits
        } catch {
            try refuse(digest, error)
            return nil
        }
        let update = verified.payload
        guard update.updateID == item.id else {
            try refuse(digest, OfficeJobUpdate.Refusal.invalidFields)
            return nil
        }
        let held = ledger.entries.first { $0.update.jobID == update.jobID && $0.update.sequence == update.sequence }
        switch OfficeJobUpdate.standing(heldSHA256: held?.payloadSHA256, arriving: verified) {
        case .same:
            return held?.update.updateID
        case .conflict:
            // The first stays. This one is recorded once and gets no receipt.
            try refuse(digest, OfficeJobUpdate.Refusal.invalidFields)
            return nil
        case .new:
            break
        }
        var next = ledger
        // An identifier is never reused: one already kept under other bytes is refused.
        guard !next.entries.contains(where: { $0.update.updateID == update.updateID }) else {
            try refuse(digest, OfficeJobUpdate.Refusal.invalidFields)
            return nil
        }
        guard Self.makeRoom(in: &next, forJob: update.jobID) else { return nil }   // it waits
        next.entries.append(Entry(update: update, payloadSHA256: verified.payloadSHA256, envelopeSHA256: digest,
                                  envelope: data, jobState: seams.jobState(update.jobID), receivedAt: now))
        try commit(next)
        return update.updateID
    }

    /// The receipt for an update this phone has committed, signed once and published once.
    private func giveReceipt(_ updateID: String) async throws {
        guard let entry = ledger.entries.first(where: { $0.update.updateID == updateID }),
              !entry.receiptPublished else { return }
        guard let payload = Data(base64Encoded: try await seams.transport.jobUpdateReceiptPayload(
                  updateID: updateID, jobState: entry.jobState.rawValue, at: entry.receivedAt)),
              let receipt = OfficeJobUpdate.receiptPayload(payload),
              receipt.updateID == updateID, receipt.updateSHA256 == entry.payloadSHA256,
              receipt.enrolmentID == entry.update.enrolmentID, receipt.jobID == entry.update.jobID,
              receipt.sequence == entry.update.sequence else { throw Failure.notWhatWasAskedFor }
        let signature: String
        if let kept = entry.signature {
            signature = kept
        } else {
            signature = try await seams.sign(payload).base64EncodedString()
            try change(updateID) { $0.signature = signature }
        }
        _ = try await seams.transport.publishJobUpdateReceipt(updateID: updateID, signatureBase64: signature)
        try change(updateID) { $0.receiptPublished = true }
    }

    // MARK: - On the job

    /// The updates on one office job, newest first.
    func updates(forJob jobID: String) -> [Entry] {
        ledger.entries.filter { $0.update.jobID == jobID }.sorted { $0.update.sequence > $1.update.sequence }
    }

    /// How many of a job's updates the technician has not had open yet.
    func unopened(forJob jobID: String) -> Int {
        ledger.entries.filter { $0.update.jobID == jobID && $0.openedAt == nil }.count
    }

    /// The technician has the job open with its updates on it.
    func markOpened(jobID: String) {
        guard unopened(forJob: jobID) > 0 else { return }
        let now = Int64(seams.clock().timeIntervalSince1970)
        var next = ledger
        for index in next.entries.indices where next.entries[index].update.jobID == jobID
            && next.entries[index].openedAt == nil {
            next.entries[index].openedAt = now
        }
        try? commit(next)
    }

    /// Everything kept, for leaving the organisation.
    func removeAll() {
        try? commit(Ledger())
    }

    // MARK: - The record

    /// An update whose job this phone does not hold is dropped once it has run out.
    private func prune(now: Int64) throws {
        var next = ledger
        next.entries.removeAll { $0.update.expiresAt <= now && seams.jobState($0.update.jobID) == .unknown }
        try commit(next)
    }

    private func isRefused(_ digest: String) -> Bool { ledger.refused.contains { $0.digest == digest } }

    private func refuse(_ digest: String, _ error: Error) throws {
        guard !isRefused(digest) else { return }
        var next = ledger
        next.refused.append(Refused(digest: digest,
                                    reason: String(String(describing: error).prefix(Self.maximumReasonCharacters))))
        if next.refused.count > Self.maximumRefused {
            next.refused.removeFirst(next.refused.count - Self.maximumRefused)
        }
        try commit(next)
    }

    private func change(_ updateID: String, _ change: (inout Entry) -> Void) throws {
        guard let index = ledger.entries.firstIndex(where: { $0.update.updateID == updateID }) else { return }
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

    /// Makes room for one more update on a job, by letting go of the oldest update the
    /// technician has already had open. False when there is none to let go: the arriving update
    /// then waits in the office's folder, unreceipted, rather than pushing out one nobody has seen.
    static func makeRoom(in ledger: inout Ledger, forJob jobID: String) -> Bool {
        func dropOldestOpened(where matches: (Entry) -> Bool) -> Bool {
            let candidates = ledger.entries.enumerated().filter { $0.element.openedAt != nil && matches($0.element) }
            guard let oldest = candidates.min(by: { $0.element.receivedAt < $1.element.receivedAt }) else { return false }
            ledger.entries.remove(at: oldest.offset)
            return true
        }
        if ledger.entries.filter({ $0.update.jobID == jobID }).count >= maximumPerJob,
           !dropOldestOpened(where: { $0.update.jobID == jobID }) { return false }
        if ledger.entries.count >= maximumEntries, !dropOldestOpened(where: { _ in true }) { return false }
        return true
    }

    /// What this phone holds for an office job identifier: a job ahead or started and not
    /// finished is held; one only finished is finished; anything else is unknown.
    static func jobState(_ jobID: String, ahead: [String],
                         started: [(jobID: String, finished: Bool)]) -> OfficeJobUpdate.JobState {
        if ahead.contains(jobID) || started.contains(where: { $0.jobID == jobID && !$0.finished }) { return .held }
        return started.contains { $0.jobID == jobID } ? .finished : .unknown
    }

    /// The words for one update, for the job's screen. The body is the office's own text.
    static func status(_ update: OfficeJobUpdate.Update,
                       date: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> OfficeFieldConnectionPolicy.Status {
        func joined(_ lines: [String]) -> String? {
            let kept = lines.filter { !$0.isEmpty }
            return kept.isEmpty ? nil : kept.joined(separator: "\n")
        }
        switch OfficeJobUpdate.UpdateKind(rawValue: update.updateKind) {
        case .parts?:
            let title = update.quantity > 0 ? "\(update.part) × \(update.quantity)" : update.part
            var state = partStateWords(update.partState)
            if !update.expectedOn.isEmpty { state += ", expected \(update.expectedOn)" }
            return .init(title: title, detail: joined([state + ".", update.body]), systemImage: "shippingbox")
        case .schedule?:
            var when = date(Date(timeIntervalSince1970: TimeInterval(update.scheduledFor)))
            if update.scheduledUntil > 0 {
                when += " to " + date(Date(timeIntervalSince1970: TimeInterval(update.scheduledUntil)))
            }
            return .init(title: "New time from the office", detail: joined([when, update.body]),
                         systemImage: "calendar.badge.clock")
        case .note?, nil:
            return .init(title: "Note from the office",
                         detail: update.body.isEmpty ? "An update this version of the app can't show in full." : update.body,
                         systemImage: "text.bubble")
        }
    }

    static func partStateWords(_ state: String) -> String {
        switch state {
        case "ordered": return "Ordered"
        case "dispatched": return "Dispatched"
        case "arrived": return "Arrived"
        case "substituted": return "Substituted"
        case "unavailable": return "Unavailable"
        default: return "Updated"
        }
    }
}

extension OfficeJobUpdateService {
    nonisolated static func defaultLedgerFile() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("job-updates.json")
    }

    /// A missing or unreadable record reads as empty: an update still in the office's folder is
    /// taken again, and receipted with the receipt the transport already built.
    nonisolated static func readLedger(_ file: URL) -> Ledger {
        guard let data = try? Data(contentsOf: file),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.version == 1 else { return Ledger() }
        return ledger
    }

    nonisolated static func writeLedger(_ ledger: Ledger, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var folder = file.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try JSONEncoder().encode(ledger).write(
            to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The app's wiring: the pairing gate and a file for the record.
extension OfficeJobUpdateService.Seams {
    @MainActor
    static func app(transport: any OfficeManagedFolderTransport,
                    pairing: @escaping @MainActor () -> OfficePairingService = { OfficePairingService() },
                    ledgerFile: URL? = OfficeJobUpdateService.defaultLedgerFile()) -> Self {
        var seams = Self(
            transport: transport,
            trust: {
                let binding = try await pairing().currentApprovedPeer().binding.payload
                guard let officeKey = Data(base64Encoded: binding.officeApplicationKey) else {
                    throw OfficePeerBinding.Refusal.invalidFields
                }
                return OfficeJobUpdate.Trust(
                    organizationID: binding.organizationID, enrolmentID: binding.enrolmentID,
                    officeID: binding.officeID, generation: binding.generation,
                    officeTransportID: binding.officeTransportID, phoneTransportID: binding.phoneTransportID,
                    officeApplicationKey: officeKey)
            })
        if let ledgerFile {
            seams.load = { OfficeJobUpdateService.readLedger(ledgerFile) }
            seams.save = { try OfficeJobUpdateService.writeLedger($0, to: ledgerFile) }
        }
        return seams
    }
}
