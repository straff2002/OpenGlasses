import XCTest
@testable import OpenGlasses

/// Plan FP P3 — learnings in the vault export route: an exported vault folder carries its approved
/// entries as `learnings/team-learnings.json` (a decisions bundle), importing that folder stages
/// it — nothing applied until accepted — a pack vault still refuses to export, and uninstalling a
/// vault forgets its `learning:` namespace at once while the entries stay, to be re-published if
/// the vault returns.
@MainActor
final class TeamLearningVaultExchangeTests: XCTestCase {

    private typealias F = TeamLearningFixtures
    private static let vaultId = "fp_exchange_test"

    private var root: URL!
    private var entries: LearningEntryStore!
    private var candidates: LearningCandidateStore!
    private var documents: DocumentStore!

    override func setUp() {
        super.setUp()
        root = F.tempDirectory("TeamLearningVaultExchange")
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        documents = F.documentStore(in: root)
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        documents = nil
        candidates = nil
        entries = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A vault with the model core, no manuals, installed as a customer folder.
    private func installVault() throws -> VaultManifest {
        let dir = root.appendingPathComponent("source-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: Self.vaultId, name: "Exchange Test", version: "1.0.0",
                                     files: ["models.md"], proceduresDir: nil,
                                     gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try F.modelsCore.write(to: dir.appendingPathComponent("models.md"), atomically: true, encoding: .utf8)
        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        return installed
    }

    private func outbox() -> LearningBundleOutbox {
        let outbox = LearningBundleOutbox(candidates: candidates, entries: entries)
        outbox.capability = { .granted }
        outbox.hipaaMode = { false }
        outbox.organisationLabel = { "Northbridge" }
        outbox.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        return outbox
    }

    private func vaults() -> [LearningCorpus.VaultTarget] {
        [LearningCorpus.VaultTarget(id: Self.vaultId, modelIndex: F.modelIndex())]
    }

    // MARK: - Export and import

    func testAnExportCarriesTheVaultsLearningsAndImportingItStagesThemUnapplied() throws {
        _ = try installVault()
        let scoped = F.entry(vaultIDs: [Self.vaultId])
        let everywhere = F.entry(vaultIDs: [], finding: "A finding for every vault")
        let elsewhere = F.entry(vaultIDs: ["another_vault"], finding: "Not this vault's")
        var retracted = F.entry(vaultIDs: [Self.vaultId], finding: "Withdrawn later")
        retracted.retractedAt = Date(timeIntervalSince1970: 1_799_000_000)
        retracted.retractionReason = "Wrong unit"
        [scoped, everywhere, elsewhere, retracted].forEach(entries.upsert)

        let source = outbox()
        let folder = try VaultExporter.export(id: Self.vaultId) { source.vaultExport(vaultId: $0) }
        XCTAssertTrue(VaultValidator.validate(directory: folder).isValid, "an extra folder does not break the vault")
        let data = try XCTUnwrap(VaultImporter.learningsBundleData(in: folder))
        let bundle = try LearningBundle.decode(data).get().bundle
        XCTAssertEqual(bundle.direction, .decisions)
        XCTAssertEqual(Set(bundle.entries.map(\.entryID)), [scoped.id, everywhere.id, retracted.id])
        XCTAssertEqual(bundle.retracted.map(\.entryID), [retracted.id])
        XCTAssertEqual(bundle.statuses, [], "a vault export carries no review decisions")

        // Another phone imports the folder: the learnings wait for acceptance.
        let otherEntries = LearningEntryStore(directory: root.appendingPathComponent("other", isDirectory: true))
        let intake = LearningBundleIntake(candidates: candidates, entries: otherEntries, documentStore: documents)
        intake.capability = { .granted }
        intake.hipaaMode = { false }
        intake.vaults = { [unowned self] in self.vaults() }
        intake.recordStatus = { _, _ in }
        guard case .staged(let pending) = try intake.receive(data).get() else { return XCTFail("staged") }
        XCTAssertEqual(pending.entries.count, 3)
        XCTAssertEqual(otherEntries.entries, [])
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(Self.vaultId)), 0)
        _ = try intake.acceptAll().get()
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(Self.vaultId)), 2,
                       "the two live entries answer; the retracted one is history")
    }

    func testAVaultWithNoLearningsExportsNoLearningsFolder() throws {
        _ = try installVault()
        let folder = try VaultExporter.export(id: Self.vaultId) { [unowned self] in self.outbox().vaultExport(vaultId: $0) }
        XCTAssertNil(VaultImporter.learningsBundleData(in: folder))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(VaultExporter.learningsDirectory).path))
    }

    func testUnderHIPAAOrWithoutTheCapabilityTheExportGoesWithoutLearnings() throws {
        _ = try installVault()
        entries.upsert(F.entry(vaultIDs: [Self.vaultId]))
        let gated = outbox()
        gated.hipaaMode = { true }
        XCTAssertNil(gated.vaultExport(vaultId: Self.vaultId))
        gated.hipaaMode = { false }
        gated.capability = { .notIncluded(held: [.bundledVaults]) }
        XCTAssertNil(gated.vaultExport(vaultId: Self.vaultId))
        let folder = try VaultExporter.export(id: Self.vaultId) { gated.vaultExport(vaultId: $0) }
        XCTAssertNil(VaultImporter.learningsBundleData(in: folder))
    }

    func testAPackVaultStillRefusesToExportSoItsLearningsMoveOnlyByBundle() throws {
        let manifest = try installVault()
        try VaultImporter.recordPack(VaultPackManifest(id: "com.openglasses.vault.\(Self.vaultId)", vaultId: Self.vaultId,
                                                       version: "1.0.0", name: "Pack"), for: Self.vaultId)
        XCTAssertFalse(VaultExporter.isExportable(manifest))
        XCTAssertThrowsError(try VaultExporter.export(id: Self.vaultId)) { error in
            guard case VaultExporter.ExportError.notExportable = error else { return XCTFail("\(error)") }
        }
        // The bundle route is open to it all the same.
        entries.upsert(F.entry(vaultIDs: [Self.vaultId]))
        XCTAssertNotNil(outbox().vaultExport(vaultId: Self.vaultId))
    }

    // MARK: - Uninstall

    func testUninstallForgetsTheNamespaceAtOnceAndAReturningVaultIsRepublished() async throws {
        _ = try installVault()
        let entry = F.entry(vaultIDs: [Self.vaultId])
        entries.upsert(entry)
        let review = LearningReviewService(candidates: candidates, entries: entries, documentStore: documents)
        review.hipaaMode = { false }
        review.vaults = { [unowned self] in self.vaults() }
        review.republish()
        let namespace = DocumentStore.learningNamespace(Self.vaultId)
        XCTAssertEqual(documents.documentCount(namespace: namespace), 1)

        await VaultImporter.uninstall(id: Self.vaultId, documentStore: documents)
        XCTAssertEqual(documents.documentCount(namespace: namespace), 0, "an uninstalled vault answers nothing")
        XCTAssertEqual(entries.entries, [entry], "the entry stays")

        _ = try installVault()
        review.republish()
        XCTAssertEqual(documents.documentCount(namespace: namespace), 1, "the vault came back; so did its learnings")
    }
}
