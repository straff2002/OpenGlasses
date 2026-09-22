import SQLite3
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan FN PR1 — removing one manual from an installed vault.
///
/// The promise under test is narrow and total: once a removal reports success, that manual's rows,
/// chunks, ledger entry, manifest entry and installed files are all gone, and nothing — a restart,
/// a re-index, an export round-trip, a retrieval that was already in flight — brings it back. The
/// other manuals in the same vault keep working throughout.
///
/// Everything here runs against a real temporary `DocumentStore` and the real installed-vault
/// layout, because the half of this that can go wrong is persistence. Failures are injected at the
/// filesystem and at the namespace boundary rather than through a mock, so what is exercised is the
/// code that ships.
@MainActor
final class VaultManualRemovalTests: XCTestCase {

    private static let vaultId = "fn_removal_test"
    private static let otherVaultId = "fn_removal_other"

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    /// Directories a test made read-only to force a write failure, restored whatever happens.
    private var chmodRestore: [URL] = []

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultManualRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        for url in chmodRestore {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        chmodRestore = []
        VaultImporter.uninstall(id: Self.vaultId)
        VaultImporter.uninstall(id: Self.otherVaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let installText = """
    SLP99 INSTALLATION MANUAL

    1 CLEARANCES
    The installation clearance on the flue side is 152 millimetres for the SLP99 cabinet.
    Anchor the unit before connecting the flue collar.
    """

    private static let serviceText = """
    SLP99 SERVICE MANUAL

    1 FAULT CODES
    Fault code QQ7 indicates a pressure switch that did not close during the prepurge period.
    Replace the switch when it does not reset after the burner cools.
    """

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    private func makePDF(text: String) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        return renderer.pdfData { context in
            context.beginPage()
            NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 14)])
                .draw(in: CGRect(x: 20, y: 20, width: 360, height: 560))
        }
    }

    /// Writes an importable vault folder. `texts` keys are the manifest file names.
    @discardableResult
    private func writeVault(id: String = vaultId,
                            documents: [VaultDocument],
                            texts: [String: String],
                            originals: [String: String] = [:],
                            documentsDir: String? = "documents",
                            name: String = "Removal Test") -> URL {
        let dir = tempRoot.appendingPathComponent("vault-\(id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: id, name: name, version: "1.0.0",
                                     files: ["safety.md"], proceduresDir: nil,
                                     documentsDir: documentsDir, documents: documents,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? "# Safety\n\nLock out power before opening any panel."
            .write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        let docsDir = documentsDir.map { dir.appendingPathComponent($0, isDirectory: true) } ?? dir
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        for (file, text) in texts {
            try? text.write(to: docsDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        for (file, text) in originals {
            try? makePDF(text: text).write(to: docsDir.appendingPathComponent(file))
        }
        return dir
    }

    /// The two-manual vault every behavioural test starts from: an installation manual and a
    /// service manual, each carrying a phrase the other does not.
    private static let twoManuals = [
        VaultDocument(file: "install.txt", title: "SLP99 Installation Manual", kind: "install_guide"),
        VaultDocument(file: "service.txt", title: "SLP99 Service Manual", kind: "service_manual"),
    ]

    private func installTwoManuals(store: DocumentStore) async throws -> VaultManifest {
        let dir = writeVault(documents: Self.twoManuals,
                             texts: ["install.txt": Self.installText, "service.txt": Self.serviceText])
        let manifest = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        return manifest
    }

    private var namespace: String { DocumentStore.vaultNamespace(Self.vaultId) }
    private var overlay: URL { VaultImporter.overlayDirectory(for: Self.vaultId) }
    private var baseline: URL { VaultImporter.baselineDirectory(for: Self.vaultId) }

    private func documentNames(_ store: DocumentStore) -> Set<String> {
        Set(store.list(namespace: namespace).map(\.name))
    }

    /// Whether any passage in this vault still carries `phrase`, by exact token search — the
    /// embedding-free route, so an absence assertion cannot be an artefact of similarity scoring.
    private func isRetrievable(_ phrase: String, in store: DocumentStore) -> Bool {
        !store.passages(containingToken: phrase, namespace: namespace, limit: 8).isEmpty
    }

    // MARK: - The core removal

    func testRemovingOneManualTakesItsRowsChunksLedgerManifestAndFile() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)
        let removedId = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" }?.documentId)
        XCTAssertGreaterThan(store.chunkCount(documentId: removedId), 0)

        let result = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                         documentStore: store)

        XCTAssertEqual(result.file, "install.txt")
        XCTAssertEqual(result.title, "SLP99 Installation Manual")
        XCTAssertEqual(result.documentId, removedId)
        XCTAssertGreaterThan(result.chunksRemoved, 0)
        XCTAssertEqual(result.remainingDocuments, 1)
        XCTAssertEqual(result.removedFiles, ["documents/install.txt"])

        // The index: metadata and chunks both.
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertEqual(store.chunkCount(documentId: removedId), 0)
        XCTAssertEqual(documentNames(store), ["SLP99 Service Manual"])
        XCTAssertFalse(isRetrievable("clearance", in: store))

        // The ledger and the installed manifest.
        let ledger = VaultImporter.documentLedger(for: Self.vaultId)
        XCTAssertEqual(ledger.entries.map(\.file), ["service.txt"])
        let installed = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertEqual(installed.documents.map(\.file), ["service.txt"])
        XCTAssertEqual(installed.version, manifest.version, "the vault's own identity is preserved")
        XCTAssertEqual(installed.files, manifest.files, "core files are untouched")

        // The installed file.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseline.appendingPathComponent("documents/install.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: baseline.appendingPathComponent("documents/service.txt").path))

        // And nothing is left pending.
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)
        // The manual that stayed still answers.
        XCTAssertTrue(isRetrievable("QQ7", in: store))
    }

    func testRemovedManualStaysAbsentAcrossReloadAndReindex() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)

        // "Restart": the registry and its caches are re-read from disk.
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let reloaded = try XCTUnwrap(VaultRegistry.shared.manifest(id: Self.vaultId))
        XCTAssertEqual(reloaded.documents.map(\.file), ["service.txt"])

        // "Re-index manuals".
        let ledger = try await VaultImporter.syncDocuments(manifest: reloaded, into: store)
        XCTAssertEqual(ledger.entries.map(\.file), ["service.txt"])
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertFalse(isRetrievable("clearance", in: store))
    }

    /// A re-index issued against the *stale* manifest a caller was holding when the removal landed
    /// must not re-ingest the manual. The sync re-reads the installed manifest for exactly this.
    func testReindexWithAStaleManifestDoesNotResurrectTheManual() async throws {
        let store = makeStore()
        let stale = try await installTwoManuals(store: store)
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: stale.id,
                                                documentStore: store)

        let ledger = try await VaultImporter.syncDocuments(manifest: stale, into: store)
        XCTAssertEqual(ledger.entries.map(\.file), ["service.txt"])
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
    }

    /// FN's rule, under Plan FS's export: a removed manual is gone from the manifest, so no export
    /// and no re-import can bring it back. The surviving manual is still *listed* — it is part of
    /// what the vault is — but its file stays on the phone like every other manual, so importing
    /// this folder asks for that one and only that one.
    func testExportOfTheReducedVaultDropsTheRemovedManualAndAsksOnlyForTheSurvivor() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)

        let exported = try VaultExporter.export(id: Self.vaultId)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: exported.appendingPathComponent("documents/install.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: exported.appendingPathComponent("documents/service.txt").path),
                       "manuals never leave the phone through the app")
        let validated = VaultValidator.validate(directory: exported)
        XCTAssertEqual(validated.manifest?.documents.map(\.file), ["service.txt"],
                       "the removed manual is not even claimed")
        XCTAssertEqual(validated.manifest?.documentsIncluded, false)
        XCTAssertFalse(validated.isValid)
        XCTAssertEqual(validated.issues.filter { $0.contains("not included in this export") }.count, 1,
                       "\(validated.issues)")

        XCTAssertThrowsError(try VaultImporter.install(from: exported))

        // Supplying the surviving manual is enough, and the removed one stays gone.
        try fm.createDirectory(at: exported.appendingPathComponent("documents", isDirectory: true),
                               withIntermediateDirectories: true)
        try Self.serviceText.write(to: exported.appendingPathComponent("documents/service.txt"),
                                   atomically: true, encoding: .utf8)
        let reimported = try VaultImporter.install(from: exported)
        VaultRegistry.shared.reloadUserManifests()
        XCTAssertEqual(reimported.documents.map(\.file), ["service.txt"])
        _ = try await VaultImporter.syncDocuments(manifest: reimported, into: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertFalse(isRetrievable("clearance", in: store))
    }

    /// The other half of the export rule: there is no persistent exclusion list, so an explicit
    /// import of a folder that *does* contain the manual is authoritative and restores it.
    func testExplicitReimportOfTheOriginalFolderRestoresTheManual() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)

        let again = writeVault(documents: Self.twoManuals,
                               texts: ["install.txt": Self.installText, "service.txt": Self.serviceText])
        let restored = try VaultImporter.install(from: again)
        VaultRegistry.shared.reloadUserManifests()
        XCTAssertEqual(restored.documents.count, 2)
        _ = try await VaultImporter.syncDocuments(manifest: restored, into: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)
        XCTAssertTrue(isRetrievable("clearance", in: store))
    }

    func testRemovingTheLastManualLeavesAValidVaultWithNoReferenceTier() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)
        let result = try await VaultManualRemoval.remove(file: "service.txt", fromVault: manifest.id,
                                                         documentStore: store)

        XCTAssertEqual(result.remainingDocuments, 0)
        XCTAssertEqual(store.documentCount(namespace: namespace), 0)
        let installed = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertTrue(installed.documents.isEmpty)
        XCTAssertFalse(installed.hasDocuments)
        XCTAssertEqual(installed.files, ["safety.md"], "the core tier survives")
        XCTAssertTrue(VaultImporter.documentLedger(for: Self.vaultId).entries.isEmpty)
        // The vault still loads and still grounds a turn from its core file.
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let vaultStore = try XCTUnwrap(VaultRegistry.shared.store(forId: Self.vaultId))
        XCTAssertTrue(vaultStore.hasContent)
    }

    func testRemovingAManualThatWasNeverIndexed() async throws {
        let store = makeStore()
        let dir = writeVault(documents: Self.twoManuals,
                             texts: ["install.txt": Self.installText, "service.txt": Self.serviceText])
        let manifest = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        // No sync at all: the manifest lists two manuals and the ledger knows none of them.
        XCTAssertTrue(VaultImporter.documentLedger(for: Self.vaultId).entries.isEmpty)

        let result = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                         documentStore: store)
        XCTAssertNil(result.documentId)
        XCTAssertEqual(result.chunksRemoved, 0)
        XCTAssertEqual(result.remainingDocuments, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseline.appendingPathComponent("documents/install.txt").path))

        // And a later index brings in only what is left.
        let reduced = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        let ledger = try await VaultImporter.syncDocuments(manifest: reduced, into: store)
        XCTAssertEqual(ledger.entries.map(\.file), ["service.txt"])
    }

    /// Half-indexed: the ledger still names a document the store no longer holds, which is the
    /// state an interrupted sync or a previous partial failure leaves behind.
    func testRemovingAManualWhoseIndexRowsAreAlreadyGone() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        let orphaned = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" }?.documentId)
        store.forget(documentId: orphaned)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)

        let result = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                         documentStore: store)
        XCTAssertEqual(result.documentId, orphaned)
        XCTAssertEqual(result.chunksRemoved, 0, "nothing was left in the index to delete")
        XCTAssertEqual(VaultImporter.documentLedger(for: Self.vaultId).entries.map(\.file), ["service.txt"])
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)
    }

    /// Repeating a removal that finished is not a second removal: there is nothing left of the
    /// manual to address, and the honest answer is that the vault does not list it. What must be
    /// idempotent is the *retry* of an unfinished one, which the failure tests below cover.
    func testRepeatingAFinishedRemovalChangesNothing() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        let first = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                        documentStore: store)
        XCTAssertGreaterThan(first.chunksRemoved, 0)

        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected unknownDocument")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .unknownDocument = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertEqual(VaultImporter.documentLedger(for: Self.vaultId).entries.map(\.file), ["service.txt"])
    }

    /// A removal whose manifest write landed but whose ledger and index did not — the half-state a
    /// crash between steps leaves — is finished by asking for the same removal again.
    func testRemovingAManualTheManifestHasAlreadyDroppedFinishesTheIndexSide() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        // Reduce only the manifest, leaving the ledger entry and the indexed rows behind.
        try JSONEncoder().encode(VaultManualRemoval.reducedManifest(manifest, removing: "install.txt"))
            .write(to: VaultImporter.registryDirectory.appendingPathComponent("\(Self.vaultId).json"),
                   options: .atomic)
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)

        let result = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                         documentStore: store)
        XCTAssertGreaterThan(result.chunksRemoved, 0)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertEqual(VaultImporter.documentLedger(for: Self.vaultId).entries.map(\.file), ["service.txt"])
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)
    }

    /// The identity is the manifest file, never the displayed title — two manuals may share one.
    func testRemovalAddressesTheManualByFileNotByTitle() async throws {
        let store = makeStore()
        let documents = [
            VaultDocument(file: "install.txt", title: "SLP99 Manual"),
            VaultDocument(file: "service.txt", title: "SLP99 Manual"),
        ]
        let dir = writeVault(documents: documents,
                             texts: ["install.txt": Self.installText, "service.txt": Self.serviceText])
        let manifest = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)

        _ = try await VaultManualRemoval.remove(file: "service.txt", fromVault: manifest.id,
                                                documentStore: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertTrue(isRetrievable("clearance", in: store), "the installation manual is the survivor")
        XCTAssertFalse(isRetrievable("QQ7", in: store))
    }

    // MARK: - Shared files

    func testASharedOriginalIsKeptWhileAnotherManualStillPointsAtIt() async throws {
        let store = makeStore()
        let documents = [
            VaultDocument(file: "install.txt", title: "Install", source: "combined.pdf"),
            VaultDocument(file: "service.txt", title: "Service", source: "combined.pdf"),
        ]
        let dir = writeVault(documents: documents,
                             texts: ["install.txt": Self.installText, "service.txt": Self.serviceText],
                             originals: ["combined.pdf": "Manufacturer original"])
        let manifest = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        let original = baseline.appendingPathComponent("documents/combined.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        let first = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                        documentStore: store)
        XCTAssertEqual(first.keptSharedFiles, ["documents/combined.pdf"])
        XCTAssertEqual(first.removedFiles, ["documents/install.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "the surviving manual still needs its original")

        let second = try await VaultManualRemoval.remove(file: "service.txt", fromVault: manifest.id,
                                                         documentStore: store)
        XCTAssertTrue(second.keptSharedFiles.isEmpty)
        XCTAssertEqual(Set(second.removedFiles), ["documents/service.txt", "documents/combined.pdf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testARecognitionCheckpointGoesWithTheLastManualThatSharesItsHash() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        let entry = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" })
        try OCRCheckpoint(contentHash: entry.contentHash).save(to: overlay)
        let checkpoint = OCRCheckpoint.url(in: overlay, contentHash: entry.contentHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))

        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    // MARK: - Boundaries

    func testUnrelatedVaultsAndPersonalDocumentsAreUntouched() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)

        let otherDir = writeVault(id: Self.otherVaultId,
                                  documents: [VaultDocument(file: "other.txt", title: "Other Manual")],
                                  texts: ["other.txt": Self.serviceText], name: "Other Vault")
        let other = try VaultImporter.install(from: otherDir)
        VaultRegistry.shared.reloadUserManifests()
        _ = try await VaultImporter.syncDocuments(manifest: other, into: store)
        _ = await store.ingest(name: "Personal", text: "A personal note about groceries and errands.",
                               namespace: "global")

        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)

        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(Self.otherVaultId)), 1)
        XCTAssertEqual(store.documentCount(namespace: "global"), 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: VaultImporter.baselineDirectory(for: Self.otherVaultId)
                .appendingPathComponent("documents/other.txt").path))
    }

    func testAPathEscapingTheVaultIsRefused() {
        let root = tempRoot.appendingPathComponent("vault-root", isDirectory: true)
        XCTAssertTrue(VaultManualRemoval.isContained("documents/manual.pdf", in: root))
        XCTAssertTrue(VaultManualRemoval.isContained("manual.pdf", in: root))
        XCTAssertFalse(VaultManualRemoval.isContained("../manual.pdf", in: root))
        XCTAssertFalse(VaultManualRemoval.isContained("documents/../../manual.pdf", in: root))
        XCTAssertFalse(VaultManualRemoval.isContained("/etc/hosts", in: root))
        XCTAssertFalse(VaultManualRemoval.isContained("", in: root))
        XCTAssertFalse(VaultManualRemoval.isContained(".", in: root))
    }

    func testRemovalRefusesAnEscapingDocumentPath() async throws {
        let store = makeStore()
        _ = try await installTwoManuals(store: store)
        // Rewrite the installed manifest with a document whose file escapes the vault. The
        // manifest is a customer's file, so this is a shape it can genuinely arrive in.
        let escaping = VaultManifest(id: Self.vaultId, name: "Removal Test", version: "1.0.0",
                                     files: ["safety.md"], documentsDir: "documents",
                                     documents: [VaultDocument(file: "../../escape.txt", title: "Escape")],
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite."])
        try JSONEncoder().encode(escaping)
            .write(to: VaultImporter.registryDirectory.appendingPathComponent("\(Self.vaultId).json"),
                   options: .atomic)

        do {
            _ = try await VaultManualRemoval.remove(file: "../../escape.txt", fromVault: Self.vaultId,
                                                    documentStore: store)
            XCTFail("expected invalidPath")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .invalidPath = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testRemovalRefusesAnUnknownFileAndAnUninstalledVault() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        do {
            _ = try await VaultManualRemoval.remove(file: "nope.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected unknownDocument")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .unknownDocument = error else { return XCTFail("wrong error: \(error)") }
        }
        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: "refrigeration",
                                                    documentStore: store)
            XCTFail("expected notInstalled for a bundled vault")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .notInstalled = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testRemovalRefusesASignedPack() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        try VaultImporter.recordPack(
            VaultPackManifest(id: "com.openglasses.vault.\(Self.vaultId)", vaultId: Self.vaultId,
                              version: "1.0.0", name: "Pack"),
            for: Self.vaultId)
        defer { try? FileManager.default.removeItem(
            at: baseline.appendingPathComponent(VaultPackManifest.filename)) }

        XCTAssertEqual(VaultManualRemoval.eligibility(of: Self.vaultId),
                       .protectedPack(name: "Removal Test"))
        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected protectedPack")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .protectedPack = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(store.documentCount(namespace: namespace), 2, "nothing was touched")
    }

    func testEligibilityReportsAnUninstalledVault() {
        XCTAssertEqual(VaultManualRemoval.eligibility(of: "no_such_vault"), .notInstalled)
        XCTAssertFalse(VaultManualRemoval.eligibility(of: "no_such_vault").isAllowed)
    }

    // MARK: - Ledger trouble

    func testAnUnreadableLedgerAsksForRepairRatherThanGuessing() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        try Data("{ this is not a ledger".utf8)
            .write(to: overlay.appendingPathComponent(VaultDocumentLedger.filename), options: .atomic)

        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected repairRequired")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .repairRequired = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(store.documentCount(namespace: namespace), 2, "nothing was deleted on a guess")
    }

    /// The ledger decodes but does not account for everything the index holds for this vault. The
    /// manual's identity cannot be established, and matching on the displayed title is exactly the
    /// shortcut that must not be taken.
    func testAnIndexTheLedgerDoesNotAccountForAsksForRepair() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        var ledger = VaultImporter.documentLedger(for: Self.vaultId)
        ledger.remove(file: "install.txt")
        try ledger.save(to: overlay)

        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected repairRequired")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .repairRequired = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)
    }

    func testLoadStrictSeparatesAbsentFromUnreadable() throws {
        let dir = tempRoot.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(try VaultDocumentLedger.loadStrict(from: dir))
        XCTAssertFalse(VaultDocumentLedger.exists(in: dir))

        try VaultDocumentLedger(entries: []).save(to: dir)
        XCTAssertTrue(VaultDocumentLedger.exists(in: dir))
        XCTAssertEqual(try VaultDocumentLedger.loadStrict(from: dir), VaultDocumentLedger())

        try Data("not json".utf8).write(to: dir.appendingPathComponent(VaultDocumentLedger.filename))
        XCTAssertThrowsError(try VaultDocumentLedger.loadStrict(from: dir))
        XCTAssertEqual(VaultDocumentLedger.load(from: dir), VaultDocumentLedger(),
                       "the lenient load still reads an unreadable ledger as empty")
    }

    // MARK: - Failure and recovery

    /// The manifest cannot be written. The index rows are already gone, so reporting success would
    /// be a lie in one direction and reporting nothing-happened a lie in the other: the target has
    /// to stay pending and the retry has to finish it.
    func testAManifestWriteFailureLeavesTheTargetPendingAndARetryFinishesIt() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        makeReadOnly(VaultImporter.registryDirectory)

        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected cleanupFailed")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .cleanupFailed = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(error.isRetryable)
        }

        XCTAssertEqual(VaultManualRemoval.pendingFiles(for: Self.vaultId), ["install.txt"])
        XCTAssertTrue(VaultImporter.installedManifests().first { $0.id == Self.vaultId }?
            .documents.contains { $0.file == "install.txt" } ?? false,
            "the manifest genuinely did not change")

        restorePermissions()
        let retry = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                        documentStore: store)
        XCTAssertEqual(retry.remainingDocuments, 1)
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseline.appendingPathComponent("documents/install.txt").path))
    }

    func testAFileDeleteFailureLeavesTheTargetPendingAndARetryFinishesIt() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        makeReadOnly(baseline.appendingPathComponent("documents", isDirectory: true))

        do {
            _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
            XCTFail("expected cleanupFailed")
        } catch let error as VaultManualRemoval.RemovalError {
            guard case .cleanupFailed = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(VaultManualRemoval.pendingFiles(for: Self.vaultId), ["install.txt"])

        restorePermissions()
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseline.appendingPathComponent("documents/install.txt").path))
    }

    /// A removal that stops between the journal write and any durable change — the crash case —
    /// is finished by the launch-time recovery, not by the next person to ask a question.
    func testAnInterruptedRemovalIsFinishedByRecovery() async throws {
        let store = makeStore()
        _ = try await installTwoManuals(store: store)
        let entry = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" })
        try VaultRemovalJournal.record(
            .init(file: entry.file, title: entry.title, documentId: entry.documentId, startedAt: Date()),
            in: overlay)

        // Before recovery runs, the manual is already unavailable.
        XCTAssertTrue(VaultManualRemoval.isPending(file: "install.txt", vaultId: Self.vaultId))
        XCTAssertEqual(VaultManualRemoval.pendingDocumentIds(for: Self.vaultId), [entry.documentId])

        let recovered = await VaultManualRemoval.recoverPendingRemovals(documentStore: store)
        XCTAssertEqual(recovered.map(\.file), ["install.txt"])
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertEqual(VaultImporter.documentLedger(for: Self.vaultId).entries.map(\.file), ["service.txt"])
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)

        // Running it again finds nothing to do.
        let second = await VaultManualRemoval.recoverPendingRemovals(documentStore: store)
        XCTAssertTrue(second.isEmpty)
    }

    /// A re-index that runs while a removal is pending must finish the removal, not re-ingest the
    /// manual whose index rows the removal has already taken.
    func testASyncFinishesAPendingRemovalBeforeItDiffs() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        let entry = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" })
        // The state an interruption after step 1 leaves: rows gone, everything else still there.
        try store.forget(documentId: entry.documentId, inNamespace: namespace)
        try VaultRemovalJournal.record(
            .init(file: entry.file, title: entry.title, documentId: entry.documentId, startedAt: Date()),
            in: overlay)

        let ledger = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        XCTAssertEqual(ledger.entries.map(\.file), ["service.txt"])
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertFalse(isRetrievable("clearance", in: store))
        XCTAssertTrue(VaultManualRemoval.pendingFiles(for: Self.vaultId).isEmpty)
    }

    private func makeReadOnly(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        chmodRestore.append(url)
    }

    private func restorePermissions() {
        for url in chmodRestore {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        chmodRestore = []
    }

    // MARK: - Retrieval and sessions

    func testAPendingRemovalIsWithheldFromRetrievalBeforeAnythingIsDeleted() async throws {
        let store = makeStore()
        _ = try await installTwoManuals(store: store)
        let entry = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" })
        try VaultRemovalJournal.record(
            .init(file: entry.file, title: entry.title, documentId: entry.documentId, startedAt: Date()),
            in: overlay)

        let service = try startSession(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let outcome = service.manualRetriever(store: try XCTUnwrap(service.activeVault))
            .retrieve(.init(turn: "what is the installation clearance", limit: 4))
        XCTAssertFalse(outcome.passages.contains { $0.documentId == entry.documentId },
                       "a manual on its way out cannot be quoted")
        // The store still holds it — the withholding is the availability check, not a deletion.
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)
    }

    func testRetrievalDropsAManualDeletedWhileTheTurnWasInFlight() async throws {
        let store = makeStore()
        _ = try await installTwoManuals(store: store)
        let entry = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" })
        let service = try startSession(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let vaultStore = try XCTUnwrap(service.activeVault)
        // The retriever is built for the turn; the removal lands before it publishes.
        let retriever = service.manualRetriever(store: vaultStore)
        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: Self.vaultId,
                                                documentStore: store)
        let outcome = retriever.retrieve(.init(turn: "what is the installation clearance", limit: 4))
        XCTAssertFalse(outcome.passages.contains { $0.documentId == entry.documentId })
    }

    func testAPendingRemovalIsNotOpenableAsASourcePage() async throws {
        let store = makeStore()
        let documents = [
            VaultDocument(file: "install.pdf", title: "Install", kind: "install_guide"),
            VaultDocument(file: "service.txt", title: "Service"),
        ]
        let dir = writeVault(documents: documents, texts: ["service.txt": Self.serviceText],
                             originals: ["install.pdf": Self.installText])
        let manifest = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        let service = try startSession(store: store)
        let figure = FieldSessionService.StagedFigure(documentId: "x", documentTitle: "Install",
                                                      page: 1, figure: nil, sourceFile: "install.pdf")
        XCTAssertNotNil(service.sourcePDFURL(for: figure), "resolvable before the removal starts")

        try VaultRemovalJournal.record(.init(file: "install.pdf", title: "Install",
                                             documentId: nil, startedAt: Date()), in: overlay)
        XCTAssertNil(service.sourcePDFURL(for: figure))
        XCTAssertNil(service.manufacturerPDFURL(for: figure))
    }

    private func startSession(store: DocumentStore) throws -> FieldSessionService {
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions",
                                                                                        isDirectory: true))
        service.documentStore = store
        _ = try service.startSession(vaultId: Self.vaultId, assetId: nil)
        return service
    }

    // MARK: - Entitlement

    /// Product decision: installed content can always be removed. A team whose licence lapsed still
    /// has to be able to take a superseded manual out of a vault its technicians work from.
    func testRemovalIsAllowedWhenTheTeamEntitlementHasExpired() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        let granted = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        defer { FieldAssistEntitlement.shared.provider = granted }

        XCTAssertTrue(VaultManualRemoval.isPermittedByEntitlement)
        let result = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                         documentStore: store)
        XCTAssertEqual(result.remainingDocuments, 1)
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
    }

    /// Cleanup-only reconciliation is not ingest and does not need the ingest gate; a sync with
    /// something to ingest still does.
    func testCleanupOnlySyncRunsWithoutTheIngestEntitlement() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        XCTAssertEqual(store.documentCount(namespace: namespace), 2)

        // Re-import the same vault with no manuals at all.
        let emptied = writeVault(documents: [], texts: [:])
        let reduced = try VaultImporter.install(from: emptied)
        VaultRegistry.shared.reloadUserManifests()
        XCTAssertFalse(reduced.hasDocuments)
        XCTAssertTrue(VaultImporter.needsDocumentSync(manifest: reduced),
                      "a manifest with no manuals still has a ledger to reconcile")

        let granted = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        defer { FieldAssistEntitlement.shared.provider = granted }

        let ledger = try await VaultImporter.syncDocuments(manifest: reduced, into: store)
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(store.documentCount(namespace: namespace), 0, "old indexed passages are cleared")
        XCTAssertFalse(isRetrievable("clearance", in: store))
        XCTAssertFalse(isRetrievable("QQ7", in: store))

        // And with something to ingest, the gate still applies.
        let restored = try VaultImporter.install(from: writeVault(
            documents: Self.twoManuals,
            texts: ["install.txt": Self.installText, "service.txt": Self.serviceText]))
        VaultRegistry.shared.reloadUserManifests()
        do {
            _ = try await VaultImporter.syncDocuments(manifest: restored, into: store)
            XCTFail("expected notEntitled")
        } catch VaultImporter.ImportError.notEntitled {
            // expected
        }
        _ = manifest
    }

    func testNeedsDocumentSyncIsFalseOnlyWhenThereIsNothingToReconcile() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        XCTAssertTrue(VaultImporter.needsDocumentSync(manifest: manifest))

        _ = try await VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                documentStore: store)
        _ = try await VaultManualRemoval.remove(file: "service.txt", fromVault: manifest.id,
                                                documentStore: store)
        let emptied = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertFalse(VaultImporter.needsDocumentSync(manifest: emptied))
    }

    // MARK: - Serialisation

    /// Indexing yields between chunks, so "the button is disabled" is not a guarantee. A removal
    /// and a re-index started together must not interleave: whichever runs second sees the other's
    /// finished state, and the manual does not come back.
    func testARemovalAndAReindexStartedTogetherDoNotInterleave() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)

        async let removal = VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                      documentStore: store)
        async let reindex = VaultImporter.syncDocuments(manifest: manifest, into: store)
        _ = try await removal
        _ = try await reindex

        let installed = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertEqual(installed.documents.map(\.file), ["service.txt"])
        XCTAssertEqual(VaultImporter.documentLedger(for: Self.vaultId).entries.map(\.file), ["service.txt"])
        XCTAssertEqual(store.documentCount(namespace: namespace), 1)
        XCTAssertFalse(isRetrievable("clearance", in: store))
    }

    func testTwoRemovalsInTheSameVaultRunOneAfterTheOther() async throws {
        let store = makeStore()
        let manifest = try await installTwoManuals(store: store)
        async let first = VaultManualRemoval.remove(file: "install.txt", fromVault: manifest.id,
                                                    documentStore: store)
        async let second = VaultManualRemoval.remove(file: "service.txt", fromVault: manifest.id,
                                                     documentStore: store)
        let results = try await [first, second]
        XCTAssertEqual(Set(results.map(\.file)), ["install.txt", "service.txt"])
        XCTAssertEqual(store.documentCount(namespace: namespace), 0)
        let installed = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertTrue(installed.documents.isEmpty, "neither removal wrote the other's manifest back")
    }

    func testTheOperationLockReleasesAfterAThrow() async {
        XCTAssertFalse(VaultOperationLock.isBusy("lock_probe"))
        struct Boom: Error {}
        do {
            try await VaultOperationLock.withLock("lock_probe") { throw Boom() }
            XCTFail("expected the body's error")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(VaultOperationLock.isBusy("lock_probe"), "a throwing body still releases")
    }

    func testTheOperationLockSerialisesAndDoesNotBlockOtherVaults() async {
        let trace = VaultLockTrace()
        async let a: Void = VaultOperationLock.withLock("lock_a") {
            await trace.append("a-in")
            await Task.yield()
            await Task.yield()
            await trace.append("a-out")
        }
        async let b: Void = VaultOperationLock.withLock("lock_a") {
            await trace.append("b-in")
            await trace.append("b-out")
        }
        async let c: Void = VaultOperationLock.withLock("lock_b") {
            await trace.append("c")
        }
        _ = await (a, b, c)
        let order = await trace.order
        guard let aOut = order.firstIndex(of: "a-out"), let bIn = order.firstIndex(of: "b-in") else {
            return XCTFail("both holders should have run: \(order)")
        }
        XCTAssertLessThan(aOut, bIn, "the second holder waited for the first: \(order)")
        XCTAssertTrue(order.contains("c"), "a different vault is never blocked")
    }

    // MARK: - Reduced manifest

    func testTheReducedManifestKeepsEverythingButTheDocument() {
        let manifest = VaultManifest(id: "v", name: "V", version: "2.1.0",
                                     files: ["a.md", "b.md"], proceduresDir: "procedures",
                                     documentsDir: "documents",
                                     documents: [VaultDocument(file: "one.txt", title: "One"),
                                                 VaultDocument(file: "two.txt", title: "Two")],
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite."],
                                     sourceAttributionFormat: "Source: {files}",
                                     sourceAttributionRequired: true)
        let reduced = VaultManualRemoval.reducedManifest(manifest, removing: "one.txt")
        XCTAssertEqual(reduced.documents.map(\.file), ["two.txt"])
        XCTAssertEqual(reduced.id, manifest.id)
        XCTAssertEqual(reduced.version, manifest.version)
        XCTAssertEqual(reduced.files, manifest.files)
        XCTAssertEqual(reduced.proceduresDir, manifest.proceduresDir)
        XCTAssertEqual(reduced.documentsDir, manifest.documentsDir)
        XCTAssertEqual(reduced.gating, manifest.gating)
        XCTAssertEqual(reduced.promptRules, manifest.promptRules)
        XCTAssertEqual(reduced.sourceAttributionFormat, manifest.sourceAttributionFormat)
        XCTAssertEqual(reduced.sourceAttributionRequired, manifest.sourceAttributionRequired)
        XCTAssertEqual(VaultManualRemoval.reducedManifest(manifest, removing: "missing.txt").documents.count, 2)
    }

    func testTheJournalRoundTripsAndDoesNotAccumulateRetries() throws {
        let dir = tempRoot.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(VaultRemovalJournal.load(from: dir).pending.isEmpty)

        let entry = VaultRemovalJournal.Pending(file: "a.txt", title: "A", documentId: "doc-1",
                                                startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try VaultRemovalJournal.record(entry, in: dir)
        try VaultRemovalJournal.record(entry, in: dir)
        XCTAssertEqual(VaultRemovalJournal.load(from: dir).pending, [entry])

        let other = VaultRemovalJournal.Pending(file: "b.txt", title: "B", documentId: nil,
                                                startedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try VaultRemovalJournal.record(other, in: dir)
        XCTAssertEqual(VaultRemovalJournal.load(from: dir).pending.map(\.file), ["a.txt", "b.txt"])

        try VaultRemovalJournal.clear(file: "a.txt", in: dir)
        XCTAssertEqual(VaultRemovalJournal.load(from: dir).pending, [other])
        try VaultRemovalJournal.clear(file: "b.txt", in: dir)
        XCTAssertTrue(VaultRemovalJournal.load(from: dir).pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(VaultRemovalJournal.filename).path),
            "the last record takes the file with it")
    }
}

/// The checked, namespace-scoped delete removal depends on. Separated from the vault tests because
/// what is under test here is the store's own contract: propagate, scope, and verify.
@MainActor
final class DocumentStoreCheckedDeletionTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentStoreCheckedDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// The directory the store under test writes `documents.sqlite` into, kept so a test can open
    /// that file directly when it needs to damage it.
    private var directory: URL!

    private func makeStore() -> DocumentStore {
        directory = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DocumentStore(directory: directory)
    }

    /// Delete one document row and leave its chunks — through a second SQLite connection, because
    /// no supported call produces this state and it is the state the checked delete has to survive.
    private func deleteDocumentRowDirectly(id: String, in directory: URL) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(directory.appendingPathComponent("documents.sqlite").path, &db) == SQLITE_OK else {
            return XCTFail("could not open the store's database")
        }
        let sql = "DELETE FROM documents WHERE id = '\(id)'"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(db)))
    }

    private static let text = """
    A service manual paragraph about the prepurge period and the pressure switch that follows it,
    long enough to produce more than one chunk when the chunker splits it into overlapping sections.
    """

    func testCheckedForgetRemovesMetadataAndChunksAndReportsTheCount() async throws {
        let store = makeStore()
        let ingested = await store.ingest(name: "Manual", text: Self.text,
                                          namespace: DocumentStore.vaultNamespace("v"))
        let ref = try XCTUnwrap(ingested)
        XCTAssertGreaterThan(store.chunkCount(documentId: ref.id), 0)

        let removed = try store.forget(documentId: ref.id,
                                       inNamespace: DocumentStore.vaultNamespace("v"))
        XCTAssertEqual(removed, ref.chunkCount)
        XCTAssertEqual(store.chunkCount(documentId: ref.id), 0)
        XCTAssertTrue(store.list(namespace: DocumentStore.vaultNamespace("v")).isEmpty)
        XCTAssertNil(store.fullText(documentId: ref.id))
    }

    func testCheckedForgetRefusesToReachIntoAnotherNamespace() async throws {
        let store = makeStore()
        let ingested = await store.ingest(name: "Personal", text: Self.text, namespace: "global")
        let personal = try XCTUnwrap(ingested)
        XCTAssertThrowsError(try store.forget(documentId: personal.id,
                                              inNamespace: DocumentStore.vaultNamespace("v"))) { error in
            XCTAssertEqual(error as? DocumentStore.DeletionError,
                           .wrongNamespace(expected: "vault:v", actual: "global"))
        }
        XCTAssertEqual(store.documentCount(namespace: "global"), 1)
        XCTAssertGreaterThan(store.chunkCount(documentId: personal.id), 0)
    }

    func testCheckedForgetIsIdempotent() async throws {
        let store = makeStore()
        let ingested = await store.ingest(name: "Manual", text: Self.text,
                                          namespace: DocumentStore.vaultNamespace("v"))
        let ref = try XCTUnwrap(ingested)
        _ = try store.forget(documentId: ref.id, inNamespace: DocumentStore.vaultNamespace("v"))
        XCTAssertEqual(try store.forget(documentId: ref.id,
                                        inNamespace: DocumentStore.vaultNamespace("v")), 0)
        XCTAssertEqual(try store.forget(documentId: "never-existed",
                                        inNamespace: DocumentStore.vaultNamespace("v")), 0)
    }

    /// The failure the old untyped forget could leave behind: the document row gone and its chunks
    /// still in the table, still reachable by token search. A checked delete sweeps them.
    func testCheckedForgetSweepsChunksOrphanedByAHalfFinishedDelete() async throws {
        let store = makeStore()
        let namespace = DocumentStore.vaultNamespace("v")
        let ingested = await store.ingest(name: "Manual", text: Self.text, namespace: namespace)
        let ref = try XCTUnwrap(ingested)
        let other = await store.ingest(name: "Other", text: Self.text, namespace: namespace)
        let surviving = try XCTUnwrap(other)
        // The damaged state is made on the file itself, through a second connection, rather than
        // through an API that would never produce it: this is what a delete that half-succeeded
        // leaves, and there is no supported way to ask the store for it.
        deleteDocumentRowDirectly(id: ref.id, in: directory)
        XCTAssertGreaterThan(store.chunkCount(documentId: ref.id), 0, "the chunks outlived the row")

        let swept = try store.forget(documentId: ref.id, inNamespace: namespace)
        XCTAssertEqual(swept, ref.chunkCount)
        XCTAssertEqual(store.chunkCount(documentId: ref.id), 0)
        XCTAssertGreaterThan(store.chunkCount(documentId: surviving.id), 0, "and nothing else went")
    }

    func testDeletionErrorsDescribeThemselves() {
        XCTAssertNotNil(DocumentStore.DeletionError.sqlite(code: 5, extended: 261).errorDescription)
        XCTAssertNotNil(DocumentStore.DeletionError
            .wrongNamespace(expected: "vault:a", actual: "vault:b").errorDescription)
        XCTAssertNotNil(DocumentStore.DeletionError.rowsRemain(documents: 1, chunks: 3).errorDescription)
    }
}

/// Records the order two lock holders ran in, from whatever task each one is on.
private actor VaultLockTrace {
    private(set) var order: [String] = []
    func append(_ value: String) { order.append(value) }
}
