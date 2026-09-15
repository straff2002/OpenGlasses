import Foundation

/// Which iOS protection class a Medical Compliance file gets, and the sweep that applies it to
/// recording artefacts which already exist when the mode is turned on.
///
/// ## Two classes, chosen by *when* a file can be written
///
/// - `.foregroundRecord` → `FileProtectionType.complete`. For files that are only ever written
///   while the app is in front of an unlocked phone: the audit log and clinical exports. Nothing
///   about them needs to survive a lock, so they get the strongest class.
/// - `.recordingArtefact` → `FileProtectionType.completeUnlessOpen`. For recordings (audio and
///   video), the transcripts written beside and about them, and the recorded-sessions list. The
///   app declares the `audio` background mode, so a recording can be started, stopped and filed
///   while the phone is locked, by voice or from the glasses. A `.complete` file cannot be created
///   or opened while locked, and setting `.complete` on a file that was just finished while locked
///   fails — which is how these files used to end up with no protection at all.
///   `.completeUnlessOpen` can be created and written while locked, and once closed it cannot be
///   opened again until the phone is unlocked. At rest it protects the same way `.complete` does.
///
/// Both classes come with backup exclusion. Outside compliance mode this type does nothing: the
/// decision function returns nil and no attribute is touched.
///
/// Failures are reported through `PrivacyLog` and never thrown. A recording that could not be
/// protected is still a recording the wearer needs to keep.
enum ComplianceFileProtection {

    enum Kind: Equatable {
        /// Written only in the foreground: the audit log, clinical exports.
        case foregroundRecord
        /// Can be created or finished while the phone is locked: recordings, their transcripts,
        /// the recorded-sessions list.
        case recordingArtefact
    }

    /// The class `kind` gets, or nil when compliance mode is off and nothing should be set.
    static func protectionType(for kind: Kind, complianceMode: Bool) -> FileProtectionType? {
        guard complianceMode else { return nil }
        switch kind {
        case .foregroundRecord: return .complete
        case .recordingArtefact: return .completeUnlessOpen
        }
    }

    /// Apply `kind`'s class and backup exclusion to one file or directory. Returns nil when the
    /// mode is off (nothing was done). A missing file is reported as `absent`, not as a failure.
    @discardableResult
    static func apply(_ kind: Kind, to url: URL, complianceMode: Bool,
                      fileManager: FileManager = .default) -> StoreProtection.Outcome? {
        guard let protection = protectionType(for: kind, complianceMode: complianceMode) else {
            return nil
        }
        return StoreProtection.apply(protection, backupExcluded: true, to: url,
                                     fileManager: fileManager)
    }

    /// `apply`, plus a content-free log line saying whether it held.
    @discardableResult
    static func protect(_ url: URL, as kind: Kind, complianceMode: Bool,
                        fileManager: FileManager = .default) -> StoreProtection.Outcome? {
        let outcome = apply(kind, to: url, complianceMode: complianceMode, fileManager: fileManager)
        report(outcome)
        return outcome
    }

    // MARK: - In-progress recordings

    /// Subfolder of the temporary directory that in-progress recordings are written into while
    /// compliance mode is on.
    ///
    /// `AVAssetWriter` creates its output file itself, lazily, and the file is open for the whole
    /// recording, so there is no moment to set an attribute on it before the first bytes land.
    /// A new file takes its protection class from the directory it is created in, so the folder
    /// carries the class and the writer's file inherits it from the start.
    static let inProgressDirectoryName = "ComplianceRecordings"

    /// Where a recording that is starting now should be written. Outside compliance mode that is
    /// the temporary directory itself, as before. Inside it, the protected subfolder — or, if that
    /// folder cannot be created, the temporary directory again: the recording still happens, and
    /// the file is protected explicitly when it is finished and filed.
    static func inProgressDirectory(complianceMode: Bool,
                                    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                                    fileManager: FileManager = .default) -> URL {
        guard complianceMode else { return temporaryDirectory }
        let directory = temporaryDirectory
            .appendingPathComponent(inProgressDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        } catch {
            PrivacyLog.medical(.compliance, .fileProtectionFailed, error: SafeErrorSummary(error))
            return temporaryDirectory
        }
        // `createDirectory` ignores `attributes` when the folder already exists, so set the class
        // explicitly too. Idempotent.
        protect(directory, as: .recordingArtefact, complianceMode: true, fileManager: fileManager)
        return directory
    }

    // MARK: - The enable-time sweep

    /// The app's own storage locations for recording artefacts. Read from the owning services
    /// (see `HIPAAComplianceService.recordingArtefactLocations`), never guessed at here.
    struct Locations: Equatable {
        /// Folders holding recordings: audio, video, and each video's transcript sidecar.
        var recordingsDirectories: [URL]
        /// The app's own transcripts folder. A folder the wearer chose is not swept: it can be
        /// iCloud Drive or another app's storage, where this app's class does not govern the copy.
        var transcriptsDirectory: URL?
        /// `recorded_sessions.json`.
        var recordedSessionsFile: URL?
    }

    enum SweepTarget: Equatable {
        /// The folder and everything directly inside it. The folder itself gets the class too,
        /// so files created there later inherit it.
        case directory(URL)
        case file(URL)
    }

    /// What the sweep will touch, in order, with duplicates removed.
    static func sweepTargets(_ locations: Locations) -> [SweepTarget] {
        var seen = Set<String>()
        var targets: [SweepTarget] = []
        func add(_ target: SweepTarget, _ url: URL) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            targets.append(target)
        }
        for directory in locations.recordingsDirectories { add(.directory(directory), directory) }
        if let transcripts = locations.transcriptsDirectory { add(.directory(transcripts), transcripts) }
        if let sessions = locations.recordedSessionsFile { add(.file(sessions), sessions) }
        return targets
    }

    /// Apply the recording-artefact class to every existing file at `locations`.
    ///
    /// Cheap and idempotent: it sets attributes and reads nothing, re-applying a class a file
    /// already carries is a no-op, and a location that does not exist is skipped. Run from the
    /// mode being turned on, which happens in Settings on an unlocked phone.
    @discardableResult
    static func sweep(_ locations: Locations,
                      fileManager: FileManager = .default) -> StoreProtection.Outcome {
        var total = StoreProtection.Outcome()
        var anyPresent = false
        for target in sweepTargets(locations) {
            let outcome: StoreProtection.Outcome
            switch target {
            case .directory(let url):
                outcome = StoreProtection.applyToDirectory(.completeUnlessOpen, backupExcluded: true,
                                                           at: url, fileManager: fileManager)
            case .file(let url):
                outcome = StoreProtection.apply(.completeUnlessOpen, backupExcluded: true,
                                                to: url, fileManager: fileManager)
            }
            total.applied += outcome.applied
            total.failed += outcome.failed
            if !outcome.absent { anyPresent = true }
        }
        total.absent = !anyPresent
        return total
    }

    // MARK: - Reporting

    /// Content-free: a count and a class of event, never a file name.
    static func report(_ outcome: StoreProtection.Outcome?) {
        guard let outcome, !outcome.absent else { return }
        if outcome.failed > 0 {
            PrivacyLog.medical(.compliance, .fileProtectionFailed, count: outcome.failed)
        } else if outcome.applied > 0 {
            PrivacyLog.medical(.compliance, .fileProtected, count: outcome.applied)
        }
    }
}
