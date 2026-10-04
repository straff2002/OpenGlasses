import Foundation

/// Takes each sealed recorded job to the office and keeps it until the office says it has it
/// (Plan HE §4; Contracts/recorded-session.md).
///
/// On each pass, for every bundle on this phone:
///
/// - while the moment is wrong — no Wi-Fi, no power, a medical privacy mode, a pairing that is
///   not current, smaller things waiting — it says why and sends nothing more;
/// - otherwise it publishes the manifest and then the media, a few chunks ahead of what the
///   office has taken, so a recording never has more than that exposed to a route that has
///   stopped being a good one;
/// - **all chunks served is not the office having the recording.** Only the office's own signed
///   receipt, verified here against the binding held and this phone's record of the manifest it
///   sealed, moves a bundle to *acknowledged*;
/// - nothing is removed before that. After it, the media is trimmed once the waiting period has
///   passed; the timeline, transcript, manifest and receipt stay with the job. A recording that
///   waits too long, or that the office refuses, is kept whole and the technician is asked.
///
/// No engine, key or trust chain of its own: everything it touches is a seam, so it runs
/// headless.
@MainActor
final class JobRecordingSyncService: ObservableObject {
    typealias Record = JobRecordingBundleStore.Record

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        var store: JobRecordingBundleStore
        /// The binding held, from the pairing gate passing at this moment.
        var trust: @MainActor () async throws -> OfficeRecordingReceipt.Trust
        /// Whether a recording may be sent now: the network, power, policy and what else is waiting.
        var conditions: @MainActor () -> SyncEligibility.Conditions
        var limits = RetentionDecision.Limits.standard
        /// How many chunks may be in the office's folder beyond what it has taken.
        var chunksAhead = 2
        var clock: () -> Date = Date.init
    }

    /// Where one recording is, for a screen.
    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let sessionID: String
        let phase: BundleSyncState.Phase
        let sentBytes: Int64
        let totalBytes: Int64
        let outcome: JobRecordingBundleStore.Outcome?
    }

    @Published private(set) var rows: [Row] = []

    private let seams: Seams
    private var sweeping = false
    /// Why each waiting recording is waiting, from the last pass. Not kept on disk: it is true
    /// only for as long as the conditions that gave it.
    private var waiting: [String: SyncEligibility.Reason] = [:]

    init(seams: Seams) {
        self.seams = seams
        refresh()
    }

    // MARK: - One pass

    /// One pass over every bundle. Safe to repeat: a pass that is still running is not joined by a
    /// second. Throws the first thing that went wrong, after doing everything else it could.
    func sweep() async throws {
        guard !sweeping else { return }
        sweeping = true
        defer {
            sweeping = false
            refresh()
        }
        let records = seams.store.records()
        guard !records.isEmpty else { return }
        var firstFailure: Error?
        var trust: OfficeRecordingReceipt.Trust?
        // The gate once a pass, and only when something needs it.
        func gate() async throws -> OfficeRecordingReceipt.Trust {
            if let trust { return trust }
            let passed = try await seams.trust()
            trust = passed
            return passed
        }
        let statuses = (try? OfficeManagedFolders.decodeRecordingStatuses(
            try await seams.transport.recordingStatuses())) ?? []
        for record in records {
            do {
                var record = record
                try await takeIn(statuses.filter { $0.bundleID == record.bundleID }, for: &record, gate: gate)
                try await advance(&record, gate: gate)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// What the office has said about one bundle. Each message is verified here and acted on once.
    private func takeIn(_ statuses: [OfficeManagedFolders.RecordingStatus], for record: inout Record,
                        gate: () async throws -> OfficeRecordingReceipt.Trust) async throws {
        for item in statuses {
            guard let envelope = Data(base64Encoded: item.envelope) else { continue }
            let digest = OfficeJobUpdate.digest(envelope)
            guard !record.seenReceipts.contains(digest) else { continue }
            let receipt: OfficeRecordingReceipt.Receipt
            do {
                receipt = try OfficeRecordingReceipt.read(
                    envelope, trust: try await gate(),
                    sent: .init(bundleID: record.bundleID, manifestSHA256: record.manifestSHA256,
                                generation: record.generation))
            } catch is OfficeRecordingReceipt.Refusal {
                continue   // not the office's word about this bundle: it changes nothing
            }
            guard receipt.status == item.status, let status = OfficeRecordingReceipt.Status(rawValue: receipt.status) else {
                continue
            }
            var state = Self.state(of: record)
            switch status {
            case .received:
                guard state.apply(.receipt(.init(bundleID: record.bundleID, manifestSHA256: record.manifestSHA256,
                                                 status: .received))) else { break }
                record.acknowledgedAt = record.acknowledgedAt ?? seams.clock()
                // The office has it: out of the folder, and still listened for.
                try await seams.transport.withdrawRecording(bundleID: record.bundleID, forget: false)
            case .refused:
                guard let reason = BundleSyncState.RefusalReason(rawValue: receipt.reason),
                      state.apply(.receipt(.init(bundleID: record.bundleID, manifestSHA256: record.manifestSHA256,
                                                 status: .refused(reason)))) else { break }
                // Refused, and kept whole. Nothing more of it is served until the technician says.
                try await seams.transport.withdrawRecording(bundleID: record.bundleID, forget: false)
                record.publishedChunks = 0
                record.transferStarted = false
            case .reviewed, .published, .rejected:
                record.outcome = .init(status: receipt.status, vaultID: receipt.vaultID,
                                       vaultVersion: receipt.vaultVersion, at: receipt.at)
            }
            Self.keep(state, in: &record)
            record.seenReceipts.append(digest)
            try seams.store.keepReceipt(record, status: receipt.status, envelope: envelope)
            try seams.store.save(record)
        }
    }

    /// Moves one bundle on as far as this pass can.
    private func advance(_ record: inout Record,
                         gate: () async throws -> OfficeRecordingReceipt.Trust) async throws {
        let now = seams.clock()
        var state = Self.state(of: record)
        let decision = RetentionDecision.decide(state, waitingSince: record.waitingSince,
                                                acknowledgedAt: record.acknowledgedAt, now: now, limits: seams.limits)
        switch record.stage {
        case .trimmed, .failed, .expired:
            waiting[record.bundleID] = nil
            return
        case .acknowledged:
            waiting[record.bundleID] = nil
            guard decision == .trimMedia else { return }
            try seams.store.trimMedia(record)
            state.apply(.mediaTrimmed)
            Self.keep(state, in: &record)
            try seams.store.save(record)
            return
        case .sealed, .delivered:
            break
        }
        if decision == .askTechnician {
            // Too long without a receipt. Nothing is removed, and nothing more is sent, until
            // the technician chooses.
            state.apply(.expiryReached)
            Self.keep(state, in: &record)
            waiting[record.bundleID] = nil
            try seams.store.save(record)
            return
        }
        if case .notEligible(let reason) = SyncEligibility.evaluate(seams.conditions()) {
            waiting[record.bundleID] = reason
            return
        }
        waiting[record.bundleID] = nil
        _ = try await gate()   // nothing is published on a pairing that does not verify now

        let manifest = try seams.store.manifest(record)
        _ = try await seams.transport.publishRecordingManifest(
            payloadBase64: manifest.payload.base64EncodedString(),
            signatureBase64: manifest.signature.base64EncodedString(),
            timelinePath: seams.store.timelineFile(record).path,
            transcriptPath: seams.store.transcriptFile(record).path)
        state.apply(.transferStarted)
        record.transferStarted = true
        var progress = try OfficeManagedFolders.decodeRecordingProgress(
            try await seams.transport.recordingProgress(bundleID: record.bundleID))
        // A few chunks ahead of what the office has taken, and no further. The transport counts
        // the two small files with the media; they are taken first, so they are set aside here.
        let documents = record.totalBytes - record.mediaBytes
        var ahead = max(0, progress.publishedBytes - documents) - max(0, progress.servedBytes - documents)
        while record.publishedChunks < record.chunks.count,
              ahead < Int64(seams.chunksAhead) * record.chunkBytes {
            let chunk = record.chunks[record.publishedChunks]
            try await seams.transport.publishRecordingChunk(
                bundleID: record.bundleID, sha256: chunk.sha256,
                path: seams.store.chunkFile(record, sha256: chunk.sha256).path)
            record.publishedChunks += 1
            ahead += chunk.bytes
            try seams.store.save(record)
        }
        progress = try OfficeManagedFolders.decodeRecordingProgress(
            try await seams.transport.recordingProgress(bundleID: record.bundleID))
        state.apply(.progress(sentBytes: min(max(progress.servedBytes, record.sentBytes), record.totalBytes)))
        if progress.allServed, record.publishedChunks == record.chunks.count { state.apply(.allChunksServed) }
        Self.keep(state, in: &record)
        try seams.store.save(record)
    }

    // MARK: - The technician's choices

    /// Keep waiting for the office: an expired recording waits another period, a refused one is
    /// offered again from the start.
    func keepWaiting(bundleID: String) async throws {
        guard var record = seams.store.records().first(where: { $0.bundleID == bundleID }) else { return }
        var state = Self.state(of: record)
        guard state.apply(.keepWaiting) else { return }
        record.waitingSince = seams.clock()
        // An expired recording carries on from where it was; a refused one starts again.
        if case .failed = record.stage {
            record.publishedChunks = 0
            record.transferStarted = false
        }
        Self.keep(state, in: &record)
        try seams.store.save(record)
        refresh()
    }

    /// Delete a job's recording from the phone, whatever the office has or has not said.
    func delete(bundleID: String) async throws {
        guard let record = seams.store.records().first(where: { $0.bundleID == bundleID }) else { return }
        try? await seams.transport.withdrawRecording(bundleID: bundleID, forget: true)
        try seams.store.delete(record)
        waiting[bundleID] = nil
        refresh()
    }

    /// Whether deleting this recording would delete the only copy: the office has not said it
    /// has it.
    func deletionNeedsConfirmation(bundleID: String) -> Bool {
        seams.store.records().first { $0.bundleID == bundleID }?.acknowledgedAt == nil
    }

    // MARK: - The record and the state machine

    private func refresh() {
        let next = seams.store.records().map { record -> Row in
            var state = Self.state(of: record)
            if let reason = waiting[record.bundleID] { state.apply(.notEligible(reason)) }
            return Row(id: record.bundleID, sessionID: record.sessionID, phase: state.phase,
                       sentBytes: state.sentBytes, totalBytes: record.totalBytes, outcome: record.outcome)
        }
        if next != rows { rows = next }
    }

    /// The state machine at the point the record says, reached by the events that lead there.
    static func state(of record: Record) -> BundleSyncState {
        var state = BundleSyncState(bundleID: record.bundleID)
        state.apply(.recordingStopped)
        state.apply(.sealed(manifestSHA256: record.manifestSHA256, totalBytes: record.totalBytes))
        func receipt(_ status: BundleSyncState.Receipt.Status) -> BundleSyncState.Event {
            .receipt(.init(bundleID: record.bundleID, manifestSHA256: record.manifestSHA256, status: status))
        }
        switch record.stage {
        case .sealed:
            if record.transferStarted {
                state.apply(.transferStarted)
                state.apply(.progress(sentBytes: min(record.sentBytes, record.totalBytes)))
            }
        case .delivered:
            state.apply(.transferStarted)
            state.apply(.allChunksServed)
        case .acknowledged:
            state.apply(receipt(.received))
        case .trimmed:
            state.apply(receipt(.received))
            state.apply(.mediaTrimmed)
        case .failed(let reason):
            state.apply(receipt(.refused(BundleSyncState.RefusalReason(rawValue: reason) ?? .policy)))
        case .expired:
            state.apply(.expiryReached)
        }
        return state
    }

    /// Writes the state machine's phase into the record.
    static func keep(_ state: BundleSyncState, in record: inout Record) {
        record.sentBytes = state.sentBytes
        switch state.phase {
        case .recording, .preparing, .sealed, .waiting, .transferring: record.stage = .sealed
        case .delivered: record.stage = .delivered
        case .acknowledged: record.stage = .acknowledged
        case .trimmed: record.stage = .trimmed
        case .failed(let reason): record.stage = .failed(reason.rawValue)
        case .expired: record.stage = .expired
        }
    }

    // MARK: - Words

    /// Where a recording is, as a sentence for the technician. "Received by the office" only on
    /// the office's own receipt.
    static func words(_ row: Row) -> String {
        let size = ByteCountFormatter.string(fromByteCount: row.totalBytes, countStyle: .file)
        switch row.phase {
        case .recording, .preparing:
            return "Preparing the recording."
        case .sealed:
            return "Recording waiting to sync. \(size)."
        case .waiting(let reason):
            return "Recording waiting to sync. \(reason.explanation)"
        case .transferring(let sent, let total):
            let percent = total > 0 ? Int((Double(sent) / Double(total) * 100).rounded(.down)) : 0
            return "Sending the recording to the office: \(percent)% of \(size)."
        case .delivered:
            return "Recording sent. Waiting for the office to confirm it."
        case .acknowledged, .trimmed:
            if let outcome = row.outcome, outcome.status == OfficeRecordingReceipt.Status.published.rawValue {
                return "Recording received by the office. A procedure was published from it."
            }
            return "Recording received by the office."
        case .failed(let reason):
            return "The office didn't accept the recording (\(refusalWords(reason))). It is still on this phone."
        case .expired:
            return "The office hasn't confirmed this recording in a long time. It is still on this phone."
        }
    }

    static func refusalWords(_ reason: BundleSyncState.RefusalReason) -> String {
        switch reason {
        case .signature: return "it couldn't check this phone's signature"
        case .binding: return "this phone's pairing with the office has changed"
        case .digest: return "what arrived wasn't what was sent"
        case .tooLarge: return "it is too large"
        case .policy: return "your organisation's rules don't allow it"
        }
    }
}
