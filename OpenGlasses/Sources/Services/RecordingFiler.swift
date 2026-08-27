import Foundation

/// The filesystem work filing a finished recording needs, behind a seam so tests can run in a
/// temp directory and fake a failing move or copy without a real recording.
protocol RecordingFileOperating {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
}

/// The real thing: `FileManager`, with the argument labels the filer wants.
struct RecordingFileManagerOperations: RecordingFileOperating {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }
}

/// Decides where a finished recording ends up, and puts it there.
///
/// The recorder writes into `tmp/` while it encodes, which is the right place for a file that is
/// still being written and the wrong place for one that is finished: iOS evicts the temporary
/// directory whenever it likes. Until this existed, only the AI-tool path opted into saving to
/// Photos — the UI path handed the temporary URL straight to a share sheet, so dismissing that
/// sheet threw the recording away without ever saying so. An hour of footage is not something to
/// lose to a swipe.
///
/// So filing is unconditional and ordered by durability: move out of `tmp/` into the app's own
/// Recordings folder first (that copy needs no permission and cannot be declined), then the
/// optional extras — the Photos album and a user-chosen folder. Nothing is ever deleted; if a
/// destination fails, the ones that worked stand, and `Outcome` says plainly which did.
struct RecordingFiler {

    /// Where a filing attempt left things.
    struct Outcome: Equatable {
        /// The most durable location the file reached — the Recordings folder when the move
        /// worked, otherwise the user-folder copy, otherwise the temporary file it started as.
        /// This is the URL to share, to protect, and to write the transcript sidecar beside.
        var primaryURL: URL
        /// The move into the app's Recordings folder succeeded.
        var savedToLibrary: Bool
        /// A Photos save was asked for.
        var photosRequested: Bool
        /// The Photos save landed.
        var savedToPhotos: Bool
        /// A user-chosen folder was configured.
        var folderRequested: Bool
        /// Where the user-folder copy landed, if one was made.
        var folderCopyURL: URL?
        /// The Photos save was refused by authorization rather than failing on its own merits.
        /// Worth its own flag because it is the only failure here the wearer can actually fix,
        /// and telling them "couldn't save" when the answer is one switch in Settings is not
        /// honest reporting — it is a dead end.
        var photosNotPermitted: Bool = false

        /// True when at least one copy survives outside the temporary directory.
        var isPersisted: Bool {
            savedToLibrary || savedToPhotos || folderCopyURL != nil
        }

        /// Where the surviving copy actually is, phrased to drop into a sentence. Reads off what
        /// landed rather than off `primaryURL`'s parent, so a run where the app-folder move failed
        /// doesn't describe the user's own folder as "the app's".
        private var location: String {
            if savedToLibrary {
                return "the app's \(primaryURL.deletingLastPathComponent().lastPathComponent) folder"
            }
            if folderCopyURL != nil { return "your chosen folder" }
            if savedToPhotos { return "your Photos library" }
            return "temporary storage"
        }

        /// What to tell the user, or nil when everything they asked for landed.
        ///
        /// Deliberately names where the recording *is* rather than only what failed: the whole
        /// point of the safety-net copy is that the user can go and get it.
        var message: String? {
            guard isPersisted else {
                return "The recording could not be saved anywhere — it is still in temporary "
                     + "storage and may not survive. Free up some space and try again."
            }
            if photosRequested && !savedToPhotos {
                if photosNotPermitted {
                    return "OpenGlasses doesn't have permission to add to your photo library, so "
                         + "the recording isn't in Photos. You can turn that on in Settings. It is "
                         + "safe in \(location) — nothing was lost."
                }
                return "Couldn't save the recording to Photos. The recording is safe in "
                     + "\(location) — nothing was lost."
            }
            if folderRequested && folderCopyURL == nil {
                return "Couldn't copy the recording to your chosen folder. The recording is safe "
                     + "in \(location) — nothing was lost."
            }
            return nil
        }

        /// Where the recording ended up, in plain words — spoken back by the voice paths, which
        /// have no screen to show a file path on. Always says something, unlike `message`.
        var summary: String {
            var places: [String] = []
            if savedToLibrary { places.append("the app's Recordings folder") }
            if savedToPhotos { places.append("the Glasses album in Photos") }
            if folderCopyURL != nil { places.append("your chosen folder") }
            switch places.count {
            case 0:
                return "The recording is still in temporary storage — it was not saved."
            case 1:
                return "Saved to \(places[0])."
            default:
                let last = places.removeLast()
                return "Saved to \(places.joined(separator: ", ")) and \(last)."
            }
        }
    }

