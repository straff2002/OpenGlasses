import Foundation

/// The one place a durable store's at-rest posture is applied, so `DataStoreRegistry` describes
/// something the file system will actually confirm.
///
/// The inventory's headline finding (W03.1) was that the seven SQLite stores sat in `Documents`
/// with no protection attribute the app had set and no backup exclusion, and that the two JSON
/// stores which *did* ask for `.completeFileProtection` were still copied into every backup. Both
/// halves are fixed here rather than in nine slightly different snippets.
///
/// ## Why `.completeUntilFirstUserAuthentication` for the databases
///
/// A SQLite handle is held open across a screen lock, and these stores are written from work that
/// continues while the app is backgrounded — the offline queue drains, usage is accounted for a
/// model turn that finishes late, a memory is written by a scheduled task. Under
/// `.complete` those writes fail the moment the device locks, and a failed write against an open
/// WAL is how a database gets truncated rather than merely unavailable. First-unlock is therefore
/// the strongest class these files can actually hold.
///
/// There is a second reason, and it is the honest one to state in the plan: SQLite creates the
/// `-wal` and `-shm` siblings itself, at whatever the container's default class is. Pinning the
/// main file to `.complete` while its write-ahead log sits at the container default would be a
/// guarantee in the registry that the bytes on disk do not honour. Pinning the class the siblings
/// will get is a guarantee that holds.
///
/// So the *protection* change here is mostly documentary — it states a class instead of inheriting
/// one — and the change that moves real bytes is the **backup exclusion**. That distinction is
/// recorded in `docs/plans/ET-iso27701-privacy.md` rather than smoothed over.
enum StoreProtection {

    /// The files SQLite creates beside a database. Journal mode is WAL for every store here, but
    /// `-journal` is included because a rollback-journal file can be left behind by an older
    /// build or a failed mode switch, and it holds the same rows.
    static let sqliteSiblingSuffixes = ["-wal", "-shm", "-journal"]

    /// What one `apply` did, so a caller can report a failure rather than assume success.
    struct Outcome: Equatable {
        /// Files whose attributes were set (or already matched).
        var applied: Int = 0
        /// Files that exist but refused the change — typically protected data while locked.
        var failed: Int = 0
        /// True when nothing at the primary URL exists yet; not a failure.
        var absent: Bool = false

        var isClean: Bool { failed == 0 }
    }

    /// Apply `protection` and, when asked, backup exclusion to `url` — and to its SQLite siblings
    /// when `includingSQLiteSiblings` is set.
    ///
    /// Idempotent by construction: setting the attribute a file already carries is a no-op, which
    /// is what makes this safe to call on every open and is how a store that already exists on a
    /// device is migrated. A file that is not there yet is skipped, not created.
    @discardableResult
    static func apply(_ protection: FileProtectionType,
                      backupExcluded: Bool,
                      to url: URL,
                      includingSQLiteSiblings: Bool = false,
                      fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        guard fileManager.fileExists(atPath: url.path) else {
            outcome.absent = true
            return outcome
        }
        applyOne(protection, backupExcluded: backupExcluded, to: url,
                 fileManager: fileManager, into: &outcome)
        guard includingSQLiteSiblings else { return outcome }
        for suffix in sqliteSiblingSuffixes {
            let sibling = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: sibling.path) else { continue }
            applyOne(protection, backupExcluded: backupExcluded, to: sibling,
                     fileManager: fileManager, into: &outcome)
        }
        return outcome
    }

    /// The posture every SQLite store in this app gets: first-unlock protection, backup excluded,
    /// siblings included. One call so the class cannot drift between the seven databases.
    @discardableResult
    static func applyDatabase(at url: URL, fileManager: FileManager = .default) -> Outcome {
        apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: url,
              includingSQLiteSiblings: true, fileManager: fileManager)
    }

    /// Apply to a directory and everything directly inside it. Used by the stores that keep a
    /// folder rather than a file.
    @discardableResult
    static func applyToDirectory(_ protection: FileProtectionType,
                                 backupExcluded: Bool,
                                 at url: URL,
                                 fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        guard fileManager.fileExists(atPath: url.path) else {
            outcome.absent = true
            return outcome
        }
        applyOne(protection, backupExcluded: backupExcluded, to: url,
                 fileManager: fileManager, into: &outcome)
        let children = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            applyOne(protection, backupExcluded: backupExcluded, to: child,
                     fileManager: fileManager, into: &outcome)
        }
        return outcome
    }

    private static func applyOne(_ protection: FileProtectionType,
                                 backupExcluded: Bool,
                                 to url: URL,
                                 fileManager: FileManager,
                                 into outcome: inout Outcome) {
        var ok = true
        do {
            try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        } catch {
            // The simulator and some volumes do not implement data protection at all. That is a
            // platform answer, not a store failure, so it is not counted against the store; the
            // attribute test reads back only what the platform reports.
            ok = (error as NSError).code != NSFileWriteUnsupportedSchemeError
        }
        if backupExcluded {
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do { try mutable.setResourceValues(values) } catch { ok = false }
        }
        if ok { outcome.applied += 1 } else { outcome.failed += 1 }
    }
}
