import Foundation

/// The little of a spreadsheet workbook the van's stock needs (Plan IH §6).
enum XLSX {

    enum Cell: Equatable {
        case empty
        case text(String)
        case number(Int)
        /// A stock figure, written as its exact decimal (`<v>4.25</v>`, `<v>4</v>`). OOXML always
        /// stores a number with a `.`; the spreadsheet shows it in its own locale.
        case decimal(StockQuantity)
    }

    struct Column: Equatable {
        var width: Double = 14
        /// Text-formatted, so a part number typed into a new row stays as typed: no dropped
        /// leading zeros, no scientific notation.
        var isText = false
        var isHidden = false
    }

    struct Sheet: Equatable {
        var name: String
        var columns: [Column]
        /// The first row is the header.
        var rows: [[Cell]]
        var isHidden = false
    }

    struct Workbook: Equatable {
        var sheets: [Sheet]
    }
}

/// Writes a workbook a spreadsheet program opens (Plan IH §6).
///
/// Owned outright, like the ZIP reader beside the book importer: a workbook is a ZIP of a handful
/// of small XML parts, and writing the parts stored — not compressed — needs nothing but a
/// checksum. Every text cell is an inline string, so nothing is ever reinterpreted as a number.
///
/// Pure: the same workbook and the same date give the same bytes.
enum XLSXWriter {

