import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the selected on-device model becomes a stable id, with the legacy string field
/// retained and synchronized for one compatibility release.
///
/// Two properties carry the whole risk, and both are here:
///
///  - **The migration is forward-only and read-back-verified.** A preferences write that did not
///    land must not be stamped as done, and a stamped device must never re-run.
///  - **Downgrade safety.** An MLX selection always survives a downgrade to a build without this
///    plan; a GGUF selection never corrupts one.
final class LocalModelSelectionMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Stands in for `ModelConfig.model` on the on-device provider, so nothing here touches the
    /// Keychain.
    private var legacyField = ""
    private var runtimes: [String: LocalModelRuntime] = [:]

    override func setUp() {
        super.setUp()
        suiteName = "LocalModelSelectionMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        legacyField = ""
        runtimes = [:]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> LocalModelSelectionStore {
        LocalModelSelectionStore(
            defaults: defaults,
            legacySelection: { [self] in legacyField },
            setLegacySelection: { [self] in legacyField = $0 },
            runtimeForID: { [self] in runtimes[$0.rawValue] ?? .mlx },
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    // MARK: - The legacy shape

    func testALegacyStringSelectionMigratesToARecord() {
        legacyField = "mlx-community/Qwen2.5-3B-Instruct-4bit"
        let store = makeStore()

        XCTAssertEqual(store.migrateIfNeeded(),
                       .migrated(LocalModelID("mlx-community/Qwen2.5-3B-Instruct-4bit")))
        XCTAssertEqual(store.record()?.id.rawValue, "mlx-community/Qwen2.5-3B-Instruct-4bit")
        XCTAssertEqual(store.record()?.version, LocalModelSelectionRecord.currentVersion)
        XCTAssertEqual(legacyField, "mlx-community/Qwen2.5-3B-Instruct-4bit",
                       "the migration reads the legacy field; it has nothing to write back")
    }

    func testAnIdIsReadableBeforeTheMigrationHasRun() {
        // The behaviour a device gets if the migration is deferred or cannot write: exactly what it
        // had before.
        legacyField = "mlx-community/thing-4bit"
        XCTAssertEqual(makeStore().selectedID()?.rawValue, "mlx-community/thing-4bit")
    }

    func testTheMigrationIsForwardOnlyAndIdempotent() {
        legacyField = "mlx-community/first"
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .migrated(LocalModelID("mlx-community/first")))

        // A later legacy change must not be re-migrated over a deliberate selection.
        legacyField = "mlx-community/second"
        XCTAssertEqual(store.migrateIfNeeded(), .alreadyMigrated)
        XCTAssertEqual(store.record()?.id.rawValue, "mlx-community/first")
    }

    func testNothingToMigrateStillStamps() {
        let store = makeStore()
        XCTAssertEqual(store.migrateIfNeeded(), .nothingToMigrate)
        XCTAssertEqual(defaults.integer(forKey: LocalModelSelectionStore.migrationVersionKey),
                       LocalModelSelectionStore.migrationVersion)
        XCTAssertNil(store.selectedID())
    }

    func testARecordWrittenByANewerBuildIsNotOverwrittenOrHalfRead() {
        // Version 99 means "written by a build whose fields may mean something else".
        let future = try! JSONEncoder.iso8601.encode(
            LocalModelSelectionRecord(id: LocalModelID("future/model"),
                                      updatedAt: Date(), version: 99))
        defaults.set(future, forKey: LocalModelSelectionStore.recordKey)
        legacyField = "mlx-community/thing"
        let store = makeStore()

        XCTAssertNil(store.record(), "a newer record is ignored, not decoded partially")
        // The migration sees no readable record, so it carries the legacy field forward — which is
        // the only value this build can honestly act on.
        XCTAssertEqual(store.migrateIfNeeded(), .migrated(LocalModelID("mlx-community/thing")))
    }

    // MARK: - Synchronization and downgrade safety

    func testAnMLXSelectionWritesBothFields() {
        runtimes["mlx-community/thing-4bit"] = .mlx
        let store = makeStore()
        XCTAssertTrue(store.select(LocalModelID("mlx-community/thing-4bit")))
        XCTAssertEqual(store.selectedID()?.rawValue, "mlx-community/thing-4bit")
        XCTAssertEqual(legacyField, "mlx-community/thing-4bit",
                       "for every model that exists today the id IS the hub repository id")
    }

    func testAGGUFSelectionLeavesTheLastMLXSelectionInTheLegacyField() {
        runtimes["mlx-community/thing-4bit"] = .mlx
        runtimes["owner/repo#m-Q4_K_M.gguf"] = .llamaCpp
        let store = makeStore()

        store.select(LocalModelID("mlx-community/thing-4bit"))
        store.select(LocalModelID("owner/repo#m-Q4_K_M.gguf"))

        XCTAssertEqual(store.selectedID()?.rawValue, "owner/repo#m-Q4_K_M.gguf",
                       "this build reads the record")
        XCTAssertEqual(legacyField, "mlx-community/thing-4bit",
                       "a build without this plan must be left an id it can actually fetch")
    }

    func testAGGUFSelectionNeverPutsAGGUFIdInTheLegacyField() {
        runtimes["owner/repo#m-Q4_K_M.gguf"] = .llamaCpp
        runtimes["other/repo#n-Q5_K_M.gguf"] = .llamaCpp
        legacyField = "other/repo#n-Q5_K_M.gguf"   // as if an earlier build had got this wrong
        let store = makeStore()

        store.select(LocalModelID("owner/repo#m-Q4_K_M.gguf"))
        XCTAssertEqual(legacyField, "",
                       "an id the older build cannot fetch is cleared, not left to fail every launch")
    }

    func testDowngradingWithAGGUFSelectionLeavesTheMLXSelectionUsable() {
        // The property, end to end: pick MLX, then pick GGUF, then read the world as a pre-plan
        // build would — which is the legacy field and nothing else.
        runtimes["mlx-community/Qwen2.5-3B-Instruct-4bit"] = .mlx
        runtimes["owner/repo#m-Q4_K_M.gguf"] = .llamaCpp
        let store = makeStore()
        store.select(LocalModelID("mlx-community/Qwen2.5-3B-Instruct-4bit"))
        store.select(LocalModelID("owner/repo#m-Q4_K_M.gguf"))

        let whatAnOlderBuildSees = legacyField
        XCTAssertEqual(whatAnOlderBuildSees, "mlx-community/Qwen2.5-3B-Instruct-4bit")
        XCTAssertEqual(LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: whatAnOlderBuildSees)
                        .runtime, .mlx)
    }

    func testClearingForgetsTheRecordAndOnlyTheMatchingLegacyValue() {
        runtimes["mlx-community/thing-4bit"] = .mlx
        let store = makeStore()
        store.select(LocalModelID("mlx-community/thing-4bit"))
        store.clearSelection()
        XCTAssertNil(store.record())
        XCTAssertEqual(legacyField, "", "the legacy field named the model being forgotten")

        // A legacy value naming a *different* model is still a usable answer for an older build.
        runtimes["owner/repo#m.gguf"] = .llamaCpp
        legacyField = "mlx-community/other-4bit"
        store.select(LocalModelID("owner/repo#m.gguf"))
        store.clearSelection()
        XCTAssertEqual(legacyField, "mlx-community/other-4bit")
    }

    // MARK: - Runtime resolved from the descriptor

    func testAnIdWithNoRecordResolvesToTheMLXCompatibilityInstallation() {
        let installation = LocalModelSelection.compatibilityInstallation(
            for: LocalModelID("someone/typed-by-hand"))
        XCTAssertEqual(installation.runtime, .mlx,
                       "MLX is the only runtime that could have produced an existing installation")
        XCTAssertTrue(installation.storage.isLegacy)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
