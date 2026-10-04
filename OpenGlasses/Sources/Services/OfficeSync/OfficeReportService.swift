import Foundation

/// Sends a technician's record to the office over the managed folders, and knows how much of it
/// the office has (Contracts/office-reports.md).
///
/// For each record handed over it builds the attachment manifest and the report, signs the
/// report with the phone application key, publishes it with its record and manifest, and then
/// publishes each attachment. On each pass it reads the office's receipts: only a receipt that
/// verifies for exactly the report published changes anything, and only upwards — evidence
/// pending, record accepted, fully accepted. A finished transfer, a connection, or no answer at
/// all delivers nothing: a report with no receipt is waiting, however long that is.
///
/// A record sent again is a new operation and a higher revision; a lower revision the office has
/// not yet accepted is withdrawn when the higher one is published. A report is withdrawn from the
/// folders once it is fully accepted.
///
/// No engine, key or trust chain of its own: everything it touches is a seam, so it runs
/// headless.
@MainActor
final class OfficeReportService: ObservableObject {

    /// One attachment and where its exact bytes are kept on this phone.
    struct Evidence: Equatable, Sendable {
        let attachment: OfficeReport.Attachment
        let file: URL
    }

    /// One record to send.
    struct Submission: Sendable {
        /// The queued operation: new for every send.
        let operationID: String
        let recordKind: OfficeReport.RecordKind
        /// What the record is about, stable across sends: the job session, or the parts request.
        let recordID: String
        let jobReference: String
        /// The office's own identifier and revision of the job, from a format-2 job file.
        let jobID: String
        let jobRevision: Int64
        /// The record's exact bytes.
        let record: Data
        let evidence: [Evidence]
        let transcript: OfficeReport.Transcript
        let createdAt: Date
    }

    /// Where one operation stands.
    enum Status: Equatable, Sendable {
        /// Published, or not yet possible to publish; the office has said nothing.
        case waiting
        /// The office has the record; at least one required attachment is still to arrive.
        case evidencePending
        /// The office has the record and every required attachment: delivered.
        case recordAccepted
        /// The office has everything the report named.
        case fullyAccepted
        /// A later revision of the same record was published before this one was accepted.
        case superseded

        /// Whether the record counts as delivered to the office.
        var isDelivered: Bool { self == .recordAccepted || self == .fullyAccepted }
    }

    struct Entry: Codable, Equatable, Sendable {
        let operationID: String
        let reportID: String
        let recordKind: String
        let recordID: String
        let enrolmentID: String
        let revision: Int64
        /// The exact bytes signed, and the signature, kept so the same report is published again.
        var payload: Data
        var signature: String?
        let recordSHA256: String
        let manifest: Data
        /// Each attachment's digest and the file its bytes are in.
        var files: [String: String]
        var attachmentsPublished: [String]
        /// The exact envelope in the folder, which is what a receipt names. Nil until published.
        var published: Data?
        var outcome: OfficeReport.Outcome?
        var superseded: Bool
        var withdrawn: Bool
    }

