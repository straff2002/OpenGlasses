import XCTest
@testable import OpenGlasses

/// The global "small context" switch became the per-model `ModelConfig.smallContext`. These pin
/// the legacy-safe decode, the one-shot migration, and the honest local-model caption.
final class SmallContextMigrationTests: XCTestCase {

    private var originalModels: [ModelConfig] = []
    private var originalFlag = false

    override func setUp() {
        super.setUp()
        originalModels = Config.savedModels
        originalFlag = Config.llmImageLightweightPromptEnabled
    }

    override func tearDown() {
        Config.setSavedModels(originalModels)
        Config.setLLMImageLightweightPromptEnabled(originalFlag)
        super.tearDown()
    }

    // MARK: - Legacy decode

    func testConfigSavedBeforeFieldDecodesAsOff() throws {
        let legacyJSON = """
        {"id":"m1","name":"Groq","provider":"groq","apiKey":"k","model":"llama","baseURL":"https://api.groq.com"}
        """
        let config = try JSONDecoder().decode(ModelConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(config.smallContext)
        XCTAssertFalse(config.smallContextEnabled)
    }

    func testRoundTripPreservesExplicitChoice() throws {
        var config = ModelConfig.defaultConfig(for: .groq)
        config.smallContext = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModelConfig.self, from: data)
        XCTAssertTrue(decoded.smallContextEnabled)
    }

    // MARK: - Migration

    func testGlobalFlagCarriesOntoCloudModelsOnly() {
        var groq = ModelConfig.defaultConfig(for: .groq)
        let local = ModelConfig.defaultConfig(for: .local)
        var anthropic = ModelConfig.defaultConfig(for: .anthropic)
        // A model the user already decided about keeps its decision.
        anthropic.smallContext = false
        groq.smallContext = nil
        Config.setSavedModels([groq, local, anthropic])
        Config.setLLMImageLightweightPromptEnabled(true)

        Config.migrateSmallContextToPerModelIfNeeded()

        let migrated = Config.savedModels
        XCTAssertEqual(migrated[0].smallContext, true, "undecided cloud model inherits the global choice")
        XCTAssertNil(migrated[1].smallContext, "on-device models never carry the flag — they are always lean")
        XCTAssertEqual(migrated[2].smallContext, false, "an explicit per-model decision survives migration")
        XCTAssertFalse(Config.llmImageLightweightPromptEnabled, "global flag cleared after migration")
    }

    func testMigrationIsNoOpWhenFlagOff() {
        let groq = ModelConfig.defaultConfig(for: .groq)
        Config.setSavedModels([groq])
        Config.setLLMImageLightweightPromptEnabled(false)

        Config.migrateSmallContextToPerModelIfNeeded()

        XCTAssertNil(Config.savedModels[0].smallContext)
    }

    // MARK: - Local caption

    func testLocalContextCaptionUsesBudgetTables() {
        let caption = ModelFormView.localContextCaption(modelId: "unknown-model")
        XCTAssertTrue(caption.contains("compact prompt"))
        XCTAssertTrue(caption.contains("k-token context"))
        // The numbers must come from the budget the truncation logic enforces.
        let window = LocalModelBudget.contextWindow(for: "unknown-model")
        XCTAssertTrue(caption.contains("~\(window / 1024)k-token"))
    }
}
