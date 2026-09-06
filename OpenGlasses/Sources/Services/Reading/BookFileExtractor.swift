import Compression
import Foundation
import PDFKit

/// Extracts the plain text of a user-supplied book file for P4 reference alignment
/// (docs/plans/BT-reading-companion.md): PDF (PDFKit), EPUB (spine-ordered XHTML), UTF-8 text.
///
/// EPUB support is deliberately dependency-free: an EPUB is a ZIP of XHTML files plus a manifest,
/// and read-only ZIP + tag stripping is little enough code to own outright — `ZipArchiveReader`
/// below is the whole archive story, with inflation done by the system Compression framework.
/// Everything here is deterministic and fixture-testable; nothing touches the network.
enum BookFileExtractor {

    /// Extract `(name, text)` from a book file, or `nil` when the file yields no text
    /// (unknown format, scanned PDF, corrupt archive). Alignment quality degrades gracefully
    /// upstream, so partial extractions are returned rather than rejected.
    static func extract(from url: URL) -> (name: String, text: String)? {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url),
                  let text = document.string, !text.isEmpty else { return nil }
            return (name, text)
        case "epub":
            guard let data = try? Data(contentsOf: url),
                  let text = EPUBExtractor.text(from: data), !text.isEmpty else { return nil }
            return (name, text)
        default:
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
            return (name, text)
        }
    }
}

/// EPUB → plain text in spine (reading) order.
enum EPUBExtractor {

    /// Prevent a locally supplied archive from turning a forged central-directory size into an
    /// unbounded allocation. EPUB compatibility can use a larger profile than executable packs.
    private static let maxEntryBytes = 16 * 1024 * 1024

    /// The whole pipeline: ZIP → `META-INF/container.xml` → OPF manifest+spine → XHTML → text.
    /// Falls back to concatenating every (X)HTML entry in archive order when the manifest is
    /// missing or malformed — a readable-but-unordered book still beats no book.
    static func text(from data: Data) -> String? {
        guard let archive = ZipArchiveReader(data: data) else { return nil }

        let documents = spineDocumentPaths(in: archive)
            ?? archive.entryNames
                .filter { name in
                    let ext = (name as NSString).pathExtension.lowercased()
                    return ext == "xhtml" || ext == "html" || ext == "htm"
                }
                .sorted()

        let chapters = documents.compactMap { path -> String? in
            guard let bytes = archive.entryData(named: path, maximumUncompressedSize: maxEntryBytes),
                  let html = String(data: bytes, encoding: .utf8) else { return nil }
            let text = HTMLTextStripper.text(from: html)
            return text.isEmpty ? nil : text
        }
        let joined = chapters.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// Resolve the spine's content documents, in order. `nil` when container/OPF parsing fails.
    private static func spineDocumentPaths(in archive: ZipArchiveReader) -> [String]? {
        guard let containerData = archive.entryData(named: "META-INF/container.xml",
                                                    maximumUncompressedSize: maxEntryBytes),
              let container = String(data: containerData, encoding: .utf8),
              let opfPath = firstMatch(in: container, pattern: "full-path=\"([^\"]+)\""),
              let opfData = archive.entryData(named: opfPath,
                                              maximumUncompressedSize: maxEntryBytes),
              let opf = String(data: opfData, encoding: .utf8) else { return nil }

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        // Manifest: id → href, XHTML items only. Attribute order varies between producers, so
        // pull each attribute independently off the item tag.
        var hrefByID: [String: String] = [:]
        for tag in allMatches(in: opf, pattern: "<item\\b[^>]*>") {
            guard let id = firstMatch(in: tag, pattern: "\\bid=\"([^\"]+)\""),
                  let href = firstMatch(in: tag, pattern: "\\bhref=\"([^\"]+)\"") else { continue }
            if let media = firstMatch(in: tag, pattern: "media-type=\"([^\"]+)\""),
               !media.contains("html") { continue }
            hrefByID[id] = href.removingPercentEncoding ?? href
        }

        let spineIDs = allMatches(in: opf, pattern: "<itemref\\b[^>]*>")
            .compactMap { firstMatch(in: $0, pattern: "\\bidref=\"([^\"]+)\"") }
        guard !spineIDs.isEmpty else { return nil }

        let paths = spineIDs.compactMap { id -> String? in
            guard let href = hrefByID[id] else { return nil }
            let joined = opfDirectory.isEmpty ? href : opfDirectory + "/" + href
            return (joined as NSString).standardizingPath
        }
        return paths.isEmpty ? nil : paths
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

/// XHTML → readable text: scripts/styles/head dropped, block boundaries become newlines, tags
/// stripped, common entities decoded. Whitespace precision doesn't matter downstream — alignment
/// tokenizes on whitespace runs — so this favors simplicity over DOM fidelity.
enum HTMLTextStripper {

    static func text(from html: String) -> String {
        var s = html
        for block in ["script", "style", "head"] {
            s = replace(in: s, pattern: "<\(block)\\b[\\s\\S]*?</\(block)>", with: " ")
        }
        s = replace(in: s, pattern: "<!--[\\s\\S]*?-->", with: " ")
        s = replace(in: s, pattern: "<(?:br|/p|/div|/h[1-6]|/li|/tr|/blockquote|/section)\\b[^>]*>", with: "\n")
        s = replace(in: s, pattern: "<[^>]+>", with: " ")
        s = decodeEntities(s)
        // Collapse intra-line whitespace but keep line structure.
        let lines = s.split(separator: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        "&lsquo;": "'", "&rsquo;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        for (entity, character) in namedEntities {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities, decimal and hex.
        for match in EPUBTextRegex.numericEntity.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s), let inner = Range(match.range(at: 1), in: s) else { continue }
            let body = s[inner]
            let scalarValue: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalarValue = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(body)
            }
            if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                s.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return s
    }

    private static func replace(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: replacement)
    }
}

private enum EPUBTextRegex {
    static let numericEntity = try! NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
}

/// Strict read-only ZIP parser with checked central/local-directory consistency and streaming
/// stored/deflate decoding. ZIP64, multi-disk, encryption and malformed layouts are refused.
struct ZipArchiveReader {

