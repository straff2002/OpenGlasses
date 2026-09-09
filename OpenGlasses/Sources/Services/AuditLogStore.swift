import Foundation

/// Persistence seam for the medical-compliance audit log (roadmap W05.1).
///
/// `HIPAAComplianceService` wrote through `FileManager` directly, so nothing could exercise the
/// durability paths that matter for audit evidence: an app restart, a write refused because
/// protected data is locked, and a writer that commits only part of a record. Production behaviour
/// is unchanged — ``FileAuditLogStore`` is the same protected, atomically written JSON file.
///
/// Implementations must commit **all or nothing**. The service relies on that to keep the
/// in-memory log and the persisted log in agreement after a failed write.
protocol AuditLogStore: AnyObject {
    /// Previously persisted bytes, or nil when nothing has been stored yet.
    func load() throws -> Data?

    /// Replace the stored log. All-or-nothing: on throw the previously stored bytes must remain.
    func save(_ data: Data) throws

    /// Move undecodable bytes aside so a fresh log does not overwrite them. Evidence that cannot
    /// be read is still evidence.
    func quarantineUnreadable() throws

    /// File to apply compliance file protection to, when the store is file-backed.
    var protectedFileURL: URL? { get }
}

/// The production store: one protected JSON file in the documents directory.
final class FileAuditLogStore: AuditLogStore {

    let url: URL

    init(url: URL) {
        self.url = url
    }

    convenience init() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.init(url: docsDir.appendingPathComponent("hipaa_audit_log.json"))
    }

    var protectedFileURL: URL? { url }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// `.atomic` is write-temp-then-rename, so a failure part-way through leaves the previous file
    /// untouched and a reader never observes a half-written log.
    func save(_ data: Data) throws {
        try data.write(to: url, options: [.atomic])
    }

    func quarantineUnreadable() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantined = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: quarantined)
    }
}
