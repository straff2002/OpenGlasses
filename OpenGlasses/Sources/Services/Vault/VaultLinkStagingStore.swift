import Foundation

/// Plan FS §3 — where a vault archive sits between "downloaded" and "reviewed".
///
/// A received vault can be a large file, so it is never held whole in memory while the reader
/// reads the review sheet: the bytes go to a protected, backup-excluded file under Caches, the
/// review is taken from a mapped read of it, and the file is deleted the moment the install
/// finishes, fails or is dismissed. Nothing survives the process — a staging directory found at
/// launch belonged to an approval that no longer exists and is swept.
///
/// The on-disk size is authoritative on every append, so a peer that lies about `Content-Length`
/// cannot write past the cap by streaming.
struct StagedVaultArchive: Equatable {
    let id: UUID
    let fileURL: URL

    var directory: URL { fileURL.deletingLastPathComponent() }
}

enum VaultLinkStagingError: Error, Equatable {
    case setupFailed
    case writeFailed
    case unavailable
    case tooLarge
}

/// Protected staging for one consented vault fetch.
final class VaultLinkStagingStore {

    let root: URL

    private let fileManager: FileManager
    private let maximumBytes: Int

    init(root: URL? = nil, fileManager: FileManager = .default,
         maximumBytes: Int = Config.vaultLinkMaxBytes) {
        self.fileManager = fileManager
        self.maximumBytes = maximumBytes
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.root = root ?? caches.appendingPathComponent("VaultLinkStaging", isDirectory: true)
    }

    /// An empty, protected file, created before any untrusted byte is written.
    func create() throws -> StagedVaultArchive {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("archive.zip")
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try protect(root)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try protect(directory)
            guard fileManager.createFile(atPath: fileURL.path, contents: nil,
                                         attributes: [.protectionKey: FileProtectionType.complete]) else {
                throw VaultLinkStagingError.setupFailed
            }
            try protect(fileURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw VaultLinkStagingError.setupFailed
        }
        return StagedVaultArchive(id: id, fileURL: fileURL)
    }

    /// One bounded chunk. The file's own size decides whether it fits, on every call.
    func append(_ data: Data, to archive: StagedVaultArchive) throws {
        guard isContained(archive.fileURL), fileManager.fileExists(atPath: archive.fileURL.path),
              let size = try? fileManager.attributesOfItem(atPath: archive.fileURL.path)[.size] as? NSNumber,
              size.intValue <= maximumBytes,
              data.count <= maximumBytes - size.intValue else {
            throw VaultLinkStagingError.tooLarge
        }
        do {
            let handle = try FileHandle(forWritingTo: archive.fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw VaultLinkStagingError.writeFailed
        }
    }

    /// Mapped read: the zip reader walks the central directory and inflates one entry at a time,
    /// so the archive itself never needs a second copy in the heap.
    func load(_ archive: StagedVaultArchive) throws -> Data {
        guard isContained(archive.fileURL), fileManager.fileExists(atPath: archive.fileURL.path),
              let size = try? fileManager.attributesOfItem(atPath: archive.fileURL.path)[.size] as? NSNumber,
              size.intValue <= maximumBytes else {
            throw VaultLinkStagingError.unavailable
        }
        do {
            return try Data(contentsOf: archive.fileURL, options: .mappedIfSafe)
        } catch {
            throw VaultLinkStagingError.unavailable
        }
    }

    func remove(_ archive: StagedVaultArchive) {
        guard isContained(archive.directory) else { return }
        try? fileManager.removeItem(at: archive.directory)
    }

    /// No approval survives process termination, so any session directory still here belonged to
    /// one that is gone.
    func removeAbandonedSessions() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for child in children where UUID(uuidString: child.lastPathComponent) != nil && isContained(child) {
            try? fileManager.removeItem(at: child)
        }
    }

    private func isContained(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private func protect(_ url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete],
                                      ofItemAtPath: url.path)
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
