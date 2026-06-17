import XCTest
import Combine
@testable import OpenGlasses

/// Tests for the Kokoro model download orchestration core (Additional Capabilities #1): the
/// download-to-staging → verify → atomic-install state machine, driven by an **injected installer**
/// (a fake that writes files), so no network/archive code runs. The live `.tar.bz2` fetch+extract
/// adapter is deferred and not covered here.
@MainActor
final class KokoroModelDownloaderTests: XCTestCase {

    private var root: URL!
    private var modelDir: URL!
    private let bundle = KokoroModelBundle.active
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        modelDir = root.appendingPathComponent("KokoroTTS", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: root)
        root = nil
        modelDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fake installers

    /// Writes every required file + directory into `destination` (a complete, valid install).
    private func fullInstaller(progressSteps: [Double] = []) -> KokoroModelDownloader.Installer {
        { bundle, destination, progress in
            for step in progressSteps { await progress(step) }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in bundle.requiredFiles {
                try Data(repeating: 0x42, count: 8).write(to: destination.appendingPathComponent(name))
            }
            for name in bundle.requiredDirectories {
                let dir = destination.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(repeating: 0x42, count: 4).write(to: dir.appendingPathComponent("entry.bin"))
            }
        }
    }

    /// Writes only the files (no directories) — an incomplete install that must fail verification.
    private func filesOnlyInstaller() -> KokoroModelDownloader.Installer {
        { bundle, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in bundle.requiredFiles {
                try Data(repeating: 0x42, count: 8).write(to: destination.appendingPathComponent(name))
            }
        }
    }

    private func makeDownloader(installer: @escaping KokoroModelDownloader.Installer) -> KokoroModelDownloader {
        KokoroModelDownloader(bundle: bundle, modelDirectory: modelDir, installer: installer)
    }

    private func stagingLeftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix("KokoroTTS-staging-") } ?? []
    }

    // MARK: - Tests

    func testInitialStateReflectsAbsentModel() {
        let downloader = makeDownloader(installer: fullInstaller())
        XCTAssertEqual(downloader.state, .notDownloaded)
    }

    func testSuccessfulDownloadInstallsAndBecomesReady() async {
        let downloader = makeDownloader(installer: fullInstaller())
        await downloader.download()
        XCTAssertEqual(downloader.state, .ready)
        let store = KokoroModelStore(bundle: bundle, directory: modelDir)
        XCTAssertTrue(store.isModelPresent)
        XCTAssertTrue(stagingLeftovers().isEmpty, "staging dir should be moved into place, not left behind")
    }

    func testDownloadIsSkippedWhenModelAlreadyPresent() async {
        // Pre-install a full bundle, then confirm download() is a no-op that doesn't call the installer.
        var installerCalls = 0
        let counting: KokoroModelDownloader.Installer = { bundle, destination, progress in
            installerCalls += 1
            try await self.fullInstaller()(bundle, destination, progress)
        }
        // First download populates the model.
        let first = makeDownloader(installer: counting)
        await first.download()
        XCTAssertEqual(installerCalls, 1)

        // A fresh downloader over the same (now-present) directory must skip.
        let second = makeDownloader(installer: counting)
        await second.download()
        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(installerCalls, 1, "installer must not run when the model is already present")
    }

    func testInstallerErrorLeavesFailedStateAndNoModel() async {
        struct Boom: LocalizedError { var errorDescription: String? { "network down" } }
        let downloader = makeDownloader(installer: { _, _, _ in throw Boom() })
        await downloader.download()
        guard case .failed(let reason) = downloader.state else {
            return XCTFail("expected .failed, got \(downloader.state)")
        }
        XCTAssertEqual(reason, "network down")
        XCTAssertFalse(KokoroModelStore(bundle: bundle, directory: modelDir).isModelPresent)
        XCTAssertTrue(stagingLeftovers().isEmpty, "failed download must clean up its staging dir")
    }

    func testIncompleteDownloadFailsVerificationAndDoesNotInstall() async {
        let downloader = makeDownloader(installer: filesOnlyInstaller())
        await downloader.download()
        guard case .failed(let reason) = downloader.state else {
            return XCTFail("expected .failed, got \(downloader.state)")
        }
        XCTAssertTrue(reason.contains("incomplete"), "reason should flag the incomplete bundle: \(reason)")
        XCTAssertFalse(KokoroModelStore(bundle: bundle, directory: modelDir).isModelPresent)
        XCTAssertTrue(stagingLeftovers().isEmpty)
    }

    func testProgressIsReportedThroughState() async {
        let downloader = makeDownloader(installer: fullInstaller(progressSteps: [0.25, 0.5, 1.0]))
        var seen: [KokoroModelState] = []
        downloader.$state.sink { seen.append($0) }.store(in: &cancellables)
        await downloader.download()
        XCTAssertTrue(seen.contains(.downloading(progress: 0.5)), "progress should surface as .downloading: \(seen)")
        XCTAssertEqual(downloader.state, .ready)
    }

    func testDeleteModelResetsState() async {
        let downloader = makeDownloader(installer: fullInstaller())
        await downloader.download()
        XCTAssertEqual(downloader.state, .ready)
        downloader.deleteModel()
        XCTAssertEqual(downloader.state, .notDownloaded)
        XCTAssertFalse(KokoroModelStore(bundle: bundle, directory: modelDir).isModelPresent)
    }
}
