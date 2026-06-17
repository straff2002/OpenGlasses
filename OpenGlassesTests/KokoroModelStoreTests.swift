import XCTest
@testable import OpenGlasses

/// Tests for the Kokoro on-device TTS model store + bundle descriptor + engine readiness (Additional
/// Capabilities #1). All presence logic is exercised headlessly against a temp directory — no
/// network, no binary. The store is descriptor-driven, so "installed" means every declared file
/// **and** directory (e.g. `espeak-ng-data/`, `dict/`) is present.
final class KokoroModelStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: KokoroModelStore!
    private let bundle = KokoroModelBundle.active

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = KokoroModelStore(bundle: bundle, directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, bytes: Int = 8) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: tempDir.appendingPathComponent(name))
    }

    /// Create a directory and drop a dummy file in it so it counts as non-empty.
    private func writeDirectory(_ name: String) throws {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4).write(to: dir.appendingPathComponent("entry.bin"))
    }

    /// Write every required file and directory so the bundle counts as fully installed.
    private func installFullBundle() throws {
        for name in bundle.requiredFiles { try writeFile(name) }
        for name in bundle.requiredDirectories { try writeDirectory(name) }
    }

    // MARK: - Bundle descriptor

    func testActiveBundleIsInt8MultiLang() {
        XCTAssertEqual(bundle.id, "kokoro-int8-multi-lang-v1_1")
        XCTAssertTrue(bundle.requiredFiles.contains("model.int8.onnx"))
        XCTAssertTrue(bundle.requiredFiles.contains("voices.bin"))
        XCTAssertTrue(bundle.requiredFiles.contains("tokens.txt"))
        XCTAssertTrue(bundle.requiredDirectories.contains("espeak-ng-data"))
        XCTAssertTrue(bundle.requiredDirectories.contains("dict"))
    }

    func testHuggingFaceURLsAreWellFormed() {
        // The chosen hosting is HuggingFace, with files stored unpacked (no tarball).
        XCTAssertEqual(bundle.huggingFaceRepo, "csukuangfj/kokoro-int8-multi-lang-v1_1")
        XCTAssertEqual(bundle.huggingFaceTreeAPIURL.host, "huggingface.co")
        XCTAssertTrue(bundle.huggingFaceTreeAPIURL.absoluteString.contains("/tree/main"))

        let modelURL = bundle.huggingFaceResolveURL(for: "model.int8.onnx")
        XCTAssertEqual(modelURL.absoluteString,
                       "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/resolve/main/model.int8.onnx")

        // A nested path (a file inside espeak-ng-data/) keeps its slashes.
        let nestedURL = bundle.huggingFaceResolveURL(for: "espeak-ng-data/phontab")
        XCTAssertEqual(nestedURL.absoluteString,
                       "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/resolve/main/espeak-ng-data/phontab")
    }

    // MARK: - Presence

    func testFreshStoreHasNoModel() {
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingFiles, bundle.requiredFiles)
        XCTAssertEqual(store.missingDirectories, bundle.requiredDirectories)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertEqual(store.totalBytesOnDisk(), 0)
    }

    func testFullInstallMakesModelPresent() throws {
        try installFullBundle()
        XCTAssertTrue(store.isModelPresent)
        XCTAssertTrue(store.missingFiles.isEmpty)
        XCTAssertTrue(store.missingDirectories.isEmpty)
        XCTAssertEqual(store.state, .ready)
        XCTAssertGreaterThan(store.totalBytesOnDisk(), 0)
    }

    func testFilesPresentButDirectoriesMissingIsNotReady() throws {
        // The key correctness fix over a files-only check: sherpa-onnx needs espeak-ng-data/ + dict/,
        // so the model isn't "ready" with the flat files alone.
        for name in bundle.requiredFiles { try writeFile(name) }
        XCTAssertFalse(store.isModelPresent)
        XCTAssertTrue(store.missingFiles.isEmpty)
        XCTAssertEqual(store.missingDirectories, bundle.requiredDirectories)
    }

    func testEmptyDirectoryCountsAsMissing() throws {
        try installFullBundle()
        // Empty out one required directory — an empty espeak-ng-data is as useless as a missing one.
        let dir = tempDir.appendingPathComponent("espeak-ng-data", isDirectory: true)
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingDirectories, ["espeak-ng-data"])
    }

    func testPartialFilesAreReportedMissing() throws {
        try installFullBundle()
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("voices.bin"))
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingFiles, ["voices.bin"])
    }

    func testEmptyFileCountsAsMissing() throws {
        try installFullBundle()
        // A truncated/aborted download can leave a 0-byte stub — it must not pass as installed.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("model.int8.onnx"))
        try writeFile("model.int8.onnx", bytes: 0)
        XCTAssertFalse(store.isModelPresent)
        XCTAssertEqual(store.missingFiles, ["model.int8.onnx"])
    }

    func testDirectoryNamedLikeAFileDoesNotSatisfyAFileRequirement() throws {
        try installFullBundle()
        // Replace a required file with a directory of the same name — must not count as present.
        let modelURL = tempDir.appendingPathComponent("model.int8.onnx")
        try FileManager.default.removeItem(at: modelURL)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        XCTAssertFalse(store.isFilePresent("model.int8.onnx"))
        XCTAssertFalse(store.isModelPresent)
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
        try installFullBundle()
        XCTAssertTrue(store.isModelPresent)
        try store.deleteModel()
        XCTAssertFalse(store.isModelPresent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testDeleteModelOnAbsentDirectoryIsNoOp() throws {
        XCTAssertNoThrow(try store.deleteModel())
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        XCTAssertEqual(KokoroModelStore.defaultDirectory.lastPathComponent, "KokoroTTS")
    }

    // MARK: - Engine readiness (compile flag off → never selectable)

    @MainActor
    func testEngineNotReadyWithoutBinaryEvenWhenModelPresent() throws {
        try installFullBundle()
        let engine = KokoroTTSEngine(modelStore: store)
        XCTAssertFalse(KokoroTTSEngine.isCompiledIn)
        XCTAssertFalse(engine.isReady)   // model on disk, but no binary → clean no-op
    }

    @MainActor
    func testEngineSynthesizeThrowsWithoutBinary() async throws {
        try installFullBundle()
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
