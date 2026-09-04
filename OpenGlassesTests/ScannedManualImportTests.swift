import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan EF — scanned manuals in a vault's documents tier.
///
/// The recogniser is behind `ScannedPageReader`; these tests drive a table-driven fake through
/// the per-page policy, assembly, confidence counting, checkpoint/resume, validator warning,
/// ledger fields, and the provenance line, without a Vision run deciding the verdict.
@MainActor
final class ScannedManualImportTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannedManualImportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: "scan_test")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A page spec: `.text` draws selectable text, `.image` draws the same words as a bitmap (no
    /// text layer), `.blank` draws nothing.
    enum PageSpec { case text(String), image(String), blank }

    private func makePDF(_ pages: [PageSpec], name: String = "fixture") -> URL {
        let url = tempRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).pdf")
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for spec in pages {
                context.beginPage()
                switch spec {
                case .blank: break
                case .text(let s):
                    NSAttributedString(string: s, attributes: [.font: UIFont.systemFont(ofSize: 14)])
                        .draw(in: bounds.insetBy(dx: 20, dy: 20))
                case .image(let s):
                    // Rasterise the words first, then draw the bitmap: no text layer on this page.
                    let imageRenderer = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 120))
                    let image = imageRenderer.image { _ in
                        UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 360, height: 120))
                        NSAttributedString(string: s, attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
                            .draw(in: CGRect(x: 10, y: 10, width: 340, height: 100))
                    }
                    image.draw(in: CGRect(x: 20, y: 20, width: 360, height: 120))
                }
            }
        }
        try? data.write(to: url)
        return url
    }

    /// Answers each recognise call from a queue; records how many pages it was asked to read.
    final class FakeReader: ScannedPageReader, @unchecked Sendable {
        var answers: [ScannedPageText]
        var calls = 0
        var failAfter: Int?
        init(answers: [ScannedPageText], failAfter: Int? = nil) { self.answers = answers; self.failAfter = failAfter }
        func recognise(_ image: CGImage) async -> ScannedPageText {
            calls += 1
            if let failAfter, calls > failAfter { return .empty }
            return answers.isEmpty ? .empty : answers.removeFirst()
        }
    }

    private func checkpointStore(_ dir: URL, hash: String) -> (load: () -> OCRCheckpoint, save: (OCRCheckpoint) throws -> Void) {
        (load: { OCRCheckpoint.load(from: dir, contentHash: hash) }, save: { try $0.save(to: dir) })
    }

    // MARK: - Per-page policy

    func testMixedPDFSendsOnlyTextlessPagesToTheReader() async throws {
        let url = makePDF([.text("Page one about compressors."), .image("ZX9 low charge"), .text("Page three about fans.")])
        XCTAssertEqual(VaultDocumentExtractor.survey(url), .init(pageCount: 3, pagesWithText: 2))

        let reader = FakeReader(answers: [ScannedPageText(text: "Fault code ZX9 indicates low charge.", confidence: 0.9)])
        let extracted = try await VaultDocumentExtractor.extract(from: url, reader: reader, thermal: .nominal)
        XCTAssertEqual(reader.calls, 1, "only the page without a text layer is recognised")
        XCTAssertEqual(extracted.pageCount, 3)
        XCTAssertEqual(extracted.ocrPages, 1)
        XCTAssertEqual(extracted.lowConfidencePages, 0)
        XCTAssertEqual(extracted.text.filter { $0 == "\u{0C}" }.count, 2)

        let chunks = DocumentChunker(targetChars: 40, maxChars: 80, overlapChars: 0).chunk(extracted.text)
        XCTAssertTrue(chunks.contains { $0.page == 2 && $0.text.contains("ZX9") }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.page == 3 && $0.text.contains("fans") }, "\(chunks)")
    }

    func testAllScanPDFRecognisesEveryPageAndCountsLowConfidence() async throws {
        let url = makePDF([.image("A"), .image("B"), .image("C")])
        let reader = FakeReader(answers: [
            .init(text: "Alpha", confidence: 0.95), .init(text: "Bravo", confidence: 0.2), .init(text: "Charlie", confidence: 0.7)
        ])
        let extracted = try await VaultDocumentExtractor.extract(from: url, reader: reader, thermal: .nominal)
        XCTAssertEqual(reader.calls, 3)
        XCTAssertEqual(extracted.ocrPages, 3)
        XCTAssertEqual(extracted.lowConfidencePages, 1)
        XCTAssertTrue(extracted.usedRecognition)
        XCTAssertEqual(extracted.text, "Alpha\u{0C}Bravo\u{0C}Charlie")
    }

    func testReaderFailureLeavesAnEmptyPageNotAnAbort() async throws {
        let url = makePDF([.image("A"), .image("B")])
        let reader = FakeReader(answers: [.init(text: "Alpha", confidence: 0.9)], failAfter: 1)
        let extracted = try await VaultDocumentExtractor.extract(from: url, reader: reader, thermal: .nominal)
        XCTAssertEqual(extracted.text, "Alpha\u{0C}")
        XCTAssertEqual(extracted.lowConfidencePages, 1, "an empty page counts as low confidence")
    }

    func testNoReaderKeepsTheOldRefusal() async throws {
        let url = makePDF([.image("A")])
        do {
            _ = try await VaultDocumentExtractor.extract(from: url, reader: nil)
            XCTFail("expected noTextLayer")
        } catch VaultDocumentExtractor.ExtractionError.noTextLayer {
            // expected
        }
        XCTAssertThrowsError(try VaultDocumentExtractor.extract(from: url))
    }

    // MARK: - Checkpoint and resume

    func testInterruptedRecognitionResumesFromTheCheckpoint() async throws {
        let url = makePDF([.image("A"), .image("B"), .image("C")])
        let dir = tempRoot.appendingPathComponent("ledger", isDirectory: true)
        let hash = "abc123"

        // First run: the reader dies after two pages (returns empty for the third).
        let first = FakeReader(answers: [.init(text: "Alpha", confidence: 0.9), .init(text: "Bravo", confidence: 0.9)], failAfter: 2)
        _ = try await VaultDocumentExtractor.extract(from: url, reader: first, thermal: .nominal,
                                                     checkpoint: checkpointStore(dir, hash: hash))
        let saved = OCRCheckpoint.load(from: dir, contentHash: hash)
        XCTAssertEqual(saved.pages.count, 3, "every attempted page is checkpointed, including the failed one")

        // Simulate the interruption having happened before page 3 was attempted.
        var partial = saved
        partial.pages[2] = nil
        try partial.save(to: dir)

        // Second run only recognises page 3 and produces the full text.
        let second = FakeReader(answers: [.init(text: "Charlie", confidence: 0.9)])
        let extracted = try await VaultDocumentExtractor.extract(from: url, reader: second, thermal: .nominal,
                                                                 checkpoint: checkpointStore(dir, hash: hash))
        XCTAssertEqual(second.calls, 1)
        XCTAssertEqual(extracted.text, "Alpha\u{0C}Bravo\u{0C}Charlie")

        // A checkpoint for a different hash is never reused.
        XCTAssertEqual(OCRCheckpoint.load(from: dir, contentHash: "other").pages.count, 0)
    }

    // MARK: - Render policy

    func testRenderPolicyStepsDownUnderThermalPressure() {
        let policy = ScanRenderPolicy()
        XCTAssertEqual(policy.dpi(for: .nominal), 200)
        XCTAssertEqual(policy.dpi(for: .fair), 200)
        XCTAssertEqual(policy.dpi(for: .serious), 150)
        XCTAssertEqual(policy.dpi(for: .critical), 150)
        XCTAssertTrue(policy.isLowConfidence(.init(text: "x", confidence: 0.49)))
        XCTAssertFalse(policy.isLowConfidence(.init(text: "x", confidence: 0.5)))
    }

    func testRasterizerSizesToDPIAndCaps() throws {
        let url = makePDF([.text("hello")])
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let image = try XCTUnwrap(PDFPageRasterizer.image(for: page, dpi: 72))
        XCTAssertEqual(image.width, 400, accuracy: 2)
        let capped = try XCTUnwrap(PDFPageRasterizer.image(for: page, dpi: 2_000, maxPixels: 1_000))
        XCTAssertLessThanOrEqual(max(capped.width, capped.height), 1_002)
    }

    // MARK: - Validator

    func testValidatorWarnsAboutScansInsteadOfRefusing() throws {
        let dir = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let scan = makePDF([.image("A"), .image("B")])
        let mixed = makePDF([.text("typeset"), .image("scan")])
        try FileManager.default.copyItem(at: scan, to: docs.appendingPathComponent("scan.pdf"))
        try FileManager.default.copyItem(at: mixed, to: docs.appendingPathComponent("mixed.pdf"))
        try "# Safety\n\nLock out power.".write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        let manifest = VaultManifest(id: "scan_test", name: "Scan Test", version: "1.0.0", files: ["safety.md"],
                                     documentsDir: "documents",
                                     documents: [VaultDocument(file: "scan.pdf", title: "Scan"), VaultDocument(file: "mixed.pdf", title: "Mixed")],
                                     gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))

        let result = VaultValidator.validate(directory: dir)
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertEqual(result.warnings.count, 2, "\(result.warnings)")
        XCTAssertTrue(result.warnings.contains { $0.contains("scan.pdf has no text layer on 2 of 2 pages") })
        XCTAssertTrue(result.warnings.contains { $0.contains("mixed.pdf has no text layer on 1 of 2 pages") })
    }

    // MARK: - Importer end to end

    func testSyncRecognisesRecordsProvenanceAndCleansUpTheCheckpoint() async throws {
        let dir = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: makePDF([.image("A"), .image("B")]), to: docs.appendingPathComponent("scan.pdf"))
        try "# Safety\n\nLock out power.".write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        let manifest = VaultManifest(id: "scan_test", name: "Scan Test", version: "1.0.0", files: ["safety.md"],
                                     documentsDir: "documents", documents: [VaultDocument(file: "scan.pdf", title: "Scanned Manual")],
                                     gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        _ = try VaultImporter.install(from: dir)

        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let reader = FakeReader(answers: [
            .init(text: "Fault code ZX9 indicates low charge on the RTU-500.", confidence: 0.9),
            .init(text: "Fault code ZX3 indicates a condenser fan failure.", confidence: 0.3)
        ])
        var recognitionUpdates: [(Int, Int)] = []
        let ledger = try await VaultImporter.syncDocuments(manifest: manifest, into: store, scanReader: reader,
                                                           recognitionProgress: { _, done, total in recognitionUpdates.append((done, total)) })
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].ocrPages, 2)
        XCTAssertEqual(ledger.entries[0].lowConfidencePages, 1)
        XCTAssertTrue(ledger.entries[0].usedRecognition)
        XCTAssertEqual(recognitionUpdates.map(\.0), [1, 2])
        XCTAssertEqual(VaultManagerView.entrySummary(ledger.entries[0]).contains("2 pages read by recognition · 1 low confidence"), true)

        let namespace = DocumentStore.vaultNamespace("scan_test")
        XCTAssertEqual(store.list(namespace: namespace).first?.sourceType, VaultImporter.recognisedSourceType)
        XCTAssertFalse(FileManager.default.fileExists(atPath: OCRCheckpoint.url(in: VaultImporter.overlayDirectory(for: "scan_test"),
                                                                                  contentHash: ledger.entries[0].contentHash).path),
                       "checkpoint removed once the document is ingested")

        // Retrieval marks the provenance of a recognised passage.
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        _ = try service.startSession(vaultId: "scan_test", assetId: nil)
        let context = try XCTUnwrap(service.promptContext(turn: "what is ZX9"))
        XCTAssertTrue(context.contains(VaultRetriever.Passage.provenanceNote), context)

        // A text-layer document in the same vault carries no note.
        let plainDocs = try await VaultImporter.syncDocuments(manifest: manifest, into: store, scanReader: reader)
        XCTAssertEqual(plainDocs, ledger, "unchanged content is a no-op even with a reader present")
    }

    /// The Mac-side extractor (`Scripts/extract-manual-text.swift`) writes Markdown with a
    /// "Page N" line before each page; the chunker must read those as page boundaries so a
    /// pre-extracted manual cites pages exactly like a PDF would.
    func testPreExtractedMarkdownKeepsPageCitations() throws {
        let md = tempRoot.appendingPathComponent("pre.md")
        try """
        # RTU-500 Service Manual

        Page 1

        Fault code ZX9 indicates a low refrigerant charge.

        Page 2

        The high-pressure switch opens at 610 psig.
        """.write(to: md, atomically: true, encoding: .utf8)
        let extracted = try VaultDocumentExtractor.extract(from: md)
        XCTAssertNil(extracted.pageCount)
        let chunks = DocumentChunker(targetChars: 40, maxChars: 80, overlapChars: 0).chunk(extracted.text)
        XCTAssertTrue(chunks.contains { $0.page == 1 && $0.text.contains("ZX9") }, "\(chunks)")
        XCTAssertTrue(chunks.contains { $0.page == 2 && $0.text.contains("610 psig") }, "\(chunks)")
    }

    func testProvenanceLineOnlyOnRecognisedPassages() {
        let retriever = VaultRetriever(
            query: { _, _ in [
                DocumentStore.Passage(documentId: "scan", documentName: "Scan", chunkIndex: 0, text: "ZX9 low charge", similarity: 0.5, page: 1, section: nil),
                DocumentStore.Passage(documentId: "typed", documentName: "Typed", chunkIndex: 0, text: "ZX9 low charge", similarity: 0.5, page: 1, section: nil)
            ] },
            provenance: { $0 == "scan" })
        let block = VaultRetriever.promptBlock(retriever.retrieve(.init(turn: "ZX9")))
        XCTAssertEqual(block.components(separatedBy: VaultRetriever.Passage.provenanceNote).count - 1, 1, block)
        XCTAssertTrue(block.contains("Source: Scan, page 1 \(VaultRetriever.Passage.provenanceNote)"), block)
    }
}
