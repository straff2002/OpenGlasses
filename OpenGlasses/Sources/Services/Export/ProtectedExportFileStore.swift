import Foundation

/// The security attributes every protected export must carry, behind a seam so tests can observe
/// the pass and drive its failure path — the simulator does not reliably report file protection
/// back, so asserting the applier ran is the part that stays verifiable everywhere.
protocol ProtectedExportProtecting {
    func protect(_ url: URL) throws
}

/// Production attributes: complete file protection plus backup exclusion.
struct FileProtectionApplier: ProtectedExportProtecting {
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

/// One protected session directory holding exactly one file.
struct ProtectedExportSession: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    /// Generic on-disk location, named by UUID. Any user-facing name travels separately.
    let fileURL: URL

    var directory: URL { fileURL.deletingLastPathComponent() }
}

/// What can go wrong before a caller has a file. Deliberately two cases and no payload: the
/// path, the filename and the underlying error are all things the caller must not be handed a
/// reason to log.
enum ProtectedExportFault: Error, Equatable {
    /// The session could not be created, or its security attributes could not be applied.
    case setupFailed
    /// The content could not be written.
    case writeFailed
}

/// Creates and destroys the protected session directories every user-initiated export lives in.
///
/// Every export gets its own `Library/Caches/<root>/<UUID>/` directory, protected before any
/// content is written and marked complete only once the finished file is protected too. That
/// ordering is what lets the scavenger tell a crash-abandoned session from a live one without
/// keeping a ledger of what any file contained.
///
/// This is the mechanism that shipped for clinical exports, lifted out of them unchanged so the
/// diagnostics export gets the same guarantees rather than a second, slightly different copy of
/// them. What stays per-domain is the *policy* on top: which formats exist, what the audit trail
/// records, and when a share is considered over. `MedicalExportFileStore` is the clinical
/// adapter; `DiagnosticExportCoordinator` is the diagnostics one.
final class ProtectedExportFileStore {
    /// Crash-recovery window for a completed session whose share never released it.
    static let completedSessionTTL: TimeInterval = 3600

    /// Empty marker written last. Its presence means "content finished and protected".
    private static let completionMarkerName = ".complete"

    let root: URL

    private let fileManager: FileManager
    private let protector: ProtectedExportProtecting
    /// Sessions this process still owns. A scan never touches them, so a scavenge racing a live
    /// export cannot delete the file that is about to be shared.
    private var activeSessions: Set<UUID> = []

    init(rootDirectoryName: String,
         root: URL? = nil,
         fileManager: FileManager = .default,
         protector: ProtectedExportProtecting = FileProtectionApplier()) {
        self.fileManager = fileManager
        self.protector = protector
        if let root {
            self.root = root
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.root = caches.appendingPathComponent(rootDirectoryName, isDirectory: true)
        }
    }

    // MARK: - Creation

    /// Create a protected session and hand its file to `write`, which must produce the content at
    /// the URL it is given. Any failure — writing, or setting a security attribute — removes the
    /// whole session directory before throwing, so a partially protected file never survives the
    /// call.
    func createSession(fileExtension: String,
                       now: Date = Date(),
                       write: (URL) throws -> Void) throws -> ProtectedExportSession {
        let sessionID = UUID()
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Protect the container before it can hold anything.
            try protector.protect(directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw ProtectedExportFault.setupFailed
        }

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        guard Self.isContained(fileURL, within: root) else {
            try? fileManager.removeItem(at: directory)
            throw ProtectedExportFault.setupFailed
        }

        do {
            try write(fileURL)
            guard fileManager.fileExists(atPath: fileURL.path) else { throw ProtectedExportFault.writeFailed }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw ProtectedExportFault.writeFailed
        }

        do {
            try protector.protect(fileURL)
            fileManager.createFile(atPath: directory.appendingPathComponent(Self.completionMarkerName).path,
                                   contents: nil)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw ProtectedExportFault.setupFailed
        }

        activeSessions.insert(sessionID)
        return ProtectedExportSession(id: sessionID, createdAt: now, fileURL: fileURL)
    }

    // MARK: - Release

    /// Remove a session's directory. Idempotent: releasing twice, or releasing a session whose
    /// directory a scavenge already removed, is a no-op.
    func release(id: UUID, directory: URL) {
        activeSessions.remove(id)
        guard Self.isContained(directory, within: root) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func release(_ session: ProtectedExportSession) {
        release(id: session.id, directory: session.directory)
    }

    /// Remove every session under the export root, active ones included. For a data reset, where
    /// "later" is not an acceptable answer.
    @discardableResult
    func revokeAll() -> Int {
        activeSessions.removeAll()
        return sessionDirectories().reduce(into: 0) { count, directory in
            if (try? fileManager.removeItem(at: directory)) != nil { count += 1 }
        }
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

    /// Display names come from outside this type — a tool argument, a wearer-typed title. They
    /// never reach the filesystem (the on-disk name is a UUID) but they are still stripped of path
    /// separators so a name like `../../secrets` cannot misrepresent to the share UI what is being
    /// sent.
    static func sanitizedDisplayName(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "_" else { return fallback }
        return cleaned
    }
}
