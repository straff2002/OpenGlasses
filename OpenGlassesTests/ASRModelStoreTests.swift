import XCTest
@testable import OpenGlasses

/// Tests for the on-device ASR model layer (Additional Capabilities #8): the SenseVoice bundle
/// descriptor, the presence store, the download orchestration, engine readiness, and the Config
/// preference — all headless (temp dir + injected installer; no network, no real model).
final class ASRModelStoreTests: XCTestCase {

    private var tempDir: URL!
    private let bundle = ASRModelBundle.active

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASRModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private func store() -> ASRModelStore { ASRModelStore(bundle: bundle, directory: tempDir) }

    private func writeFile(_ name: String, bytes: Int = 8) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: tempDir.appendingPathComponent(name))
    }

    private func installAll() throws {
        for name in bundle.requiredFiles { try writeFile(name) }
    }

    // MARK: - Bundle descriptor

    func testBundleIsSenseVoice() {
        XCTAssertEqual(bundle.id, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17")
        XCTAssertEqual(bundle.requiredFiles, ["model.int8.onnx", "tokens.txt"])
        XCTAssertEqual(bundle.directoryName, "SenseVoiceASR")
    }

    func testResolveURL() {
        XCTAssertEqual(bundle.huggingFaceResolveURL(for: "model.int8.onnx").absoluteString,
                       "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx")
    }

    func testDefaultDirectoryUnderApplicationSupport() {
        XCTAssertEqual(ASRModelStore.defaultDirectory(for: bundle).lastPathComponent, "SenseVoiceASR")
    }

    // MARK: - Presence

    func testFreshStoreHasNoModel() {
        let s = store()
        XCTAssertFalse(s.isModelPresent)
        XCTAssertEqual(s.missingFiles, bundle.requiredFiles)
        XCTAssertEqual(s.state, .notDownloaded)
        XCTAssertEqual(s.totalBytesOnDisk(), 0)
    }

    func testAllFilesPresentIsReady() throws {
        try installAll()
        let s = store()
        XCTAssertTrue(s.isModelPresent)
        XCTAssertEqual(s.state, .ready)
        XCTAssertGreaterThan(s.totalBytesOnDisk(), 0)
    }

    func testMissingTokensReported() throws {
        try writeFile("model.int8.onnx")
        XCTAssertEqual(store().missingFiles, ["tokens.txt"])
    }

    func testEmptyFileCountsAsMissing() throws {
        try writeFile("model.int8.onnx", bytes: 0)
        try writeFile("tokens.txt")
        XCTAssertEqual(store().missingFiles, ["model.int8.onnx"])
    }

    func testDeleteRemovesModel() throws {
        try installAll()
        let s = store()
        XCTAssertTrue(s.isModelPresent)
        try s.deleteModel()
        XCTAssertFalse(s.isModelPresent)
    }

    // MARK: - Engine readiness (sherpa binary compiled in via SHERPA_ONNX_ENABLED)

    @MainActor
    func testEngineReadyWhenModelPresent() throws {
        try installAll()
        let engine = OnDeviceASREngine(modelStore: store())
        XCTAssertTrue(OnDeviceASREngine.isCompiledIn)
        XCTAssertTrue(engine.isReady)
    }

    @MainActor
    func testEngineNotReadyWhenModelAbsent() {
        XCTAssertFalse(OnDeviceASREngine(modelStore: store()).isReady)
    }

    @MainActor
    func testTranscribeThrowsWhenModelAbsent() async {
        let engine = OnDeviceASREngine(modelStore: store())
        do {
            _ = try await engine.transcribe(samples: [0, 0, 0], sampleRate: 16000)
            XCTFail("should throw when model absent")
        } catch let error as ASRError {
            XCTAssertEqual(error, .modelUnavailable)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - Download orchestration (injected installer)

    @MainActor
    func testDownloadInstallsAndBecomesReady() async {
        let modelDir = tempDir.appendingPathComponent("SenseVoiceASR", isDirectory: true)
        let installer: ASRModelDownloader.Installer = { bundle, destination, progress in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in bundle.requiredFiles {
                try Data(repeating: 0x42, count: 8).write(to: destination.appendingPathComponent(name))
            }
            progress(1.0)
        }
        let downloader = ASRModelDownloader(bundle: bundle, modelDirectory: modelDir, installer: installer)
        await downloader.download()
        XCTAssertEqual(downloader.state, .ready)
        XCTAssertTrue(ASRModelStore(bundle: bundle, directory: modelDir).isModelPresent)
    }

    @MainActor
    func testIncompleteDownloadFails() async {
        let modelDir = tempDir.appendingPathComponent("SenseVoiceASR", isDirectory: true)
        let installer: ASRModelDownloader.Installer = { _, destination, _ in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 8).write(to: destination.appendingPathComponent("model.int8.onnx"))
            // tokens.txt missing
        }
        let downloader = ASRModelDownloader(bundle: bundle, modelDirectory: modelDir, installer: installer)
        await downloader.download()
        guard case .failed = downloader.state else { return XCTFail("expected .failed, got \(downloader.state)") }
        XCTAssertFalse(ASRModelStore(bundle: bundle, directory: modelDir).isModelPresent)
    }

    // MARK: - Config

    func testConfigPreferenceRoundTrips() {
        let original = Config.asrEnginePreference
        defer { Config.setASREnginePreference(original) }
        Config.setASREnginePreference(.onDevice)
        XCTAssertEqual(Config.asrEnginePreference, .onDevice)
        Config.setASREnginePreference(.appleSpeech)
        XCTAssertEqual(Config.asrEnginePreference, .appleSpeech)
    }

    func testConfigPreferenceDefaultsToAuto() {
        let original = Config.asrEnginePreference
        defer { Config.setASREnginePreference(original) }
        UserDefaults.standard.removeObject(forKey: "asrEnginePreference")
        XCTAssertEqual(Config.asrEnginePreference, .auto)
    }
}