    /// The durable record. It lives outside the transport.
    struct Ledger: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry] = []
        /// The highest revision used for each record, by enrolment, kind and record identifier.
        var revisions: [String: Int64] = [:]
    }

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        /// The binding held, from the pairing gate passing at this moment.
        var held: @MainActor () async throws -> OfficeCheckIn.Held
        var sign: (Data) async throws -> Data = { try await OfficePhoneIdentity.shared.signOfficeReport($0) }
        var load: () -> Ledger = { Ledger() }
        var save: (Ledger) throws -> Void = { _ in }
    }

    enum Failure: Error, Equatable {
        /// The record or its evidence cannot be a report: too large, or outside the contract's
        /// rules. Sending it again will not help.
        case notReportable(String)
        /// The transport published something other than the report asked for.
        case notWhatWasAskedFor
    }

    static let maximumEntries = 200

    /// What is still on its way, for a screen.
    struct Summary: Equatable, Sendable {
        /// Reports the office has said nothing about.
        var waiting = 0
        /// Reports whose record the office has, and whose required documents it does not.
        var evidencePending = 0
    }

    /// Bumped whenever a report's standing changes, for whatever is waiting on it.
    @Published private(set) var changes = 0
    @Published private(set) var summary = Summary()
    private(set) var ledger: Ledger

    private let seams: Seams
    private var busy = false

    init(seams: Seams) {
        self.seams = seams
        ledger = seams.load()
        summary = Self.summary(of: ledger)
    }

    // MARK: - Reading

    func status(operationID: String) -> Status? {
        ledger.entries.first { $0.operationID == operationID }.map(Self.status)
    }

    /// How many reports for these records the office has not fully accepted. What an organisation's
    /// erase-after-delivery rule waits on: zero means everything they named is at the office.
    func notFullyAccepted(recordIDs: Set<String>) -> Int {
        ledger.entries.filter { recordIDs.contains($0.recordID) && !$0.superseded && $0.outcome != .fullyAccepted }.count
    }

    /// Operations whose documents are no longer owed: the office has all of them, or a later
    /// report replaced the one that named them.
    var settledOperationIDs: Set<String> {
        Set(ledger.entries.filter { $0.superseded || $0.outcome == .fullyAccepted }.map(\.operationID))
    }

    /// Drop what this phone holds about these records: for a phone leaving its organisation, once
    /// the records themselves are erased. Nothing is withdrawn from the office.
    func forget(recordIDs: Set<String>) {
        var next = ledger
        next.entries.removeAll { recordIDs.contains($0.recordID) }
        try? commit(next)
    }

    static func summary(of ledger: Ledger) -> Summary {
        var summary = Summary()
        for entry in ledger.entries where !entry.superseded {
            switch entry.outcome {
            case nil: summary.waiting += 1
            case .evidencePending?: summary.evidencePending += 1
            case .recordAccepted?, .fullyAccepted?: break
            }
        }
        return summary
    }

    /// The words for what is still on its way. Nil when nothing is. A record is "with the office"
    /// only on its receipt; nothing here says sent or delivered for a finished transfer.
    static func status(_ summary: Summary) -> OfficeFieldConnectionPolicy.Status? {
        if summary.waiting > 0 {
            return .init(title: summary.waiting == 1 ? "1 record for the office" : "\(summary.waiting) records for the office",
                         detail: "Kept on this phone until the office confirms it has them.",
                         systemImage: "tray.and.arrow.up")
        }
        if summary.evidencePending > 0 {
            return .init(title: summary.evidencePending == 1 ? "The office has 1 record" : "The office has \(summary.evidencePending) records",
                         detail: "Their documents are still on the way.",
                         systemImage: "doc.badge.clock")
        }
        return nil
    }

    static func status(_ entry: Entry) -> Status {
        if entry.superseded { return .superseded }
        switch entry.outcome {
        case .fullyAccepted?: return .fullyAccepted
        case .recordAccepted?: return .recordAccepted
        case .evidencePending?: return .evidencePending
        case nil: return .waiting
        }
    }

    // MARK: - Sending

    /// Publish the report for one record, or publish it again. Safe to repeat: one operation is
    /// one report, whatever it is asked. Throws when nothing could be published now — the gate
    /// does not pass, or the folders are closed — and the caller waits.
    @discardableResult
    func submit(_ submission: Submission) async throws -> Status {
        // One at a time: two passes interleaved could each take the same revision.
        while busy { try await Task.sleep(nanoseconds: 5_000_000) }
        busy = true
        defer { busy = false }
        let held = try await seams.held()
        if let known = ledger.entries.first(where: { $0.operationID == submission.operationID }) {
            guard known.enrolmentID == held.enrolmentID else {
                throw Failure.notReportable("This record was sent under another enrolment.")
            }
            if !known.superseded, known.outcome != .fullyAccepted {
                try await publish(known.operationID, record: submission.record, held: held)
            }
            return status(operationID: submission.operationID) ?? .waiting
        }

        guard let manifest = OfficeReport.manifestBytes(submission.evidence.map(\.attachment)) else {
            throw Failure.notReportable("The evidence for this record can't be listed for the office.")
        }
        guard submission.record.count <= OfficeReport.maximumRecordBytes, !submission.record.isEmpty else {
            throw Failure.notReportable("The record is too large to send to the office.")
        }
        let key = Self.revisionKey(enrolmentID: held.enrolmentID, kind: submission.recordKind,
                                   recordID: submission.recordID)
        let revision = (ledger.revisions[key] ?? 0) + 1
        guard let report = OfficeReport.report(
                operationID: submission.operationID, recordKind: submission.recordKind,
                recordID: submission.recordID, revision: revision,
                identity: OfficeReport.Identity(held), jobReference: submission.jobReference,
                jobID: submission.jobID, jobRevision: submission.jobRevision, record: submission.record,
                manifest: manifest, transcript: submission.transcript,
                createdAt: Int64(submission.createdAt.timeIntervalSince1970)),
              OfficeReport.transcriptAgrees(report, attachments: submission.evidence.map(\.attachment)),
              let payload = OfficeReport.payloadBytes(report) else {
            throw Failure.notReportable("This record can't be written as a report for the office.")
        }
        // The revision is taken, and the report's exact bytes kept, before anything is signed.
        var next = ledger
        next.revisions[key] = revision
        next.entries.append(Entry(
            operationID: submission.operationID, reportID: report.reportID,
            recordKind: submission.recordKind.rawValue, recordID: submission.recordID,
            enrolmentID: held.enrolmentID, revision: revision, payload: payload, signature: nil,
            recordSHA256: report.recordSHA256, manifest: manifest,
            files: Dictionary(submission.evidence.map { ($0.attachment.sha256, $0.file.path) },
                              uniquingKeysWith: { first, _ in first }),
            attachmentsPublished: [], published: nil, outcome: nil, superseded: false, withdrawn: false))
        Self.trim(&next)
        try commit(next)

        try await publish(submission.operationID, record: submission.record, held: held)
        try await supersedeEarlier(than: submission.operationID)
        return status(operationID: submission.operationID) ?? .waiting
    }

    /// Sign (once), publish the report with its record and manifest, then each attachment.
    private func publish(_ operationID: String, record: Data, held: OfficeCheckIn.Held) async throws {
        guard let entry = ledger.entries.first(where: { $0.operationID == operationID }) else { return }
        guard OfficeReport.digest(record) == entry.recordSHA256 else {
            throw Failure.notReportable("The record has changed since its report was written.")
        }
        let signature: String
        if let kept = entry.signature {
            signature = kept
        } else {
            signature = try await seams.sign(entry.payload).base64EncodedString()
            try update(operationID) { $0.signature = signature }
        }
        let published = Data(try await seams.transport.publishReport(
            payloadBase64: entry.payload.base64EncodedString(), signatureBase64: signature,
            recordBase64: record.base64EncodedString(),
            manifestBase64: entry.manifest.base64EncodedString()).utf8)
        // What is in the folder is this phone's report for this record and manifest. A report
        // published before this record of it was written is the same report, and it is the one
        // the office's receipt names.
        guard let report = try? OfficeReport.report(published, phoneApplicationKey: held.phoneApplicationKey,
                                                    identity: OfficeReport.Identity(held)),
              report.reportID == entry.reportID, report.recordSHA256 == entry.recordSHA256,
              report.manifestSHA256 == OfficeReport.digest(entry.manifest) else {
            throw Failure.notWhatWasAskedFor
        }
        guard let envelope = try? JSONDecoder().decode(OfficeReport.Envelope.self, from: published),
              let payload = Data(base64Encoded: envelope.payload) else { throw Failure.notWhatWasAskedFor }
        try update(operationID) {
            $0.payload = payload
            $0.signature = envelope.signature
            $0.published = published
            $0.withdrawn = false
        }
        try await publishAttachments(operationID)
    }

    /// Publish whatever evidence is not in the folder yet. One that cannot be published now — its
    /// file is not there, the folders have closed — is tried on the next pass; the rest still go.
    private func publishAttachments(_ operationID: String) async throws {
        guard let entry = ledger.entries.first(where: { $0.operationID == operationID }),
              entry.published != nil, !entry.withdrawn else { return }
        var firstFailure: Error?
        for (digest, path) in entry.files.sorted(by: { $0.key < $1.key })
        where !entry.attachmentsPublished.contains(digest) {
            do {
                try await seams.transport.publishReportAttachment(sha256: digest, path: path)
                try update(operationID) { $0.attachmentsPublished.append(digest) }
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// A lower revision of the same record that the office has not accepted is withdrawn: the
    /// higher one says everything it said.
    private func supersedeEarlier(than operationID: String) async throws {
        guard let latest = ledger.entries.first(where: { $0.operationID == operationID }) else { return }
        for earlier in ledger.entries
        where earlier.operationID != operationID && earlier.recordKind == latest.recordKind
            && earlier.recordID == latest.recordID && earlier.enrolmentID == latest.enrolmentID
            && earlier.revision < latest.revision && !earlier.superseded
            && !(earlier.outcome.map { $0 >= .recordAccepted } ?? false) {
            try update(earlier.operationID) { $0.superseded = true }
            try await withdraw(earlier.operationID)
        }
    }

    private func withdraw(_ operationID: String) async throws {
        guard let entry = ledger.entries.first(where: { $0.operationID == operationID }),
              !entry.withdrawn else { return }
        try await seams.transport.withdrawReport(reportID: entry.reportID)
        try update(operationID) { $0.withdrawn = true }
    }

    // MARK: - Receipts

    /// One pass over the office's receipts, and over evidence still to publish. Returns whether
    /// any report's standing changed. Safe to repeat.
    @discardableResult
    func sweep() async throws -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let before = ledger
        var firstFailure: Error?
        let listed = try OfficeManagedFolders.decodeReportReceipts(try await seams.transport.reportReceipts())
        let open = ledger.entries.filter { !$0.superseded && !$0.withdrawn && $0.published != nil }
        if !listed.isEmpty || !open.isEmpty {
            // The gate first: a receipt is read against the binding that verifies now.
            let held = try await seams.held()
            for receipt in listed {
                do {
                    try take(receipt, held: held)
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }
            for entry in ledger.entries where !entry.superseded && !entry.withdrawn {
                do {
                    if entry.outcome == .fullyAccepted {
                        // Nothing more is owed: its files leave the folder.
                        try await withdraw(entry.operationID)
                    } else {
                        try await publishAttachments(entry.operationID)
                    }
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }
        }
        let changed = ledger.entries.map(Self.status) != before.entries.map(Self.status)
        if changed { changes += 1 }
        if let firstFailure { throw firstFailure }
        return changed
    }

    /// A receipt changes a report's standing only when it verifies for exactly the report this
    /// phone published, and only upwards: an outcome is never withdrawn.
    private func take(_ listed: OfficeManagedFolders.ReportReceipt, held: OfficeCheckIn.Held) throws {
        guard let entry = ledger.entries.first(where: {
                  $0.reportID == listed.reportID && $0.enrolmentID == held.enrolmentID && !$0.superseded
              }),
              let envelope = entry.published,
              let data = Data(base64Encoded: listed.envelope),
              let report = OfficeReport.reportPayload(entry.payload),
              let attachments = OfficeReport.manifest(entry.manifest) else { return }
        guard let (_, outcome) = try? OfficeReport.receipt(
                data, officeApplicationKey: held.officeApplicationKey, reportEnvelope: envelope,
                report: report, attachments: attachments),
              outcome.stage == listed.stage,
              entry.outcome.map({ outcome > $0 }) ?? true else { return }
        try update(entry.operationID) { $0.outcome = outcome }
    }

    // MARK: - The record

    private func update(_ operationID: String, _ change: (inout Entry) -> Void) throws {
        guard let index = ledger.entries.firstIndex(where: { $0.operationID == operationID }) else { return }
        var next = ledger
        change(&next.entries[index])
        try commit(next)
    }

    /// Saved first: what is in memory is never ahead of what is on disk.
    private func commit(_ next: Ledger) throws {
        guard next != ledger else { return }
        try seams.save(next)
        ledger = next
        summary = Self.summary(of: next)
    }

    /// Bounded: the oldest settled entries go first. One the office has not fully accepted stays.
    private static func trim(_ ledger: inout Ledger) {
        while ledger.entries.count > maximumEntries,
              let settled = ledger.entries.firstIndex(where: { $0.superseded || $0.outcome == .fullyAccepted }) {
            ledger.entries.remove(at: settled)
        }
    }

    static func revisionKey(enrolmentID: String, kind: OfficeReport.RecordKind, recordID: String) -> String {
        [enrolmentID, kind.rawValue, recordID].joined(separator: "\u{0}")
    }
}

extension OfficeReport.Identity {
    /// The pairing a report is sent under: only from a binding that verified just now.
    init(_ held: OfficeCheckIn.Held) {
        self.init(organizationID: held.organizationID, enrolmentID: held.enrolmentID,
                  officeID: held.officeID, phoneTransportID: held.phoneTransportID)
    }
}

extension OfficeReportService {
    nonisolated static func defaultLedgerFile() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("reports.json")
    }

    /// A missing or unreadable record reads as empty. A record still queued is then sent again as
    /// a new report; the transport's own record of what it published still stands.
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

/// The app's wiring: the pairing gate, and a file for the record.
extension OfficeReportService.Seams {
    @MainActor
    static func app(transport: any OfficeManagedFolderTransport,
                    pairing: @escaping @MainActor () -> OfficePairingService = { OfficePairingService() },
                    ledgerFile: URL? = OfficeReportService.defaultLedgerFile()) -> Self {
        var seams = Self(transport: transport, held: {
            guard let held = OfficeCheckIn.Held(try await pairing().currentApprovedPeer()) else {
                throw OfficePeerBinding.Refusal.invalidFields
            }
            return held
        })
        if let ledgerFile {
            seams.load = { OfficeReportService.readLedger(ledgerFile) }
            seams.save = { try OfficeReportService.writeLedger($0, to: ledgerFile) }
        }
        return seams
    }
}
