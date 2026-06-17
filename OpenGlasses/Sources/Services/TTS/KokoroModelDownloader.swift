import Foundation

/// Failure modes of the Kokoro model download.
enum KokoroDownloadError: LocalizedError, Equatable {
    /// The download finished but the bundle is missing required artefacts.
    case incompleteDownload(missing: String)

    var errorDescription: String? {
        switch self {
        case .incompleteDownload(let missing):
            return "Downloaded model is incomplete (missing: \(missing))"
        }
    }
}

/// Orchestrates first-enable download of a `KokoroModelBundle` into Application Support (Additional
/// Capabilities #1). The **deterministic core** of the download — the state machine, the
/// download-to-staging → verify → atomic-install flow, and failure cleanup — is driven through an
/// **injected installer**, so the orchestration is fully unit-testable headlessly with a fake that
/// just writes files.
///
/// The default installer is `HuggingFaceModelInstaller.live`, which fetches the bundle's unpacked
/// files from HuggingFace (no archive decoding needed). It isn't user-triggerable yet: the Settings
/// UI shows only model status, because the model is unusable until the sherpa-onnx binary is
/// compiled in (`KOKORO_ENABLED`), so there's no point downloading ~185 MB that can't be played.
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
         installer: @escaping Installer = HuggingFaceModelInstaller.live.makeInstaller()) {
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
}
