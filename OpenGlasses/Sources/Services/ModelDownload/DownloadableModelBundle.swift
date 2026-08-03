import Foundation

/// Describes a downloadable on-device model bundle — the single source of truth for what "installed"
/// means for a tier (Kokoro TTS, SenseVoice ASR, and any future tier such as the Plan CK
/// fingerspelling model). A pure value: the descriptor declares the artefact set and where it's
/// hosted; presence checking lives in `ModelStore`, and the download state machine in
/// `ModelDownloader`.
///
/// Each tier keeps its own concrete struct (so `KokoroModelBundle.active` and `ASRModelBundle.active`
/// stay distinct types with distinct shipped bundles) and conforms here to share the store/downloader
/// core.
protocol DownloadableModelBundle: Equatable, Sendable {

    /// Stable identifier (usually the upstream repo's model name).
    var id: String { get }

    /// User-facing name for the Settings status row.
    var displayName: String { get }

    /// Sub-directory under Application Support that holds the installed model files.
    var directoryName: String { get }

    /// The HuggingFace repo id hosting the bundle's files, e.g. `csukuangfj/kokoro-int8-multi-lang-v1_1`.
    var huggingFaceRepo: String { get }

    /// Rough total download size, for the Settings status row / a "this will use ~N MB" prompt.
    var approxDownloadBytes: Int64 { get }

    /// Files that must each exist and be non-empty for the model to count as installed.
    var requiredFiles: [String] { get }

    /// Directories that must each exist and contain at least one file (e.g. Kokoro's
    /// `espeak-ng-data/`). Empty for tiers whose models are flat files.
    var requiredDirectories: [String] { get }

    /// The bundle the app ships with for this tier.
    static var active: Self { get }

    /// The production installer for this tier (network code lives in the tier's own files; the
    /// descriptor just carries the seam so `ModelDownloader.init` can default to it).
    static var liveInstaller: ModelDownloader<Self>.Installer { get }
}

extension DownloadableModelBundle {

    /// Flat-file tiers don't need directories.
    var requiredDirectories: [String] { [] }

    /// The HuggingFace tree API URL listing every file in the repo (recursive), for installers that
    /// enumerate what to fetch and compute the total size.
    var huggingFaceTreeAPIURL: URL {
        // swiftlint:disable:next force_unwrapping — composed from a validated repo id.
        URL(string: "https://huggingface.co/api/models/\(huggingFaceRepo)/tree/main?recursive=true")!
    }

    /// The download URL for a single file `path` within the repo (sub-paths keep their slashes —
    /// `.urlPathAllowed` permits `/`).
    func huggingFaceResolveURL(for path: String) -> URL {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // swiftlint:disable:next force_unwrapping — repo id + percent-escaped path.
        return URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main/\(escaped)")!
    }
}
