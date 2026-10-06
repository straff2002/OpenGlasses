import CoreGraphics
import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan HQ P1 item 1 — every PDF the app writes carries its provenance where a machine looks: the
/// Info dictionary (Title, Creator, Subject, Keywords) and an XMP packet with the IPTC digital
/// source type. And, as in `AIProvenanceTests`, the instructions the model was given never ride
/// along: a canary in the prompt sources must be nowhere in the bytes.
final class PDFProvenanceStampTests: XCTestCase {

    private static let promptCanary = "CANARY-PROMPT-BODY-51d7e0"
    static let trained = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    static let composite = "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"

    static func provenance() -> AIProvenance {
        AIProvenance.forAssessment(
            modelIdentifier: "test-model-1",
            providerClass: .cloud,
            promptSources: ["You are a safety expert. \(promptCanary)", "{schema:v3}"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "2026.9 (400)")
    }

    // MARK: - The packet

    func testXMPParsesAndCarriesTheDigestTheIPTCTypeAndNoInstructions() throws {
        let p = Self.provenance()
        let packet = p.xmpPacket(title: "A title")
        XCTAssertTrue(PDFMetadataProbe.isWellFormedXML(packet))

        let text = try XCTUnwrap(String(data: packet, encoding: .utf8))
        XCTAssertTrue(text.contains(p.promptVersionDigest))
        XCTAssertTrue(text.contains("Iptc4xmpExt:DigitalSourceType=\"\(Self.trained)\""))
        XCTAssertTrue(text.contains("xmlns:Iptc4xmpExt=\"http://iptc.org/std/Iptc4xmpExt/2008-02-29/\""))
        XCTAssertTrue(text.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""))
        XCTAssertTrue(text.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\""))
        XCTAssertTrue(text.contains("xmp:CreatorTool=\"Avenkin 2026.9 (400)\""))
        XCTAssertTrue(text.contains("xmp:CreateDate=\"2023-11-14T22:13:20Z\""))
        XCTAssertTrue(text.contains("<rdf:li>AI-generated</rdf:li>"))
        XCTAssertTrue(text.contains(p.footerLine), "dc:description is the footer line")
        XCTAssertFalse(text.contains(Self.promptCanary))
        XCTAssertFalse(text.contains("safety expert"))
    }

    func testCompositeDocumentsDeclareTheCompositeType() throws {
        let text = try XCTUnwrap(String(data: Self.provenance().xmpPacket(title: "T", composite: true),
                                        encoding: .utf8))
        XCTAssertTrue(text.contains(Self.composite))
        XCTAssertFalse(text.contains("\"\(Self.trained)\""))
    }

    /// A value with markup characters is escaped, not allowed to break the packet.
    func testValuesAreEscaped() {
        let stamp = PDFProvenanceStamp.aiGenerated(provenance: nil, title: "A & B <c> \"d\"",
                                                   composite: false, unrecordedSubject: "x < y & z")
        XCTAssertTrue(PDFMetadataProbe.isWellFormedXML(stamp.xmpPacket))
    }

    func testAnUnrecordedModelStillSaysAIGenerated() throws {
        let stamp = PDFProvenanceStamp.aiGenerated(provenance: nil, title: "T", composite: true,
                                                   unrecordedSubject: "Model not recorded.")
        XCTAssertEqual(stamp.documentInfo[kCGPDFContextCreator as String] as? String,
                       "Avenkin — contains AI-generated content")
        XCTAssertEqual(stamp.documentInfo[kCGPDFContextKeywords as String] as? String, "AI-generated")
        let text = try XCTUnwrap(String(data: stamp.xmpPacket, encoding: .utf8))
        XCTAssertTrue(text.contains("Model not recorded."))
        XCTAssertTrue(text.contains(Self.composite))
    }

    // MARK: - The renderers

    @MainActor
    func testSafetyPDFCarriesTheInfoDictionaryAndTheXMP() throws {
        let report = try SafetyReport.from(
            json: ["summary": "Trench on the plan.",
                   "assessments": [["category": "excavation", "is_present": true]]],
            provenance: Self.provenance())
        let data = SafetyReportPDF.data(for: report)
        try assertStamped(data, title: SafetyReportPDF.documentTitle, sourceType: Self.trained)
    }

    @MainActor
    func testFieldPDFsCarryTheInfoDictionaryAndTheCompositeXMP() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfstamp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = EntitlementTestScope.grant()
        defer { EntitlementTestScope.restore(previous) }

        let service = FieldSessionService(sessionsRoot: root)
        let session = try service.startSession(vaultId: "refrigeration", assetId: "Unit 47B")
        service.logUserMessage("What does E5 mean?")
        service.logAssistantMessage("E5 is a compressor motor lock.", citations: ["error_codes.md"])
        _ = try service.endSession(outcome: .resolved)
        let sessionDir = root.appendingPathComponent(session.id, isDirectory: true)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: sessionDir,
                                                              provenance: Self.provenance()))

        let workOrder = root.appendingPathComponent("work_order.pdf")
        try SessionExporter.writePDF(export, to: workOrder)
        try assertStamped(Data(contentsOf: workOrder), title: SessionExporter.workOrderTitle,
                          sourceType: Self.composite)

        let record = WorkRecord(session: WorkRecordTests.scriptedSession(), vaultName: "Furnace")
        let transcript = root.appendingPathComponent("transcript.pdf")
        try SessionExporter.writeTranscriptPDF(record: record, lines: [], to: transcript,
                                               provenance: Self.provenance())
        try assertStamped(Data(contentsOf: transcript), title: SessionExporter.transcriptTitle,
                          sourceType: Self.composite)

        let addendum = root.appendingPathComponent("addendum.pdf")
        try SessionExporter.writeAddendumPDF(record: record, debriefs: [], to: addendum,
                                             provenance: Self.provenance())
        try assertStamped(Data(contentsOf: addendum), title: DebriefDocumentPolicy.addendumTitle,
                          sourceType: Self.composite)
    }

    // MARK: - Helper

    private func assertStamped(_ data: Data, title: String, sourceType: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8), file: file, line: line)

        // The Info dictionary, read back the way any PDF reader reads it.
        let attributes = try XCTUnwrap(PDFDocument(data: data)?.documentAttributes, file: file, line: line)
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, title, file: file, line: line)
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String,
                       "Avenkin 2026.9 (400) — AI-generated", file: file, line: line)
        let subject = try XCTUnwrap(attributes[PDFDocumentAttribute.subjectAttribute] as? String,
                                    file: file, line: line)
        XCTAssertTrue(subject.contains("AI-generated by test-model-1"), file: file, line: line)
        XCTAssertTrue(PDFMetadataProbe.keywords(attributes).contains("AI-generated"),
                      "keywords: \(String(describing: attributes[PDFDocumentAttribute.keywordsAttribute]))",
                      file: file, line: line)

        // The XMP, from the catalog's Metadata stream.
        let xmp = try XCTUnwrap(PDFMetadataProbe.xmp(in: data), "no XMP metadata stream", file: file, line: line)
        XCTAssertTrue(xmp.contains("Iptc4xmpExt:DigitalSourceType=\"\(sourceType)\""), file: file, line: line)
        XCTAssertTrue(xmp.contains(Self.provenance().promptVersionDigest), file: file, line: line)
        XCTAssertTrue(PDFMetadataProbe.isWellFormedXML(Data(xmp.utf8)), file: file, line: line)

        // Core Graphics deflates the Metadata stream, so the packet is checked decoded (above and
        // here) and the raw bytes only for what must never be there in any form.
        XCTAssertFalse(xmp.contains(Self.promptCanary), file: file, line: line)
        XCTAssertFalse(PDFMetadataProbe.contains(data, Self.promptCanary), file: file, line: line)
    }
}

/// Reads back what a PDF says about itself.
enum PDFMetadataProbe {
    /// The XMP packet in the document catalog's `Metadata` stream, decoded.
    static func xmp(in data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let bytes = CGPDFStreamCopyData(stream, &format) else { return nil }
        return String(data: bytes as Data, encoding: .utf8)
    }

    /// PDFKit hands keywords back as an array or a string depending on how they were written.
    static func keywords(_ attributes: [AnyHashable: Any]) -> [String] {
        switch attributes[PDFDocumentAttribute.keywordsAttribute] {
        case let list as [String]: return list
        case let text as String: return text.components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
        default: return []
        }
    }

    static func isWellFormedXML(_ data: Data) -> Bool {
        XMLParser(data: data).parse()
    }

    static func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }
}
