import Foundation

/// The record of which local models are installed, and the one-time migration that gives every
/// already-downloaded MLX model a record without touching a byte of it.
///
/// ### What "installed" means
/// A model is installed only when `installed/<storageComponent>/` holds **both** a decodable
/// `installation.json` and a `.complete` marker. A directory with one and not the other is a
/// half-written record and is never presented as installed — the marker is written last, so an
/// interruption leaves an incomplete record rather than a lie.
///
/// ### Why the files do not move
/// Existing MLX models live in swift-huggingface's `models--org--name` layout directly under
/// `LocalModels/`, and moving multi-gigabyte directories is exactly the kind of migration that
/// costs a user their model when it is interrupted. So PR1 **discovers and records**; the record
/// says `.legacyHubSnapshot` and points at the directory where the files already are. Nothing is
/// copied, moved, or deleted.
///
/// ### Why the version stamp is written last
/// Following the split-store precedent in `FHIRConfigurationStore`: every record is written, then
/// **read back and compared**, and only when all of them verify is the migration version stamped.
/// An interrupted or unverifiable run therefore retries on the next launch instead of recording
/// that a migration happened. The migration is forward-only and idempotent.
///
/// Pure Foundation, with the root directory, `FileManager`, defaults and the legacy scan all
/// injectable, so the whole thing runs headlessly against a temp directory.
final class LocalModelRepository {

    /// Preference key holding the completed migration version.
    static let migrationVersionKey = "localModelRecordsMigratedVersion"
    /// Bumped when the migration must run again over already-migrated devices.
    static let migrationVersion = 1

    static let manifestFileName = "installation.json"
    static let completionMarkerName = ".complete"
    static let installedDirectoryName = "installed"
    static let stagingDirectoryName = "staging"
    static let quarantineDirectoryName = "quarantine"

    /// Outcome of the legacy migration. Mirrors the vocabulary the FHIR split-store migration
    /// established, so "we could not check" never reads as success.
    enum MigrationOutcome: Equatable {
        /// Nothing to record, or already recorded at this version.
        case notNeeded
        /// Records written and read back; the version was stamped.
        case migrated(count: Int)
        /// Storage was unavailable (file protection while the device is locked). Retried next
        /// launch; the version is not stamped.
        case deferred
        /// A write succeeded but the read-back disagreed, or the directory could not be created.
        /// The version is not stamped and the existing installations are untouched.
        case failed
    }

    /// Why a record could not be written. Typed so the migration can tell "retry later" from
    /// "something is wrong".
    enum RecordError: Error, Equatable {
        /// Storage refused the write in a way that is expected to clear (device locked).
        case storageUnavailable
        /// The record was written and read back as something else.
        case readBackMismatch(LocalModelID)
        /// The record's own directory could not be created or written.
        case notWritable
    }

    let root: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    /// Legacy MLX model ids present on disk. Injected so a test can supply them without building a
    /// hub cache layout; production scans `root` for `models--org--name` directories.
    private let legacyModelIDs: () -> [String]
    /// Clock, injected so a record's `installedAt` is deterministic in tests.
    private let now: () -> Date

    init(root: URL? = nil,
         fileManager: FileManager = .default,
         defaults: UserDefaults = .standard,
         legacyModelIDs: (() -> [String])? = nil,
         now: @escaping () -> Date = Date.init) {
        let resolvedRoot = root ?? Self.defaultRoot(fileManager: fileManager)
        self.root = resolvedRoot
        self.fileManager = fileManager
        self.defaults = defaults
        self.now = now
        self.legacyModelIDs = legacyModelIDs
            ?? { Self.legacyHubModelIDs(under: resolvedRoot, fileManager: fileManager) }
    }