    struct EntryMetadata: Equatable {
        let name: String
        let generalPurposeBitFlag: UInt16
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let externalAttributes: UInt32
    }

    private struct Entry {
        let metadata: EntryMetadata
        let compressedRange: Range<Int>
    }

    private let data: Data
    private var entries: [String: Entry] = [:]
    private(set) var entryMetadata: [EntryMetadata] = []

    var entryNames: [String] { Array(entries.keys) }

    init?(data: Data) {
        self.data = data
        let minimumEOCD = 22
        guard data.count >= minimumEOCD else { return nil }

        var eocdOffset: Int?
        let scanFloor = max(0, data.count - minimumEOCD - 65_535)
        var cursor = data.count - minimumEOCD
        while cursor >= scanFloor {
            if readUInt32(at: cursor) == 0x0605_4B50 {
                let commentLength = Int(readUInt16(at: cursor + 20))
                if checkedAdd(cursor, minimumEOCD, commentLength) == data.count {
                    eocdOffset = cursor
                    break
                }
            }
            cursor -= 1
        }
        guard let eocdOffset,
              readUInt16(at: eocdOffset + 4) == 0,
              readUInt16(at: eocdOffset + 6) == 0 else { return nil }
        let diskEntries = Int(readUInt16(at: eocdOffset + 8))
        let entryCount = Int(readUInt16(at: eocdOffset + 10))
        guard diskEntries == entryCount, entryCount != Int(UInt16.max) else { return nil }
        let centralSize = Int(readUInt32(at: eocdOffset + 12))
        let centralOffset = Int(readUInt32(at: eocdOffset + 16))
        guard centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max),
              let centralEnd = checkedAdd(centralOffset, centralSize),
              centralEnd == eocdOffset else { return nil }

