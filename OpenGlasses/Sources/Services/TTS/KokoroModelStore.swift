import Foundation

/// Download/availability state of the Kokoro model bundle.
enum KokoroModelState: Equatable {
    /// No model on disk yet (the default — Kokoro is a no-op until it's downloaded).
    case notDownloaded
    /// A download is in progress (0...1).
    case downloading(progress: Double)
    /// Downloaded; verifying the extracted files against the bundle descriptor.
    case verifying
    /// All required files/directories are present on disk; the engine can load it.
    case ready
    /// A previous download/verification failed; carries a short reason.
    case failed(reason: String)
}

/// Tracks whether a Kokoro model bundle (`KokoroModelBundle`) is present in Application Support
/// (Additional Capabilities #1). Kokoro is a **no-op until the model is present** — the int8 weights
/// are ~90 MB, so they're downloaded on first enable rather than bundled (avoids binary bloat),
/// mirroring the SDK's no-Display no-op discipline.
///
/// This is the *presence/selection* half — pure file-system bookkeeping driven by the bundle's
/// declared file + directory set, so it's fully unit-testable by pointing `directory` at a temp
/// folder. The actual network download + extraction lives in `KokoroModelDownloader`.
struct KokoroModelStore {

    /// The bundle whose artefacts define "installed".
    let bundle: KokoroModelBundle

    /// Where the model files live. Injectable so tests can use a temp directory.
    let directory: URL

    private let fileManager: FileManager

    init(bundle: KokoroModelBundle = .active, directory: URL, fileManager: FileManager = .default) {
        self.bundle = bundle
        self.directory = directory
        self.fileManager = fileManager
    }

    /// App-wide store rooted at `Application Support/KokoroTTS`, for the active bundle.
    static let shared = KokoroModelStore(directory: Self.defaultDirectory)

    /// `Application Support/KokoroTTS` (falls back to a temp dir if Application Support is somehow
    /// unavailable — defensive; never expected in practice).
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("KokoroTTS", isDirectory: true)
    }

    /// The on-disk URL a required file/directory would live at (whether or not it exists yet).
    func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// A file counts as present only if it exists, **is a file**, and is **non-empty** — a truncated
    /// or aborted download can leave a 0-byte stub, which must not pass as "installed".
    func isFilePresent(_ name: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL(name).path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = (try? fileManager.attributesOfItem(atPath: fileURL(name).path)[.size]) as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    /// A directory counts as present only if it exists, **is a directory**, and contains at least one
    /// entry (an empty `espeak-ng-data/` is as useless as a missing one).
    func isDirectoryPresent(_ name: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL(name).path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? fileManager.contentsOfDirectory(atPath: fileURL(name).path) else {
            return false
        }
        return !contents.isEmpty
    }

    /// Required files not yet present (missing/empty/not-a-file), in the bundle's canonical order.
    var missingFiles: [String] {
        bundle.requiredFiles.filter { !isFilePresent($0) }
    }

    /// Required directories not yet present (missing/empty/not-a-directory).
    var missingDirectories: [String] {
        bundle.requiredDirectories.filter { !isDirectoryPresent($0) }
    }

    /// True only when **every** required file and directory is present.
    var isModelPresent: Bool {
        missingFiles.isEmpty && missingDirectories.isEmpty
    }

    /// Presence-derived state. (`.downloading` / `.verifying` / `.failed` are reported by
    /// `KokoroModelDownloader` while it works.)
    var state: KokoroModelState {
        isModelPresent ? .ready : .notDownloaded
    }

    /// Total bytes the model files occupy on disk (0 when nothing is downloaded). Used by the
    /// Settings status row. Counts the declared files (not a full recursive directory walk).
    func totalBytesOnDisk() -> Int64 {
        bundle.requiredFiles.reduce(into: Int64(0)) { sum, name in
            if let size = try? fileManager.attributesOfItem(atPath: fileURL(name).path)[.size] as? NSNumber {
                sum += size.int64Value
            }
        }
    }

    /// Create the model directory if needed (called before a download writes into it).
    func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Delete the whole model bundle (free the disk space / force a re-download).
    func deleteModel() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}
