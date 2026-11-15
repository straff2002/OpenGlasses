import CoreText
import Foundation
import PDFKit
import UIKit

/// Local-only upload preparation. Non-PDF files retain their original bytes beside a paginated
/// text reading copy; citations explicitly name that copy rather than inventing Word pagination.
enum ManualFileUpload {
    static let extensions: Set<String> = ["pdf", "doc", "docx", "md", "markdown"]
    static let conversionNotice = String(localized: "Word and Markdown manuals get a text reading copy for page citations. Original layout and images are not preserved in that copy; use PDF for diagrams. Your original file is also saved on this phone.")
    static let maximumWordBytes = 100 * 1_048_576
    static let maximumTextBytes = 20 * 1_048_576

    struct Prepared: Identifiable, Sendable {
        let id: UUID
        let directory: URL
        let original: URL
        let readingPDF: URL
        let converted: Bool
        let pages: Int
        let bytes: Int64
        let suggestedTitle: String
        func discard() { try? FileManager.default.removeItem(at: directory) }
    }

    static func prepare(_ url: URL, maximumPages: Int = 10_000) throws -> Prepared {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw failure(String(localized: "Choose a PDF, DOC, DOCX or Markdown manual.")) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes > 0 else { throw failure(String(localized: "This manual is empty.")) }
        if ext != "pdf", bytes > maximumWordBytes { throw failure(String(localized: "This Word or Markdown file is too large to convert on the phone. Export it as PDF and upload that copy.")) }
        let id = UUID()
        let directory = fm.temporaryDirectory.appendingPathComponent("ManualUpload-\(id.uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            let original = directory.appendingPathComponent("original.\(ext)")
            try fm.copyItem(at: url, to: original)
            let readingPDF: URL
            if ext == "pdf" { readingPDF = original }
            else {
                let text = try text(from: original)
                readingPDF = directory.appendingPathComponent("reading-copy.pdf")
                try render(text, to: readingPDF, maximumPages: maximumPages)
            }
            try Task.checkCancellation()
            for file in Set([original, readingPDF]) {
                try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            }
            return Prepared(id: id, directory: directory, original: original, readingPDF: readingPDF,
                converted: ext != "pdf", pages: try ManualLibraryAdmission.pageCount(readingPDF), bytes: bytes,
                suggestedTitle: url.deletingPathExtension().lastPathComponent)
        } catch { try? fm.removeItem(at: directory); throw error }
    }

    static func text(from url: URL) throws -> String {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let result: String
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            guard bytes.count <= maximumTextBytes,
                  let value = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) else {
                throw failure(String(localized: "This Markdown manual could not be read. Save it as UTF-8 or PDF and try again."))
            }
            result = value
        case "docx":
            guard let zip = ZipArchiveReader(data: bytes),
                  let xml = zip.entryData(named: "word/document.xml", maximumUncompressedSize: maximumTextBytes) else {
                throw failure(String(localized: "This DOCX manual is unreadable or password protected. Export it as PDF and try again."))
            }
            result = try WordXML.text(xml)
        case "doc": result = try LegacyWordText.read(bytes)
        default: throw failure(String(localized: "Choose a PDF, DOC, DOCX or Markdown manual."))
        }
        let clean = result.replacingOccurrences(of: "\u{0C}", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw failure(String(localized: "No readable text was found in this manual. Upload a PDF to recognise scanned pages or diagrams.")) }
        return clean
    }

    private static func render(_ text: String, to url: URL, maximumPages: Int) throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let area = paper.insetBy(dx: 42, dy: 42)
        let path = CGPath(rect: area, transform: nil)
        var offset = 0
        var pages = 0
        var problem: Error?
        try UIGraphicsPDFRenderer(bounds: paper).writePDF(to: url) { context in
            while offset < attributed.length {
                if Task.isCancelled { problem = CancellationError(); break }
                guard pages < max(1, maximumPages) else {
                    problem = failure(String(localized: "This reading copy exceeds the plan's page limit. Upload a shorter manual or a PDF instead.")); break
                }
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let range = CTFrameGetVisibleStringRange(frame)
                guard range.length > 0 else { problem = failure(String(localized: "This manual could not be paginated.")); break }
                context.beginPage()
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: paper.height)
                cg.scaleBy(x: 1, y: -1)
                cg.textMatrix = .identity
                CTFrameDraw(frame, cg)
                cg.restoreGState()
                offset += range.length
                pages += 1
            }
        }
        if let problem { throw problem }
    }

    static func failure(_ message: String) -> ManualLibraryAdmission.Failure { .refused(message) }
}