        var centralCursor = centralOffset
        var parsed: [(EntryMetadata, Int)] = []
        var seenNames = Set<String>()
        for _ in 0..<entryCount {
            guard let fixedEnd = checkedAdd(centralCursor, 46), fixedEnd <= centralEnd,
                  readUInt32(at: centralCursor) == 0x0201_4B50 else { return nil }
            let nameLength = Int(readUInt16(at: centralCursor + 28))
            let extraLength = Int(readUInt16(at: centralCursor + 30))
            let commentLength = Int(readUInt16(at: centralCursor + 32))
            guard let recordEnd = checkedAdd(fixedEnd, nameLength, extraLength, commentLength),
                  recordEnd <= centralEnd, nameLength > 0 else { return nil }
            let nameRange = fixedEnd..<(fixedEnd + nameLength)
            guard let name = String(data: subdata(nameRange), encoding: .utf8), !name.isEmpty,
                  seenNames.insert(name).inserted else { return nil }
            let metadata = EntryMetadata(
                name: name,
                generalPurposeBitFlag: readUInt16(at: centralCursor + 8),
                compressionMethod: readUInt16(at: centralCursor + 10),
                crc32: readUInt32(at: centralCursor + 16),
                compressedSize: Int(readUInt32(at: centralCursor + 20)),
                uncompressedSize: Int(readUInt32(at: centralCursor + 24)),
                externalAttributes: readUInt32(at: centralCursor + 38)
            )
            guard metadata.compressedSize != Int(UInt32.max),
                  metadata.uncompressedSize != Int(UInt32.max) else { return nil }
            parsed.append((metadata, Int(readUInt32(at: centralCursor + 42))))
            centralCursor = recordEnd
        }
        guard centralCursor == centralEnd else { return nil }

