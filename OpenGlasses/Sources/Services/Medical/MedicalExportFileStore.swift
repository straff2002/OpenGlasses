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

/// The clinical name for the shared protection seam. Kept so clinical call sites and their tests
/// read in their own vocabulary while there is one implementation of the attributes themselves.
typealias MedicalExportProtecting = ProtectedExportProtecting

/// The clinical face of `ProtectedExportFileStore`: it adds the export *formats*, the clinical
/// error vocabulary, and the display-name fallback, and owns none of the mechanism.
///
/// The session directory, the protect-before-write ordering, the completion marker, the
/// crash-recovery scavenge and the containment checks all live in the shared store, because the
/// diagnostics export (Plan DM P3) needs precisely those guarantees and a second copy of them
/// would be a second thing to keep correct.
final class MedicalExportFileStore {
    /// Crash-recovery window for a completed session whose share never released it.
    static let completedSessionTTL: TimeInterval = ProtectedExportFileStore.completedSessionTTL

    private static let rootDirectoryName = "MedicalExports"

    private let store: ProtectedExportFileStore

    var root: URL { store.root }

    init(root: URL? = nil,
         fileManager: FileManager = .default,
         protector: MedicalExportProtecting = FileProtectionApplier()) {
        store = ProtectedExportFileStore(rootDirectoryName: Self.rootDirectoryName,
                                         root: root,
                                         fileManager: fileManager,
                                         protector: protector)
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
        let session: ProtectedExportSession
        do {
            session = try store.createSession(fileExtension: format.fileExtension, now: now, write: write)
        } catch ProtectedExportFault.writeFailed {
            throw MedicalExportError.exportWriteFailed
        } catch {
            throw MedicalExportError.exportSetupFailed
        }

        return MedicalExportLease(
            id: session.id,
            format: format,
            createdAt: session.createdAt,
            fileURL: session.fileURL,
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
        store.release(id: lease.id, directory: lease.sessionDirectory)
    }

    /// Remove every session under the export root, active ones included. For medical reset and
    /// compliance-mode enable, where "later" is not an acceptable answer.
    @discardableResult
    func revokeAll() -> Int { store.revokeAll() }

    // MARK: - Scavenging

    /// Delete abandoned sessions, and only those: incomplete ones immediately, completed ones once
    /// they outlive the crash-recovery window.
    @discardableResult
    func scavenge(now: Date = Date(), ttl: TimeInterval = completedSessionTTL) -> Int {
        store.scavenge(now: now, ttl: ttl)
    }

    // MARK: - Path safety

    /// True when `url` resolves to a location strictly beneath `root`.
    static func isContained(_ url: URL, within root: URL) -> Bool {
        ProtectedExportFileStore.isContained(url, within: root)
    }

    /// Display names come from tool arguments. They never reach the filesystem — the on-disk name
    /// is a UUID — but they are still stripped of path separators so a name like `../../secrets`
    /// cannot misrepresent to the share UI what is being sent.
    static func sanitizedDisplayName(_ raw: String, format: ExportFormat) -> String {
        ProtectedExportFileStore.sanitizedDisplayName(
            raw, fallback: "clinical_export.\(format.fileExtension)")
    }
}