private final class WordXML: NSObject, XMLParserDelegate {
    private var output = ""
    private var inText = false
    private var deletedDepth = 0
    static func text(_ data: Data) throws -> String {
        guard let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ManualFileUpload.failure(String(localized: "This DOCX manual contains unsupported XML. Export it as PDF and try again."))
        }
        let delegate = WordXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw ManualFileUpload.failure(String(localized: "This DOCX manual is damaged. Export it as PDF and try again.")) }
        return delegate.output
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "del" { deletedDepth += 1 }
        guard deletedDepth == 0 else { return }
        if name == "t" { inText = true }
        if name == "tab" { output += "\t" }
        if name == "br" || name == "cr" { output += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText && deletedDepth == 0 { output += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "del" { deletedDepth = max(0, deletedDepth - 1); return }
        guard deletedDepth == 0 else { return }
        if name == "t" { inText = false }
        if name == "p" || name == "tr" { output += "\n" }
        if name == "tc" { output += "\t" }
    }
}

/// Word 97–2003 body text, using MS-CFB stream chains and MS-DOC's CLX piece table. No macros,
/// embedded objects or external resources are loaded. Unsupported/encrypted files fail closed.
/// https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/01d5d8c4-cf9c-4ef9-80fd-439e763cfe01
private enum LegacyWordText {
    static func read(_ data: Data) throws -> String {
        let compound = try Compound(data)
        let word = try compound.stream("WordDocument")
        guard try word.u16(0) == 0xA5EC, try word.u16(2) >= 0xC1 else { throw bad() }
        let flags = try word.u16(10)
        guard flags & 0x8100 == 0 else { throw ManualFileUpload.failure(String(localized: "This DOC manual is password protected. Export an unlocked PDF and try again.")) }
        let table = try compound.stream(flags & 0x200 == 0 ? "0Table" : "1Table")
        let lw = 34 + Int(try word.u16(32)) * 2
        let cslw = Int(try word.u16(lw))
        guard cslw >= 4 else { throw bad() }
        let count = Int(try word.u32(lw + 2 + 12))
        guard count > 0, count <= ManualFileUpload.maximumTextBytes / 2 else { throw bad() }
        let pairs = lw + 2 + cslw * 4
        guard try word.u16(pairs) >= 34 else { throw bad() }
        let clxOffset = Int(try word.u32(pairs + 2 + 33 * 8))
        let clxLength = Int(try word.u32(pairs + 2 + 33 * 8 + 4))
        let clx = try table.part(clxOffset, clxLength)
        var cursor = 0
        while try clx.u8(cursor) == 1 { cursor += 3 + Int(try clx.u16(cursor + 1)) }
        guard try clx.u8(cursor) == 2 else { throw bad() }
        let length = Int(try clx.u32(cursor + 1))
        guard length >= 16, (length - 4) % 12 == 0 else { throw bad() }
        let plc = try clx.part(cursor + 5, length)
        let pieces = (length - 4) / 12
        guard pieces > 0, try plc.u32(0) == 0 else { throw bad() }
        var output = ""
        var covered = 0
        for i in 0..<pieces {
            let start = Int(try plc.u32(i * 4))
            let end = Int(try plc.u32((i + 1) * 4))
            guard start == covered, end >= start else { throw bad() }
            if start >= count { break }
            let n = min(end, count) - start
            let fc = try plc.u32(4 * (pieces + 1) + i * 8 + 2)
            let compressed = fc & 0x4000_0000 != 0
            let offset = Int(fc & 0x3FFF_FFFF) / (compressed ? 2 : 1)
            let bytes = try word.part(offset, n * (compressed ? 1 : 2))
            guard let text = String(data: bytes, encoding: compressed ? .windowsCP1252 : .utf16LittleEndian) else { throw bad() }
            output += text
            covered = end
        }
        guard covered >= count else { throw bad() }
        // Field instructions are not visible document text; retain only displayed field results.
        var result = ""
        var fields: [Bool] = []
        for scalar in output.unicodeScalars {
            switch scalar.value {
            case 0x13: fields.append(false)
            case 0x14: if !fields.isEmpty { fields[fields.count - 1] = true }
            case 0x15: if !fields.isEmpty { fields.removeLast() }
            default:
                guard fields.allSatisfy({ $0 }) else { continue }
                if scalar.value == 13 { result += "\n" }
                else if scalar.value == 7 { result += "\t" }
                else if scalar.value >= 32 || scalar.value == 9 || scalar.value == 10 || scalar.value == 12 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
    static func bad() -> ManualLibraryAdmission.Failure { ManualFileUpload.failure(String(localized: "This DOC manual is damaged or uses an unsupported Word format. Export it as PDF or DOCX and try again.")) }

    private struct Compound {
        let data: Data
        let size: Int
        let fat: [UInt32]
        let directory: Data
        let miniFat: [UInt32]
        let mini: Data
        init(_ data: Data) throws {
            guard data.count >= 512, data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
                  try data.u16(28) == 0xFFFE, try data.u16(32) == 6 else { throw bad() }
            let shift = try data.u16(30)
            guard shift == 9 || shift == 12 else { throw bad() }
            let size = 1 << Int(shift)
            let sectorCount = data.count / size - 1
            guard sectorCount > 0 else { throw bad() }
            func sector(_ id: UInt32) throws -> Data {
                guard Int(id) < sectorCount else { throw bad() }
                return try data.part((Int(id) + 1) * size, size)
            }
            var difat = try stride(from: 76, to: 512, by: 4).map { try data.u32($0) }.filter { $0 != UInt32.max }
            let extendedCount = Int(try data.u32(72))
            guard extendedCount <= sectorCount else { throw bad() }
            var next = try data.u32(68)
            var seen = Set<UInt32>()
            for _ in 0..<extendedCount {
                guard seen.insert(next).inserted else { throw bad() }
                let block = try sector(next)
                difat += try stride(from: 0, to: size - 4, by: 4).map { try block.u32($0) }.filter { $0 != UInt32.max }
                next = try block.u32(size - 4)
            }
            let fatCount = Int(try data.u32(44))
            guard fatCount > 0, difat.count == fatCount, fatCount <= sectorCount, Set(difat).count == difat.count else { throw bad() }
            var fat: [UInt32] = []
            for id in difat {
                let block = try sector(id)
                fat += try stride(from: 0, to: size, by: 4).map { try block.u32($0) }
            }
            let directory = try Self.chain(start: data.u32(48), fat: fat, block: sector, maximum: data.count)
            guard directory.count >= 128, try directory.u8(66) == 5 else { throw bad() }
            let miniStart = try data.u32(60)
            let miniCount = Int(try data.u32(64))
            guard miniCount <= sectorCount else { throw bad() }
            let miniFatBytes = miniCount == 0 ? Data() : try Self.chain(start: miniStart, fat: fat, block: sector, maximum: miniCount * size)
            let miniFat = try stride(from: 0, to: miniFatBytes.count, by: 4).map { try miniFatBytes.u32($0) }
            let miniSize = Int(try directory.u32(120))
            guard miniSize <= data.count else { throw bad() }
            let mini = miniSize == 0 ? Data() : try Self.chain(start: directory.u32(116), fat: fat, block: sector, maximum: data.count).prefix(miniSize)
            self.data = data; self.size = size; self.fat = fat; self.directory = directory
            self.miniFat = miniFat; self.mini = Data(mini)
        }
        func stream(_ name: String) throws -> Data {
            for offset in stride(from: 0, through: directory.count - 128, by: 128) {
                let length = Int(try directory.u16(offset + 64))
                guard length >= 2, length <= 64, try directory.u8(offset + 66) == 2 else { continue }
                let title = String(data: try directory.part(offset, length - 2), encoding: .utf16LittleEndian)
                guard title == name else { continue }
                let count = Int(try directory.u32(offset + 120))
                guard count > 0, count <= data.count, count <= ManualFileUpload.maximumWordBytes else { throw bad() }
                let first = try directory.u32(offset + 116)
                let value: Data
                if count < 4096 {
                    value = try Self.chain(start: first, fat: miniFat, block: { try mini.part(Int($0) * 64, 64) }, maximum: mini.count)
                } else {
                    value = try Self.chain(start: first, fat: fat, block: { try data.part((Int($0) + 1) * size, size) }, maximum: data.count)
                }
                guard value.count >= count else { throw bad() }
                return Data(value.prefix(count))
            }
            throw bad()
        }
        private static func chain(start: UInt32, fat: [UInt32], block: (UInt32) throws -> Data, maximum: Int) throws -> Data {
            var output = Data(); var next = start; var seen = Set<UInt32>()
            while next != 0xFFFF_FFFE {
                guard Int(next) < fat.count, seen.insert(next).inserted else { throw bad() }
                let bytes = try block(next)
                guard output.count <= maximum - bytes.count else { throw bad() }
                output.append(bytes); next = fat[Int(next)]
            }
            return output
        }
    }
}

private extension Data {
    func part(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { throw LegacyWordText.bad() }
        return subdata(in: offset..<(offset + length))
    }
    func u8(_ offset: Int) throws -> UInt8 { guard offset >= 0, offset < count else { throw LegacyWordText.bad() }; return self[offset] }
    func u16(_ offset: Int) throws -> UInt16 { UInt16(try u8(offset)) | (UInt16(try u8(offset + 1)) << 8) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try u16(offset)) | (UInt32(try u16(offset + 2)) << 16) }
}