        var physicalRanges: [Range<Int>] = []
        for (metadata, localOffset) in parsed {
            guard let fixedEnd = checkedAdd(localOffset, 30), fixedEnd <= centralOffset,
                  readUInt32(at: localOffset) == 0x0403_4B50,
                  readUInt16(at: localOffset + 6) == metadata.generalPurposeBitFlag,
                  readUInt16(at: localOffset + 8) == metadata.compressionMethod else { return nil }
            let localNameLength = Int(readUInt16(at: localOffset + 26))
            let localExtraLength = Int(readUInt16(at: localOffset + 28))
            guard let payloadStart = checkedAdd(fixedEnd, localNameLength, localExtraLength),
                  let payloadEnd = checkedAdd(payloadStart, metadata.compressedSize),
                  payloadEnd <= centralOffset,
                  String(data: subdata(fixedEnd..<(fixedEnd + localNameLength)), encoding: .utf8) == metadata.name else {
                return nil
            }

            let usesDescriptor = metadata.generalPurposeBitFlag & 0x0008 != 0
            var physicalEnd = payloadEnd
            if usesDescriptor {
                let hasSignature = payloadEnd + 4 <= centralOffset && readUInt32(at: payloadEnd) == 0x0807_4B50
                let descriptorStart = payloadEnd + (hasSignature ? 4 : 0)
                guard let descriptorEnd = checkedAdd(descriptorStart, 12), descriptorEnd <= centralOffset,
                      readUInt32(at: descriptorStart) == metadata.crc32,
                      Int(readUInt32(at: descriptorStart + 4)) == metadata.compressedSize,
                      Int(readUInt32(at: descriptorStart + 8)) == metadata.uncompressedSize else { return nil }
                physicalEnd = descriptorEnd
            } else {
                guard readUInt32(at: localOffset + 14) == metadata.crc32,
                      Int(readUInt32(at: localOffset + 18)) == metadata.compressedSize,
                      Int(readUInt32(at: localOffset + 22)) == metadata.uncompressedSize else { return nil }
            }

            let physicalRange = localOffset..<physicalEnd
            physicalRanges.append(physicalRange)
            let entry = Entry(metadata: metadata, compressedRange: payloadStart..<payloadEnd)
            entries[metadata.name] = entry
            entryMetadata.append(metadata)
        }
        let ordered = physicalRanges.sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            return nil
        }
    }

    /// Streams decoded entry bytes through a fixed-size output buffer while enforcing the actual
    /// byte count and CRC. The sink may return false to abort.
    func streamEntry(
        named name: String,
        maximumUncompressedSize: Int? = nil,
        sink: (Data) -> Bool
    ) -> Bool {
        let key = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        guard let entry = entries[key] ?? entries["./" + key] else { return false }
        let metadata = entry.metadata
        let limit = maximumUncompressedSize ?? Int.max
        guard limit >= 0, metadata.uncompressedSize <= limit else { return false }
        let raw = subdata(entry.compressedRange)
        var count = 0
        var crc = UInt32.max
        func consume(_ chunk: Data) -> Bool {
            let (next, overflow) = count.addingReportingOverflow(chunk.count)
            guard !overflow, next <= limit, next <= metadata.uncompressedSize else { return false }
            crc = Self.updateCRC32(crc, with: chunk)
            count = next
            return sink(chunk)
        }

        let decoded: Bool
        switch metadata.compressionMethod {
        case 0:
            guard raw.count == metadata.uncompressedSize else { return false }
            decoded = Self.streamStored(raw, sink: consume)
        case 8:
            decoded = Self.streamDeflate(raw, maximumOutput: limit, sink: consume)
        default:
            return false
        }
        return decoded && count == metadata.uncompressedSize && (crc ^ UInt32.max) == metadata.crc32
    }

    func entryData(named name: String, maximumUncompressedSize: Int? = nil) -> Data? {
        var output = Data()
        guard streamEntry(named: name, maximumUncompressedSize: maximumUncompressedSize,
                          sink: { output.append($0); return true }) else { return nil }
        return output
    }

    private static func streamStored(_ data: Data, sink: (Data) -> Bool) -> Bool {
        let chunkSize = 32 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            guard sink(data.subdata(in: offset..<end)) else { return false }
            offset = end
        }
        return true
    }

    /// Raw-deflate decoding with a 32 KiB rolling destination. Output is budgeted before it is
    /// handed to the caller and no buffer is allocated from attacker-controlled declared size.
    private static func streamDeflate(
        _ input: Data,
        maximumOutput: Int,
        sink: (Data) -> Bool
    ) -> Bool {
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else { return false }
        defer { compression_stream_destroy(&stream) }

        return input.withUnsafeBytes { source -> Bool in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                return input.isEmpty
            }
            stream.src_ptr = sourceBase
            stream.src_size = input.count
            var producedTotal = 0
            var destination = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let status: compression_status = destination.withUnsafeMutableBytes { buffer in
                    stream.dst_ptr = buffer.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = buffer.count
                    return compression_stream_process(&stream, 0)
                }
                let produced = destination.count - stream.dst_size
                if produced > 0 {
                    let (next, overflow) = producedTotal.addingReportingOverflow(produced)
                    guard !overflow, next <= maximumOutput,
                          sink(Data(destination.prefix(produced))) else { return false }
                    producedTotal = next
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return stream.src_size == 0
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size > 0 else { return false }
                default:
                    return false
                }
            }
        }
    }

    private func subdata(_ range: Range<Int>) -> Data {
        let lower = data.startIndex + range.lowerBound
        return data.subdata(in: lower..<(lower + range.count))
    }

    private func checkedAdd(_ values: Int...) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow, next >= 0, next <= data.count else { return nil }
            total = next
        }
        return total
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(readUInt16(at: offset)) | (UInt32(readUInt16(at: offset + 2)) << 16)
    }

    private static func updateCRC32(_ initial: UInt32, with bytes: Data) -> UInt32 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc
    }
}
