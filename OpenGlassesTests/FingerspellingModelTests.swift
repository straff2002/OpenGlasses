import XCTest
@testable import OpenGlasses

/// Tests for the fingerspelling model store + downloader state machine (Plan CK): configured
/// vs dormant, presence checks, staging → verify → atomic install, failure cleanup. Fresh
/// temp directories and injected installers throughout.
@MainActor
final class FingerspellingModelTests: XCTestCase {

    private var tempDir: URL!

    private func makeBundle(repo: String = "example/fingerspelling-conformer") -> FingerspellingModelBundle {
        FingerspellingModelBundle(
            id: "test-model", displayName: "Test", directoryName: "FingerspellingTest",
            huggingFaceRepo: repo, approxDownloadBytes: 1000,
            requiredFiles: ["pkg/model.bin", "vocab.txt"])
    }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerspelling-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func modelDir() -> URL { tempDir.appendingPathComponent("model", isDirectory: true) }

    private func write(_ name: String, in directory: URL, contents: String = "x") throws {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Store

    func testUnconfiguredRepoReportsNotConfigured() {
        let store = FingerspellingModelStore(bundle: makeBundle(repo: ""), directory: modelDir())
        XCTAssertEqual(store.state, .notConfigured)
        XCTAssertNil(makeBundle(repo: "").huggingFaceResolveURL(for: "vocab.txt"))
    }

    func testMissingFilesReportedAndEmptyFileNotPresent() throws {
        let store = FingerspellingModelStore(bundle: makeBundle(), directory: modelDir())
        XCTAssertEqual(store.state, .notDownloaded)
        try write("vocab.txt", in: modelDir())
        try write("pkg/model.bin", in: modelDir(), contents: "")   // 0-byte stub
        XCTAssertEqual(store.missingFiles, ["pkg/model.bin"])
        XCTAssertFalse(store.isModelPresent)
    }

    func testResolveURLEscapesSubpaths() {
        let url = makeBundle().huggingFaceResolveURL(for: "pkg/model.bin")
        XCTAssertEqual(url?.absoluteString,
                       "https://huggingface.co/example/fingerspelling-conformer/resolve/main/pkg/model.bin")
    }

    // MARK: - Downloader

    func testDownloadStagesVerifiesAndInstalls() async {
        let bundle = makeBundle()
        let downloader = FingerspellingModelDownloader(
            bundle: bundle, modelDirectory: modelDir(),
            installer: { bundle, destination, progress in
                for file in bundle.requiredFiles {
                    let dest = destination.appendingPathComponent(file)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try Data("model-bytes".utf8).write(to: dest)
                }
                await progress(1.0)
            })
        await downloader.download()
        XCTAssertEqual(downloader.state, .ready)
        let store = FingerspellingModelStore(bundle: bundle, directory: modelDir())
        XCTAssertTrue(store.isModelPresent)
    }

    func testIncompleteDownloadFailsAndCleansUp() async {
        let bundle = makeBundle()
        let downloader = FingerspellingModelDownloader(
            bundle: bundle, modelDirectory: modelDir(),
            installer: { bundle, destination, _ in
                // Only one of the two required files arrives.
                try Data("x".utf8).write(to: destination.appendingPathComponent("vocab.txt"))
            })
        await downloader.download()
        guard case .failed(let reason) = downloader.state else {
            return XCTFail("expected .failed, got \(downloader.state)")
        }
        XCTAssertTrue(reason.contains("pkg/model.bin"))
        // Nothing half-installed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir().path))
    }

    func testInstallerErrorSurfacesAsFailed() async {
        struct Boom: Error {}
        let downloader = FingerspellingModelDownloader(
            bundle: makeBundle(), modelDirectory: modelDir(),
            installer: { _, _, _ in throw Boom() })
        await downloader.download()
        guard case .failed = downloader.state else {
            return XCTFail("expected .failed, got \(downloader.state)")
        }
    }

    func testDownloadIsNoOpWhenAlreadyInstalled() async throws {
        let bundle = makeBundle()
        for file in bundle.requiredFiles { try write(file, in: modelDir()) }
        var installerRan = false
        let downloader = FingerspellingModelDownloader(
            bundle: bundle, modelDirectory: modelDir(),
            installer: { _, _, _ in installerRan = true })
        await downloader.download()
        XCTAssertEqual(downloader.state, .ready)
        XCTAssertFalse(installerRan)
    }

    func testUnconfiguredDownloadRefuses() async {
        let downloader = FingerspellingModelDownloader(
            bundle: makeBundle(repo: ""), modelDirectory: modelDir(),
            installer: { _, _, _ in XCTFail("must not run") })
        await downloader.download()
        XCTAssertEqual(downloader.state, .notConfigured)
    }

    func testDeleteModelResetsState() async throws {
        let bundle = makeBundle()
        for file in bundle.requiredFiles { try write(file, in: modelDir()) }
        let downloader = FingerspellingModelDownloader(
            bundle: bundle, modelDirectory: modelDir(), installer: { _, _, _ in })
        downloader.refreshState()
        XCTAssertEqual(downloader.state, .ready)
        downloader.deleteModel()
        XCTAssertEqual(downloader.state, .notDownloaded)
    }
}
