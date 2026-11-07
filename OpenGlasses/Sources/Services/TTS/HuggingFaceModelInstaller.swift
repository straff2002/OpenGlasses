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
            let files = try await listFiles(bundle)
            try await Self.fetch(files, of: bundle, into: destination, progress: progress, downloadFile: downloadFile)
        }
    }

    /// Fetch `files` of any bundle's repo into `destination`, preserving sub-paths and reporting
    /// cumulative-byte progress. Shared by every tier that hosts unpacked files on HuggingFace.
    static func fetch<B: DownloadableModelBundle>(_ listed: [HuggingFaceFile], of bundle: B, into destination: URL,
                                                  progress: @escaping ModelDownloader<B>.ProgressHandler,
                                                  downloadFile: FileDownloader) async throws {
        try await fetch(listed, of: bundle, into: destination, progress: progress) { url, dest, _ in
            try await downloadFile(url, dest)
        }
    }

    /// Downloads `url` to `destination`, calling `received` with the bytes received so far.
    typealias ProgressingFileDownloader = (_ url: URL, _ destination: URL,
                                           _ received: @escaping @Sendable (Int64) -> Void) async throws -> Int64

    /// `fetch`, with progress inside each file too: a bundle whose weights are one large file
    /// (the search model's is 89% of it) otherwise sits at 0% until that file lands. Progress is
    /// reported in whole-percent steps.
    static func fetch<B: DownloadableModelBundle>(_ listed: [HuggingFaceFile], of bundle: B, into destination: URL,
                                                  progress: @escaping ModelDownloader<B>.ProgressHandler,
                                                  downloadFile: ProgressingFileDownloader) async throws {
        let files = listed.filter { !$0.path.hasSuffix("/") }
        guard !files.isEmpty else {
            throw ModelDownloadError.incompleteDownload(missing: "empty repo listing")
        }
        let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        let reporter = PercentReporter(total: total, progress: progress)
        var written: Int64 = 0
        for file in files {
            let dest = destination.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let before = written
            written += try await downloadFile(bundle.huggingFaceResolveURL(for: file.path), dest) { received in
                reporter.report(before + received)
            }
            await progress(min(Double(written) / Double(total), 1.0))
        }
    }

    /// Turns byte counts from a download's delegate thread into whole-percent progress on the main
    /// actor, skipping repeats.
    final class PercentReporter: @unchecked Sendable {
        private let total: Int64
        private let progress: @MainActor (Double) -> Void
        private let lock = NSLock()
        private var lastPercent = -1

        init(total: Int64, progress: @escaping @MainActor (Double) -> Void) {
            self.total = max(total, 1)
            self.progress = progress
        }

        func report(_ bytes: Int64) {
            let percent = Int(min(Double(bytes) / Double(total), 1.0) * 100)
            lock.lock()
            guard percent > lastPercent else { lock.unlock(); return }
            lastPercent = percent
            lock.unlock()
            let fraction = Double(percent) / 100
            Task { @MainActor in progress(fraction) }
        }
    }

    /// The production per-file fetch with byte progress, for `purpose`'s route.
    static func liveProgressingDownload(for purpose: NetworkRoute) -> ProgressingFileDownloader {
        { url, destination, received in
            let url = try EndpointPolicy.requireOpenable(url: url, for: purpose)
            let delegate = ByteCountDelegate(received: received)
            let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            try checkOK(response)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// A per-task delegate that passes on how many bytes have arrived.
    private final class ByteCountDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let received: @Sendable (Int64) -> Void
        private var observation: NSKeyValueObservation?
        init(received: @escaping @Sendable (Int64) -> Void) { self.received = received }

        // Observing the task's byte count is what reports progress for the async API; the
        // `didWriteData` callback below is kept for when the system delivers it too.
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let received = received
            observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
                received(task.countOfBytesReceived)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            received(totalBytesWritten)
        }

        // The async `download(from:delegate:)` hands the file back itself; nothing to do here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    /// The production repo listing for any bundle, through `purpose`'s route.
    static func liveListing<B: DownloadableModelBundle>(of bundle: B, for purpose: NetworkRoute) async throws -> [HuggingFaceFile] {
        let listing = try EndpointPolicy.requireOpenable(url: bundle.huggingFaceTreeAPIURL, for: purpose)
        let (data, response) = try await URLSession.shared.data(from: listing)
        try checkOK(response)
        return try parseTree(data)
    }

    // MARK: - Production seams

    /// The production installer: lists the repo via the HF tree API and downloads each file with
    /// URLSession.
    static let live = HuggingFaceModelInstaller(
        listFiles: { bundle in
            let listing = try EndpointPolicy.requireOpenable(url: bundle.huggingFaceTreeAPIURL,
                                                             for: .ttsVoiceModelDownload)
            let (data, response) = try await URLSession.shared.data(from: listing)
            try checkOK(response)
            return try parseTree(data)
        },
        downloadFile: { url, destination in
            let url = try EndpointPolicy.requireOpenable(url: url, for: .ttsVoiceModelDownload)
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
