import XCTest
@testable import OpenGlasses

/// Tests for the HuggingFace download installer (Additional Capabilities #1): tree-API JSON parsing,
/// resolve-URL construction, and the per-file install loop (sub-paths preserved, progress reported) —
/// all headless via injected fake network seams. No real network.
@MainActor
final class HuggingFaceModelInstallerTests: XCTestCase {

    private var dest: URL!
    private let bundle = KokoroModelBundle.active

    override func setUpWithError() throws {
        try super.setUpWithError()
        dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("HFInstallerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dest)
        dest = nil
        try super.tearDownWithError()
    }

    // MARK: - Tree parsing

    func testParseTreeKeepsFilesAndDropsDirectories() throws {
        let json = """
        [
          {"type":"directory","path":"espeak-ng-data","size":0},
          {"type":"file","path":"model.int8.onnx","size":114299010},
          {"type":"file","path":"tokens.txt","size":1111},
          {"type":"file","path":"espeak-ng-data/phontab","size":2048}
        ]
        """.data(using: .utf8)!
        let files = try HuggingFaceModelInstaller.parseTree(json)
        XCTAssertEqual(files, [
            HuggingFaceFile(path: "model.int8.onnx", size: 114_299_010),
            HuggingFaceFile(path: "tokens.txt", size: 1111),
            HuggingFaceFile(path: "espeak-ng-data/phontab", size: 2048),
        ])
    }

    func testParseTreeToleratesMissingSize() throws {
        let json = #"[{"type":"file","path":"tokens.txt"}]"#.data(using: .utf8)!
        let files = try HuggingFaceModelInstaller.parseTree(json)
        XCTAssertEqual(files, [HuggingFaceFile(path: "tokens.txt", size: 0)])
    }

    // MARK: - Resolve URL construction

    func testResolveURLForNestedPath() {
        XCTAssertEqual(bundle.huggingFaceResolveURL(for: "dict/jieba.dict.utf8").absoluteString,
                       "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/resolve/main/dict/jieba.dict.utf8")
    }

    // MARK: - Install loop

    /// Records which URLs were "downloaded" and writes placeholder bytes to the destination.
    private func recordingInstaller(files: [HuggingFaceFile]) -> (HuggingFaceModelInstaller, () -> [URL]) {
        final class Box { var urls: [URL] = [] }
        let box = Box()
        let installer = HuggingFaceModelInstaller(
            listFiles: { _ in files },
            downloadFile: { url, destination in
                box.urls.append(url)
                let bytes = files.first { $0.path.hasSuffix(destination.lastPathComponent) }?.size ?? 8
                try Data(repeating: 0x42, count: Int(max(bytes, 1))).write(to: destination)
                return max(bytes, 1)
            }
        )
        return (installer, { box.urls })
    }

    func testInstallLoopWritesFilesPreservingSubPaths() async throws {
        let files = [
            HuggingFaceFile(path: "tokens.txt", size: 4),
            HuggingFaceFile(path: "dict/jieba.dict.utf8", size: 4),
            HuggingFaceFile(path: "espeak-ng-data/phontab", size: 4),
        ]
        let (installer, requestedURLs) = recordingInstaller(files: files)

        var lastProgress: Double = 0
        try await installer.makeInstaller()(bundle, dest) { lastProgress = $0 }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("tokens.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("dict/jieba.dict.utf8").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("espeak-ng-data/phontab").path))
        XCTAssertEqual(lastProgress, 1.0, accuracy: 0.0001)
        // Each file is fetched from its resolve URL.
        XCTAssertEqual(requestedURLs().count, 3)
        XCTAssertTrue(requestedURLs().allSatisfy { $0.absoluteString.contains("/resolve/main/") })
    }

    func testEmptyListingThrows() async {
        let installer = HuggingFaceModelInstaller(listFiles: { _ in [] }, downloadFile: { _, _ in 0 })
        do {
            try await installer.makeInstaller()(bundle, dest) { _ in }
            XCTFail("an empty repo listing should throw")
        } catch let error as KokoroDownloadError {
            guard case .incompleteDownload = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testDownloadErrorPropagates() async {
        struct Boom: Error {}
        let installer = HuggingFaceModelInstaller(
            listFiles: { _ in [HuggingFaceFile(path: "tokens.txt", size: 4)] },
            downloadFile: { _, _ in throw Boom() }
        )
        do {
            try await installer.makeInstaller()(bundle, dest) { _ in }
            XCTFail("a download error should propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - End-to-end with the downloader orchestrator

    func testDownloaderUsesHFInstallerToReachReady() async {
        // Drive the real orchestrator with an HF installer backed by fake network seams; the full
        // bundle's files/dirs are produced, so it verifies and installs.
        let modelDir = dest.appendingPathComponent("KokoroTTS", isDirectory: true)
        let files = bundle.requiredFiles.map { HuggingFaceFile(path: $0, size: 8) }
            + ["espeak-ng-data/phontab", "dict/jieba.dict.utf8"].map { HuggingFaceFile(path: $0, size: 8) }
        let installer = HuggingFaceModelInstaller(
            listFiles: { _ in files },
            downloadFile: { _, destination in
                try Data(repeating: 0x42, count: 8).write(to: destination)
                return 8
            }
        ).makeInstaller()

        let downloader = KokoroModelDownloader(bundle: bundle, modelDirectory: modelDir, installer: installer)
        await downloader.download()
        XCTAssertEqual(downloader.state, .ready)
        XCTAssertTrue(KokoroModelStore(bundle: bundle, directory: modelDir).isModelPresent)
    }
}
