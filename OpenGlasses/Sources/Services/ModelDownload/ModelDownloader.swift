import Foundation

/// Failure modes of a model download. Shared by every tier (aliased as `KokoroDownloadError` /
/// `ASRDownloadError`).
enum ModelDownloadError: LocalizedError, Equatable {
    /// The download finished but the bundle is missing required artefacts.
    case incompleteDownload(missing: String)

    var errorDescription: String? {
        switch self {
        case .incompleteDownload(let missing):
            return "Downloaded model is incomplete (missing: \(missing))"
        }
    }
}

/// Orchestrates first-enable download of a model bundle into Application Support. The
/// **deterministic core** — the state machine, the download-to-staging → verify → atomic-install
/// flow, and failure cleanup — is driven through an **injected installer**, so the orchestration is
/// fully unit-testable headlessly with a fake that just writes files.
///
/// The default installer is the bundle's `liveInstaller` (per-tier network code: the HuggingFace
/// tree-enumerating fetch for Kokoro, a direct per-file fetch for ASR). Stages into a sibling
/// directory and only atomically swaps it into place once it verifies, so a partial/failed download
/// never leaves a half-installed model that would pass the presence check.
@MainActor
final class ModelDownloader<Bundle: DownloadableModelBundle>: ObservableObject {

    /// Progress is reported on the main actor as a fraction 0...1.
    typealias ProgressHandler = @MainActor (Double) -> Void

    /// Fetches `bundle`'s files into `destination` (a staging directory), reporting progress.
    /// Throws to signal a failed download.
    typealias Installer = (_ bundle: Bundle,
                           _ destination: URL,
                           _ progress: @escaping ProgressHandler) async throws -> Void

    @Published private(set) var state: ModelDownloadState

    private let bundle: Bundle
    private let modelDirectory: URL
    private let fileManager: FileManager
    private let installer: Installer

    init(bundle: Bundle = .active,
         modelDirectory: URL? = nil,
         fileManager: FileManager = .default,
         installer: @escaping Installer = Bundle.liveInstaller) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.modelDirectory = modelDirectory
            ?? ModelStore.defaultDirectory(for: bundle, fileManager: fileManager)
        self.installer = installer
        self.state = ModelStore(bundle: bundle, directory: self.modelDirectory, fileManager: fileManager).state
    }

    private var store: ModelStore<Bundle> {
        ModelStore(bundle: bundle, directory: modelDirectory, fileManager: fileManager)
    }

    /// Re-derive `state` from what's on disk (e.g. when the Settings screen appears).
    func refreshState() {
        if case .downloading = state { return }   // don't clobber an in-flight download
        state = store.state
    }

    /// Download + install the bundle. Idempotent: a no-op (→ `.ready`) when the model is already
    /// present.
    func download() async {
        if store.isModelPresent {
            state = .ready
            return
        }

        state = .downloading(progress: 0)
        let staging = modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(bundle.directoryName)-staging-\(UUID().uuidString)", isDirectory: true)

        do {
            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            try await installer(bundle, staging) { [weak self] fraction in
                self?.state = .downloading(progress: min(max(fraction, 0), 1))
            }

            state = .verifying
            let staged = ModelStore(bundle: bundle, directory: staging, fileManager: fileManager)
            guard staged.isModelPresent else {
                let missing = (staged.missingFiles + staged.missingDirectories).joined(separator: ", ")
                throw ModelDownloadError.incompleteDownload(missing: missing)
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
