import Foundation

/// Manages HIPAA-compliant data handling for clinical use cases.
///
/// When HIPAA mode is enabled:
/// - All transcript/recording files use NSFileProtectionComplete (encrypted at rest, only accessible when unlocked)
/// - Files are excluded from iCloud backup
/// - Audit log tracks all data access events (recordings, shares, deletions)
/// - Auto-purge removes files older than the configured retention period
/// - Cloud memory sync is disabled (no PHI leaves the device via gateway)
/// - Web search and messaging tools are disabled to prevent PHI leakage
/// - Local LLM is preferred to keep clinical data on-device
@MainActor
class HIPAAComplianceService: ObservableObject {

    /// The chained, typed audit log. The chain is the stored form; `auditLog` is the flat view of
    /// it that the UI and the export read.
    @Published private(set) var chain: [AuditChainedEvent] = []

    var auditLog: [AuditEvent] { chain.map(\.event) }

    /// Last durability problem seen by the audit log, or nil when the persisted log is current.
    /// Surfaced rather than swallowed: an audit record that failed to persist must not look like
    /// one that did.
    @Published private(set) var lastPersistenceFailure: AuditPersistenceFailure?

    /// What the last verification pass concluded about the stored log (roadmap W05.3). Set on
    /// every load, whether or not it produced a record.
    @Published private(set) var lastIntegrityVerdict: AuditChainVerification = .intact

    /// Set when the checkpoint could not be read or written. A checkpoint that is unavailable
    /// weakens rollback detection to nothing, so it is reported rather than assumed absent.
    @Published private(set) var lastCheckpointFault: AuditCheckpointFault?

    enum AuditPersistenceFailure: Equatable {
        /// The stored log could not be read or decoded; unreadable bytes were kept, not replaced.
        case load
        /// The store refused the write (e.g. protected data locked); the previous log stands.
        case save
    }

    /// Result of an audit-clear request.
    enum AuditClearOutcome: Equatable {
        case cleared
        /// No positive owner decision, so the log was kept and the attempt recorded.
        case refused(OwnerAuthorization)
        /// Authorized, but the resulting log could not be persisted.
        case persistenceFailed
    }

    /// A protected, TTL-bound copy of the audit log on disk, plus the digest of exactly the bytes
    /// that were written (roadmap W05.4). The digest, not the content, is what the audit trail
    /// records about its own export.
    struct AuditLogExport: Identifiable, Equatable {
        let session: ProtectedExportSession
        let digest: String
        let entryCount: Int

        var id: UUID { session.id }
        var fileURL: URL { session.fileURL }
    }

    private let store: AuditLogStore
    private let checkpoints: AuditCheckpointStore
    private let exportStore: ProtectedExportFileStore
    private let maxAuditEntries = 1000
    /// How often the head is checkpointed. Small enough that a rollback loses little, large
    /// enough that an ordinary session is not writing to the keychain on every event.
    private let checkpointInterval = 16
    private var eventsSinceCheckpoint = 0
    /// Where the next record's sequence starts when the chain is empty — after a clear, or after
    /// a log that was deleted outright. Never resets to zero once a checkpoint exists, so
    /// continuing a cleared log does not read as a rollback.
    private var sequenceFloor = 0

    /// Invoked right after `hipaaMode` is toggled so live services (cloud diarization, ambient
    /// captions) can tear down/restart deterministically rather than waiting for a natural
    /// restart. Wired by AppState; nil in tests and headless contexts.
    var onModeChanged: (() -> Void)?

    /// The default store is the production one: the same protected JSON file in the documents
    /// directory this service has always used. The seam exists so restart, locked-storage and
    /// partial-write behaviour can be exercised. The checkpoint seam exists for the same reason
    /// and because its production home, the keychain, is not available to a headless test.
    init(store: AuditLogStore = FileAuditLogStore(),
         checkpoints: AuditCheckpointStore = KeychainAuditCheckpointStore(),
         exportStore: ProtectedExportFileStore = ProtectedExportFileStore(
            rootDirectoryName: "MedicalAuditExports")) {
        self.store = store
        self.checkpoints = checkpoints
        self.exportStore = exportStore
        loadAuditLog()
    }

