import Foundation

/// Describes a downloadable Kokoro model bundle for sherpa-onnx (Additional Capabilities #1 — the
/// on-device TTS tier). A value type so the store/downloader logic is pure and the artefact set is a
/// single source of truth.
///
/// The shipped choice is **`kokoro-int8-multi-lang-v1_1`** (int8, English + Chinese). It's hosted on
/// HuggingFace as **unpacked individual files** (verified against the repo tree), so the download is a
/// plain per-file fetch — no `.tar.bz2`/bzip2 decoding needed. The `model.int8.onnx` alone is ~114 MB
/// and `voices.bin` ~54 MB, so the full bundle is ~185 MB: downloaded on first enable rather than
/// bundled, which is the whole rationale for the on-device tier.
struct KokoroModelBundle: Equatable {

    /// Stable identifier, also the extracted folder name upstream.
    let id: String

    /// User-facing name for the Settings status row.
    let displayName: String

    /// The HuggingFace repo id hosting the bundle's files, e.g.
    /// `csukuangfj/kokoro-int8-multi-lang-v1_1`. Files are stored unpacked, so the downloader lists
    /// the repo tree and fetches each file.
    let huggingFaceRepo: String

    /// The k2-fsa GitHub release `.tar.bz2` — an alternative source that would need bzip2/tar
    /// extraction. Recorded for reference; the shipped path uses the unpacked HuggingFace files.
    let gitHubArchiveURL: URL

    /// Rough total download size, for the Settings status row / a "this will use ~N MB" prompt.
    let approxDownloadBytes: Int64

    /// Files that must each exist and be non-empty for the model to count as installed.
    let requiredFiles: [String]

    /// Directories that must each exist and contain at least one file (e.g. `espeak-ng-data/`,
    /// `dict/`) — sherpa-onnx needs these for phonemization, so a download that dropped them must
    /// not pass as "ready".
    let requiredDirectories: [String]

    /// The HuggingFace tree API URL listing every file in the repo (recursive), for the downloader to
    /// enumerate what to fetch and compute the total size.
    var huggingFaceTreeAPIURL: URL {
        // swiftlint:disable:next force_unwrapping — composed from a validated repo id.
        URL(string: "https://huggingface.co/api/models/\(huggingFaceRepo)/tree/main?recursive=true")!
    }

    /// The download URL for a single file `path` within the repo.
    func huggingFaceResolveURL(for path: String) -> URL {
        let escaped = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        // swiftlint:disable:next force_unwrapping — repo id + percent-escaped path.
        return URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main/\(escaped)")!
    }

    // swiftlint:disable force_unwrapping — static, known-good literal URLs.

    /// The shipped bundle: int8, multilingual (en + zh), ~185 MB. File/dir layout verified against the
    /// `csukuangfj/kokoro-int8-multi-lang-v1_1` HuggingFace repo tree.
    static let int8MultiLangV1_1 = KokoroModelBundle(
        id: "kokoro-int8-multi-lang-v1_1",
        displayName: "Kokoro (int8, multilingual)",
        huggingFaceRepo: "csukuangfj/kokoro-int8-multi-lang-v1_1",
        gitHubArchiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2")!,
        approxDownloadBytes: 185_000_000,
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
