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
    @Published var auditLog: [AuditEntry] = []

    /// Last durability problem seen by the audit log, or nil when the persisted log is current.
    /// Surfaced rather than swallowed: an audit record that failed to persist must not look like
    /// one that did.
    @Published private(set) var lastPersistenceFailure: AuditPersistenceFailure?

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

    struct AuditEntry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let action: String
        let detail: String

        init(action: String, detail: String) {
            self.id = UUID()
            self.timestamp = Date()
            self.action = action
            self.detail = detail
        }
    }

    private let store: AuditLogStore
    private let maxAuditEntries = 1000

    /// Invoked right after `hipaaMode` is toggled so live services (cloud diarization, ambient
    /// captions) can tear down/restart deterministically rather than waiting for a natural
    /// restart. Wired by AppState; nil in tests and headless contexts.
    var onModeChanged: (() -> Void)?

    /// The default store is the production one: the same protected JSON file in the documents
    /// directory this service has always used. The seam exists so restart, locked-storage and
    /// partial-write behaviour can be exercised.
    init(store: AuditLogStore = FileAuditLogStore()) {
        self.store = store
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
            appendAuditEntry(action: "COMPLIANCE_ENABLED",
                             detail: "Medical compliance mode enabled")
        } else {
            appendAuditEntry(action: "COMPLIANCE_DISABLED",
                             detail: "Medical compliance mode disabled")
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

    /// Log a HIPAA audit event. Returns whether the event was recorded **and persisted** — false
    /// when compliance mode is off (events are not collected) or the store refused the write.
    @discardableResult
    func log(action: String, detail: String) -> Bool {
        guard Config.hipaaMode else { return false }

        return appendAuditEntry(action: action, detail: detail)
    }

    /// Record an audit-control event without consulting the mode it is changing. Callers are
    /// limited to this service's own control transitions; ordinary feature events still go
    /// through `log` and remain suppressed while compliance mode is off.
    @discardableResult
    private func appendAuditEntry(action: String, detail: String) -> Bool {

        let previous = auditLog
        let entry = AuditEntry(action: action, detail: detail)
        auditLog.append(entry)

        // Trim to max size
        if auditLog.count > maxAuditEntries {
            auditLog = Array(auditLog.suffix(maxAuditEntries))
        }

        guard saveAuditLog() else {
            // The store commits all-or-nothing, so the persisted log is still `previous`. Roll the
            // in-memory copy back so the two agree: an entry that never reached storage must not
            // be displayed or exported as though it had.
            auditLog = previous
            return false
        }
        PrivacyLog.medical(.audit, .auditRecorded, operation: PrivacyToken(action))
        return true
    }

    /// Export the audit log as a formatted string for compliance review.
    func exportAuditLog() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        var output = "HIPAA AUDIT LOG — OpenGlasses\n"
        output += "Exported: \(dateFormatter.string(from: Date()))\n"
        output += "Entries: \(auditLog.count)\n"
        output += "========================================\n\n"

        for entry in auditLog {
            output += "[\(dateFormatter.string(from: entry.timestamp))] \(entry.action)\n"
            output += "  \(entry.detail)\n\n"
        }

        return output
    }

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
            // it would erase the only trace that someone tried.
            appendAuditEntry(action: "AUDIT_CLEAR_REFUSED",
                             detail: "Audit log clear refused: owner authorization \(authorization.auditToken)")
            return .refused(authorization)
        }

        let recordClear = Config.hipaaMode
        auditLog.removeAll()
        if recordClear {
            // The marker is written after the old entries are removed so it is not erased by the
            // operation it records. When the mode is off, this method remains a true reset helper
            // for test/setup and migration paths and does not start collecting events.
            return appendAuditEntry(action: "AUDIT_LOG_CLEARED", detail: "Audit log cleared by user")
                ? .cleared : .persistenceFailed
        }
        return saveAuditLog() ? .cleared : .persistenceFailed
    }

    private func loadAuditLog() {
        do {
            guard let data = try store.load() else { return }
            auditLog = try JSONDecoder().decode([AuditEntry].self, from: data)
            lastPersistenceFailure = nil
        } catch {
            // Keep whatever is stored: unreadable evidence is still evidence, and the next append
            // would otherwise overwrite it. Quarantining moves it aside under its own name.
            try? store.quarantineUnreadable()
            lastPersistenceFailure = .load
            PrivacyLog.medical(.audit, .auditLoadFailed, error: SafeErrorSummary(error))
        }
    }

    @discardableResult
    private func saveAuditLog() -> Bool {
        do {
            let data = try JSONEncoder().encode(auditLog)
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
            log(action: "AUTO_PURGE", detail: "Purged \(purgedCount) file(s) older than \(retentionDays) days")
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
                log(action: "FILE_PURGED", detail: fileURL.lastPathComponent)
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
        log(action: "SECURE_DELETE", detail: url.lastPathComponent)
    }
}
