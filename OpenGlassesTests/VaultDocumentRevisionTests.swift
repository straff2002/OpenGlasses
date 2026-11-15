import XCTest
@testable import OpenGlasses

/// Plan LV P0 — `VaultDocument.revision` and `.origin`: absent → exactly today's behaviour, and a
/// manifest without them is the bytes it was.
final class VaultDocumentRevisionTests: XCTestCase {

    func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testADocumentWithoutThemIsTheBytesItWas() throws {
        let json = #"{"edition":"Rev C","file":"Installation manual.pdf","kind":"company_manual","title":"Installation manual"}"#
        let document = try JSONDecoder().decode(VaultDocument.self, from: Data(json.utf8))
        XCTAssertNil(document.revision)
        XCTAssertNil(document.origin)
        XCTAssertEqual(try encoded(document), json)
        XCTAssertEqual(document, VaultDocument(file: "Installation manual.pdf", title: "Installation manual",
                                               kind: "company_manual", edition: "Rev C"))
    }

    func testAManifestWithoutThemRoundTripsByteForByte() throws {
        let json = #"{"documents":[{"file":"a.md","title":"A"},{"edition":"2024","file":"b.pdf","source":"b-original.pdf","title":"B"}],"documents_dir":"documents","documents_included":true,"files":["safety.md"],"gating":{"iap":"com.openglasses.vault.fixture-split-systems"},"id":"fixture-split-systems","name":"Fixture Split Systems","prompt_rules":["Never fabricate a value."],"source_attribution_format":"Source: {files}","source_attribution_required":true,"version":"7"}"#
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: Data(json.utf8))
        XCTAssertEqual(try encoded(manifest), json)
    }

    func testRevisionAndOriginRoundTrip() throws {
        let revision = String(repeating: "a", count: 64)
        let document = VaultDocument(file: "Installation manual.md", title: "Installation manual", kind: "company_manual",
                                     revision: revision, origin: .company)
        let json = try encoded(document)
        XCTAssertEqual(json, #"{"file":"Installation manual.md","kind":"company_manual","origin":"company","revision":"\#(revision)","title":"Installation manual"}"#)
        let decoded = try JSONDecoder().decode(VaultDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.revision, revision)
        XCTAssertEqual(decoded.origin, .company)
        for origin in [VaultDocument.Origin.company, .technician, .capture] {
            let data = Data(#"{"file":"x.md","title":"X","origin":"\#(origin.rawValue)"}"#.utf8)
            XCTAssertEqual(try JSONDecoder().decode(VaultDocument.self, from: data).origin, origin)
        }
    }

    /// Informational fields: a value from a newer build, or the wrong type, reads as absent rather
    /// than refusing the vault.
    func testAnUnknownOriginOrAMalformedRevisionReadsAsAbsent() throws {
        for json in [#"{"file":"x.md","title":"X","origin":"partner","revision":7}"#,
                     #"{"file":"x.md","title":"X","origin":3,"revision":null}"#] {
            let document = try JSONDecoder().decode(VaultDocument.self, from: Data(json.utf8))
            XCTAssertNil(document.origin, json)
            XCTAssertNil(document.revision, json)
            XCTAssertEqual(document.file, "x.md")
        }
    }

    func testThePersonalProjectionLeavesThemBehind() {
        let manifest = VaultManifest(id: "fixture-split-systems", name: "Fixture", version: "1", files: [],
                                     documents: [VaultDocument(file: "a.pdf", title: "A", revision: String(repeating: "b", count: 64),
                                                               origin: .technician)])
        XCTAssertNil(manifest.personalProjection.documents.first?.revision)
        XCTAssertNil(manifest.personalProjection.documents.first?.origin)
    }
}
