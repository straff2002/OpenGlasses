import Foundation

/// An opaque handle to one protected clinical export. Holding a lease is what keeps the file on
/// disk; releasing it is what removes the whole session directory. Callers get a lease rather
/// than a bare URL so no code path can acquire a clinical file without also acquiring the
/// obligation to release it.
struct MedicalExportLease: Identifiable, Equatable {
    let id: UUID
    let format: ExportFormat
    let createdAt: Date
    /// Generic on-disk location, named by UUID. The user-facing name travels separately.
    let fileURL: URL
    /// Name offered to the share UI. Never becomes a filename.
    let displayName: String

    var sessionDirectory: URL { fileURL.deletingLastPathComponent() }
}

/// The security attributes every clinical export must carry, behind a seam so tests can observe
/// the pass and drive its failure path — the simulator does not reliably report file protection
/// back, so asserting the applier ran is the part that stays verifiable everywhere.
protocol MedicalExportProtecting {
    func protect(_ url: URL) throws
}

/// Production attributes: complete file protection plus backup exclusion.
struct FileProtectionApplier: MedicalExportProtecting {
    func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

/// Creates and destroys the protected session directories clinical exports live in.
///
/// Every export gets its own `Library/Caches/MedicalExports/<UUID>/` directory, protected before
/// any content is written and marked complete only once the finished file is protected too. That
/// ordering is what lets the scavenger tell a crash-abandoned session from a live one without
/// keeping a ledger of what any file contained.
final class MedicalExportFileStore {
    /// Crash-recovery window for a completed session whose share never released it.
    static let completedSessionTTL: TimeInterval = 3600

    private static let rootDirectoryName = "MedicalExports"
    /// Empty marker written last. Its presence means "content finished and protected".
    private static let completionMarkerName = ".complete"

    let root: URL

    private let fileManager: FileManager
    private let protector: MedicalExportProtecting
    /// Sessions this process still owns. A scan never touches them, so a scavenge racing a live
    /// export cannot delete the file that is about to be shared.
    private var activeSessions: Set<UUID> = []

    init(root: URL? = nil,
         fileManager: FileManager = .default,
         protector: MedicalExportProtecting = FileProtectionApplier()) {
        self.fileManager = fileManager
        self.protector = protector
        if let root {
            self.root = root
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.root = caches.appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        }
    }

    // MARK: - Creation

    /// Create a protected session and hand its file to `write`, which must produce the content at
    /// the URL it is given. Any failure — writing, or setting a security attribute — removes the
    /// whole session directory before throwing, so a partially protected clinical file never
    /// survives the call.
    func createLease(format: ExportFormat,
                     displayName: String,
                     now: Date = Date(),
                     write: (URL) throws -> Void) throws -> MedicalExportLease {
        let sessionID = UUID()
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Protect the container before it can hold anything.
            try protector.protect(directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw MedicalExportError.exportSetupFailed
        }

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
        guard Self.isContained(fileURL, within: root) else {
            try? fileManager.removeItem(at: directory)
            throw MedicalExportError.exportSetupFailed
        }

        do {
            try write(fileURL)
            guard fileManager.fileExists(atPath: fileURL.path) else { throw MedicalExportError.exportWriteFailed }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw MedicalExportError.exportWriteFailed
        }

        do {
            try protector.protect(fileURL)
            fileManager.createFile(atPath: directory.appendingPathComponent(Self.completionMarkerName).path,
                                   contents: nil)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw MedicalExportError.exportSetupFailed
        }

        activeSessions.insert(sessionID)
        return MedicalExportLease(
            id: sessionID,
            format: format,
            createdAt: now,
            fileURL: fileURL,
            displayName: Self.sanitizedDisplayName(displayName, format: format)
        )
    }

    /// Convenience for the formats that produce their bytes up front. Written atomically.
    func createLease(data: Data,
                     format: ExportFormat,
                     displayName: String,
                     now: Date = Date()) throws -> MedicalExportLease {
        try createLease(format: format, displayName: displayName, now: now) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Release

    /// Remove a lease's session directory. Idempotent: releasing twice, or releasing a lease whose
    /// directory a scavenge already removed, is a no-op.
    func release(_ lease: MedicalExportLease) {
        activeSessions.remove(lease.id)
        let directory = lease.sessionDirectory
        guard Self.isContained(directory, within: root) else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Remove every session under the export root, active ones included. For medical reset and
    /// compliance-mode enable, where "later" is not an acceptable answer.
    @discardableResult
    func revokeAll() -> Int {
        activeSessions.removeAll()
        let removed = sessionDirectories().reduce(into: 0) { count, directory in
            if (try? fileManager.removeItem(at: directory)) != nil { count += 1 }
        }
        return removed
    }

    // MARK: - Scavenging

    /// Delete abandoned sessions, and only those: incomplete ones immediately, completed ones once
    /// they outlive the crash-recovery window. Sessions this process still owns are skipped, and
    /// nothing outside the export root is ever examined.
    @discardableResult
    func scavenge(now: Date = Date(), ttl: TimeInterval = completedSessionTTL) -> Int {
        var removed = 0
        for directory in sessionDirectories() {
            if let id = UUID(uuidString: directory.lastPathComponent), activeSessions.contains(id) { continue }

            let marker = directory.appendingPathComponent(Self.completionMarkerName)
            if fileManager.fileExists(atPath: marker.path) {
                let finished = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(finished) > ttl else { continue }
            }
            if (try? fileManager.removeItem(at: directory)) != nil { removed += 1 }
        }
        return removed
    }

    /// Session directories under the export root. Only direct children, and only directories, so a
    /// sibling path outside the root can never be reached from here.
    private func sessionDirectories() -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && Self.isContained(url, within: root)
        }
    }

    // MARK: - Path safety

    /// True when `url` resolves to a location strictly beneath `root`. Callers supply no path
    /// components, so this is a belt-and-braces check on our own construction.
    static func isContained(_ url: URL, within root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Display names come from tool arguments. They never reach the filesystem — the on-disk name
    /// is a UUID — but they are still stripped of path separators so a name like `../../secrets`
    /// cannot misrepresent to the share UI what is being sent.
    static func sanitizedDisplayName(_ raw: String, format: ExportFormat) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "_" else { return "clinical_export.\(format.fileExtension)" }
        return cleaned
    }
}