    /// `Application Support/LocalModels` — the same directory `LocalLLMService` already uses, so a
    /// record sits beside the files it describes.
    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("LocalModels", isDirectory: true)
    }

    var installedRoot: URL { root.appendingPathComponent(Self.installedDirectoryName, isDirectory: true) }
    var stagingRoot: URL { root.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true) }
    var quarantineRoot: URL { root.appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true) }

    func directory(for id: LocalModelID) -> URL {
        installedRoot.appendingPathComponent(id.storageComponent, isDirectory: true)
    }

    // MARK: - Reading

    /// Every complete installation, ordered by id so the result is stable.
    func installedModels() -> [InstalledLocalModel] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: installedRoot, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .compactMap { entry -> InstalledLocalModel? in
                guard LocalModelID(storageComponent: entry.lastPathComponent) != nil else { return nil }
                return installation(inDirectory: entry)
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func installation(for id: LocalModelID) -> InstalledLocalModel? {
        installation(inDirectory: directory(for: id))
    }

    func isInstalled(_ id: LocalModelID) -> Bool { installation(for: id) != nil }

    /// Load a record, enforcing the "manifest **and** marker" rule.
    private func installation(inDirectory directory: URL) -> InstalledLocalModel? {
        let marker = directory.appendingPathComponent(Self.completionMarkerName)
        guard fileManager.fileExists(atPath: marker.path) else { return nil }
        let manifest = directory.appendingPathComponent(Self.manifestFileName)
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? Self.decoder.decode(InstalledLocalModel.self, from: data)
    }

    // MARK: - Writing

    /// Write a record and prove it can be read back before marking it complete.
    ///
    /// Order matters and is the crash-consistency argument: manifest → read back → marker. A power
    /// loss before the marker leaves a directory that `installedModels()` ignores; a power loss
    /// after it leaves a record that was already verified.
    func record(_ installation: InstalledLocalModel) throws {
        let directory = directory(for: installation.id)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Self.classify(error)
        }

        let manifest = directory.appendingPathComponent(Self.manifestFileName)
        do {
            let data = try Self.encoder.encode(installation)
            try data.write(to: manifest, options: .atomic)
        } catch {
            throw Self.classify(error)
        }

        // Read back before declaring the record good. A store that accepts a write and returns
        // something else is a failure, not an installation.
        guard let readBack = try? Data(contentsOf: manifest),
              let decoded = try? Self.decoder.decode(InstalledLocalModel.self, from: readBack),
              Self.matches(written: installation, readBack: decoded) else {
            throw RecordError.readBackMismatch(installation.id)
        }

        do {
            try Data().write(to: directory.appendingPathComponent(Self.completionMarkerName),
                             options: .atomic)
        } catch {
            throw Self.classify(error)
        }
        excludeFromBackup(directory)
    }

    /// Whether a read-back record is the record that was written.
    ///
    /// Compared on the fields the record exists to carry rather than by whole-value equality: the
    /// encoder rounds `installedAt` to the JSON date representation, and a sub-millisecond
    /// difference there is not a corrupted record. Pure, so the rule is directly testable.
    static func matches(written: InstalledLocalModel, readBack: InstalledLocalModel) -> Bool {
        written.id == readBack.id
            && written.manifestVersion == readBack.manifestVersion
            && written.descriptor == readBack.descriptor
            && written.storage == readBack.storage
            && written.validatedFiles == readBack.validatedFiles
            && written.acceptedLicenseRevision == readBack.acceptedLicenseRevision
            && abs(written.installedAt.timeIntervalSince(readBack.installedAt)) < 1
    }

    /// Distinguish "the device is locked, try again" from "this is broken".
    private static func classify(_ error: Error) -> RecordError {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return .notWritable }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileReadNoPermission, .fileWriteNoPermission, .fileReadInapplicableStringEncoding:
            return .storageUnavailable
        default:
            return .notWritable
        }
    }

    private func excludeFromBackup(_ url: URL) {
        // Re-downloadable weights (and the records describing them) must not ride along in iCloud
        // backups — the same rule the hub cache directory already follows.
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    // MARK: - Migration

    /// True while legacy MLX installs still have no record at the current version.
    var isMigrationPending: Bool {
        defaults.integer(forKey: Self.migrationVersionKey) < Self.migrationVersion
    }

    /// Give every already-downloaded MLX model a record. Idempotent, forward-only, and safe to call
    /// on every launch.
    ///
    /// Nothing is moved and nothing is deleted: the record points at the hub directory the files
    /// are already in. The only "legacy removal" involved is the version stamp that stops this
    /// running again, and it is written last — after every record has been read back.
    @discardableResult
    func migrateIfNeeded() -> MigrationOutcome {
        guard isMigrationPending else { return .notNeeded }

        let legacyIDs = legacyModelIDs()
        guard !legacyIDs.isEmpty else {
            // Nothing on disk is not a failure to migrate — it is a device with no local models.
            defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
            return .notNeeded
        }

        do {
            try fileManager.createDirectory(at: installedRoot, withIntermediateDirectories: true)
        } catch {
            let fault = Self.classify(error)
            return report(fault, found: legacyIDs.count, written: 0)
        }

        var written = 0
        for rawID in legacyIDs {
            let id = LocalModelID(rawID)
            // Idempotent: a record from an interrupted earlier run is left exactly as it is.
            if isInstalled(id) { continue }

            let descriptor = LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: rawID)
            let directoryName = Self.legacyDirectoryName(forModelID: rawID)
            let record = InstalledLocalModel(
                descriptor: descriptor,
                storage: .legacyHubSnapshot(directoryName: directoryName),
                installedAt: legacyInstallDate(directoryName: directoryName) ?? now(),
                // Empty, and honestly so: these files were fetched before any digest was recorded,
                // so there is nothing this record can claim to have validated.
                validatedFiles: [])
            do {
                try self.record(record)
                written += 1
            } catch {
                let fault = (error as? RecordError) ?? .notWritable
                return report(fault, found: legacyIDs.count, written: written)
            }
        }

        // Every record verified. Only now is it safe to stop looking at the legacy layout.
        defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
        // Counts only: a compatibility id is whatever the user typed, so it is user-authored text
        // and has no business in a log line. How many were recorded is the diagnostic.
        PrivacyLog.localModel(.recordsMigrated, count: written, total: legacyIDs.count)
        return .migrated(count: written)
    }

    private func report(_ fault: RecordError, found: Int, written: Int) -> MigrationOutcome {
        switch fault {
        case .storageUnavailable:
            PrivacyLog.localModel(.recordsMigrationDeferred, count: written, total: found)
            return .deferred
        case .readBackMismatch, .notWritable:
            PrivacyLog.localModel(.recordsMigrationFailed, count: written, total: found)
            return .failed
        }
    }

    /// Creation date of the legacy hub directory, so a migrated record does not claim the model was
    /// installed the moment the migration ran.
    private func legacyInstallDate(directoryName: String) -> Date? {
        let url = root.appendingPathComponent(directoryName, isDirectory: true)
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    // MARK: - Legacy layout

    /// `mlx-community/gemma-4-e2b-it-4bit` → `models--mlx-community--gemma-4-e2b-it-4bit`.
    static func legacyDirectoryName(forModelID rawID: String) -> String {
        "models--" + rawID.replacingOccurrences(of: "/", with: "--")
    }

    /// `models--mlx-community--gemma-4-e2b-it-4bit` → `mlx-community/gemma-4-e2b-it-4bit`, or nil
    /// when the directory is not a hub snapshot.
    static func modelID(fromLegacyDirectoryName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let repo = String(name.dropFirst("models--".count))
        guard !repo.isEmpty else { return nil }
        return repo.replacingOccurrences(of: "--", with: "/")
    }

    /// Scan for hub-layout model directories. The same rule `LocalLLMService.downloadedModelIdsOnDisk`
    /// applies, kept here so the repository can be pointed at any root.
    static func legacyHubModelIDs(under root: URL, fileManager: FileManager = .default) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries
            .compactMap { modelID(fromLegacyDirectoryName: $0.lastPathComponent) }
            .sorted()
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so a record's bytes depend only on its values — which is what makes the
        // read-back comparison and any future digest of the manifest meaningful.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