    /// Single entry point for toggling compliance mode: writes the flag, audit-logs the change,
    /// and fires `onModeChanged` so dependent live sessions reconfigure at once. Callers must use
    /// this rather than setting `Config.hipaaMode` directly, so the teardown never gets skipped.
    func setMode(_ enabled: Bool) {
        // A disable event belongs to the audit trail even though ordinary audit events are
        // suppressed while the mode is off. Record it before lowering the gate; otherwise the
        // transition which stops audit collection erases its own evidence.
        if enabled {
            Config.hipaaMode = true
            append(AuditEvent(kind: .complianceModeEnabled, actorClass: .owner,
                              targetClass: .complianceMode, purpose: .operations))
        } else {
            append(AuditEvent(kind: .complianceModeDisabled, actorClass: .owner,
                              targetClass: .complianceMode, purpose: .operations))
            Config.hipaaMode = false
        }
        if enabled {
            // Plan BQ P2: compliance mode hard-disables Spotlight donation — purge
            // everything previously donated. (Refreshes while enabled donate nothing.)
            Task { @MainActor in await SpotlightIndexService.shared.purgeAll() }
        }
        onModeChanged?()
    }

    // MARK: - File Protection

    /// Apply HIPAA-compliant file protection to a file or directory.
    /// Sets NSFileProtectionComplete and excludes from iCloud backup.
    func protectFile(at url: URL) {
        guard Config.hipaaMode else { return }

        do {
            // Encrypt at rest — only accessible when device is unlocked
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )

            // Exclude from iCloud backup
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(resourceValues)

            PrivacyLog.medical(.compliance, .fileProtected)
        } catch {
            PrivacyLog.medical(.compliance, .fileProtectionFailed,
                               error: SafeErrorSummary(error))
        }
    }

    /// Protect all files in a directory.
    func protectDirectory(at url: URL) {
        guard Config.hipaaMode else { return }
        protectFile(at: url)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents {
            protectFile(at: fileURL)
        }
    }

    // MARK: - Audit Logging

    /// Record a typed audit event (roadmap W05.2). Returns whether it was recorded **and
    /// persisted** — false when compliance mode is off (events are not collected) or the store
    /// refused the write.
    @discardableResult
    func record(_ kind: AuditEventKind,
                actor: AuditActorClass = .system,
                target: AuditTargetClass,
                purpose: AuditPurpose? = nil,
                result: AuditResult = .succeeded,
                decision: AuditDecision? = nil,
                count: Int? = nil,
                subject: String? = nil,
                subjectDigest: String? = nil,
                correlation: String? = nil) -> Bool {
        guard Config.hipaaMode else { return false }
        return append(AuditEvent(kind: kind, actorClass: actor, targetClass: target,
                                 purpose: purpose, result: result, decision: decision,
                                 count: count, subject: subject, subjectDigest: subjectDigest,
                                 correlation: correlation))
    }

    /// Free-text bridge for call sites that still pass an action and a detail string.
    ///
    /// Kept because the callers live in change sets this one does not own; it is not a way back
    /// into free text. The action is matched against the typed vocabulary and, where it is not
    /// known, kept only if it is a bare operation token; the detail never reaches storage at all,
    /// only its fingerprint. Migrating the remaining callers to ``record(_:actor:target:...)`` is
    /// recorded as owed.
    @discardableResult
    func log(action: String, detail: String) -> Bool {
        guard Config.hipaaMode else { return false }
        let mapped = Self.mapping(forLegacyAction: action)
        return append(AuditEvent(kind: mapped.kind, targetClass: mapped.target,
                                 result: mapped.result, action: action, detail: detail))
    }

    /// How a legacy action token lands in the typed vocabulary. Unknown tokens become `.legacy`
    /// rather than being guessed at.
    static func mapping(forLegacyAction action: String)
        -> (kind: AuditEventKind, target: AuditTargetClass, result: AuditResult) {
        let failed = action.contains("_FAILED") || action.contains("REFUSED")
        let result: AuditResult = failed ? .failed : .succeeded
        switch action {
        case AuditEventKind.complianceModeEnabled.auditToken:
            return (.complianceModeEnabled, .complianceMode, result)
        case AuditEventKind.complianceModeDisabled.auditToken:
            return (.complianceModeDisabled, .complianceMode, result)
        case AuditEventKind.auditClearGranted.auditToken: return (.auditClearGranted, .auditLog, result)
        case AuditEventKind.auditClearRefused.auditToken: return (.auditClearRefused, .auditLog, .refused)
        case AuditEventKind.appLaunched.auditToken: return (.appLaunched, .complianceMode, result)
        case "AUTO_PURGE": return (.retentionPurgeCompleted, .transcript, result)
        case AuditEventKind.filePurged.auditToken: return (.filePurged, .transcript, result)
        case AuditEventKind.fileSecurelyDeleted.auditToken: return (.fileSecurelyDeleted, .transcript, result)
        case AuditEventKind.recordingStarted.auditToken: return (.recordingStarted, .transcript, result)
        case AuditEventKind.recordingStopped.auditToken: return (.recordingStopped, .transcript, result)
        case AuditEventKind.transcriptSaved.auditToken: return (.transcriptSaved, .transcript, result)
        case "FHIR_EXPORT", "CLINICAL_EXPORT": return (.clinicalExport, .export, result)
        case "EXPORT_LEASE_CREATED", "EXPORT_SHARE_STARTED": return (.exportCreated, .export, result)
        default:
            if action.hasPrefix("EXPORT_") { return (.exportReleased, .export, result) }
            return (.legacy, .auditLog, result)
        }
    }

    /// Append to the chain without consulting the mode being changed. Callers are limited to this
    /// service's own control transitions and to the mode-gated entry points above.
    @discardableResult
    private func append(_ event: AuditEvent) -> Bool {
        let previousChain = chain
        let previousSinceCheckpoint = eventsSinceCheckpoint
        chain.append(AuditChain.append(event, to: chain.last, continuingFrom: sequenceFloor))

        // Trim to max size. The surviving records keep their sequence numbers, so a trimmed log is
        // an anchored suffix rather than a renumbered one — the difference between retention and
        // something that looks like tampering.
        if chain.count > maxAuditEntries {
            chain = Array(chain.suffix(maxAuditEntries))
        }

        guard saveAuditLog() else {
            // The store commits all-or-nothing, so the persisted log is still `previousChain`.
            // Roll the in-memory copy back so the two agree: an entry that never reached storage
            // must not be displayed or exported as though it had.
            chain = previousChain
            eventsSinceCheckpoint = previousSinceCheckpoint
            return false
        }
        PrivacyLog.medical(.audit, .auditRecorded, operation: PrivacyToken(event.action))

        eventsSinceCheckpoint += 1
        if eventsSinceCheckpoint >= checkpointInterval { writeCheckpoint() }
        return true
    }

    // MARK: - Integrity (W05.3)

    /// Write the sealed checkpoint for the current head. Silent when there is nothing to
    /// checkpoint; reported, never swallowed, when protected storage refuses.
    private func writeCheckpoint() {
        do {
            // An empty log has no head to certify, and a stale checkpoint over it would report a
            // truncation that an authorized clear had already accounted for.
            guard let head = chain.last else {
                try checkpoints.clear()
                eventsSinceCheckpoint = 0
                lastCheckpointFault = nil
                return
            }
            try checkpoints.save(sequence: head.sequence, headDigest: head.digest, at: Date())
            eventsSinceCheckpoint = 0
            lastCheckpointFault = nil
        } catch let fault as AuditCheckpointFault {
            lastCheckpointFault = fault
            PrivacyLog.medical(.audit, .auditCheckpointFailed)
        } catch {
            lastCheckpointFault = .unavailable
            PrivacyLog.medical(.audit, .auditCheckpointFailed)
        }
    }

    private func readCheckpoint() -> AuditCheckpoint? {
        do {
            let checkpoint = try checkpoints.load()
            lastCheckpointFault = nil
            return checkpoint
        } catch let fault as AuditCheckpointFault {
            lastCheckpointFault = fault
            PrivacyLog.medical(.audit, .auditCheckpointFailed)
            return nil
        } catch {
            lastCheckpointFault = .unavailable
            PrivacyLog.medical(.audit, .auditCheckpointFailed)
            return nil
        }
    }

    /// Judge the loaded chain and record the verdict.
    ///
    /// The verdict record is **appended after** the records it judges, so it extends the chain
    /// rather than altering the thing being judged; the digests it certifies are already fixed by
    /// the time it exists. An intact verdict is exposed through `lastIntegrityVerdict` but not
    /// written: an "all fine" row on every launch would fill a bounded log with the absence of
    /// news and push out the records it is there to protect.
    private func verifyOnLoad(_ checkpoint: AuditCheckpoint?) {
        let verdict = AuditChain.verify(events: chain, checkpoint: checkpoint)
        lastIntegrityVerdict = verdict
        guard !verdict.isIntact else { return }

        PrivacyLog.medical(.audit, .auditIntegrityFailed,
                           operation: PrivacyToken(verdict.auditToken))
        // The damaged records are kept exactly as found — repairing them would destroy the
        // evidence — and the finding is recorded next to them.
        append(AuditEvent(kind: .integrityCheck, targetClass: .auditLog,
                          purpose: .complianceReview, result: .failed,
                          count: chain.count, subject: verdict.auditToken))
        // Checkpointed afterwards on purpose: the breach is now itself part of the chain, so the
        // next launch reports the state of the log from here rather than re-reporting the same
        // finding forever.
        writeCheckpoint()
    }

    /// Whether the current policy revision differs from the one the newest stored record was
    /// written under. Recorded as its own event so a reviewer can see where the rules changed.
    private func recordPolicyVersionChangeIfNeeded() {
        guard let previous = chain.last?.event.policyVersion,
              previous != AuditPolicyVersion.current else { return }
        append(AuditEvent(kind: .policyVersionChanged, targetClass: .policy,
                          purpose: .complianceReview, subject: previous))
    }

    // MARK: - Export (W05.4)

    /// The audit log as typed JSON, for compliance review.
    ///
    /// Every field is from the schema — there is no free-text row and no rendered sentence — and
    /// each record carries its sequence and digests so a reviewer can re-walk the chain outside
    /// this app.
    func exportAuditLog() -> String {
        let document = AuditLogExportDocument(
            schema: AuditLogExportDocument.currentSchema,
            policyVersion: AuditPolicyVersion.current,
            exportedAt: AuditEvent.timestampFormatter.string(from: Date()),
            entryCount: chain.count,
            integrity: lastIntegrityVerdict.auditToken,
            headDigest: chain.last?.digest,
            events: chain)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"schema\":\"\(AuditLogExportDocument.currentSchema)\",\"error\":\"encoding\"}"
        }
        return text
    }

    /// Write the audit log to a protected, backup-excluded, TTL-bound session directory and record
    /// the export — by the digest of the bytes written, never their content.
    ///
    /// Abandoned sessions are scavenged first, so an export that was never released cannot
    /// outlive its window just because nothing asked again.
    func exportProtectedAuditLog(now: Date = Date()) throws -> AuditLogExport {
        exportStore.scavenge(now: now)
        let data = Data(exportAuditLog().utf8)
        let digest = AuditFingerprint.of(data)
        let entryCount = chain.count
        let session = try exportStore.createSession(fileExtension: "json", now: now) { url in
            try data.write(to: url, options: .atomic)
        }
        append(AuditEvent(kind: .auditExportCreated, actorClass: .owner, targetClass: .export,
                          purpose: .complianceReview, count: entryCount, subjectDigest: digest,
                          correlation: session.id.uuidString))
        return AuditLogExport(session: session, digest: digest, entryCount: entryCount)
    }

    /// Destroy an export's files and record that it is gone.
    func releaseAuditLogExport(_ export: AuditLogExport) {
        exportStore.release(export.session)
        append(AuditEvent(kind: .auditExportReleased, actorClass: .owner, targetClass: .export,
                          purpose: .complianceReview, subjectDigest: export.digest,
                          correlation: export.session.id.uuidString))
    }

    /// Remove every audit export still on disk. For a data reset, and for compliance-mode changes.
    @discardableResult
    func revokeAuditLogExports() -> Int {
        exportStore.revokeAll()
    }

    // MARK: - Clearing

    /// Clear the audit log (itself an auditable event), subject to owner authorization.
    ///
    /// Fails **closed**: only an explicit `.granted` decision clears. Anything else — denied, or no
    /// decision obtainable — keeps the log and records the attempt instead. There is no default
    /// argument on purpose, so no caller can delete compliance evidence without having asked.
    @discardableResult
    func clearAuditLog(authorization: OwnerAuthorization) -> AuditClearOutcome {
        guard authorization.isGranted else {
            // Recorded regardless of the current mode: like the disable transition, a refused
            // attempt to destroy the log is a control event about the log itself, and suppressing
            // it would erase the only trace that someone tried. The owner-authorization outcome
            // travels on the record as a fixed token rather than as a second row.
            append(AuditEvent(kind: .auditClearRefused, actorClass: .owner, targetClass: .auditLog,
                              purpose: .complianceReview, result: .refused,
                              decision: AuditDecision(authorization)))
            return .refused(authorization)
        }

        let recordClear = Config.hipaaMode
        // The chain carries on from where it stopped. Restarting the sequence at zero would make
        // an authorized clear indistinguishable from a rollback.
        sequenceFloor = (chain.last?.sequence).map { $0 + 1 } ?? sequenceFloor
        chain.removeAll()
        if recordClear {
            // The marker is written after the old entries are removed so it is not erased by the
            // operation it records. When the mode is off, this method remains a true reset helper
            // for test/setup and migration paths and does not start collecting events.
            let recorded = append(AuditEvent(kind: .auditClearGranted, actorClass: .owner,
                                             targetClass: .auditLog, purpose: .complianceReview,
                                             decision: .granted))
            if recorded { writeCheckpoint() }
            return recorded ? .cleared : .persistenceFailed
        }
        guard saveAuditLog() else { return .persistenceFailed }
        writeCheckpoint()
        return .cleared
    }

    // MARK: - Persistence

    private func loadAuditLog() {
        let checkpoint = readCheckpoint()
        sequenceFloor = checkpoint.map { $0.sequence + 1 } ?? 0
        do {
            guard let data = try store.load() else {
                verifyOnLoad(checkpoint)
                return
            }
            chain = try Self.decodeChain(from: data)
            sequenceFloor = (chain.last?.sequence).map { $0 + 1 } ?? sequenceFloor
            lastPersistenceFailure = nil
            verifyOnLoad(checkpoint)
            recordPolicyVersionChangeIfNeeded()
        } catch {
            // Keep whatever is stored: unreadable evidence is still evidence, and the next append
            // would otherwise overwrite it. Quarantining moves it aside under its own name.
            try? store.quarantineUnreadable()
            lastPersistenceFailure = .load
            PrivacyLog.medical(.audit, .auditLoadFailed, error: SafeErrorSummary(error))
        }
    }

    /// Chained records first; a pre-schema `[AuditEntry]` array second, migrated into `.legacy`
    /// events and given a chain. The old rows keep their ids and timestamps and lose their detail
    /// text, which never had a home in the new schema.
    static func decodeChain(from data: Data) throws -> [AuditChainedEvent] {
        let decoder = JSONDecoder()
        if let chained = try? decoder.decode([AuditChainedEvent].self, from: data) {
            return chained
        }
        return AuditChain.rebuild(try decoder.decode([AuditEvent].self, from: data))
    }

    @discardableResult
    private func saveAuditLog() -> Bool {
        do {
            let data = try JSONEncoder().encode(chain)
            try store.save(data)
            if let url = store.protectedFileURL { protectFile(at: url) }
            lastPersistenceFailure = nil
            return true
        } catch {
            lastPersistenceFailure = .save
            PrivacyLog.medical(.audit, .auditSaveFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    // MARK: - Data Retention / Auto-Purge

    /// Purge transcripts and recordings older than the retention period.
    /// Called on app launch and periodically.
    func enforceRetentionPolicy() {
        guard Config.hipaaMode else { return }
        let retentionDays = Config.hipaaRetentionDays
        guard retentionDays > 0 else { return } // 0 = no auto-purge

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        var purgedCount = 0

        // Purge transcripts
        let transcriptsDir = transcriptsDirectory()
        purgedCount += purgeOldFiles(in: transcriptsDir, olderThan: cutoffDate)

        // Purge temp recordings
        let tempDir = FileManager.default.temporaryDirectory
        purgedCount += purgeOldFiles(in: tempDir, olderThan: cutoffDate, matching: "OpenGlasses_")

        if purgedCount > 0 {
            record(.retentionPurgeCompleted, target: .transcript, purpose: .retentionPolicy,
                   count: purgedCount)
            PrivacyLog.medical(.compliance, .retentionPurged, count: purgedCount,
                               days: retentionDays)
        }
    }

    private func transcriptsDirectory() -> URL {
        if let custom = Config.transcriptFolderURL { return custom }
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docsDir.appendingPathComponent("Transcripts")
    }

    private func purgeOldFiles(in directory: URL, olderThan cutoff: Date, matching prefix: String? = nil) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return 0 }

        var count = 0
        for fileURL in contents {
            if let prefix, !fileURL.lastPathComponent.hasPrefix(prefix) { continue }

            guard let values = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                  let created = values.creationDate,
                  created < cutoff else { continue }

            do {
                try FileManager.default.removeItem(at: fileURL)
                count += 1
                // The filename is frequently a date and a patient, so it is fingerprinted: enough
                // to tie a purge to the file it removed, not enough to name it.
                record(.filePurged, target: .transcript, purpose: .retentionPolicy,
                       subject: fileURL.lastPathComponent)
            } catch {
                PrivacyLog.medical(.compliance, .purgeFailed, error: SafeErrorSummary(error))
            }
        }
        return count
    }

    // MARK: - Secure Deletion

    /// Securely delete a file (overwrite then remove).
    func secureDelete(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Overwrite with random data before deletion
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0 {
                let randomData = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
                fileHandle.write(randomData)
                fileHandle.closeFile()
            }
        }

        try? FileManager.default.removeItem(at: url)
        record(.fileSecurelyDeleted, target: .transcript, purpose: .wearerRequest,
               subject: url.lastPathComponent)
    }
}


// MARK: - Export document

/// The shape of an exported audit log. Typed all the way down: a reviewer reads the same fields
/// the app stores, and there is no rendered prose in it for content to hide in.
struct AuditLogExportDocument: Codable, Equatable {
    static let currentSchema = "openglasses.audit.v1"

    let schema: String
    let policyVersion: String
    let exportedAt: String
    let entryCount: Int
    /// The verdict of the last verification pass, so an export of a damaged log says so.
    let integrity: String
    let headDigest: String?
    let events: [AuditChainedEvent]
}