    static func data(for workbook: XLSX.Workbook, modified: Date) -> Data {
        var files: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes(sheetCount: workbook.sheets.count).utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbookXML(workbook).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships(sheetCount: workbook.sheets.count).utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
        ]
        for (offset, sheet) in workbook.sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(offset + 1).xml", Data(sheetXML(sheet).utf8)))
        }
        return archive(files, modified: modified)
    }

    // MARK: - Parts

    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"

    private static func contentTypes(sheetCount: Int) -> String {
        let prefix = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        var xml = header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        xml += #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        xml += #"<Default Extension="xml" ContentType="application/xml"/>"#
        xml += #"<Override PartName="/xl/workbook.xml" ContentType="\#(prefix).sheet.main+xml"/>"#
        xml += #"<Override PartName="/xl/styles.xml" ContentType="\#(prefix).styles+xml"/>"#
        for index in 0..<sheetCount {
            xml += #"<Override PartName="/xl/worksheets/sheet\#(index + 1).xml" ContentType="\#(prefix).worksheet+xml"/>"#
        }
        return xml + "</Types>"
    }

    private static var rootRelationships: String {
        header + #"<Relationships xmlns="\#(packageRelationships)">"#
            + #"<Relationship Id="rId1" Type="\#(relationshipNamespace)/officeDocument" Target="xl/workbook.xml"/>"#
            + "</Relationships>"
    }

    private static func workbookXML(_ workbook: XLSX.Workbook) -> String {
        var xml = header + #"<workbook xmlns="\#(mainNamespace)" xmlns:r="\#(relationshipNamespace)"><sheets>"#
        for (offset, sheet) in workbook.sheets.enumerated() {
            let state = sheet.isHidden ? #" state="hidden""# : ""
            xml += #"<sheet name="\#(escape(sheetName(sheet.name)))" sheetId="\#(offset + 1)"\#(state) r:id="rId\#(offset + 1)"/>"#
        }
        return xml + "</sheets></workbook>"
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        var xml = header + #"<Relationships xmlns="\#(packageRelationships)">"#
        for index in 0..<sheetCount {
            xml += #"<Relationship Id="rId\#(index + 1)" Type="\#(relationshipNamespace)/worksheet" Target="worksheets/sheet\#(index + 1).xml"/>"#
        }
        xml += #"<Relationship Id="rId\#(sheetCount + 1)" Type="\#(relationshipNamespace)/styles" Target="styles.xml"/>"#
        return xml + "</Relationships>"
    }

    /// Three cell formats: 0 general, 1 text, 2 the bold header.
    private static var styles: String {
        header + #"<styleSheet xmlns="\#(mainNamespace)">"#
            + #"<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>"#
            + #"<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>"#
            + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
            + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
            + #"<cellXfs count="3">"#
            + #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#
            + #"<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
            + #"<xf numFmtId="49" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>"#
            + "</cellXfs></styleSheet>"
    }

    private static func sheetXML(_ sheet: XLSX.Sheet) -> String {
        var xml = header + #"<worksheet xmlns="\#(mainNamespace)">"#
        xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        if !sheet.columns.isEmpty {
            xml += "<cols>"
            for (offset, column) in sheet.columns.enumerated() {
                let style = column.isText ? #" style="1""# : ""
                let hidden = column.isHidden ? #" hidden="1""# : ""
                xml += #"<col min="\#(offset + 1)" max="\#(offset + 1)" width="\#(column.width)"\#(style)\#(hidden) customWidth="1"/>"#
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (rowOffset, row) in sheet.rows.enumerated() {
            xml += #"<row r="\#(rowOffset + 1)">"#
            for (columnOffset, cell) in row.enumerated() {
                let reference = columnLetters(columnOffset) + String(rowOffset + 1)
                let isText = columnOffset < sheet.columns.count && sheet.columns[columnOffset].isText
                switch cell {
                case .empty:
                    continue
                case .text(let value):
                    let style = rowOffset == 0 ? 2 : (isText ? 1 : 0)
                    xml += #"<c r="\#(reference)" t="inlineStr" s="\#(style)"><is><t xml:space="preserve">\#(escape(value))</t></is></c>"#
                case .number(let value):
                    xml += #"<c r="\#(reference)"><v>\#(value)</v></c>"#
                case .decimal(let value):
                    xml += #"<c r="\#(reference)"><v>\#(value.decimalString)</v></c>"#
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    // MARK: - Text

    /// "A", "B", … "Z", "AA".
    static func columnLetters(_ index: Int) -> String {
        var remaining = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + remaining % 26))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    /// A name a spreadsheet program accepts for a sheet: at most 31 characters, none of `[]:*?/\`.
    static func sheetName(_ name: String) -> String {
        let cleaned = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
        return cleaned.isEmpty ? "Sheet" : cleaned
    }

    /// Escaped for XML, with the characters XML 1.0 cannot carry removed.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - ZIP, stored

    private static func archive(_ files: [(name: String, data: Data)], modified: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        let year = min(max((parts.year ?? 1980) - 1980, 0), 127)
        let dosDate = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        let dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        /// Bit 11: names are UTF-8.
        let flags: UInt16 = 0x0800

        var bytes = Data()
        var central = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let checksum = crc32(file.data)
            let offset = UInt32(bytes.count)
            let size = UInt32(file.data.count)

            bytes.append(le: UInt32(0x0403_4B50))
            bytes.append(le: UInt16(20))
            bytes.append(le: flags)
            bytes.append(le: UInt16(0))
            bytes.append(le: dosTime)
            bytes.append(le: dosDate)
            bytes.append(le: checksum)
            bytes.append(le: size)
            bytes.append(le: size)
            bytes.append(le: UInt16(name.count))
            bytes.append(le: UInt16(0))
            bytes.append(name)
            bytes.append(file.data)

            central.append(le: UInt32(0x0201_4B50))
            central.append(le: UInt16(20))
            central.append(le: UInt16(20))
            central.append(le: flags)
            central.append(le: UInt16(0))
            central.append(le: dosTime)
            central.append(le: dosDate)
            central.append(le: checksum)
            central.append(le: size)
            central.append(le: size)
            central.append(le: UInt16(name.count))
            central.append(le: UInt16(0))
            central.append(le: UInt16(0))
            central.append(le: UInt16(0))
            central.append(le: UInt16(0))
            central.append(le: UInt32(0))
            central.append(le: offset)
            central.append(name)
        }

        let centralOffset = UInt32(bytes.count)
        bytes.append(central)
        bytes.append(le: UInt32(0x0605_4B50))
        bytes.append(le: UInt16(0))
        bytes.append(le: UInt16(0))
        bytes.append(le: UInt16(files.count))
        bytes.append(le: UInt16(files.count))
        bytes.append(le: UInt32(central.count))
        bytes.append(le: centralOffset)
        bytes.append(le: UInt16(0))
        return bytes
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xEDB8_8320 : 0) }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func append<Value: FixedWidthInteger>(le value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
