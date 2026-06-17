import Foundation

/// Download/availability state of the Kokoro model bundle.
enum KokoroModelState: Equatable {
    /// No model on disk yet (the default — Kokoro is a no-op until it's downloaded).
    case notDownloaded
    /// A download is in progress (0...1). The download itself is network and is deferred.
    case downloading(progress: Double)
    /// All required files are present on disk; the engine can load it.
    case ready
    /// A previous download failed; carries a short reason.
    case failed(reason: String)
}

/// Tracks whether the Kokoro (`kokoro-int8-en-v0_19`) model bundle is present in Application Support
/// (Additional Capabilities #1). Kokoro is a **no-op until the model is present** — the int8 weights
/// are tens of MB, so they're downloaded on first enable rather than bundled (avoids binary bloat),
/// mirroring the SDK's no-Display no-op discipline.
///
/// This is the *presence/selection* half — pure file-system bookkeeping, so it's fully unit-testable
/// by pointing `directory` at a temp folder. The actual network download is deferred (it depends on
/// confirming the weights' redistribution terms + a hosting location).
struct KokoroModelStore {

    /// The three artefacts sherpa-onnx needs to load `kokoro-int8-en-v0_19`.
    static let requiredFiles = ["model.int8.onnx", "voices.bin", "tokens.txt"]

    /// Where the model files live. Injectable so tests can use a temp directory.
    let directory: URL

    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// App-wide store rooted at `Application Support/KokoroTTS`.
    static let shared = KokoroModelStore(directory: Self.defaultDirectory)

    /// `Application Support/KokoroTTS` (falls back to a temp dir if Application Support is somehow
    /// unavailable — defensive; never expected in practice).
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("KokoroTTS", isDirectory: true)
    }

    /// The on-disk URL a required file would live at (whether or not it exists yet).
    func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// A file counts as present only if it exists **and is non-empty** — a truncated or aborted
    /// download can leave a 0-byte stub, which must not pass as "installed".
    func isFilePresent(_ name: String) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL(name).path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    /// Required files not yet present (missing or empty), in canonical order.
    var missingFiles: [String] {
        Self.requiredFiles.filter { !isFilePresent($0) }
    }

    /// True only when **every** required file is present and non-empty.
    var isModelPresent: Bool {
        missingFiles.isEmpty
    }

    /// Presence-derived state. (`.downloading` / `.failed` are reported by the live download
    /// orchestration, which is deferred — see the type doc.)
    var state: KokoroModelState {
        isModelPresent ? .ready : .notDownloaded
    }

    /// Total bytes the model files occupy on disk (0 when nothing is downloaded). Used by the
    /// Settings status row.
    func totalBytesOnDisk() -> Int64 {
        Self.requiredFiles.reduce(into: Int64(0)) { sum, name in
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
