import Foundation

/// The on-device ASR tier's aliases onto the shared model-download layer (Additional Capabilities
/// #8). The store/downloader/state-machine logic is the generic `ModelStore` / `ModelDownloader`;
/// this tier contributes only its bundle descriptor and its live installer.
typealias ASRModelState = ModelDownloadState
typealias ASRDownloadError = ModelDownloadError
typealias ASRModelStore = ModelStore<ASRModelBundle>
typealias ASRModelDownloader = ModelDownloader<ASRModelBundle>

/// Describes the downloadable on-device ASR model — SenseVoice on sherpa-onnx (Additional
/// Capabilities #8). Unlike the Kokoro TTS bundle, SenseVoice is just two flat files
/// (`model.int8.onnx` + `tokens.txt`, hosted unpacked on HuggingFace), so the live installer fetches
/// them directly — no repo-tree enumeration, no extraction, no required directories.
struct ASRModelBundle: DownloadableModelBundle {

    /// Stable identifier (also the upstream repo's model name).
    let id: String
    /// User-facing name for the Settings status row.
    let displayName: String
    /// Sub-directory under Application Support that holds the model files.
    let directoryName: String
    /// HuggingFace repo hosting the (unpacked) files.
    let huggingFaceRepo: String
    /// Rough total download size, for the Settings status row.
    let approxDownloadBytes: Int64
    /// Files that must each be present and non-empty for the model to count as installed.
    let requiredFiles: [String]

    /// The production installer: fetches each required file directly from HuggingFace (the files are
    /// unpacked, so no tree enumeration). Progress is per-file completed fraction.
    static let liveInstaller: ASRModelDownloader.Installer = { bundle, destination, progress in
        let files = bundle.requiredFiles
        for (index, name) in files.enumerated() {
            let url = bundle.huggingFaceResolveURL(for: name)
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ASRDownloadError.incompleteDownload(missing: "\(name) (HTTP \(http.statusCode))")
            }
            let dest = destination.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            // NB: the `await` is required — calling the @MainActor `progress` closure from this
            // nonisolated context is an actor hop. (The "no async operations" warning is a known
            // diagnostic quirk that disagrees with the type system; removing await fails to build.)
            await progress(Double(index + 1) / Double(max(files.count, 1)))
        }
    }

    /// The shipped bundle: SenseVoice int8, multilingual (zh/en/ja/ko/yue), ~240 MB.
    static let senseVoiceMultiLang = ASRModelBundle(
        id: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
        displayName: "SenseVoice (multilingual)",
        directoryName: "SenseVoiceASR",
        huggingFaceRepo: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
        approxDownloadBytes: 240_000_000,
        requiredFiles: ["model.int8.onnx", "tokens.txt"]
    )

    /// The bundle the app ships with.
    static let active = senseVoiceMultiLang
}
