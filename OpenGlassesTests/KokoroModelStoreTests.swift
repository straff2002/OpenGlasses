import XCTest
@testable import OpenGlasses

/// Tests for the Kokoro on-device TTS model store + engine readiness (Additional Capabilities #1).
/// All file-presence logic is exercised headlessly against a temp directory — no network, no binary.
final class KokoroModelStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: KokoroModelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = KokoroModelStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Write `bytes` of placeholder content to one of the model's required files.
    private func writeFile(_ name: String, bytes: Int = 8) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let data = Data(repeating: 0x42, count: bytes)
        try data.write(to: tempDir.appendingPathComponent(name))
    }

    private func writeAllRequiredFiles() throws {
        for name in KokoroModelStore.requiredFiles { try writeFile(name) }
    }

    // MARK: - Presence

    func testFreshStoreHasNoModel() {
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingFiles, KokoroModelStore.requiredFiles)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertEqual(store.totalBytesOnDisk(), 0)
    }

    func testAllFilesPresentMakesModelPresent() throws {
        try writeAllRequiredFiles()
        XCTAssertTrue(store.isModelPresent)
        XCTAssertTrue(store.missingFiles.isEmpty)
        XCTAssertEqual(store.state, .ready)
        XCTAssertGreaterThan(store.totalBytesOnDisk(), 0)
    }

    func testPartialFilesAreReportedMissing() throws {
        try writeFile("model.int8.onnx")
        try writeFile("tokens.txt")
        // voices.bin is absent
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingFiles, ["voices.bin"])
    }

    func testEmptyFileCountsAsMissing() throws {
        // A truncated/aborted download can leave a 0-byte stub — it must not pass as installed.
        try writeFile("model.int8.onnx", bytes: 0)
        try writeFile("voices.bin")
        try writeFile("tokens.txt")
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingFiles, ["model.int8.onnx"])
    }

    func testRequiredFileSetIsTheKokoroBundle() {
        XCTAssertEqual(Set(KokoroModelStore.requiredFiles),
                       ["model.int8.onnx", "voices.bin", "tokens.txt"])
    }

    // MARK: - File paths / lifecycle

    func testFileURLIsUnderDirectory() {
        let url = store.fileURL("voices.bin")
        XCTAssertEqual(url.lastPathComponent, "voices.bin")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testEnsureDirectoryExistsCreatesIt() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        try store.ensureDirectoryExists()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testDeleteModelRemovesEverything() throws {
        try writeAllRequiredFiles()
        XCTAssertTrue(store.isModelPresent)
        try store.deleteModel()
        XCTAssertFalse(store.isModelPresent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testDeleteModelOnAbsentDirectoryIsNoOp() throws {
        XCTAssertNoThrow(try store.deleteModel())  // nothing to delete, must not throw
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        XCTAssertEqual(KokoroModelStore.defaultDirectory.lastPathComponent, "KokoroTTS")
    }

    // MARK: - Engine readiness (compile flag off → never selectable)

    @MainActor
    func testEngineNotReadyWithoutBinaryEvenWhenModelPresent() throws {
        try writeAllRequiredFiles()
        let engine = KokoroTTSEngine(modelStore: store)
        // The model is on disk, but the sherpa-onnx binary isn't compiled into the test build,
        // so the engine must report not-ready — Kokoro stays a clean no-op until the binary ships.
        XCTAssertFalse(KokoroTTSEngine.isCompiledIn)
        XCTAssertFalse(engine.isReady)
    }

    @MainActor
    func testEngineSynthesizeThrowsWithoutBinary() async throws {
        try writeAllRequiredFiles()
        let engine = KokoroTTSEngine(modelStore: store)
        do {
            _ = try await engine.synthesize("hello")
            XCTFail("synthesize should throw without the compiled-in binary")
        } catch let error as KokoroError {
            XCTAssertEqual(error, .notCompiledIn)
        }
    }

    // MARK: - Config round-trip

    func testConfigEnginePreferenceRoundTrips() {
        let original = Config.ttsEnginePreference
        defer { Config.setTTSEnginePreference(original) }

        Config.setTTSEnginePreference(.kokoro)
        XCTAssertEqual(Config.ttsEnginePreference, .kokoro)
        Config.setTTSEnginePreference(.system)
        XCTAssertEqual(Config.ttsEnginePreference, .system)
    }

    func testConfigEnginePreferenceDefaultsToAuto() {
        let original = Config.ttsEnginePreference
        defer { Config.setTTSEnginePreference(original) }

        UserDefaults.standard.removeObject(forKey: "ttsEnginePreference")
        XCTAssertEqual(Config.ttsEnginePreference, .auto)
    }
}
