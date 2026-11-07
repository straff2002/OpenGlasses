import CoreML
import XCTest
@testable import OpenGlasses

/// Plan KQ P2: the wearer's choice of manual-search model, its fallbacks, and the search-trained
/// model's bundle and runtime rules. The Core ML model is never loaded here.
@MainActor
final class ManualSearchModelTests: XCTestCase {

    private let choiceKey = "fieldAssistManualSearchModel"
    private let legacyKey = "fieldAssistContextualSearchEnabled"
    private var savedChoice: Any?
    private var savedLegacy: Any?

    override func setUp() {
        super.setUp()
        savedChoice = UserDefaults.standard.object(forKey: choiceKey)
        savedLegacy = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: choiceKey)
    }

    override func tearDown() {
        SearchModelRuntime.readyOverride = nil
        for (key, value) in [(choiceKey, savedChoice), (legacyKey, savedLegacy)] {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    /// A stand-in for the loaded search-trained model.
    private final class FakeSearchModel: EmbeddingBackend {
        let modelId = CoreMLEmbeddingBackend.modelId(dimension: 768)
        let dimension = 3
        func embed(_ text: String) -> [Float]? { [1, 0, 0] }
    }

    func testTheOldSwitchDecidesUntilAChoiceIsStored() {
        XCTAssertEqual(ManualSearchModel.resolve(stored: nil, legacySmarter: true), .smarter)
        XCTAssertEqual(ManualSearchModel.resolve(stored: nil, legacySmarter: false), .standard)
        XCTAssertEqual(ManualSearchModel.resolve(stored: "searchTrained", legacySmarter: false), .searchTrained)
        XCTAssertEqual(ManualSearchModel.resolve(stored: "something newer", legacySmarter: true), .smarter,
                       "a value this build doesn't know falls back to the old switch")
    }

    func testStoringAChoiceKeepsTheOldSwitchInStep() {
        UserDefaults.standard.set(false, forKey: legacyKey)
        XCTAssertEqual(Config.fieldAssistManualSearchModel, .standard)
        Config.fieldAssistManualSearchModel = .searchTrained
        XCTAssertEqual(Config.fieldAssistManualSearchModel, .searchTrained)
        XCTAssertTrue(Config.fieldAssistContextualSearchEnabled)
        Config.fieldAssistManualSearchModel = .standard
        XCTAssertFalse(Config.fieldAssistContextualSearchEnabled)
    }

    func testEachChoiceNamesItsOwnModelsIds() {
        XCTAssertEqual(ManualSearchModel.standard.modelIdPrefix, "nl-sentence")
        XCTAssertEqual(ManualSearchModel.smarter.modelIdPrefix, "nl-contextual")
        XCTAssertTrue(CoreMLEmbeddingBackend.modelId(dimension: 768).hasPrefix(ManualSearchModel.searchTrained.modelIdPrefix))
    }

    func testTheSearchTrainedModelAnswersOnlyOnceItIsLoaded() {
        SearchModelRuntime.readyOverride = { FakeSearchModel() }
        XCTAssertEqual(Embedder.fieldAssist(choice: .searchTrained).modelId, "eg2-text.768")
        XCTAssertNotEqual(Embedder.fieldAssist(choice: .smarter).modelId, "eg2-text.768",
                          "a loaded search model is used only when it is the choice")

        SearchModelRuntime.readyOverride = { nil }
        let fallback = Embedder.fieldAssist(choice: .searchTrained)
        XCTAssertFalse(fallback.modelId.hasPrefix("eg2-text"))
        XCTAssertEqual(fallback.modelId, Embedder.fieldAssist(choice: .smarter).modelId,
                       "until it is loaded, Search-trained searches as Smarter does")
    }

    func testStandardNeverUsesALoadedModel() {
        SearchModelRuntime.readyOverride = { FakeSearchModel() }
        let standard = Embedder.fieldAssist(choice: .standard)
        XCTAssertTrue(standard.modelId.hasPrefix("nl-sentence") || standard.modelId.hasPrefix("nl-word"), standard.modelId)
    }

    func testTheModelRunsOnTheCPUOnly() {
        XCTAssertEqual(CoreMLEmbeddingBackend.computeUnits, .cpuOnly,
                       "the GPU is forbidden in the background and the Neural Engine's fp16 moves every vector")
    }

    func testTheBundleNeedsThePackageAndTheTokenizer() {
        let bundle = SearchModelBundle.active
        XCTAssertEqual(bundle.huggingFaceRepo, "Skunk0/avenkin-search-eg2-text")
        for file in ["Manifest.json", "model.mlmodel", "weight.bin"] {
            XCTAssertTrue(bundle.requiredFiles.contains { $0.hasPrefix(SearchModelBundle.packageName) && $0.hasSuffix(file) }, file)
        }
        for file in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            XCTAssertTrue(bundle.requiredFiles.contains(file), file)
        }
        XCTAssertGreaterThan(bundle.approxDownloadBytes, 250_000_000)
    }

    func testTheDownloadHasItsOwnModelAssetRoute() {
        let route = NetworkRoute.searchModelDownload
        XCTAssertEqual(route.dataClasses, [.modelAsset])
        XCTAssertFalse(route.medicalPolicy.blocksLocalOnly, "a model download carries nothing about the wearer")
    }

    func testAWarmUpRunsOnlyForTheChosenLoadedModelWithAVaultOpen() {
        XCTAssertTrue(SearchModelRuntime.shouldWarmUp(choice: .searchTrained, vaultOpen: true, loaded: true))
        XCTAssertFalse(SearchModelRuntime.shouldWarmUp(choice: .smarter, vaultOpen: true, loaded: true))
        XCTAssertFalse(SearchModelRuntime.shouldWarmUp(choice: .searchTrained, vaultOpen: false, loaded: true))
        XCTAssertFalse(SearchModelRuntime.shouldWarmUp(choice: .searchTrained, vaultOpen: true, loaded: false))
    }

    func testAVaultOnTheSearchModelGetsItsMeasuredGate() {
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: Embedder.fieldAssist(choice: .searchTrained).modelId).similarityFloor,
                       RetrievalEvidencePolicy.default(for: Embedder.fieldAssist(choice: .smarter).modelId).similarityFloor,
                       "with no model loaded, the fallback's own gate applies")
        SearchModelRuntime.readyOverride = { FakeSearchModel() }
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: Embedder.fieldAssist(choice: .searchTrained).modelId).similarityFloor, 0.69)
    }
}
