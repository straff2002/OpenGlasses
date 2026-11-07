import CoreML
import Foundation
import Tokenizers

/// Which model Field Assist's manual search embeds with (Plan KQ P2). The wearer chooses in
/// Settings › Field Assist; each choice falls back down the list until its model is on the phone,
/// so a vault is never left unsearchable.
enum ManualSearchModel: String, CaseIterable, Sendable {
    /// The NaturalLanguage sentence model.
    case standard
    /// Apple's contextual model (Plan IV P4), the default.
    case smarter
    /// The search-trained model (EmbeddingGemma 2's text encoder), downloaded when chosen.
    case searchTrained

    /// The stored choice, or, before one was stored, the old "Smarter manual search" switch: on is
    /// `smarter`, off is `standard`. No install changes model on upgrade.
    static func resolve(stored: String?, legacySmarter: Bool) -> ManualSearchModel {
        if let stored, let choice = ManualSearchModel(rawValue: stored) { return choice }
        return legacySmarter ? .smarter : .standard
    }

    /// The model-id prefix this choice's own model produces, for "is the vault on it yet?".
    var modelIdPrefix: String {
        switch self {
        case .standard: return "nl-sentence"
        case .smarter: return "nl-contextual"
        case .searchTrained: return "eg2-text"
        }
    }
}

/// The search-trained model's files, hosted unpacked on HuggingFace (Plan KQ P2). Apache 2.0,
/// converted by `Scripts/kq-embedder/convert.py`: the text encoder only, int8 weights, float32
/// compute, with the tokenizer files beside it.
struct SearchModelBundle: DownloadableModelBundle {
    let id: String
    let displayName: String
    let directoryName: String
    let huggingFaceRepo: String
    let approxDownloadBytes: Int64
    let requiredFiles: [String]

    static let packageName = "eg2-text-int8.mlpackage"

    static let eg2TextInt8 = SearchModelBundle(
        id: "avenkin-search-eg2-text",
        displayName: "Search-trained model",
        directoryName: "SearchModel",
        huggingFaceRepo: "Skunk0/avenkin-search-eg2-text",
        approxDownloadBytes: 306_000_000,
        requiredFiles: [
            "\(packageName)/Manifest.json",
            "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
            "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
            "tokenizer.json",
            "tokenizer_config.json",
            "config.json",
        ]
    )

    static let active = eg2TextInt8

    static var liveInstaller: ModelDownloader<SearchModelBundle>.Installer {
        { bundle, destination, progress in
            let files = try await HuggingFaceModelInstaller.liveListing(of: bundle, for: .searchModelDownload)
            try await HuggingFaceModelInstaller.fetch(files, of: bundle, into: destination, progress: progress,
                                                      downloadFile: HuggingFaceModelInstaller.liveProgressingDownload(for: .searchModelDownload))
        }
    }
}

typealias SearchModelStore = ModelStore<SearchModelBundle>
typealias SearchModelDownloader = ModelDownloader<SearchModelBundle>

/// The loaded search-trained model, process-wide (Plan KQ P2). Loading compiles the package once
/// (kept beside it as `compiled.mlmodelc`) and reads the tokenizer, about 3.5 s on an iPhone Air,
/// so it happens off the main thread at launch and when the model arrives; until then `ready`
/// is nil and Field Assist searches with the next model down.
enum SearchModelRuntime {

    private static let lock = NSLock()
    private static var loaded: CoreMLEmbeddingBackend?
    private static var loading: Task<Bool, Never>?

    /// A seam for tests: stand in a backend (or nil) without Core ML.
    nonisolated(unsafe) static var readyOverride: (() -> EmbeddingBackend?)?

    /// The loaded backend, or nil when it isn't downloaded or hasn't finished loading.
    static var ready: EmbeddingBackend? {
        if let readyOverride { return readyOverride() }
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    /// Whether the model's files are on the phone.
    static var isInstalled: Bool { SearchModelStore(bundle: .active).state == .ready }

    /// Load the model if it's on the phone and not loaded yet. True when it is ready afterwards.
    /// Concurrent callers share one load.
    @discardableResult
    static func load() async -> Bool {
        if ready != nil { return true }
        guard isInstalled else { return false }
        let task: Task<Bool, Never> = {
            lock.lock()
            defer { lock.unlock() }
            if let loading { return loading }
            let fresh = Task.detached(priority: .utility) { await performLoad() }
            loading = fresh
            return fresh
        }()
        let ok = await task.value
        lock.lock()
        loading = nil
        lock.unlock()
        return ok
    }

    /// Drop the loaded model (after the files are removed).
    static func unload() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    private static func performLoad() async -> Bool {
        let folder = SearchModelStore(bundle: .active).directory
        let package = folder.appendingPathComponent(SearchModelBundle.packageName)
        let compiled = folder.appendingPathComponent("compiled.mlmodelc")
        do {
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temporary = try await MLModel.compileModel(at: package)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: temporary, to: compiled)
            }
            let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
            let tokenize: (String) -> [Int] = { tokenizer.encode(text: $0, addSpecialTokens: true) }
            guard let backend = CoreMLEmbeddingBackend(compiledModel: compiled, dimension: 768, tokenize: tokenize) else {
                // A compiled model from an older OS or a damaged one: compile afresh next time.
                try? FileManager.default.removeItem(at: compiled)
                return false
            }
            lock.lock()
            loaded = backend
            lock.unlock()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Warm-up (Plan KQ P0's finding)

    /// Whether a turn should warm the model: it is the chosen model, a Field Assist vault is open,
    /// and the model is loaded. Pure, for the tests.
    static func shouldWarmUp(choice: ManualSearchModel, vaultOpen: Bool, loaded: Bool) -> Bool {
        choice == .searchTrained && vaultOpen && loaded
    }

    /// One tiny prediction off the main thread, at the start of a turn, so model pages iOS
    /// reclaimed while the app was in the background are read back while the wearer speaks. P0
    /// measured 4.7 s for the first locked question without it, 118–155 ms with it.
    static func warmUp(choice: ManualSearchModel = Config.fieldAssistManualSearchModel, vaultOpen: Bool) {
        guard let backend = ready, shouldWarmUp(choice: choice, vaultOpen: vaultOpen, loaded: true) else { return }
        Task.detached(priority: .userInitiated) { _ = backend.embedQuery("warm") }
    }
}
