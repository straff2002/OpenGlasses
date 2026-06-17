import Foundation

/// Failure modes of the Kokoro model download.
enum KokoroDownloadError: LocalizedError, Equatable {
    /// The live download+extraction adapter isn't wired yet (the default installer). The `.tar.bz2`
    /// fetch + bzip2/tar extraction is the deferred, device-validated step — see `liveInstaller`.
    case adapterNotImplemented
    /// The download finished but the extracted bundle is missing required artefacts.
    case incompleteDownload(missing: String)

    var errorDescription: String? {
        switch self {
        case .adapterNotImplemented:
            return "On-device voice download isn't available in this build yet"
        case .incompleteDownload(let missing):
            return "Downloaded model is incomplete (missing: \(missing))"
        }
    }
}

/// Orchestrates first-enable download of a `KokoroModelBundle` into Application Support (Additional
/// Capabilities #1). This is the **deterministic core** of the download: the state machine, the
/// download-to-staging → verify → atomic-install flow, and failure cleanup — all driven through an
/// **injected installer**, so the orchestration is fully unit-testable headlessly with a fake that
/// just writes files. No network, no archive decoding here.
///
/// The *live* installer (fetch the `.tar.bz2` from HuggingFace/GitHub, then bunzip2 + untar into the
/// staging dir) is deferred: it needs a bzip2/tar decoder dependency and its only meaningful
/// validation is an on-device download, so it ships disabled (`adapterNotImplemented`) until the
/// sherpa-onnx binary lands alongside it.
@MainActor
final class KokoroModelDownloader: ObservableObject {

    /// Progress is reported on the main actor as a fraction 0...1.
    typealias ProgressHandler = @MainActor (Double) -> Void

    /// Fetches `bundle`'s files into `destination` (a staging directory), reporting progress.
    /// Throws to signal a failed download.
    typealias Installer = (_ bundle: KokoroModelBundle,
                           _ destination: URL,
                           _ progress: @escaping ProgressHandler) async throws -> Void

    @Published private(set) var state: KokoroModelState

    private let bundle: KokoroModelBundle
    private let modelDirectory: URL
    private let fileManager: FileManager
    private let installer: Installer

    init(bundle: KokoroModelBundle = .active,
         modelDirectory: URL = KokoroModelStore.defaultDirectory,
         fileManager: FileManager = .default,
         installer: @escaping Installer = KokoroModelDownloader.liveInstaller) {
        self.bundle = bundle
        self.modelDirectory = modelDirectory
        self.fileManager = fileManager
        self.installer = installer
        self.state = KokoroModelStore(bundle: bundle, directory: modelDirectory, fileManager: fileManager).state
    }

    private var store: KokoroModelStore {
        KokoroModelStore(bundle: bundle, directory: modelDirectory, fileManager: fileManager)
    }

    /// Re-derive `state` from what's on disk (e.g. when the Settings screen appears).
    func refreshState() {
        if case .downloading = state { return }   // don't clobber an in-flight download
        state = store.state
    }

    /// Download + install the bundle. Idempotent: a no-op (→ `.ready`) when the model is already
    /// present. Installs into a sibling staging directory and only swaps it into place once the
    /// extracted files verify against the descriptor, so a partial/failed download never leaves a
    /// half-installed model that would pass the presence check.
    func download() async {
        if store.isModelPresent {
            state = .ready
            return
        }

        state = .downloading(progress: 0)
        let staging = modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("KokoroTTS-staging-\(UUID().uuidString)", isDirectory: true)

        do {
            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            try await installer(bundle, staging) { [weak self] fraction in
                self?.state = .downloading(progress: min(max(fraction, 0), 1))
            }

            state = .verifying
            let staged = KokoroModelStore(bundle: bundle, directory: staging, fileManager: fileManager)
            guard staged.isModelPresent else {
                let missing = (staged.missingFiles + staged.missingDirectories).joined(separator: ", ")
                throw KokoroDownloadError.incompleteDownload(missing: missing)
            }

            // Atomically replace any previous install with the verified staging directory.
            try? fileManager.removeItem(at: modelDirectory)
            try fileManager.createDirectory(at: modelDirectory.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: modelDirectory)
            state = .ready
        } catch {
            try? fileManager.removeItem(at: staging)
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .failed(reason: reason)
        }
    }

    /// Delete the installed model and reset state.
    func deleteModel() {
        try? store.deleteModel()
        state = store.state
    }

    // MARK: - Live installer (deferred)

    /// The default installer used in the shipped build. The live fetch + bzip2/tar extraction is
    /// deferred (it needs an archive-decoder dependency and on-device validation), so it fails
    /// cleanly until activated. The Settings UI gates the download button on availability, so this
    /// isn't reachable from a normal build.
    static let liveInstaller: Installer = { _, _, _ in
        // DEFERRED: download `bundle.preferredArchiveURL` with a URLSession download task (forward
        // `totalBytesWritten / totalBytesExpectedToWrite` to `progress`), then bunzip2 + untar the
        // archive into `destination` (e.g. via SWCompression). Lands with the sherpa-onnx binary.
        throw KokoroDownloadError.adapterNotImplemented
    }
}
