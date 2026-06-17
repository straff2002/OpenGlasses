import Foundation

/// A file entry in a HuggingFace repo tree.
struct HuggingFaceFile: Equatable {
    let path: String
    let size: Int64
}

/// Installs a Kokoro bundle by fetching its **unpacked** files from a HuggingFace repo (Additional
/// Capabilities #1 — the on-device TTS tier). HF stores the model files individually rather than as a
/// `.tar.bz2`, so this is a plain per-file download — no bzip2/tar decoding, no extra dependency. It
/// produces a `KokoroModelDownloader.Installer`, which the downloader runs against a staging
/// directory and then verifies + atomically installs.
///
/// The two network seams — listing the repo tree and downloading a file — are injected, so the
/// enumeration / sequencing / progress logic is unit-tested headlessly; production uses `live`
/// (URLSession + the HF tree API).
struct HuggingFaceModelInstaller {

    /// Lists the files in the bundle's repo (recursive).
    typealias TreeLister = (_ bundle: KokoroModelBundle) async throws -> [HuggingFaceFile]
    /// Downloads `url` to `destination` (parent dirs already created), returning bytes written.
    typealias FileDownloader = (_ url: URL, _ destination: URL) async throws -> Int64

    let listFiles: TreeLister
    let downloadFile: FileDownloader

    /// Build the `KokoroModelDownloader.Installer` closure: enumerate the repo, then fetch each file
    /// into `destination`, preserving sub-paths (`dict/…`, `espeak-ng-data/…`) and reporting
    /// cumulative-byte progress.
    func makeInstaller() -> KokoroModelDownloader.Installer {
        { bundle, destination, progress in
            let files = try await listFiles(bundle).filter { !$0.path.hasSuffix("/") }
            guard !files.isEmpty else {
                throw KokoroDownloadError.incompleteDownload(missing: "empty repo listing")
            }
            let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
            var written: Int64 = 0
            for file in files {
                let dest = destination.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                written += try await downloadFile(bundle.huggingFaceResolveURL(for: file.path), dest)
                let fraction = min(Double(written) / Double(total), 1.0)
                await progress(fraction)
            }
        }
    }

    // MARK: - Production seams

    /// The production installer: lists the repo via the HF tree API and downloads each file with
    /// URLSession.
    static let live = HuggingFaceModelInstaller(
        listFiles: { bundle in
            let (data, response) = try await URLSession.shared.data(from: bundle.huggingFaceTreeAPIURL)
            try checkOK(response)
            return try parseTree(data)
        },
        downloadFile: { url, destination in
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            try checkOK(response)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    )

    /// Decode the HuggingFace tree API response (`[{type, path, size}]`) into file entries, dropping
    /// directory entries.
    static func parseTree(_ data: Data) throws -> [HuggingFaceFile] {
        struct Entry: Decodable { let type: String; let path: String; let size: Int64? }
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" }
            .map { HuggingFaceFile(path: $0.path, size: $0.size ?? 0) }
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw KokoroDownloadError.incompleteDownload(missing: "HTTP \(http.statusCode)")
    }
}
