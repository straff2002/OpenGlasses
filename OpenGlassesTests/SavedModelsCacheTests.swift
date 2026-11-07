import XCTest
@testable import OpenGlasses

/// `Config.savedModels` keeps its decoded list while nothing has written to the Keychain, and
/// never hands back a copy a write has replaced — including a write made straight through
/// `KeychainService`, which is how several tests and the plaintext migration store the list.
final class SavedModelsCacheTests: XCTestCase {

    private let key = "savedModelConfigs"
    private var stored: Data??

    override func setUp() {
        super.setUp()
        stored = .some(KeychainService.data(for: key))
    }

    override func tearDown() {
        KeychainService.setData(stored ?? nil, for: key)
        super.tearDown()
    }

    // MARK: - GenerationCache

    func testAValueIsReturnedOnlyAtTheGenerationItWasStoredAt() {
        let cache = GenerationCache<String>()
        XCTAssertNil(cache.value(at: 0), "An empty cache returned a value")
        cache.store("first", at: 3)
        XCTAssertEqual(cache.value(at: 3), "first")
        XCTAssertNil(cache.value(at: 4), "A value outlived a write to its source")
        XCTAssertNil(cache.value(at: 2))
    }

    func testAnOlderReadNeverReplacesANewerOne() {
        let cache = GenerationCache<String>()
        cache.store("newer", at: 5)
        cache.store("older", at: 4)
        XCTAssertEqual(cache.value(at: 5), "newer",
                       "A read that began before a later write replaced the later read's value")
        cache.store("newest", at: 6)
        XCTAssertEqual(cache.value(at: 6), "newest")
    }

    func testClearForgetsTheValue() {
        let cache = GenerationCache<Int>()
        cache.store(1, at: 1)
        cache.clear()
        XCTAssertNil(cache.value(at: 1))
    }

    // MARK: - KeychainService.writeGeneration

    func testEveryKindOfKeychainWriteAdvancesTheGeneration() throws {
        let scratch = "savedModelsCacheTests.scratch"
        defer { KeychainService.delete(scratch) }

        var before = KeychainService.writeGeneration
        KeychainService.setData(Data("a".utf8), for: scratch)
        XCTAssertGreaterThan(KeychainService.writeGeneration, before, "setData did not advance it")

        before = KeychainService.writeGeneration
        KeychainService.delete(scratch)
        XCTAssertGreaterThan(KeychainService.writeGeneration, before, "delete did not advance it")

        before = KeychainService.writeGeneration
        try KeychainService.writeData(Data("b".utf8), for: scratch,
                                      accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertGreaterThan(KeychainService.writeGeneration, before, "writeData did not advance it")

        before = KeychainService.writeGeneration
        try KeychainService.upsertDataAtomically(Data("c".utf8), for: scratch,
                                                 accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertGreaterThan(KeychainService.writeGeneration, before,
                             "upsertDataAtomically did not advance it")

        before = KeychainService.writeGeneration
        try KeychainService.deleteItem(scratch)
        XCTAssertGreaterThan(KeychainService.writeGeneration, before, "deleteItem did not advance it")
    }

    func testReadingDoesNotAdvanceTheGeneration() {
        _ = Config.savedModels // settles any one-time migration write
        let before = KeychainService.writeGeneration
        _ = Config.savedModels
        _ = Config.activeModel
        _ = KeychainService.data(for: key)
        XCTAssertEqual(KeychainService.writeGeneration, before,
                       "A read advanced the generation, so the cache could never be used")
    }

    // MARK: - Config.savedModels

    func testADirectKeychainWriteIsSeenOnTheNextRead() throws {
        try store([model(id: "one", name: "First")])
        XCTAssertEqual(Config.savedModels.first(where: { $0.id == "one" })?.name, "First")

        try store([model(id: "one", name: "Renamed")])
        XCTAssertEqual(Config.savedModels.first(where: { $0.id == "one" })?.name, "Renamed",
                       "savedModels returned the list a direct Keychain write had replaced")
    }

    func testSetSavedModelsIsSeenOnTheNextRead() {
        Config.setSavedModels([model(id: "two", name: "Before")])
        XCTAssertEqual(Config.savedModels.first(where: { $0.id == "two" })?.name, "Before")
        Config.setSavedModels([model(id: "two", name: "After")])
        XCTAssertEqual(Config.savedModels.first(where: { $0.id == "two" })?.name, "After")
    }

    func testDeletingTheListIsSeenOnTheNextRead() throws {
        try store([model(id: "gone", name: "Soon gone")])
        XCTAssertTrue(Config.savedModels.contains(where: { $0.id == "gone" }))
        KeychainService.delete(key)
        XCTAssertFalse(Config.savedModels.contains(where: { $0.id == "gone" }),
                       "An erased model list was still served from memory")
    }

    func testTheOnDeviceModelIsStillAddedToAStoredList() throws {
        try store([model(id: "three", name: "Only cloud")])
        let models = Config.savedModels
        XCTAssertTrue(models.contains(where: { $0.provider == LLMProvider.appleOnDevice.rawValue }))
        XCTAssertEqual(Config.savedModels.map(\.id), models.map(\.id),
                       "The migrated list and the next read disagree")
    }

    // MARK: - Helpers

    private func store(_ models: [ModelConfig]) throws {
        KeychainService.setData(try JSONEncoder().encode(models), for: key)
    }

    private func model(id: String, name: String) -> ModelConfig {
        ModelConfig(id: id, name: name, provider: LLMProvider.anthropic.rawValue, apiKey: "test-key",
                    model: "claude-test", baseURL: LLMProvider.anthropic.defaultBaseURL)
    }
}
