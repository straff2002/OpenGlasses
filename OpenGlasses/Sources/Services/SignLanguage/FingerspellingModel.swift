import Foundation

/// Download/availability state of the fingerspelling recognition model.
enum FingerspellingModelState: Equatable {
    /// No hosting repo configured yet — the converted model hasn't been published.
    case notConfigured
    case notDownloaded
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(reason: String)
}

/// Describes the downloadable fingerspelling model (Plan CK): the gate-passing CTC model
/// over 543 holistic landmarks (20.8% CER on the competition-corpus gate), converted to
/// an fp16 Core ML package and hosted as unpacked files on HuggingFace (published
/// 2026-08-05, `Config.fingerspellingModelRepo`) — downloaded on first enable rather
/// than bundled (the Kokoro/SenseVoice discipline). The repo stays configurable so a
/// staged replacement artefact needs no app update.
///
/// Alongside the model: `vocab.txt` (the CTC charset, blank first, one symbol per line —
/// a sanity copy of `FingerspellingCTCDecoder.charset`) and `holistic_landmarker.task`
/// (the MediaPipe holistic landmark extractor consumed by `HolisticLandmarkService` —
/// distributed with the model rather than app-bundled). Per-sequence standardisation
/// replaced the old CMVN sidecar; there are no shipped feature stats.
struct FingerspellingModelBundle: Equatable {

    let id: String
    let displayName: String
    /// Sub-directory under Application Support holding the model files.
    let directoryName: String
    /// HuggingFace repo hosting the unpacked files (empty = not yet published).
    let huggingFaceRepo: String
    /// Rough download size for the Settings status row.
    let approxDownloadBytes: Int64
    /// Files that must each be present and non-empty (sub-paths preserved — the `.mlpackage`
    /// is a directory).
    let requiredFiles: [String]

    var isConfigured: Bool { !huggingFaceRepo.isEmpty }

    /// The download URL for a file within the repo (sub-paths escaped per segment).
    func huggingFaceResolveURL(for path: String) -> URL? {
        guard isConfigured else { return nil }
        let escaped = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main/\(escaped)")
    }

    static let modelPackageName = "Fingerspelling2P.mlpackage"
    static let landmarkerTaskName = "holistic_landmarker.task"

    /// The active bundle; the repo comes from Settings so publishing the artefact needs no
    /// app update.
    static var active: FingerspellingModelBundle {
        FingerspellingModelBundle(
            id: "fingerspelling-ctc-v2",
            displayName: "Fingerspelling (CTC)",
            directoryName: "FingerspellingModel",
            huggingFaceRepo: Config.fingerspellingModelRepo,
            approxDownloadBytes: 32_000_000,
            requiredFiles: [
                "\(modelPackageName)/Manifest.json",
                "\(modelPackageName)/Data/com.apple.CoreML/model.mlmodel",
                "\(modelPackageName)/Data/com.apple.CoreML/weights/weight.bin",
                "vocab.txt",
                landmarkerTaskName,
            ]
        )
    }
}

/// File-system bookkeeping for the fingerspelling model — pure, injectable-directory,
/// mirroring `ASRModelStore` (a shared model-store layer is a flagged follow-up).
struct FingerspellingModelStore {

    let bundle: FingerspellingModelBundle
    let directory: URL
    private let fileManager: FileManager

    init(bundle: FingerspellingModelBundle = .active, directory: URL? = nil,
         fileManager: FileManager = .default) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(for: bundle, fileManager: fileManager)
    }

    static func defaultDirectory(for bundle: FingerspellingModelBundle,
                                 fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent(bundle.directoryName, isDirectory: true)
    }

    func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Present only if the file exists, is a file, and is non-empty (a truncated download
    /// leaves a 0-byte stub that must not pass as installed).
    func isFilePresent(_ name: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL(name).path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = (try? fileManager.attributesOfItem(atPath: fileURL(name).path)[.size]) as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    var missingFiles: [String] { bundle.requiredFiles.filter { !isFilePresent($0) } }
    var isModelPresent: Bool { missingFiles.isEmpty }

    var state: FingerspellingModelState {
        guard bundle.isConfigured else { return .notConfigured }
        return isModelPresent ? .ready : .notDownloaded
    }

    func deleteModel() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}

/// Failure modes of the fingerspelling model download.
enum FingerspellingDownloadError: LocalizedError, Equatable {
    case notConfigured
    case incompleteDownload(missing: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No model repository configured yet."
        case .incompleteDownload(let missing):
            return "Downloaded model is incomplete (missing: \(missing))"
        }
    }
}

/// Orchestrates first-enable download into Application Support: download-to-staging → verify →
/// atomic install, driven through an injected installer so the state machine is fully testable
/// headlessly. Mirrors `ASRModelDownloader`/`KokoroModelDownloader` (shared layer = flagged
/// follow-up).
@MainActor
final class FingerspellingModelDownloader: ObservableObject {

    typealias ProgressHandler = @MainActor (Double) -> Void
    typealias Installer = (_ bundle: FingerspellingModelBundle,
                           _ destination: URL,
                           _ progress: @escaping ProgressHandler) async throws -> Void

    @Published private(set) var state: FingerspellingModelState

    private let bundle: FingerspellingModelBundle
    private let modelDirectory: URL
    private let fileManager: FileManager
    private let installer: Installer

    init(bundle: FingerspellingModelBundle = .active,
         modelDirectory: URL? = nil,
         fileManager: FileManager = .default,
         installer: @escaping Installer = FingerspellingModelDownloader.liveInstaller) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.modelDirectory = modelDirectory
            ?? FingerspellingModelStore.defaultDirectory(for: bundle, fileManager: fileManager)
        self.installer = installer
        self.state = FingerspellingModelStore(bundle: bundle, directory: self.modelDirectory,
                                              fileManager: fileManager).state
    }

    private var store: FingerspellingModelStore {
        FingerspellingModelStore(bundle: bundle, directory: modelDirectory, fileManager: fileManager)
    }

    func refreshState() {
        if case .downloading = state { return }
        state = store.state
    }

    /// Download + install. Idempotent (no-op → `.ready` when already present). Stages into a
    /// sibling directory and only atomically swaps once verified, so a partial download never
    /// half-installs.
    func download() async {
        guard bundle.isConfigured else {
            state = .notConfigured
            return
        }
        if store.isModelPresent {
            state = .ready
            return
        }

        state = .downloading(progress: 0)
        let staging = modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("Fingerspelling-staging-\(UUID().uuidString)", isDirectory: true)

        do {
            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            try await installer(bundle, staging) { [weak self] fraction in
                self?.state = .downloading(progress: min(max(fraction, 0), 1))
            }

            state = .verifying
            let staged = FingerspellingModelStore(bundle: bundle, directory: staging,
                                                  fileManager: fileManager)
            guard staged.isModelPresent else {
                throw FingerspellingDownloadError.incompleteDownload(
                    missing: staged.missingFiles.joined(separator: ", "))
            }

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

    func deleteModel() {
        try? store.deleteModel()
        state = store.state
    }

    /// Production installer: fetch each required file (sub-paths preserved) with URLSession.
    static let liveInstaller: Installer = { bundle, destination, progress in
        let files = bundle.requiredFiles
        var completed = 0
        for path in files {
            guard let url = bundle.huggingFaceResolveURL(for: path) else {
                throw FingerspellingDownloadError.notConfigured
            }
            let dest = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FingerspellingDownloadError.incompleteDownload(missing: "\(path) (HTTP \(http.statusCode))")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            completed += 1
            let fraction = Double(completed) / Double(max(files.count, 1))
            await progress(fraction)
        }
    }
}
