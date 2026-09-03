import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan ED — OEM manuals as a retrieved tier in Field Assist vaults.
///
/// Pure pieces (manifest, extractor, tokenizer, retriever, evidence policy, ledger, validator) are
/// exercised without a session; the wiring pieces use a temporary `DocumentStore` and a fresh
/// `FieldSessionService` with an injected entitlement, never the shared singletons' storage.
@MainActor
final class VaultManualRetrievalTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultManualRetrievalTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: "manual_test")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    /// A PDF whose pages carry the given strings; an empty string leaves that page blank.
    private func makePDF(pages: [String]) -> URL {
        let url = tempRoot.appendingPathComponent("fixture-\(UUID().uuidString.prefix(6)).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        let data = renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                guard !text.isEmpty else { continue }
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14)]
                NSAttributedString(string: text, attributes: attributes)
                    .draw(in: CGRect(x: 20, y: 20, width: 360, height: 560))
            }
        }
        try? data.write(to: url)
        return url
    }

    private static let manualText = """
    RTU-500 SERVICE MANUAL

    1 FAULT CODES
    Fault code ZX9 indicates a low refrigerant charge on the RTU-500. Check the liquid line sight glass and verify subcooling before adding charge.
    Fault code ZX3 indicates a condenser fan failure. Inspect the fan motor capacitor and the fan relay.

    2 PRESSURE SWITCH
    The high-pressure switch opens at 610 psig and resets automatically at 420 psig. Replace the switch if it does not reset.
    """

    /// Writes a custom vault with one markdown core file and one text manual under documents/.
    @discardableResult
    private func writeVault(id: String = "manual_test", manualText: String = manualText,
                            documents: [VaultDocument] = [VaultDocument(file: "manual.txt", title: "Test Manual", kind: "service_manual")],
                            coreText: String = "# Safety\n\nLock out power before opening any panel.",
                            documentsDir: String? = "documents") -> URL {
        let dir = tempRoot.appendingPathComponent("vault-\(id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: id, name: "Manual Test", version: "1.0.0",
                                     files: ["safety.md"], proceduresDir: nil,
                                     documentsDir: documentsDir, documents: documents,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? coreText.write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        let docsDir = documentsDir.map { dir.appendingPathComponent($0, isDirectory: true) } ?? dir
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        for document in documents where document.file.hasSuffix(".txt") {
            try? manualText.write(to: docsDir.appendingPathComponent(document.file), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func passage(_ id: String, _ index: Int, _ text: String, sim: Float, page: Int? = nil,
                         section: String? = nil, name: String = "Manual") -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: id, documentName: name, chunkIndex: index, text: text,
                              similarity: sim, page: page, section: section)
    }

    // MARK: - Manifest

    func testLegacyManifestDecodesWithoutDocuments() throws {
        let json = """
        {"id":"x","name":"X","version":"1.0.0","files":["a.md"],"gating":{"iap":null},"prompt_rules":["Never fabricate.","Cite."]}
        """
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.documents.isEmpty)
        XCTAssertFalse(manifest.hasDocuments)
        XCTAssertNil(manifest.documentsDir)
        XCTAssertTrue(manifest.sourceAttributionRequired, "missing key defaults to required")
    }

    func testManifestWithDocumentsRoundTrips() throws {
        let manifest = VaultManifest(id: "x", name: "X", version: "1.0.0", files: [], documentsDir: "documents",
                                     documents: [VaultDocument(file: "m.pdf", title: "M", kind: "service_manual")],
                                     promptRules: ["Never fabricate.", "Cite."])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(VaultManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.documentRelativePath(decoded.documents[0]), "documents/m.pdf")
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"documents_dir\""))
    }

    func testBuiltInManifestsStillResolve() {
        XCTAssertNotNil(VaultRegistry.shared.manifest(id: "refrigeration"))
        XCTAssertFalse(VaultRegistry.shared.manifest(id: "refrigeration")!.hasDocuments)
    }

    // MARK: - Extractor

    func testPDFExtractionKeepsPageBoundaries() throws {
        let url = makePDF(pages: ["Page one text about compressors.", "", "Page three text about fans."])
        let extracted = try VaultDocumentExtractor.extract(from: url)
        XCTAssertEqual(extracted.pageCount, 3)
        let separators = extracted.text.filter { $0 == "\u{0C}" }.count
        XCTAssertEqual(separators, 2, "two form feeds separate three pages, blank page included")

        // Small chunks so each page's sentence lands in its own chunk; a chunk cites the page its
        // first sentence starts on.
        let chunks = DocumentChunker(targetChars: 40, maxChars: 80, overlapChars: 0).chunk(extracted.text)
        XCTAssertTrue(chunks.contains { $0.page == 1 && $0.text.contains("compressors") }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.page == 3 && $0.text.contains("fans") }, "\(chunks)")
    }

    func testPDFWithoutTextLayerIsRefused() {
        let url = makePDF(pages: ["", ""])
        XCTAssertThrowsError(try VaultDocumentExtractor.extract(from: url)) { error in
            guard case VaultDocumentExtractor.ExtractionError.noTextLayer = error else {
                return XCTFail("expected noTextLayer, got \(error)")
            }
        }
    }

    func testUnsupportedAndEmptyFormatsAreRefused() throws {
        let png = tempRoot.appendingPathComponent("x.png")
        try Data([0]).write(to: png)
        XCTAssertThrowsError(try VaultDocumentExtractor.extract(from: png))

        let empty = tempRoot.appendingPathComponent("empty.txt")
        try "  \n".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try VaultDocumentExtractor.extract(from: empty)) { error in
            guard case VaultDocumentExtractor.ExtractionError.empty = error else { return XCTFail("\(error)") }
        }

        let md = tempRoot.appendingPathComponent("notes.md")
        try "# Notes\n\nSome text.".write(to: md, atomically: true, encoding: .utf8)
        let extracted = try VaultDocumentExtractor.extract(from: md)
        XCTAssertNil(extracted.pageCount)
        XCTAssertTrue(extracted.text.contains("Some text."))
    }

    // MARK: - Code tokenizer

    func testCandidateTokensMatchEquipmentLookupBehaviour() {
        let tokens = CodeTokenizer.candidateTokens(from: "Model 30RB-060 Carrier fault E5 E5 the compressor-unit")
        XCTAssertEqual(tokens, ["Model", "30RB", "060", "Carrier", "fault", "E5", "the", "unit"])
        XCTAssertEqual(EquipmentLookupTool().candidateTokens(from: "E5 30RB"), ["E5", "30RB"])
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "Model 30RB-060 Carrier fault E5"), ["30RB", "060", "E5"])
    }

    func testWholeTokenContainment() {
        XCTAssertTrue(CodeTokenizer.contains("code E5 means low pressure", token: "e5"))
        XCTAssertTrue(CodeTokenizer.contains("fault E5.", token: "E5"))
        XCTAssertFalse(CodeTokenizer.contains("code E50 means", token: "E5"))
        XCTAssertFalse(CodeTokenizer.contains("codeE5", token: "E5"))
        XCTAssertFalse(CodeTokenizer.contains("anything", token: ""))
    }

    // MARK: - Retriever and evidence policy

    func testTokenBoostOutranksHigherSimilarityWithoutTheToken() {
        let retriever = VaultRetriever(query: { _, _ in [
            self.passage("d", 0, "General advice about refrigerant charge.", sim: 0.6),
            self.passage("d", 1, "Fault code ZX9 indicates low charge.", sim: 0.45, page: 4, section: "1 FAULT CODES")
        ] })
        let outcome = retriever.retrieve(.init(turn: "what does ZX9 mean"))
        let passages = outcome.passages
        XCTAssertEqual(passages.first?.chunkIndex, 1)
        XCTAssertEqual(passages.first?.matchedTokens, ["ZX9"])
        XCTAssertEqual(passages.first?.citation, "Manual, page 4, §1 FAULT CODES")
        XCTAssertEqual(passages.count, 2)
    }

    func testMergeDeduplicatesAcrossQueryPartsKeepingBestScore() {
        var seenQueries: [String] = []
        let retriever = VaultRetriever(query: { q, _ in
            seenQueries.append(q)
            return [self.passage("d", 7, "Fault code ZX9 low charge.", sim: q.contains("ZX9") ? 0.5 : 0.2)]
        })
        let outcome = retriever.retrieve(.init(turn: "the unit is short cycling", ocrText: "RTU-500\nZX9", procedureStep: "Check charge"))
        XCTAssertEqual(seenQueries.count, 3)
        XCTAssertTrue(seenQueries.contains("RTU 500 ZX9"), "OCR part is queried as its tokens: \(seenQueries)")
        XCTAssertEqual(outcome.passages.count, 1)
        XCTAssertEqual(outcome.passages.first?.similarity, 0.5)
        XCTAssertEqual(outcome.passages.first?.matchedTokens, ["ZX9"])
    }

    func testKeywordSearchSuppliesPassagesTheEmbedderCannotReach() {
        // A bare code like "ZX9" has no embedding, so the semantic query returns nothing; the
        // exact-token search must still surface the passage, boosted, as sufficient evidence.
        var tokenQueries: [String] = []
        let retriever = VaultRetriever(
            query: { _, _ in [] },
            tokenSearch: { token, _ in
                tokenQueries.append(token)
                return [self.passage("d", 3, "Fault code ZX9 indicates low charge.", sim: 0, page: 2)]
            })
        let outcome = retriever.retrieve(.init(turn: "ZX9"))
        XCTAssertEqual(tokenQueries, ["ZX9"])
        XCTAssertTrue(outcome.isSufficient)
        XCTAssertEqual(outcome.passages.first?.matchedTokens, ["ZX9"])
        XCTAssertEqual(outcome.passages.first?.score, 0.25)
    }

    func testProcedureStepParticipatesOnlyWhenGiven() {
        var seenQueries: [String] = []
        let retriever = VaultRetriever(query: { q, _ in seenQueries.append(q); return [] })
        _ = retriever.retrieve(.init(turn: "hello"))
        XCTAssertEqual(seenQueries, ["hello"])
        _ = retriever.retrieve(.init(turn: "hello", procedureStep: "Step 2"))
        XCTAssertEqual(seenQueries, ["hello", "hello", "Step 2"])
    }

    func testEvidencePolicyTruthTable() {
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.3)
        let weak = VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: 0, text: "x", page: nil,
                                          section: nil, similarity: 0.1, score: 0.1, matchedTokens: [])
        let tokenHit = VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: 1, text: "E5", page: nil,
                                              section: nil, similarity: 0.1, score: 0.35, matchedTokens: ["E5"])
        let strong = VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: 2, text: "y", page: nil,
                                            section: nil, similarity: 0.5, score: 0.5, matchedTokens: [])

        XCTAssertEqual(policy.decide([], limit: 4), .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))
        XCTAssertEqual(policy.decide([weak], limit: 4), .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))
        XCTAssertEqual(policy.decide([tokenHit], limit: 4), .sufficient([tokenHit]))
        XCTAssertEqual(policy.decide([strong, weak, tokenHit], limit: 1), .sufficient([strong]), "weak passages are dropped, limit applies")
    }

    func testRenderingStatesInsufficiencyExplicitly() {
        let block = VaultRetriever.promptBlock(.insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))
        XCTAssertTrue(block.hasPrefix("MANUAL PASSAGES: none retrieved"))
        XCTAssertTrue(block.contains("do not cover this"))
        let tool = VaultRetriever.toolResult(.insufficient(reason: RetrievalEvidencePolicy.insufficientSentence), query: "ZX9")
        XCTAssertEqual(tool, RetrievalEvidencePolicy.insufficientSentence)
    }

    // MARK: - Ledger

    func testLedgerPlanCases() {
        let kept = VaultDocumentLedger.Entry(file: "a.pdf", title: "A", documentId: "ida", contentHash: "h1", chunkCount: 3)
        let changed = VaultDocumentLedger.Entry(file: "b.pdf", title: "B", documentId: "idb", contentHash: "h2", chunkCount: 3)
        let removed = VaultDocumentLedger.Entry(file: "c.pdf", title: "C", documentId: "idc", contentHash: "h3", chunkCount: 3)
        let ledger = VaultDocumentLedger(entries: [kept, changed, removed])
        let plan = VaultDocumentLedger.plan(current: ledger, desired: [
            .init(file: "a.pdf", title: "A", contentHash: "h1"),
            .init(file: "b.pdf", title: "B", contentHash: "h2-new"),
            .init(file: "d.pdf", title: "D", contentHash: "h4")
        ])
        XCTAssertEqual(plan.unchanged, [kept])
        XCTAssertEqual(plan.toForget, [changed, removed])
        XCTAssertEqual(plan.toIngest.map(\.file), ["b.pdf", "d.pdf"])
        XCTAssertFalse(plan.isNoop)

        let noop = VaultDocumentLedger.plan(current: VaultDocumentLedger(entries: [kept]),
                                            desired: [.init(file: "a.pdf", title: "A", contentHash: "h1")])
        XCTAssertTrue(noop.isNoop)
    }

    func testLedgerPersistsAndHashIsStable() throws {
        let dir = tempRoot.appendingPathComponent("ledger", isDirectory: true)
        var ledger = VaultDocumentLedger()
        ledger.entries = [.init(file: "a.pdf", title: "A", documentId: "ida", contentHash: "h", chunkCount: 1)]
        try ledger.save(to: dir)
        XCTAssertEqual(VaultDocumentLedger.load(from: dir), ledger)
        XCTAssertEqual(VaultDocumentLedger.load(from: tempRoot.appendingPathComponent("nowhere")), VaultDocumentLedger())
        XCTAssertEqual(VaultDocumentLedger.hash(of: Data("abc".utf8)), VaultDocumentLedger.hash(of: Data("abc".utf8)))
        XCTAssertNotEqual(VaultDocumentLedger.hash(of: Data("abc".utf8)), VaultDocumentLedger.hash(of: Data("abd".utf8)))
    }

    // MARK: - Validator

    func testValidatorAcceptsDocumentsAndWarnsOnCoreBudget() {
        let dir = writeVault(coreText: String(repeating: "Lock out power before opening any panel. ", count: 1_000))
        let result = VaultValidator.validate(directory: dir)
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("budget"))
    }

    func testValidatorRefusesMissingEmptyAndDuplicateDocuments() {
        let missing = writeVault(documents: [VaultDocument(file: "gone.pdf", title: "Gone")])
        XCTAssertTrue(VaultValidator.validate(directory: missing).issues.contains { $0.contains("listed document missing: documents/gone.pdf") })

        let empty = writeVault(manualText: " ", documents: [VaultDocument(file: "blank.txt", title: "Blank")])
        XCTAssertTrue(VaultValidator.validate(directory: empty).issues.contains { $0.contains("cannot be imported") })

        let duplicate = writeVault(documents: [VaultDocument(file: "manual.txt", title: "A"),
                                               VaultDocument(file: "manual.txt", title: "B")])
        XCTAssertTrue(VaultValidator.validate(directory: duplicate).issues.contains { $0.contains("listed twice") })

        let untitled = writeVault(documents: [VaultDocument(file: "manual.txt", title: " ")])
        XCTAssertTrue(VaultValidator.validate(directory: untitled).issues.contains { $0.contains("no title") })
    }

    func testValidatorAllowsDocumentsOnlyVault() {
        let dir = writeVault()
        // Rewrite the manifest with no core files.
        let manifest = VaultManifest(id: "manual_test", name: "Manual Test", version: "1.0.0", files: [],
                                     documentsDir: "documents",
                                     documents: [VaultDocument(file: "manual.txt", title: "Test Manual")],
                                     gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let result = VaultValidator.validate(directory: dir)
        XCTAssertTrue(result.isValid, "\(result.issues)")
    }

    // MARK: - Document store namespaces

    func testNamespaceScopedClearLeavesVaultDocumentsIntact() async {
        let store = makeStore()
        _ = await store.ingest(name: "Personal", text: "A personal note about groceries and errands.", namespace: "global")
        _ = await store.ingest(name: "Manual", text: Self.manualText, namespace: DocumentStore.vaultNamespace("v"))
        XCTAssertEqual(store.list().count, 2)
        store.clear(namespace: "global")
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace("v")), 1)
        XCTAssertTrue(DocumentStore.isVaultNamespace("vault:v"))
        XCTAssertFalse(DocumentStore.isVaultNamespace("global"))
    }

    // MARK: - Importer sync

    func testSyncIngestsReimportIsNoopChangeReplacesAndUninstallForgets() async throws {
        let store = makeStore()
        let dir = writeVault()
        let manifest = try VaultImporter.install(from: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VaultImporter.baselineDirectory(for: manifest.id)
            .appendingPathComponent("documents/manual.txt").path), "documents are copied into the baseline")

        let first = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.entries[0].title, "Test Manual")
        XCTAssertGreaterThan(first.entries[0].chunkCount, 0)
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(manifest.id)), 1)

        let second = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        XCTAssertEqual(second, first, "unchanged content is a no-op")
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(manifest.id)), 1)

        // Change the manual and re-push the baseline.
        try (Self.manualText + "\n\n3 ADDENDUM\nFault code ZX1 indicates a sensor fault.")
            .write(to: dir.appendingPathComponent("documents/manual.txt"), atomically: true, encoding: .utf8)
        _ = try VaultImporter.install(from: dir)
        let third = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        XCTAssertEqual(third.entries.count, 1)
        XCTAssertNotEqual(third.entries[0].documentId, first.entries[0].documentId)
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(manifest.id)), 1, "old document forgotten")
        XCTAssertEqual(VaultImporter.documentLedger(for: manifest.id), third)

        VaultImporter.uninstall(id: manifest.id, documentStore: store)
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(manifest.id)), 0)
    }

    func testSyncRequiresEntitlement() async throws {
        let store = makeStore()
        let manifest = try VaultImporter.install(from: writeVault())
        let granted = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        defer { FieldAssistEntitlement.shared.provider = granted }
        do {
            _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
            XCTFail("expected notEntitled")
        } catch VaultImporter.ImportError.notEntitled {
            // expected
        }
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(manifest.id)), 0)
    }

    func testExportIncludesDocuments() async throws {
        let manifest = try VaultImporter.install(from: writeVault())
        VaultRegistry.shared.reloadUserManifests()
        let exported = try VaultExporter.export(id: manifest.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("documents/manual.txt").path))
        let reimported = VaultValidator.validate(directory: exported)
        XCTAssertTrue(reimported.isValid, "\(reimported.issues)")
    }

    // MARK: - Session prompt context

    private func startSessionWithManual(store: DocumentStore) async throws -> FieldSessionService {
        let manifest = try VaultImporter.install(from: writeVault())
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        let sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let service = FieldSessionService(sessionsRoot: sessionsRoot)
        service.documentStore = store
        _ = try service.startSession(vaultId: manifest.id, assetId: nil)
        return service
    }

    func testPromptContextCarriesManualPassagesWithCitations() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)

        let context = try XCTUnwrap(service.promptContext(turn: "the display shows fault ZX9"))
        XCTAssertTrue(context.contains("KNOWLEDGE VAULT"), "core tier still present")
        XCTAssertTrue(context.contains("MANUAL PASSAGES (retrieved"), context)
        XCTAssertTrue(context.contains("Source: Test Manual"), context)
        XCTAssertTrue(context.contains("ZX9"), context)

        XCTAssertFalse(service.promptContext()?.contains("MANUAL PASSAGES") ?? true, "no turn → no manual block")
        XCTAssertTrue(service.activeVaultHasManuals)
    }

    func testPromptContextStatesInsufficiencyWhenNothingClearsTheGate() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)

        let context = try XCTUnwrap(service.promptContext(turn: "tell me about the weather on Mars"))
        XCTAssertTrue(context.contains("MANUAL PASSAGES: none retrieved"), context)
        XCTAssertTrue(context.contains(RetrievalEvidencePolicy.insufficientSentence), context)
    }

    func testPromptContextOmitsManualBlockWithoutStoreOrDocuments() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        service.documentStore = nil
        XCTAssertFalse(service.promptContext(turn: "ZX9")?.contains("MANUAL PASSAGES") ?? true)
        XCTAssertFalse(service.activeVaultHasManuals)
    }

    // MARK: - Tools

    func testEquipmentLookupFallsThroughToManuals() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let tool = EquipmentLookupTool(documentStore: store, sessionService: service)

        let hit = try await tool.execute(args: ["query": "ZX9"])
        XCTAssertTrue(hit.contains("Source: Test Manual"), hit)
        XCTAssertTrue(hit.contains("low refrigerant charge"), hit)

        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let miss = try await tool.execute(args: ["query": "QQ77"])
        XCTAssertTrue(miss.contains("No vault entry found for 'QQ77'"), miss)
    }

    func testManualLookupToolSearchesAndReportsInsufficiency() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        let hit = try await tool.execute(args: ["query": "ZX3 fan"])
        XCTAssertTrue(hit.contains("Manual passages for 'ZX3 fan'"), hit)
        XCTAssertTrue(hit.contains("Source: Test Manual"), hit)

        let filtered = try await tool.execute(args: ["query": "ZX3", "document": "nonexistent"])
        XCTAssertTrue(filtered.contains("No manual titled like 'nonexistent'"), filtered)

        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let miss = try await tool.execute(args: ["query": "weather on Mars"])
        XCTAssertEqual(miss, RetrievalEvidencePolicy.insufficientSentence)

        let noQuery = try await tool.execute(args: [:])
        XCTAssertTrue(noQuery.contains("Specify what to look up"), noQuery)
    }

    func testManualLookupToolWithoutSessionOrDocuments() async throws {
        let store = makeStore()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("s2", isDirectory: true))
        let tool = ManualLookupTool(documentStore: store, sessionService: service)
        let none = try await tool.execute(args: ["query": "ZX9"])
        XCTAssertTrue(none.contains("No active Field Assist session"), none)

        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let noDocs = try await tool.execute(args: ["query": "ZX9"])
        XCTAssertTrue(noDocs.contains("has no manuals"), noDocs)
    }
}