    /// The app's own recordings folder — the copy that always happens.
    let recordingsDirectory: URL
    /// Optional user-chosen folder to also copy into. Any security scope belongs to the caller,
    /// which resolves the bookmark and holds the scope across `file(_:date:saveToPhotos:)`.
    var folderURL: URL? = nil
    var ops: RecordingFileOperating = RecordingFileManagerOperations()

    /// `Documents/Recordings` — backed up, not evictable, and shared with the audio recorder so
    /// everything the app has captured sits in one place. (The container is not exposed to the
    /// Files app; a user who wants to browse their recordings picks a folder in Settings.)
    static var defaultRecordingsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Recordings")
    }

    // MARK: - Naming (pure)

    /// Timestamped name for a recording that finished at `date` — "Recording_2026-08-24_143012.mp4".
    /// Sorts chronologically as text, which is how any file browser will list it.
    static func fileName(for date: Date, fileExtension: String,
                         timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stem = "Recording_\(formatter.string(from: date))"
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    /// First name in the `base`, `base-2`, `base-3` … sequence that `exists` says is free.
    ///
    /// Two recordings can finish in the same second (a stop-start-stop in quick succession, or a
    /// user folder that already holds a file from an earlier install), and the older one must not
    /// be overwritten — losing a recording is exactly what this whole file exists to prevent.
    static func uniqueURL(base: URL, exists: (URL) -> Bool) -> URL {
        guard exists(base) else { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let directory = base.deletingLastPathComponent()
        // `appendingPathExtension("")` is not a no-op on every Foundation, so build the name.
        let named: (String) -> URL = { suffix in
            let file = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            return directory.appendingPathComponent(file)
        }
        for suffix in 2...999 {
            let candidate = named("\(suffix)")
            if !exists(candidate) { return candidate }
        }
        // 998 collisions in one second is not a real case; fall back to something unique rather
        // than returning a URL we know is taken.
        return named(UUID().uuidString)
    }

    // MARK: - Filing

    /// Move `source` out of temporary storage and into every on-disk destination.
    ///
    /// Order matters: the app-folder move goes first so a permission prompt or a Photos failure
    /// can never leave the recording stranded in `tmp/`. The user-folder copy runs from whichever
    /// location the file reached. The Photos save deliberately stays outside this method — it is
    /// the one destination that needs an authorization prompt and a framework the core has no
    /// business linking — so the caller performs it against `Outcome.primaryURL` and records the
    /// result on `savedToPhotos`. `saveToPhotos` here only says whether it was *asked for*, which
    /// is what `message` needs in order to be honest about what did and didn't land.
    func file(_ source: URL, date: Date, saveToPhotos: Bool) -> Outcome {
        let name = Self.fileName(for: date, fileExtension: source.pathExtension)

        var outcome = Outcome(primaryURL: source,
                              savedToLibrary: false,
                              photosRequested: saveToPhotos,
                              savedToPhotos: false,
                              folderRequested: folderURL != nil,
                              folderCopyURL: nil)

        // 1. Out of tmp/ and into the app's own folder — no permission, no dialog, no eviction.
        do {
            try ops.createDirectory(at: recordingsDirectory)
            let destination = Self.uniqueURL(
                base: recordingsDirectory.appendingPathComponent(name),
                exists: ops.fileExists)
            try ops.moveItem(at: source, to: destination)
            outcome.primaryURL = destination
            outcome.savedToLibrary = true
        } catch {
            NSLog("[RecordingFiler] Could not file %@ into %@: %@",
                  source.lastPathComponent, recordingsDirectory.lastPathComponent,
                  error.localizedDescription)
        }

        // 2. The user's chosen folder, if they picked one. A copy, not a move — the app folder
        //    stays the copy we can always find again.
        if let folderURL {
            do {
                try ops.createDirectory(at: folderURL)
                let destination = Self.uniqueURL(
                    base: folderURL.appendingPathComponent(name),
                    exists: ops.fileExists)
                try ops.copyItem(at: outcome.primaryURL, to: destination)
                outcome.folderCopyURL = destination
                // Only promote the folder copy when the app-folder move failed — otherwise the
                // safety net is the location we want to name and protect.
                if !outcome.savedToLibrary { outcome.primaryURL = destination }
            } catch {
                NSLog("[RecordingFiler] Could not copy to the chosen folder: %@",
                      error.localizedDescription)
            }
        }

        // Photos is the caller's job from here — by now the file is already safe on disk, which
        // is the point: the destination most likely to be declined is also the last one tried.
        return outcome
    }
}
