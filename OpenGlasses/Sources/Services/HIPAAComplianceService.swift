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

    private let auditLogURL: URL
    private let maxAuditEntries = 1000

    init() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        auditLogURL = docsDir.appendingPathComponent("hipaa_audit_log.json")
        loadAuditLog()
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

            NSLog("[HIPAA] Protected file: %@", url.lastPathComponent)
        } catch {
            NSLog("[HIPAA] Failed to protect file %@: %@", url.lastPathComponent, error.localizedDescription)
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

    /// Log a HIPAA audit event.
    func log(action: String, detail: String) {
        guard Config.hipaaMode else { return }

        let entry = AuditEntry(action: action, detail: detail)
        auditLog.append(entry)

        // Trim to max size
        if auditLog.count > maxAuditEntries {
            auditLog = Array(auditLog.suffix(maxAuditEntries))
        }

        saveAuditLog()
        NSLog("[HIPAA Audit] %@: %@", action, detail)
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

    /// Clear the audit log (itself an auditable event).
    func clearAuditLog() {
        log(action: "AUDIT_LOG_CLEARED", detail: "Audit log cleared by user")
        auditLog.removeAll()
        saveAuditLog()
    }

    private func loadAuditLog() {
        guard FileManager.default.fileExists(atPath: auditLogURL.path) else { return }
        do {
            let data = try Data(contentsOf: auditLogURL)
            auditLog = try JSONDecoder().decode([AuditEntry].self, from: data)
        } catch {
            NSLog("[HIPAA] Failed to load audit log: %@", error.localizedDescription)
        }
    }

    private func saveAuditLog() {
        do {
            let data = try JSONEncoder().encode(auditLog)
            try data.write(to: auditLogURL, options: .atomic)
            protectFile(at: auditLogURL)
        } catch {
            NSLog("[HIPAA] Failed to save audit log: %@", error.localizedDescription)
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
            NSLog("[HIPAA] Auto-purged %d files (retention: %d days)", purgedCount, retentionDays)
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
                NSLog("[HIPAA] Failed to purge %@: %@", fileURL.lastPathComponent, error.localizedDescription)
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
