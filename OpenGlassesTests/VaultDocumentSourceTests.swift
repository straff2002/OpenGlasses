import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan EK P3 — a document may bundle the manufacturer's original beside the text taken out of it.
///
/// The manifest field, what the validator refuses, what the importer copies and hashes, and what
/// the exporter carries back out. The original is never indexed: the text stays what is searched,
/// so an author's corrections to it still count.
@MainActor
final class VaultDocumentSourceTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "document_source_test"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultDocumentSourceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - The manifest field

    func testAManifestWithoutTheNewFieldsStillDecodes() throws {
        let json = """
        {
          "id": "old_vault", "name": "Old", "version": "1.0.0",
          "files": ["safety.md"],
          "documents_dir": "documents",
          "documents": [{ "file": "manual.md", "title": "Old Manual", "kind": "service_manual" }],
          "prompt_rules": ["Never fabricate.", "Cite the source."]
        }
        """
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: Data(json.utf8))
        let document = try XCTUnwrap(manifest.documents.first)
        XCTAssertNil(document.source)
        XCTAssertNil(document.sourceUrl)
        XCTAssertNil(manifest.documentSourceRelativePath(document))
        XCTAssertEqual(manifest.documentRelativePath(document), "documents/manual.md")
    }

    func testAManifestThatNamesTheOriginalDecodesAndReEncodes() throws {
        let json = """
        {
          "id": "new_vault", "name": "New", "version": "1.0.0",
          "files": ["safety.md"],
          "documents_dir": "documents",
          "documents": [{
            "file": "manual.md", "title": "New Manual", "kind": "service_manual",
            "source": "manual.pdf", "source_url": "https://example.com/manual.pdf"
          }],
          "prompt_rules": ["Never fabricate.", "Cite the source."]
        }
        """
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: Data(json.utf8))
        let document = try XCTUnwrap(manifest.documents.first)
        XCTAssertEqual(document.source, "manual.pdf")
        XCTAssertEqual(document.sourceUrl, "https://example.com/manual.pdf")
        XCTAssertFalse(document.isPDF, "the indexed document is the text; the PDF is beside it")
        XCTAssertEqual(manifest.documentSourceRelativePath(document), "documents/manual.pdf")

        let round = try JSONDecoder().decode(VaultManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(round, manifest)
        XCTAssertTrue(String(data: try JSONEncoder().encode(document), encoding: .utf8)!.contains("source_url"))
    }

    // MARK: - The validator

    /// A vault whose one document is extracted text; `source` / `source_url` are the variables.
    private func makeVault(source: String?, sourceUrl: String? = nil,
                           writeSource: Bool = true, sourceIsPDF: Bool = true) throws -> URL {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Self.manualText.write(to: docs.appendingPathComponent("manual.md"), atomically: true, encoding: .utf8)
        if let source, writeSource {
            if sourceIsPDF {
                makePDF(at: docs.appendingPathComponent(source), pages: 2)
            } else {
                try "not a pdf".write(to: docs.appendingPathComponent(source), atomically: true, encoding: .utf8)
            }
        }
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Source Test", version: "1.0.0",
            files: ["safety.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [VaultDocument(file: "manual.md", title: "Source Test Manual",
                                      kind: "service_manual", source: source, sourceUrl: sourceUrl)],
            gating: .init(iap: "enterprise"),
            promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nLock out power before opening any panel."
            .write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        return dir
    }

    func testTheValidatorAcceptsABundledOriginal() throws {
        let result = VaultValidator.validate(directory: try makeVault(source: "manual.pdf",
                                                                     sourceUrl: "https://example.com/m.pdf"))
        XCTAssertTrue(result.isValid, "issues: \(result.issues)")
    }

    func testTheValidatorRefusesAnOriginalItCannotShow() throws {
        let missing = VaultValidator.validate(directory: try makeVault(source: "manual.pdf", writeSource: false))
        XCTAssertTrue(missing.issues.contains { $0.contains("document source missing: documents/manual.pdf") },
                      "\(missing.issues)")

        let notAPDF = VaultValidator.validate(directory: try makeVault(source: "manual.docx", sourceIsPDF: false))
        XCTAssertTrue(notAPDF.issues.contains { $0.contains("document source must be a PDF") }, "\(notAPDF.issues)")

        let badLink = VaultValidator.validate(directory: try makeVault(source: nil, sourceUrl: "example.com/manual"))
        XCTAssertTrue(badLink.issues.contains { $0.contains("source_url must be an http(s) link") },
                      "\(badLink.issues)")
    }

    // MARK: - Import, hash, export

    func testTheImporterCopiesTheOriginalAndHashesItWithoutIndexingIt() async throws {
        let dir = try makeVault(source: "manual.pdf", sourceUrl: "https://example.com/m.pdf")
        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()

        let baseline = VaultImporter.baselineDirectory(for: Self.vaultId)
        let copied = baseline.appendingPathComponent("documents/manual.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "the original rides with the vault")

        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let ledger = try await VaultImporter.syncDocuments(manifest: installed, into: store)
        let entry = try XCTUnwrap(ledger.entries.first)
        XCTAssertEqual(entry.file, "manual.md")
        XCTAssertEqual(entry.sourceContentHash,
                       VaultDocumentLedger.hash(of: try Data(contentsOf: copied)),
                       "the hash 'unmodified since import' is checked against")
        XCTAssertNotEqual(entry.sourceContentHash, entry.contentHash)
        XCTAssertEqual(store.list(namespace: DocumentStore.vaultNamespace(Self.vaultId)).map(\.name),
                       ["Source Test Manual"], "the PDF is not a second document")

        // A second sync with nothing changed does no work.
        let again = try await VaultImporter.syncDocuments(manifest: installed, into: store)
        XCTAssertEqual(again.entries.map(\.documentId), ledger.entries.map(\.documentId))

        // The export carries it back out, so a vault round-trips without silently losing the page a
        // compliance reviewer asked for.
        let exported = try VaultExporter.export(id: Self.vaultId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("documents/manual.pdf").path))
        let reimported = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
        XCTAssertEqual(reimported.documents.first?.source, "manual.pdf")
        XCTAssertEqual(reimported.documents.first?.sourceUrl, "https://example.com/m.pdf")
        XCTAssertTrue(VaultValidator.validate(directory: exported).isValid)
    }

    func testASwappedOriginalCountsAsChangedContent() {
        let entry = VaultDocumentLedger.Entry(file: "manual.md", title: "M", documentId: "id",
                                              contentHash: "text-hash", chunkCount: 3,
                                              sourceContentHash: "pdf-hash")
        let ledger = VaultDocumentLedger(entries: [entry])

        let same = VaultDocumentLedger.plan(current: ledger, desired: [
            .init(file: "manual.md", title: "M", contentHash: "text-hash", sourceContentHash: "pdf-hash")])
        XCTAssertTrue(same.isNoop)

        // The text is byte-identical and the manual a technician is handed is not the same manual.
        let swapped = VaultDocumentLedger.plan(current: ledger, desired: [
            .init(file: "manual.md", title: "M", contentHash: "text-hash", sourceContentHash: "other-hash")])
        XCTAssertEqual(swapped.toForget.map(\.file), ["manual.md"])
        XCTAssertEqual(swapped.toIngest.map(\.sourceContentHash), ["other-hash"])
    }

    func testALedgerWrittenBeforeOriginalsExistedStillReads() throws {
        let json = """
        {"entries":[{"file":"manual.md","title":"M","documentId":"id","contentHash":"h","chunkCount":4}]}
        """
        let ledger = try JSONDecoder().decode(VaultDocumentLedger.self, from: Data(json.utf8))
        XCTAssertNil(try XCTUnwrap(ledger.entries.first).sourceContentHash)

        // And round-trips once one is recorded.
        let withOriginal = VaultDocumentLedger(entries: [
            .init(file: "manual.md", title: "M", documentId: "id", contentHash: "h", chunkCount: 4,
                  sourceContentHash: "pdf")])
        let dir = tempRoot.appendingPathComponent("ledger", isDirectory: true)
        try withOriginal.save(to: dir)
        XCTAssertEqual(VaultDocumentLedger.load(from: dir), withOriginal)
    }

    // MARK: - Fixtures

    private static let manualText: String = {
        var parts: [String] = []
        for page in 1...2 {
            parts.append("Page \(page)")
            parts.append("## Section For Page \(page)")
            parts.append("")
            for step in 1...24 {
                parts.append("Step \(step) on page \(page): close the manual gas valve and verify the reading before proceeding.")
            }
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }()

    private func makePDF(at url: URL, pages: Int) {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 460, height: 700))
        let data = renderer.pdfData { context in
            for page in 1...pages {
                context.beginPage()
                let font = UIFont(name: "Helvetica", size: 10) ?? UIFont.systemFont(ofSize: 10)
                NSAttributedString(string: "Page \(page)\nThe manufacturer's own page \(page).",
                                   attributes: [.font: font, .foregroundColor: UIColor.black])
                    .draw(at: CGPoint(x: 24, y: 24))
            }
        }
        try? data.write(to: url)
    }
}
