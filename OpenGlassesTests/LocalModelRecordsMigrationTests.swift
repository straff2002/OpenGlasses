import XCTest
@testable import OpenGlasses

/// Plan DZ P0 — installed-model records and the legacy MLX migration.
///
/// Everything runs against a temp directory and a scratch `UserDefaults` suite, so the real
/// Application Support tree and the user's real preferences are never touched.
///
/// The claims that matter, and which each test discharges:
///  - an existing MLX install gets a record **without a single file moving** (the whole reason the
///    record points at the hub layout instead of relocating it);
///  - the migration is idempotent and forward-only;
///  - the version stamp is written last, after every record has been read back;
///  - a record is "installed" only with both a manifest and a `.complete` marker; and
///  - nothing a pre-DZ build saved becomes undecodable.
final class LocalModelRecordsMigrationTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dz-records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "dz.records.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeRepository(legacyIDs: [String]? = nil,
                                now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) })
        -> LocalModelRepository {
        LocalModelRepository(root: root,
                             defaults: defaults,
                             legacyModelIDs: legacyIDs.map { ids in { ids } },
                             now: now)
    }

    /// Create a hub-layout directory with a file in it, as a real download would leave behind.
    @discardableResult
    private func plantLegacyModel(_ rawID: String, fileBytes: Int = 32) throws -> URL {
        let directory = root.appendingPathComponent(
            LocalModelRepository.legacyDirectoryName(forModelID: rawID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: fileBytes)
            .write(to: directory.appendingPathComponent("model.safetensors"))
        return directory
    }

    // MARK: - Legacy layout naming

    func testLegacyDirectoryNameRoundTrips() {
        let raw = "mlx-community/gemma-4-e2b-it-4bit"
        let name = LocalModelRepository.legacyDirectoryName(forModelID: raw)
        XCTAssertEqual(name, "models--mlx-community--gemma-4-e2b-it-4bit")
        XCTAssertEqual(LocalModelRepository.modelID(fromLegacyDirectoryName: name), raw)
    }

    func testNonHubDirectoriesAreIgnoredByTheScan() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("staging", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("installed", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertEqual(LocalModelRepository.legacyHubModelIDs(under: root),
                       ["mlx-community/Qwen2.5-0.5B-Instruct-4bit"])
        XCTAssertNil(LocalModelRepository.modelID(fromLegacyDirectoryName: "installed"))
        XCTAssertNil(LocalModelRepository.modelID(fromLegacyDirectoryName: "models--"))
    }

    // MARK: - Migration

    func testMigrationRecordsEveryLegacyModelWithoutMovingFiles() throws {
        let known = "mlx-community/Qwen2.5-3B-Instruct-4bit"
        let unknown = "someone/private-finetune"
        let knownDirectory = try plantLegacyModel(known)
        let unknownDirectory = try plantLegacyModel(unknown)

        let repository = makeRepository()
        XCTAssertEqual(repository.migrateIfNeeded(), .migrated(count: 2))

        // The files are exactly where they were. This is the claim the whole design exists to make:
        // a multi-gigabyte move is how an interrupted migration costs a user their model.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: knownDirectory.appendingPathComponent("model.safetensors").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: unknownDirectory.appendingPathComponent("model.safetensors").path))

        let installed = repository.installedModels()
        XCTAssertEqual(installed.map(\.id.rawValue).sorted(), [known, unknown].sorted())
        for record in installed {
            XCTAssertEqual(record.runtime, .mlx)
            XCTAssertTrue(record.storage.isLegacy)
            XCTAssertEqual(record.storage.directoryName,
                           LocalModelRepository.legacyDirectoryName(forModelID: record.id.rawValue))
            XCTAssertEqual(record.validatedFiles, [],
                           "these files were fetched before digests were recorded — claiming to "
                           + "have validated them would be a lie")
        }
    }

    func testKnownIDsGetTheirBundledDescriptorAndUnknownIDsACompatibilityOne() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-3B-Instruct-4bit")
        try plantLegacyModel("someone/private-finetune")
        let repository = makeRepository()
        _ = repository.migrateIfNeeded()

        let known = repository.installation(for: LocalModelID("mlx-community/Qwen2.5-3B-Instruct-4bit"))
        XCTAssertEqual(known?.descriptor.displayName, "Qwen 2.5 3B")
        XCTAssertTrue(known?.descriptor.supportsTools == true)

        let unknown = repository.installation(for: LocalModelID("someone/private-finetune"))
        XCTAssertEqual(unknown?.descriptor.runtime, .mlx, "unknown ids default to MLX")
        XCTAssertEqual(unknown?.descriptor.displayName, "someone/private-finetune")
        XCTAssertEqual(unknown?.descriptor.capabilities, [.text])
    }

    func testMigrationIsIdempotent() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-3B-Instruct-4bit")
        let repository = makeRepository()

        XCTAssertEqual(repository.migrateIfNeeded(), .migrated(count: 1))
        XCTAssertEqual(repository.migrateIfNeeded(), .notNeeded)
        XCTAssertEqual(repository.migrateIfNeeded(), .notNeeded)
        XCTAssertEqual(repository.installedModels().count, 1)
    }

    /// A second run against the same directory (version stamp cleared, as a repair would) must not
    /// duplicate or rewrite the record it already wrote.
    func testRerunningAfterTheStampIsClearedLeavesExistingRecordsAlone() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-3B-Instruct-4bit")
        let repository = makeRepository()
        _ = repository.migrateIfNeeded()
        let before = repository.installedModels()

        defaults.removeObject(forKey: LocalModelRepository.migrationVersionKey)
        XCTAssertEqual(repository.migrateIfNeeded(), .migrated(count: 0),
                       "nothing new to write — the existing records are already complete")
        XCTAssertEqual(repository.installedModels(), before)
    }

    func testNoLocalModelsIsNotNeededRatherThanAFailure() {
        let repository = makeRepository(legacyIDs: [])
        XCTAssertEqual(repository.migrateIfNeeded(), .notNeeded)
        XCTAssertFalse(repository.isMigrationPending, "a device with no local models is migrated")
    }

    func testMigrationIsPendingUntilItSucceeds() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-3B-Instruct-4bit")
        let repository = makeRepository()
        XCTAssertTrue(repository.isMigrationPending)
        _ = repository.migrateIfNeeded()
        XCTAssertFalse(repository.isMigrationPending)
    }

    /// The version stamp must not be written when a record could not be. Simulated by making the
    /// `installed` path a *file*, so the directory cannot be created.
    func testAFailedMigrationDoesNotStampTheVersion() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-3B-Instruct-4bit")
        try Data("not a directory".utf8).write(
            to: root.appendingPathComponent(LocalModelRepository.installedDirectoryName))

        let repository = makeRepository()
        XCTAssertEqual(repository.migrateIfNeeded(), .failed)
        XCTAssertTrue(repository.isMigrationPending,
                      "an unverifiable run must retry, never record that it happened")
        XCTAssertEqual(defaults.integer(forKey: LocalModelRepository.migrationVersionKey), 0)
    }

    func testInstalledAtComesFromTheLegacyDirectoryNotTheMigrationClock() throws {
        try plantLegacyModel("mlx-community/Qwen2.5-3B-Instruct-4bit")
        // Far enough in the future that the directory's real creation date is unambiguously
        // earlier — the whole point being that `installedAt` comes from the files, not the clock.
        let migrationClock = Date(timeIntervalSince1970: 4_000_000_000)
        let repository = makeRepository(now: { migrationClock })
        _ = repository.migrateIfNeeded()

        let record = try XCTUnwrap(
            repository.installation(for: LocalModelID("mlx-community/Qwen2.5-3B-Instruct-4bit")))
        XCTAssertNotEqual(record.installedAt, migrationClock,
                          "the model was installed when it was downloaded, not when we noticed")
        XCTAssertLessThan(record.installedAt, migrationClock)
    }

    // MARK: - Record round trip and the completeness rule

    func testRecordRoundTripsThroughDisk() throws {
        let repository = makeRepository(legacyIDs: [])
        let record = InstalledLocalModel(
            descriptor: LocalModelCatalog.entries[0].descriptor,
            storage: .managed(directoryName: LocalModelCatalog.entries[0].id.storageComponent),
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            validatedFiles: [LocalModelFile(relativePath: "model.gguf", byteCount: 42,
                                            sha256: "deadbeef", role: .weights)],
            acceptedLicenseRevision: "v1")

        try repository.record(record)
        let readBack = try XCTUnwrap(repository.installation(for: record.id))

        XCTAssertTrue(LocalModelRepository.matches(written: record, readBack: readBack))
        XCTAssertEqual(readBack.descriptor, record.descriptor)
        XCTAssertEqual(readBack.validatedFiles, record.validatedFiles)
        XCTAssertEqual(readBack.acceptedLicenseRevision, "v1")
        XCTAssertEqual(readBack.manifestVersion, InstalledLocalModel.currentManifestVersion)
    }

    func testAManifestWithoutTheMarkerIsNotInstalled() throws {
        let repository = makeRepository(legacyIDs: [])
        let id = LocalModelID("a/b")
        let record = InstalledLocalModel(
            descriptor: LocalModelCatalog.compatibilityDescriptor(forLegacyMLXModelID: "a/b"),
            storage: .managed(directoryName: id.storageComponent),
            installedAt: Date())
        try repository.record(record)
        XCTAssertTrue(repository.isInstalled(id))

        // Remove the marker: a half-written record, exactly what a power loss mid-install leaves.
        try FileManager.default.removeItem(
            at: repository.directory(for: id)
                .appendingPathComponent(LocalModelRepository.completionMarkerName))
        XCTAssertFalse(repository.isInstalled(id),
                       "a directory without both a manifest and the marker is never installed")
        XCTAssertEqual(repository.installedModels(), [])
    }

    func testAMarkerWithoutADecodableManifestIsNotInstalled() throws {
        let repository = makeRepository(legacyIDs: [])
        let id = LocalModelID("a/b")
        let directory = repository.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent(LocalModelRepository.manifestFileName))
        try Data().write(to: directory.appendingPathComponent(LocalModelRepository.completionMarkerName))

        XCTAssertFalse(repository.isInstalled(id))
        XCTAssertEqual(repository.installedModels(), [])
    }

    func testForeignDirectoriesUnderInstalledAreIgnored() throws {
        let repository = makeRepository(legacyIDs: [])
        try FileManager.default.createDirectory(
            at: repository.installedRoot.appendingPathComponent("%", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertEqual(repository.installedModels(), [])
    }

    func testInstalledModelsAreOrderedStably() throws {
        try plantLegacyModel("zzz/last")
        try plantLegacyModel("aaa/first")
        let repository = makeRepository()
        _ = repository.migrateIfNeeded()
        XCTAssertEqual(repository.installedModels().map(\.id.rawValue), ["aaa/first", "zzz/last"])
    }

    // MARK: - Read-back verification rule

    func testMatchesRejectsARecordThatCameBackDifferent() {
        let base = InstalledLocalModel(
            descriptor: LocalModelCatalog.entries[0].descriptor,
            storage: .managed(directoryName: "x"),
            installedAt: Date(timeIntervalSince1970: 100))
        var different = base
        different.storage = .legacyHubSnapshot(directoryName: "x")
        XCTAssertFalse(LocalModelRepository.matches(written: base, readBack: different))

        var otherDescriptor = base
        otherDescriptor.descriptor = LocalModelCatalog.entries[1].descriptor
        XCTAssertFalse(LocalModelRepository.matches(written: base, readBack: otherDescriptor))

        var otherFiles = base
        otherFiles.validatedFiles = [LocalModelFile(relativePath: "a", byteCount: 1,
                                                    sha256: "b", role: .weights)]
        XCTAssertFalse(LocalModelRepository.matches(written: base, readBack: otherFiles))
    }

    func testMatchesToleratesSubSecondDateRoundingOnly() {
        let base = InstalledLocalModel(
            descriptor: LocalModelCatalog.entries[0].descriptor,
            storage: .managed(directoryName: "x"),
            installedAt: Date(timeIntervalSince1970: 100))
        var rounded = base
        rounded.installedAt = Date(timeIntervalSince1970: 100.4)
        XCTAssertTrue(LocalModelRepository.matches(written: base, readBack: rounded),
                      "ISO-8601 second rounding is not corruption")

        var wrong = base
        wrong.installedAt = Date(timeIntervalSince1970: 500)
        XCTAssertFalse(LocalModelRepository.matches(written: base, readBack: wrong))
    }

    // MARK: - Legacy-safe decoding of the record itself

    func testRecordDecodesWhenOptionalFieldsAreAbsent() throws {
        let json = """
        {"descriptor":{"id":"a/b","displayName":"A","repositoryID":"a/b"},
         "storage":{"managed":{"directoryName":"a%2Fb"}}}
        """
        let decoded = try JSONDecoder().decode(InstalledLocalModel.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, LocalModelID("a/b"))
        XCTAssertEqual(decoded.manifestVersion, 1)
        XCTAssertEqual(decoded.validatedFiles, [])
        XCTAssertNil(decoded.acceptedLicenseRevision)
    }

    /// A record written by a future build, carrying a field this build has never heard of, must
    /// still decode — the BB salvage discipline applied to a single record.
    func testRecordDecodesDespiteUnknownFieldsFromANewerBuild() throws {
        let json = """
        {"manifestVersion":7,"descriptor":{"id":"a/b","displayName":"A","repositoryID":"a/b",
          "somethingNew":true},
         "storage":{"managed":{"directoryName":"a%2Fb"}},
         "installedAt":"2026-01-01T00:00:00Z","futureField":{"nested":1}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InstalledLocalModel.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.manifestVersion, 7)
        XCTAssertEqual(decoded.id, LocalModelID("a/b"))
    }

    /// One undecodable file entry must cost that entry, not the whole installation.
    func testOneBadFileEntryDoesNotDiscardTheRecord() throws {
        let json = """
        {"descriptor":{"id":"a/b","displayName":"A","repositoryID":"a/b"},
         "storage":{"managed":{"directoryName":"a%2Fb"}},
         "validatedFiles":[{"relativePath":"good.gguf","byteCount":10,"sha256":"aa","role":"weights"},
                           {"relativePath":"bad.gguf"}]}
        """
        let decoded = try JSONDecoder().decode(InstalledLocalModel.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.validatedFiles.map(\.relativePath), ["good.gguf"])
    }

    // MARK: - Turn-path resolution never depends on the migration

    func testTurnPathInstallationResolvesWithoutTouchingDisk() {
        // A turn must not become dependent on the migration having run, or the first launch after
        // an interrupted migration cannot answer a question.
        let installed = LLMService.mlxInstallation(forModelID: "mlx-community/Qwen2.5-3B-Instruct-4bit")
        XCTAssertEqual(installed.runtime, .mlx)
        XCTAssertTrue(installed.storage.isLegacy)
        XCTAssertEqual(installed.storage.directoryName,
                       "models--mlx-community--Qwen2.5-3B-Instruct-4bit")

        let typed = LLMService.mlxInstallation(forModelID: "someone/typed-by-hand")
        XCTAssertEqual(typed.descriptor.capabilities, [.text],
                       "no saved configuration may become unusable because of this seam")
    }
}
