import Compression
import XCTest
@testable import OpenGlasses

/// Tests the EPUB extraction pipeline (docs/plans/BT-reading-companion.md P4): the minimal ZIP
/// reader, spine-ordered chapter walk, and HTML→text stripping. Fixtures are real ZIP bytes built
/// by the stored-entry writer below, so the reader is exercised against the actual format —
/// headless, no bundled resource files.
final class BookFileExtractorTests: XCTestCase {

    // MARK: - Fixture: a minimal stored-entry ZIP writer

    /// Writes an uncompressed (method 0) ZIP — enough to feed the read path end to end.
    private func zip(_ files: [(name: String, content: String)]) -> Data {
        var body = Data()
        var centralDirectory = Data()
        var localOffsets: [Int] = []

        for file in files {
            let nameBytes = Data(file.name.utf8)
            let contentBytes = Data(file.content.utf8)
            let checksum = crc32(contentBytes)
            localOffsets.append(body.count)
            body.appendUInt32(0x0403_4B50)               // local header signature
            body.appendUInt16(20); body.appendUInt16(0)  // version, flags
            body.appendUInt16(0)                         // method: stored
            body.appendUInt16(0); body.appendUInt16(0)   // time, date
            body.appendUInt32(checksum)
            body.appendUInt32(UInt32(contentBytes.count))
            body.appendUInt32(UInt32(contentBytes.count))
            body.appendUInt16(UInt16(nameBytes.count)); body.appendUInt16(0)
            body.append(nameBytes)
            body.append(contentBytes)
        }
        for (index, file) in files.enumerated() {
            let nameBytes = Data(file.name.utf8)
            let contentBytes = Data(file.content.utf8)
            let checksum = crc32(contentBytes)
            centralDirectory.appendUInt32(0x0201_4B50)   // central directory signature
            centralDirectory.appendUInt16(20); centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(0)             // flags
            centralDirectory.appendUInt16(0)             // method: stored
            centralDirectory.appendUInt16(0); centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(checksum)
            centralDirectory.appendUInt32(UInt32(contentBytes.count))
            centralDirectory.appendUInt32(UInt32(contentBytes.count))
            centralDirectory.appendUInt16(UInt16(nameBytes.count))
            centralDirectory.appendUInt16(0); centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0); centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(UInt32(localOffsets[index]))
            centralDirectory.append(nameBytes)
        }
        var out = body
        out.append(centralDirectory)
        out.appendUInt32(0x0605_4B50)                    // end of central directory
        out.appendUInt16(0); out.appendUInt16(0)
        out.appendUInt16(UInt16(files.count)); out.appendUInt16(UInt16(files.count))
        out.appendUInt32(UInt32(centralDirectory.count))
        out.appendUInt32(UInt32(body.count))
        out.appendUInt16(0)
        return out
    }

    private func epub(chapterOrder: [String] = ["one", "two"]) -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """
        let spineRefs = chapterOrder.map { "<itemref idref=\"\($0)\"/>" }.joined()
        let opf = """
        <?xml version="1.0"?>
        <package><manifest>
        <item id="two" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
        <item id="one" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="style.css" media-type="text/css"/>
        </manifest><spine>\(spineRefs)</spine></package>
        """
        let chapter1 = """
        <html><head><title>Ignored</title><style>p { color: red }</style></head>
        <body><h1>Chapter One</h1><p>It was the best of times &amp; the worst of times.</p></body></html>
        """
        let chapter2 = """
        <html><body><p>The second chapter &#8212; with a numeric entity.</p></body></html>
        """
        return zip([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf),
            ("OEBPS/chapter1.xhtml", chapter1),
            ("OEBPS/chapter2.xhtml", chapter2),
            ("OEBPS/style.css", "p { color: red }"),
        ])
    }

    // MARK: - EPUB pipeline

    func testEPUBExtractsChaptersInSpineOrderNotManifestOrder() throws {
        let text = try XCTUnwrap(EPUBExtractor.text(from: epub(chapterOrder: ["one", "two"])))
        let first = try XCTUnwrap(text.range(of: "best of times"))
        let second = try XCTUnwrap(text.range(of: "second chapter"))
        XCTAssertTrue(first.lowerBound < second.lowerBound)

        // Reversing the spine reverses the reading order, whatever the manifest says.
        let reversed = try XCTUnwrap(EPUBExtractor.text(from: epub(chapterOrder: ["two", "one"])))
        let r1 = try XCTUnwrap(reversed.range(of: "second chapter"))
        let r2 = try XCTUnwrap(reversed.range(of: "best of times"))
        XCTAssertTrue(r1.lowerBound < r2.lowerBound)
    }

    func testEPUBStripsMarkupAndDecodesEntities() throws {
        let text = try XCTUnwrap(EPUBExtractor.text(from: epub()))
        XCTAssertTrue(text.contains("It was the best of times & the worst of times."))
        XCTAssertTrue(text.contains("The second chapter — with a numeric entity."))
        XCTAssertFalse(text.contains("<p>"), "no tags may survive")
        XCTAssertFalse(text.contains("color: red"), "style blocks and CSS files must not leak in")
        XCTAssertFalse(text.contains("Ignored"), "head content must not leak in")
    }

    func testCorruptArchiveYieldsNil() {
        XCTAssertNil(EPUBExtractor.text(from: Data("not a zip archive at all".utf8)))
        XCTAssertNil(EPUBExtractor.text(from: Data()))
    }

    /// A broken manifest must not kill the book: fall back to every (X)HTML entry in the archive.
    func testMissingManifestFallsBackToHTMLEntries() throws {
        let data = zip([
            ("a-chapter.xhtml", "<html><body><p>Fallback prose survives.</p></body></html>"),
            ("notes.txt", "not html, ignored"),
        ])
        let text = try XCTUnwrap(EPUBExtractor.text(from: data))
        XCTAssertTrue(text.contains("Fallback prose survives."))
        XCTAssertFalse(text.contains("not html"))
    }

    // MARK: - ZIP reader

    func testZipReaderReadsStoredEntriesByName() throws {
        let archive = try XCTUnwrap(ZipArchiveReader(data: zip([
            ("dir/file.txt", "hello zip"), ("other.txt", "second"),
        ])))
        XCTAssertEqual(String(data: try XCTUnwrap(archive.entryData(named: "dir/file.txt")), encoding: .utf8),
                       "hello zip")
        XCTAssertEqual(String(data: try XCTUnwrap(archive.entryData(named: "other.txt")), encoding: .utf8),
                       "second")
        XCTAssertNil(archive.entryData(named: "missing.txt"))
    }

    /// Real EPUBs use deflate — verify the inflate path against Compression-framework-produced
    /// deflate bytes, so the reader is tested beyond the stored-entry fixtures.
    func testZipReaderInflatesDeflateEntries() throws {
        let original = String(repeating: "compressible prose. ", count: 200)
        let originalBytes = Data(original.utf8)
        var compressed = Data(count: originalBytes.count + 1024)
        let compressedCount = compressed.withUnsafeMutableBytes { destination -> Int in
            originalBytes.withUnsafeBytes { source -> Int in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, originalBytes.count + 1024,
                    source.bindMemory(to: UInt8.self).baseAddress!, originalBytes.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertGreaterThan(compressedCount, 0)
        compressed.removeSubrange(compressedCount...)

        // Hand-assemble a one-entry deflate ZIP around those bytes.
        var body = Data()
        let name = Data("deflated.txt".utf8)
        body.appendUInt32(0x0403_4B50); body.appendUInt16(20); body.appendUInt16(0)
        body.appendUInt16(8)                                  // method: deflate
        body.appendUInt16(0); body.appendUInt16(0); body.appendUInt32(crc32(originalBytes))
        body.appendUInt32(UInt32(compressed.count)); body.appendUInt32(UInt32(originalBytes.count))
        body.appendUInt16(UInt16(name.count)); body.appendUInt16(0)
        body.append(name); body.append(compressed)

        var central = Data()
        central.appendUInt32(0x0201_4B50); central.appendUInt16(20); central.appendUInt16(20)
        central.appendUInt16(0); central.appendUInt16(8)
        central.appendUInt16(0); central.appendUInt16(0); central.appendUInt32(crc32(originalBytes))
        central.appendUInt32(UInt32(compressed.count)); central.appendUInt32(UInt32(originalBytes.count))
        central.appendUInt16(UInt16(name.count)); central.appendUInt16(0); central.appendUInt16(0)
        central.appendUInt16(0); central.appendUInt16(0); central.appendUInt32(0)
        central.appendUInt32(0)
        central.append(name)

        var archiveData = body
        archiveData.append(central)
        archiveData.appendUInt32(0x0605_4B50)
        archiveData.appendUInt16(0); archiveData.appendUInt16(0)
        archiveData.appendUInt16(1); archiveData.appendUInt16(1)
        archiveData.appendUInt32(UInt32(central.count)); archiveData.appendUInt32(UInt32(body.count))
        archiveData.appendUInt16(0)

        let archive = try XCTUnwrap(ZipArchiveReader(data: archiveData))
        let inflated = try XCTUnwrap(archive.entryData(named: "deflated.txt"))
        XCTAssertEqual(String(data: inflated, encoding: .utf8), original)
    }

    // MARK: - HTML stripper

    func testStripperHandlesBlockBoundariesAndEntities() {
        let html = "<p>line one</p><p>line &quot;two&quot; &#x2014; done</p><script>alert(1)</script>"
        let text = HTMLTextStripper.text(from: html)
        XCTAssertEqual(text, "line one\nline \"two\" — done")
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }
    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value & 0xFFFF)); appendUInt16(UInt16(value >> 16))
    }
}
