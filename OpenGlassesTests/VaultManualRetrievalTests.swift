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

    // MARK: - Lexical support

    func testContentTermsKeepWordsAndDropFurniture() {
        let terms = LexicalSupport.contentTerms("What is the manifold pressure on high fire?")
        XCTAssertEqual(terms, ["manifold", "pressure", "high", "fire"], "\(terms)")
        XCTAssertTrue(LexicalSupport.contentTerms("E223 on a 30RB unit").isDisjoint(with: ["e223", "30rb"]),
                      "code-like tokens are the tokenizer's job, not the lexical gate's")
        XCTAssertEqual(LexicalSupport.contentTerms("of by the and for is it"), [], "short function words never survive")
    }

    func testSuffixTrimmingMakesPluralsAndTensesAgree() {
        XCTAssertEqual(LexicalSupport.contentTerms("pressures"), LexicalSupport.contentTerms("pressure"))
        XCTAssertEqual(LexicalSupport.contentTerms("clocking"), LexicalSupport.contentTerms("clock"))
        XCTAssertEqual(LexicalSupport.contentTerms("inspected"), LexicalSupport.contentTerms("inspect"))
        XCTAssertEqual(LexicalSupport.contentTerms("switches"), LexicalSupport.contentTerms("switch"))
        XCTAssertEqual(LexicalSupport.contentTerms("bypass"), ["bypass"], "a trailing double-s is not a plural")
        // The rule is one pass of suffix trimming, not a stemmer: a silent-e verb does not agree
        // with its past tense. Pinned so the limitation is a decision rather than a surprise.
        XCTAssertNotEqual(LexicalSupport.contentTerms("primed"), LexicalSupport.contentTerms("prime"))
    }

    func testSharedTermCount() {
        let query = LexicalSupport.contentTerms("what is the manifold pressure on high fire")
        XCTAssertEqual(LexicalSupport.sharedTermCount(text: "Measure the manifold pressures at the tap.",
                                                      queryTerms: query), 2)
        XCTAssertEqual(LexicalSupport.sharedTermCount(text: "Torque the blower wheel set screw.",
                                                      queryTerms: query), 0)
        XCTAssertEqual(LexicalSupport.sharedTermCount(text: "anything", queryTerms: []), 0)
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

    func testATokenHitOutranksAnyUnmatchedPassageAndLeavesRoomForProse() {
        // The invariant, stated directly: on the word-average embedder every passage in a manual
        // scores about the same, so ranking by similarity buries the row that names the code.
        let retriever = VaultRetriever(query: { _, _ in [
            self.passage("d", 0, "General prose about heat calls and the LED menu.", sim: 0.99),
            self.passage("d", 1, "More prose about the LED menu and diagnostics.", sim: 0.95),
            self.passage("d", 2, "Third piece of prose about heating.", sim: 0.91)
        ] }, tokenSearch: { _, _ in [
            self.passage("d", 7, "E223 Low pressure switch failed open.", sim: 0, page: 20),
            self.passage("d", 8, "E223 appears again in the installation table.", sim: 0, page: 47, name: "Other")
        ] })
        let outcome = retriever.retrieve(.init(turn: "the display shows E223 on a heat call", limit: 3))
        let passages = outcome.passages
        XCTAssertEqual(passages.count, 3)
        XCTAssertEqual(passages[0].similarity, 0, "a token hit with similarity 0 outranks 0.99 without one")
        XCTAssertEqual(passages[0].chunkIndex, 7)
        XCTAssertEqual(passages[1].chunkIndex, 8)
        XCTAssertEqual(passages.prefix(2).map(\.matchedTokens), [["E223"], ["E223"]])
        // Fill, not replace: the slot the token hits leave goes to the best semantic passage.
        XCTAssertEqual(passages[2].chunkIndex, 0)
        XCTAssertEqual(passages[2].similarity, 0.99)
    }

    func testTokenHitsAreOrderedByScoreThenDeterministically() {
        let retriever = VaultRetriever(query: { _, _ in [] }, tokenSearch: { token, _ in
            token == "E5" ? [
                self.passage("d", 4, "E5 and ZX9 both appear here.", sim: 0),
                self.passage("d", 2, "E5 alone.", sim: 0, name: "Alpha"),
                self.passage("d", 3, "E5 alone as well.", sim: 0, name: "Alpha")
            ] : [self.passage("d", 4, "E5 and ZX9 both appear here.", sim: 0)]
        })
        let passages = retriever.retrieve(.init(turn: "E5 ZX9", limit: 4)).passages
        XCTAssertEqual(passages.map(\.chunkIndex), [4, 2, 3], "two matched codes beat one; then name, then index")
        XCTAssertEqual(passages[0].matchedTokens, ["E5", "ZX9"])
    }

    func testProcedureStepParticipatesOnlyWhenGiven() {
        var seenQueries: [String] = []
        let retriever = VaultRetriever(query: { q, _ in seenQueries.append(q); return [] })
        _ = retriever.retrieve(.init(turn: "hello"))
        XCTAssertEqual(seenQueries, ["hello"])
        _ = retriever.retrieve(.init(turn: "hello", procedureStep: "Step 2"))
        XCTAssertEqual(seenQueries, ["hello", "hello", "Step 2"])
    }

    // MARK: - Field report, build 497

    /// "How to test the flame sensor readings or signal": the device's sentence embedder ranked the
    /// flame-sensor section 159th, below diagnostic-code rows that merely mention a flame. The
    /// lexical route proposes it, and fusion puts the passage both lists like ahead of rows only
    /// the embedder likes.
    func testThePassageThatSharesTheQuestionsWordsIsFoundWhenTheEmbedderMissesIt() {
        let rows = (0..<6).map {
            self.passage("svc", 80 + $0, "E24\($0) Low flame current. Check the control and its wiring harness.",
                         sim: 0.51 - Float($0) * 0.01, page: 20, section: "Integrated Control Diagnostic Codes")
        }
        let flameSensor = passage("svc", 150, """
            2. Flame Sensor. To check flame sense signal use the push-button on the integrated control and go to \
            Field Test Mode. The menu will display the flame signal. A much higher than normal micro amp reading \
            may appear when checking the sensor.
            """, sim: 0.34, page: 34, section: "2. Flame Sensor", name: "Service Manual")
        var termQueries: [String] = []
        let withoutTerms = VaultRetriever(query: { _, _ in rows })
        let withTerms = VaultRetriever(query: { _, _ in rows }, termSearch: { query, _ in
            termQueries.append(query)
            return [flameSensor]
        })
        let turn = "And how to test the flame sensor readings or signal"

        XCTAssertFalse(withoutTerms.retrieve(.init(turn: turn)).passages.contains { $0.page == 34 },
                       "the embedder alone never reaches it — the field result")
        let found = withTerms.retrieve(.init(turn: turn)).passages
        XCTAssertEqual(termQueries, [turn])
        XCTAssertEqual(found.first?.chunkIndex, 150, "\(found.map(\.citation))")
        XCTAssertEqual(found.count, 4, "the rest of the slots still go to the embedder's best")

        // Without content terms — a bare code — there is nothing to search on and the order is
        // the score order, as before.
        termQueries = []
        _ = withTerms.retrieve(.init(turn: "E241"))
        XCTAssertTrue(termQueries.isEmpty)
    }

    func testFusionKeepsAnotherModelsRowBelowThisOnesWhateverItsWords() {
        let scope = VaultRetriever.ModelScope(activeTokens: ["090XV60C"], otherTokens: ["070XV36B"])
        let other = passage("d", 1, "070XV36B flame signal microamps flame sensor test reading", sim: 0.9)
        let mine = passage("d", 2, "090XV60C manifold pressure", sim: 0.5)
        let retriever = VaultRetriever(query: { _, _ in [other, mine] }, modelScope: scope)
        let ranked = retriever.retrieve(.init(turn: "flame sensor signal reading test")).passages
        XCTAssertEqual(ranked.map(\.chunkIndex), [2, 1])
    }

    /// "That's the universal manual for SLP 99 UH models": the vent tables print a 99 in a cell, and
    /// so do enough other pages that the token search's document order chose which came back.
    func testABareNumberPrintedOnPageAfterPageIsNotACode() {
        func table(_ i: Int) -> DocumentStore.Passage {
            passage("inst", i, "Vent length table 99 feet 2 inch 3 inch 46 99 81", sim: 0, page: 17 + i)
        }
        let prose = passage("svc", 50, "The parts list covers every SLP99UH model in the universal manual.", sim: 0.6)
        var limits: [String: Int] = [:]
        let retriever = VaultRetriever(query: { _, _ in [prose] }, tokenSearch: { token, limit in
            limits[token] = limit
            switch token {
            case "99": return (0..<20).map(table).prefix(limit).map { $0 }
            case "120": return [self.passage("inst", 44, "HUM 120 VAC OUTPUT", sim: 0, page: 44)]
            case "S47": return (0..<20).map { self.passage("svc", 100 + $0, "rollout switch S47", sim: 0) }.prefix(limit).map { $0 }
            default: return []
            }
        })

        let outcome = retriever.retrieve(.init(turn: "the universal manual for SLP 99 UH models", limit: 4))
        XCTAssertEqual(limits["99"], 9, "the search is asked for one more than it can use, to see the overflow")
        XCTAssertEqual(outcome.passages.first?.chunkIndex, 50, "\(outcome.passages.map(\.citation))")
        XCTAssertTrue(outcome.passages.allSatisfy { $0.matchedTokens.isEmpty })
        XCTAssertFalse(outcome.passages.contains { $0.documentId == "inst" })

        // A number that names a handful of passages still finds them, ahead of everything.
        let rare = retriever.retrieve(.init(turn: "what does the 120 VAC output feed", limit: 4))
        XCTAssertEqual(rare.passages.first?.matchedTokens, ["120"])
        // A code is a code however often it is printed: only bare numbers are judged this way.
        let code = retriever.retrieve(.init(turn: "where is S47", limit: 4))
        XCTAssertEqual(code.passages.first?.matchedTokens, ["S47"])
    }

    /// "Check page 34 of the service manual, item number two" searched 34 as a code.
    func testANamedPageIsNotSearchedAsACode() {
        var searched: [String] = []
        let retriever = VaultRetriever(query: { _, _ in [] }, tokenSearch: { token, _ in
            searched.append(token)
            return [self.passage("inst", 70, "Maximum vent length 34 feet", sim: 0, page: 18)]
        })
        let outcome = retriever.retrieve(.init(turn: "check page 34 of the service manual item number two"))
        XCTAssertTrue(searched.isEmpty, "\(searched)")
        XCTAssertFalse(outcome.passages.contains { $0.page == 18 })
        // The same number said as a value is still searched.
        _ = retriever.retrieve(.init(turn: "maximum vent length 34 feet"))
        XCTAssertEqual(searched, ["34"])
    }

    func testPageReferencesAreRecognisedAndOnlyTheirNumbersRemoved() {
        XCTAssertEqual(PageReference.pages(in: "Hey check page 34 of the service manual item number two"), [34])
        XCTAssertEqual(PageReference.pages(in: "pages 34 and 40"), [34, 40])
        XCTAssertEqual(PageReference.pages(in: "pages 34 to 36"), [34, 35, 36])
        XCTAssertEqual(PageReference.pages(in: "pages 3-60"), [3, 60], "a wide range names its ends")
        XCTAssertEqual(PageReference.pages(in: "see p. 12 and pg 14, page number 20"), [12, 14, 20])
        XCTAssertEqual(PageReference.pages(in: "Page 34, item two"), [34])
        // Not a page: a part number's tail, a quantity of pages, a code.
        XCTAssertEqual(PageReference.pages(in: "part 69W43 p 12"), [])
        XCTAssertEqual(PageReference.pages(in: "34 pages long"), [])
        XCTAssertEqual(PageReference.pages(in: "E223 on the display"), [])

        let removed = PageReference.removingReferences(from: "check page 34 of the service manual")
        XCTAssertEqual(CodeTokenizer.codeTokens(from: removed), [])
        XCTAssertTrue(removed.contains("page"), removed)
        XCTAssertEqual(PageReference.removingReferences(from: "code 108 on page 5 of 090XV60C"),
                       "code 108 on page   of 090XV60C")
    }

    /// A code-book vault (field report, build 497): "the cord type is <type>, the gauge is 14 …
    /// what's its rating by the book" boosted only the 14 — a gauge printed on page after page —
    /// and never searched the cord type. The rare designation carries the search; the common
    /// number does not. Every name, table and figure here is invented.
    func testARareCordTypeCarriesTheSearchAndACommonGaugeDoesNot() {
        let gaugeRows = (0..<40).map {
            self.passage("cec", $0, "Table \($0 + 1) conductor 14 AWG 12 AWG 10 AWG 15 20 30", sim: 0.2, page: 300 + $0)
        }
        let cordTypes = passage("cec", 900, "Table 99 Portable cords: type QXRT, light duty, gauges 14 and 16",
                                sim: 0.2, page: 610, name: "Code Book")
        let prose = passage("cec", 901, "Seasonal lighting strings and the rating of the cords that feed them.",
                            sim: 0.6, page: 120, name: "Code Book")
        var searched: [String] = []
        let retriever = VaultRetriever(query: { _, _ in [prose] }, tokenSearch: { token, limit in
            searched.append(token)
            switch token {
            case "14": return gaugeRows.prefix(limit).map { $0 }
            case "QXRT": return [cordTypes]
            default: return []
            }
        })
        let turn = "Check the cord the cord type is QXRT and the gauge is 14 I'm going to use it "
            + "for seasonal lights so what's its rating by the book"
        let outcome = retriever.retrieve(.init(turn: turn, limit: 4))
        XCTAssertEqual(Set(searched), ["14", "QXRT"])
        XCTAssertTrue(outcome.isSufficient)
        XCTAssertEqual(outcome.passages.first?.chunkIndex, 900, "\(outcome.passages.map(\.citation))")
        XCTAssertEqual(outcome.passages.first?.matchedTokens, ["QXRT"])
        XCTAssertFalse(outcome.passages.contains { $0.matchedTokens.contains("14") })
        XCTAssertFalse(outcome.passages.contains { (300..<340).contains($0.page ?? 0) })
    }

    func testCapitalisedDesignationsAreOnlyThoseWrittenAsSuch() {
        XCTAssertEqual(CodeTokenizer.capitalisedDesignations(from: "that type of cord is QXRT, OK, the gauge is 14"),
                       ["QXRT"], "two letters is a word like OK, not a designation")
        XCTAssertEqual(CodeTokenizer.capitalisedDesignations(from: "WHAT IS THE RATING OF QXRT"), [],
                       "a turn in capitals has nothing to tell apart")
        XCTAssertEqual(CodeTokenizer.capitalisedDesignations(from: "is QXRTW or QMX90 rated for it"), ["QXRTW"],
                       "a designation with a digit is already a code")
        // A word in capitals the manuals never print is not boosted. One they print everywhere is,
        // but the passages kept for it are those sharing the question's words, not the first in
        // page order.
        let pipes = (0..<30).map { self.passage("d", $0, "PVC pipe schedule 40", sim: 0) }
            + [passage("d", 30, "PVC condensate drain trap", sim: 0)]
        let retriever = VaultRetriever(query: { _, _ in [] }, tokenSearch: { token, limit in
            token == "PVC" ? pipes.prefix(limit).map { $0 } : []
        })
        let passages = retriever.retrieve(.init(turn: "run the PVC condensate drain to the ABS trap")).passages
        XCTAssertEqual(passages.first?.chunkIndex, 30, "\(passages.map(\.chunkIndex))")
        XCTAssertTrue(passages.allSatisfy { $0.matchedTokens == ["PVC"] }, "\(passages.map(\.matchedTokens))")
    }

    /// Five rephrased lookups in one turn, each refused with the same sentence: the miss says not
    /// to rephrase, and the second one in a turn says to stop.
    func testALookupMissSaysNotToRephraseAndTheSecondSaysStop() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        service.turnSourceID = "turn-1"
        let first = try await tool.execute(args: ["query": "rating of a seasonal lighting cord"])
        XCTAssertTrue(first.hasPrefix(RetrievalEvidencePolicy.insufficientSentence), first)
        XCTAssertTrue(first.contains("Do not run manual_lookup again with a rephrasing"), first)
        let second = try await tool.execute(args: ["query": "seasonal cord rating"])
        XCTAssertTrue(second.contains("That is 2 searches this turn that found nothing. Stop searching"), second)

        // A new turn starts counting again.
        service.turnSourceID = "turn-2"
        let fresh = try await tool.execute(args: ["query": "seasonal cord rating"])
        XCTAssertTrue(fresh.contains("Do not run manual_lookup again"), fresh)

        // A hit carries no such line.
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let hit = try await tool.execute(args: ["query": "ZX3 fan"])
        XCTAssertFalse(hit.contains("manual_lookup again"), hit)
    }

    // MARK: - Searching the book's way (Plan IV P5)

    /// A manual with its own back-of-book index: a lookup that misses offers what the index names
    /// for its words, and — on the first miss only — the nearest sections' headings.
    func testAMissInAManualWithAnIndexOffersItsReferencesAndThenTheNearestHeadings() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store, manualText: BackOfBookIndexTests.inventedBook())
        let manual = try XCTUnwrap(store.list(namespace: DocumentStore.vaultNamespace("manual_test")).first)
        XCTAssertNotNil(store.backOfBookIndex(documentId: manual.id), "read back from the stored chunks")
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        service.turnSourceID = "turn-1"
        let first = try await tool.execute(args: ["query": "where do the lantern hooks go"])
        XCTAssertTrue(first.hasPrefix(RetrievalEvidencePolicy.insufficientSentence), first)
        XCTAssertTrue(first.contains("The manual's own index lists these for those words: rule 41-300"), first)
        XCTAssertTrue(first.contains("The nearest sections in the manuals are headed: "), first)
        XCTAssertTrue(first.contains("Do not run manual_lookup again with a rephrasing"), "the retry is still one: \(first)")

        let second = try await tool.execute(args: ["query": "lantern hook placement"])
        XCTAssertFalse(second.contains("The nearest sections"), "no headings once the retry is spent: \(second)")
        XCTAssertTrue(second.contains("Stop searching"), second)
    }

    /// A manual without an index — the shape of the example vault's — gets no index line, and an
    /// answered lookup gets no headings.
    func testAManualWithoutAnIndexGetsNoIndexLine() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store)
        let manual = try XCTUnwrap(store.list(namespace: DocumentStore.vaultNamespace("manual_test")).first)
        XCTAssertNil(store.backOfBookIndex(documentId: manual.id))
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        service.turnSourceID = "turn-1"
        let miss = try await tool.execute(args: ["query": "fan relay"])
        XCTAssertFalse(miss.contains("own index"), miss)

        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        service.turnSourceID = "turn-2"
        let hit = try await tool.execute(args: ["query": "ZX3 fan"])
        XCTAssertFalse(hit.contains("own index"), hit)
        XCTAssertFalse(hit.contains("The nearest sections"), hit)
    }

    func testTheToolAsksForTheBooksWords() {
        let description = ManualLookupTool(documentStore: makeStore(), sessionService: FieldSessionService(
            sessionsRoot: tempRoot.appendingPathComponent("s-desc", isDirectory: true))).description
        XCTAssertTrue(description.contains("in the manual's own words"), description)
        XCTAssertTrue(description.contains("cite those lines"), "the existing guidance stays")
    }

    // MARK: - More passages where a passage is one clause (Plan IV P6)

    func testAClauseNumberedManualSendsSixPassagesToTheTurnAndTheLookup() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store, manualText: ManualPassageLimitTests.clauseNumberedBook())
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        let lookup = try await tool.execute(args: ["query": "which lid colour and tag for the panel"])
        XCTAssertTrue(lookup.contains("\n[6] "), lookup)
        XCTAssertFalse(lookup.contains("\n[7] "), lookup)
        let turn = try XCTUnwrap(service.promptContext(turn: "which lid colour and tag for the panel"))
        XCTAssertTrue(turn.contains("\n[6] "), turn)
        XCTAssertFalse(turn.contains("omitted by the context budget"), turn)
    }

    func testAProseManualStillSendsFour() async throws {
        let store = makeStore()
        let service = try await startSessionWithManual(store: store, manualText: ManualPassageLimitTests.proseManual())
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        let lookup = try await tool.execute(args: ["query": "blue dial green lamp fuse reading"])
        XCTAssertTrue(lookup.contains("\n[4] "), lookup)
        XCTAssertFalse(lookup.contains("\n[5] "), lookup)
        let turn = try XCTUnwrap(service.promptContext(turn: "blue dial green lamp fuse reading"))
        XCTAssertTrue(turn.contains("\n[4] "), turn)
        XCTAssertFalse(turn.contains("\n[5] "), turn)
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

    func testRelativeMarginTrimsTheTailButCannotRejectAQuery() {
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.30, margin: 0.02)
        func passage(_ index: Int, _ similarity: Float) -> VaultRetriever.Passage {
            VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: index, text: "x", page: nil,
                                   section: nil, similarity: similarity, score: similarity, matchedTokens: [])
        }
        let best = passage(0, 0.91), near = passage(1, 0.90), far = passage(2, 0.85)
        XCTAssertEqual(policy.decide([best, near, far], limit: 4), .sufficient([best, near]))
        // The best passage is always within `margin` of itself, so however tight the margin the
        // list still yields evidence. A margin is a precision filter, never a rejection.
        let tight = RetrievalEvidencePolicy(similarityFloor: 0.30, margin: 0)
        XCTAssertEqual(tight.decide([best, near, far], limit: 4), .sufficient([best]))
    }

    func testLexicalCriterionRejectsAPassageThatSharesNothingWithTheQuestion() {
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 2)
        func passage(_ index: Int, _ text: String) -> VaultRetriever.Passage {
            VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: index, text: text, page: nil,
                                   section: nil, similarity: 0.9, score: 0.9, matchedTokens: [])
        }
        let onTopic = passage(0, "Measure the manifold pressure at the tap on high fire.")
        let offTopic = passage(1, "Route the flue vent through the sidewall with a coupling.")
        let terms = LexicalSupport.contentTerms("what is the manifold pressure on high fire")
        XCTAssertEqual(policy.decide([offTopic, onTopic], limit: 4, queryTerms: terms), .sufficient([onTopic]))
        XCTAssertEqual(policy.decide([offTopic], limit: 4, queryTerms: terms),
                       .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))
        // A code hit is evidence whatever it shares: the tokenizer already proved the passage names
        // what was asked about.
        let tokenHit = VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: 2, text: "E5 row",
                                              page: nil, section: nil, similarity: 0, score: 0.25,
                                              matchedTokens: ["E5"])
        XCTAssertEqual(policy.decide([tokenHit], limit: 4, queryTerms: terms), .sufficient([tokenHit]))
        // Without query terms the criterion is simply off, so the old two-argument gate is intact.
        XCTAssertEqual(policy.decide([offTopic], limit: 4), .sufficient([offTopic]))
    }

    /// A flat shared-term count is unreachable for a question with fewer content terms than the
    /// count, so a short in-scope question is refused by construction. The fraction lowers the bar
    /// for short questions and never raises it for long ones.
    func testRequiredSharedTermsScalesDownForShortQuestionsOnly() {
        let flat = RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3)
        for count in 1...8 { XCTAssertEqual(flat.requiredSharedTerms(queryTermCount: count), 3) }

        let scaled = RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.75)
        XCTAssertEqual(scaled.requiredSharedTerms(queryTermCount: 1), 1)
        XCTAssertEqual(scaled.requiredSharedTerms(queryTermCount: 2), 2)   // ceil(1.5)
        XCTAssertEqual(scaled.requiredSharedTerms(queryTermCount: 3), 3)   // ceil(2.25)
        XCTAssertEqual(scaled.requiredSharedTerms(queryTermCount: 8), 3)   // never above the count
        // The fraction is inert while the lexical criterion itself is off.
        XCTAssertEqual(RetrievalEvidencePolicy(sharedFraction: 0.6).requiredSharedTerms(queryTermCount: 2), 0)
        // An empty question falls back to the flat count rather than to 1.
        XCTAssertEqual(scaled.requiredSharedTerms(queryTermCount: 0), 3)

        // End to end: a two-term question sharing both terms is evidence under the fraction and
        // refused under the flat count.
        let passage = VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: 0,
                                             text: "The pre-purge time is fifteen seconds before the ignitor warm up begins.",
                                             page: 3, section: nil, similarity: 0.9, score: 0.9, matchedTokens: [])
        let terms = LexicalSupport.contentTerms("pre-purge time")
        XCTAssertEqual(terms.count, 2, "\(terms.sorted())")
        XCTAssertFalse(flat.decide([passage], limit: 4, queryTerms: terms).isSufficient)
        XCTAssertTrue(scaled.decide([passage], limit: 4, queryTerms: terms).isSufficient)
    }

    func testPolicyDefaultsAreChosenPerEmbeddingBackend() {
        let word = RetrievalEvidencePolicy.default(for: "nl-word.en")
        XCTAssertEqual(word.minSharedTerms, 3, "the measured backend carries the lexical criterion")
        XCTAssertEqual(word.sharedFraction, 0.75, "and the measured scaling for short questions")
        XCTAssertEqual(word.similarityFloor, 0.30)
        XCTAssertNil(word.fullMatchFloor, "every passage clears 0.30 on the word model anyway")
        // The device's model was measured too, and gets the same rule (the criterion reads words,
        // not cosines, so it means the same on both), plus the measured full-match floor.
        var sentence = word
        sentence.fullMatchFloor = 0.10
        sentence.fullMatchMinTerms = 2
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: "nl-sentence.en"), sentence)
        // The contextual model, measured on both sets: the same three terms, scaled more gently.
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: "nl-contextual.multi_v1"),
                       RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.6))
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: "none.en"), RetrievalEvidencePolicy(),
                       "a model nobody measured keeps the floor rather than a guess")
    }

    /// The device's gate, before: a bare 0.30 floor over a model whose cosines sit between 0.2 and
    /// 0.6 for everything, so a question about a torque the manuals never print was answered from
    /// whatever came back. Here four passages score like that and share none of the question's
    /// words.
    func testTheSentenceModelsGateRefusesAQuestionThePassagesShareNoWordsWith() {
        let offTopic = [
            passage("d", 0, "The inducer pulls combustion air through the heat exchanger.", sim: 0.52),
            passage("d", 1, "Set the thermostat heat anticipator to the control's current.", sim: 0.49),
            passage("d", 2, "Check the condensate trap is primed before start-up.", sim: 0.47),
            passage("d", 3, "Gas valve outlet pressure is measured at the manifold tap.", sim: 0.44),
        ]
        let onTopic = passage("d", 4, "Flame signal in microamps: normal 2.6 or greater, low 2.5 or less.", sim: 0.34)
        func outcome(_ policy: RetrievalEvidencePolicy, _ turn: String) -> RetrievalOutcome {
            VaultRetriever(query: { _, _ in offTopic + [onTopic] }, policy: policy).retrieve(.init(turn: turn))
        }
        let device = RetrievalEvidencePolicy.default(for: "nl-sentence.en")
        let torque = "what is the torque for the blower wheel set screw"
        XCTAssertTrue(outcome(RetrievalEvidencePolicy(), torque).isSufficient, "the floor alone answered it")
        XCTAssertFalse(outcome(device, torque).isSufficient, "the device's gate now refuses it")

        // A short question the manual answers still gets its passage, and leads with it.
        let answered = outcome(device, "flame signal microamps")
        XCTAssertTrue(answered.isSufficient)
        XCTAssertEqual(answered.passages.first?.chunkIndex, 4)
    }

    /// On the sentence model a passage that prints every word of the question can score under
    /// the 0.30 floor while passages on another subject clear it with three of the four words
    /// (the example vault's "high fire manifold pressure"). The measured full-match floor lets the
    /// first through, for any question of two or more content terms.
    func testTheSentenceModelsGateTakesAPassageWithEveryWordOfTheQuestionBelowTheFloor() throws {
        let device = RetrievalEvidencePolicy.default(for: "nl-sentence.en")
        let floor = try XCTUnwrap(device.fullMatchFloor)
        XCTAssertLessThan(floor, device.similarityFloor)
        func passage(_ index: Int, _ text: String, _ similarity: Float) -> VaultRetriever.Passage {
            VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: index, text: text, page: nil,
                                   section: nil, similarity: similarity, score: similarity, matchedTokens: [])
        }
        let question = "high fire manifold pressure"
        let terms = LexicalSupport.contentTerms(question)
        XCTAssertEqual(terms.count, 4, "\(terms.sorted())")
        let every = "Set the manifold pressure on high fire at the outlet tap of the gas valve."
        let answering = passage(0, every, 0.22)
        let threeOfFour = passage(1, "High fire pressure switch: check the hose and the tap.", 0.22)
        let underBoth = passage(2, every, floor - 0.01)
        XCTAssertTrue(device.isEvidence(answering, queryTerms: terms))
        XCTAssertTrue(device.isEvidence(answering, question: LexicalSupport.QueryTerms(question)),
                      "the same under the passage's own rule")
        XCTAssertFalse(device.isEvidence(threeOfFour, queryTerms: terms), "below 0.30 it needs every word")
        XCTAssertFalse(device.isEvidence(underBoth, queryTerms: terms), "and the full-match floor still holds")
        XCTAssertEqual(device.decide([threeOfFour, answering], limit: 4, queryTerms: terms), .sufficient([answering]))

        // A short question counts too: "flame signal microamps" from a passage that prints all three.
        let short = LexicalSupport.contentTerms("flame signal microamps")
        XCTAssertGreaterThanOrEqual(short.count, device.fullMatchMinTerms, "\(short.sorted())")
        let flame = passage(3, "Read the flame signal in microamps at the control board.", 0.22)
        XCTAssertTrue(device.isEvidence(flame, queryTerms: short))
        // A one-term question is matched in full by any passage that prints the word: the floor
        // stays 0.30 for it.
        let one = LexicalSupport.contentTerms("manifold")
        XCTAssertLessThan(one.count, device.fullMatchMinTerms)
        XCTAssertFalse(device.isEvidence(passage(4, "Check the manifold.", 0.22), queryTerms: one))

        // The other backends are unchanged, and the rule never runs with the lexical criterion off.
        XCTAssertFalse(RetrievalEvidencePolicy.default(for: "nl-word.en").isEvidence(answering, queryTerms: terms))
        var wordsOff = device
        wordsOff.minSharedTerms = 0
        XCTAssertFalse(wordsOff.isEvidence(answering, queryTerms: terms))
    }

    func testRenderingStatesInsufficiencyExplicitly() {
        let block = VaultRetriever.promptBlock(.insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))
        XCTAssertTrue(block.hasPrefix("MANUAL PASSAGES: none retrieved"))
        XCTAssertTrue(block.contains("couldn't find it in the manuals"))
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

        await VaultImporter.uninstall(id: manifest.id, documentStore: store)
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

    /// Plan FS: an export leaves the manuals on the phone and says so, so this folder no longer
    /// validates on its own — the manual is still *required*, which is the whole point, and the
    /// validator names it instead of installing a vault that claims a manual it has not got.
    func testExportListsTheManualAsRequiredAndLeavesTheFileBehind() async throws {
        let manifest = try VaultImporter.install(from: writeVault())
        VaultRegistry.shared.reloadUserManifests()
        let exported = try VaultExporter.export(id: manifest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("documents/manual.txt").path))

        let decoded = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
        XCTAssertEqual(decoded.documents.map(\.file), ["manual.txt"])
        XCTAssertFalse(decoded.documentsIncluded)

        let reimported = VaultValidator.validate(directory: exported)
        XCTAssertFalse(reimported.isValid)
        XCTAssertTrue(reimported.issues.contains { $0.contains("not included in this export") }, "\(reimported.issues)")
    }

    // MARK: - Session prompt context

    private func startSessionWithManual(store: DocumentStore,
                                        manualText: String = manualText) async throws -> FieldSessionService {
        let manifest = try VaultImporter.install(from: writeVault(manualText: manualText))
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
        XCTAssertTrue(miss.hasPrefix(RetrievalEvidencePolicy.insufficientSentence), miss)

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

    func testCodeLikeLookupPrefersTheSectionTitledWithTheModel() async throws {
        // The model is named in the file's introduction before it gets its own section. In plain
        // file order the introduction (and any summary section) can push the model's own section
        // past the three-result cap.
        let core = """
        # Models

        This vault covers the RTU-500 rooftop unit and the accessories that fit it.

        ## Accessory kits

        The economizer kit fits the RTU-500 and the RTU-400.

        ## RTU-500

        Nominal cooling five tons. Factory charge R-410A. High-pressure switch opens at 610 psig.
        """
        let manifest = try VaultImporter.install(from: writeVault(coreText: core))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("lookup", isDirectory: true))
        _ = try service.startSession(vaultId: manifest.id, assetId: nil)

        let result = try await EquipmentLookupTool(sessionService: service).execute(args: ["query": "RTU-500"])
        let titled = try XCTUnwrap(result.range(of: "## RTU-500"))
        let intro = try XCTUnwrap(result.range(of: "This vault covers"))
        XCTAssertTrue(titled.lowerBound < intro.lowerBound,
                      "the model's own section should come first:\n\(result)")
        XCTAssertTrue(result.contains("Nominal cooling five tons"), result)
    }
}
