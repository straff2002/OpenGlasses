import Foundation

/// Describes a downloadable Kokoro model bundle for sherpa-onnx (Additional Capabilities #1 — the
/// on-device TTS tier). A value type so the store/downloader logic is pure and the artefact set is a
/// single source of truth.
///
/// The shipped choice is **`kokoro-int8-multi-lang-v1_1`** (~90 MB int8, English + Chinese) — small
/// enough to download on first enable rather than bloat the app binary, which is the whole rationale
/// for the on-device tier. The bundle is distributed as a single `.tar.bz2`; the live download +
/// extraction adapter is deferred (it needs a bzip2/tar decoder and is validated on-device — see
/// `KokoroModelDownloader`).
struct KokoroModelBundle: Equatable {

    /// Stable identifier, also the extracted folder name upstream.
    let id: String

    /// User-facing name for the Settings status row.
    let displayName: String

    /// Canonical archive (a `.tar.bz2`) on the k2-fsa GitHub releases — the authoritative source.
    let gitHubArchiveURL: URL

    /// HuggingFace mirror of the archive (the chosen hosting). Best-effort until confirmed at
    /// activation; the downloader prefers this when set, falling back to `gitHubArchiveURL`.
    let huggingFaceArchiveURL: URL?

    /// Rough download size, for the Settings status row / a "this will use ~N MB" prompt.
    let approxDownloadBytes: Int64

    /// Files that must each exist and be non-empty for the model to count as installed.
    let requiredFiles: [String]

    /// Directories that must each exist and contain at least one file (e.g. `espeak-ng-data/`,
    /// `dict/`) — sherpa-onnx needs these for phonemization, so a download that dropped them must
    /// not pass as "ready".
    let requiredDirectories: [String]

    /// The download source to use: the chosen HuggingFace mirror when available, else GitHub.
    var preferredArchiveURL: URL { huggingFaceArchiveURL ?? gitHubArchiveURL }

    // swiftlint:disable force_unwrapping — static, known-good literal URLs.

    /// The shipped bundle: int8, multilingual (en + zh), ~90 MB. File/dir layout verified against the
    /// k2-fsa `tts-models` release listing.
    static let int8MultiLangV1_1 = KokoroModelBundle(
        id: "kokoro-int8-multi-lang-v1_1",
        displayName: "Kokoro (int8, multilingual)",
        gitHubArchiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2")!,
        // NOTE: confirm the exact HuggingFace repo path at download-adapter activation; the user
        // chose HuggingFace (k2-fsa) hosting.
        huggingFaceArchiveURL: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-kokoro-int8-multi-lang-v1_1/resolve/main/kokoro-int8-multi-lang-v1_1.tar.bz2"),
        approxDownloadBytes: 90_000_000,
        requiredFiles: [
            "model.int8.onnx",
            "voices.bin",
            "tokens.txt",
            "lexicon-us-en.txt",
            "lexicon-gb-en.txt",
            "lexicon-zh.txt",
            "date-zh.fst",
            "number-zh.fst",
            "phone-zh.fst",
        ],
        requiredDirectories: [
            "espeak-ng-data",
            "dict",
        ]
    )

    // swiftlint:enable force_unwrapping

    /// The bundle the app ships with.
    static let active = int8MultiLangV1_1
}
