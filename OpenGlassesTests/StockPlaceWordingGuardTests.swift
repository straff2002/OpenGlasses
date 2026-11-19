import XCTest

/// Plan MK P1 — every word van stock says to the model about the place comes from
/// `StockPlaceWording`, so a store never hears "on the van".
///
/// A source scrape, like `DATExperimentalGuardTests`: no string literal in
/// `Services/FieldAssist/VanStock/` (beyond the files below), in `VanStockTool.swift`, or in the
/// marked stock lines of `JobCloseSequence.swift` and `PartsRequestTool.swift` may contain "van",
/// "truck", "base", "standard load" or "manuals" as a whole word. Comments are not scanned, nor is
/// the code inside an interpolation.
final class StockPlaceWordingGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let folder = "OpenGlasses/Sources/Services/FieldAssist/VanStock/"

    /// Files in the folder whose literals are not model sentences.
    private static let exemptFiles: [String: String] = [
        // The one place the words live.
        "StockPlaceWording.swift": "the wording itself",
        // Localised screen text, translated by the catalog, never read by the model.
        "StockPlaceScreenText.swift": "screen text, per kind on purpose",
        "VanStockRows.swift": "the screen's \"Not found in …\" mark, localised",
        // The workbook: its sheet name, its column words ("Base", "This truck") and the words its
        // reader accepts are a file format an older build and a spreadsheet both read.
        "VanStockSheet.swift": "the workbook's own names and markers",
    ]

    /// Contract strings that contain a place word and are not sentences. Each is cut out of a
    /// literal before it is checked. Kept short: a new one needs a reason here.
    private static let contractExceptions: [(text: String, reason: String)] = [
        ("van-stock.json", "the list's file on disk; renaming it would lose every phone's list"),
        ("van-stock-previous.json", "the list kept from before the last takeover, read back by name"),
        ("van-stock-export-", "the temporary folder an export is written into, never shown"),
    ]

    /// Words a model sentence may not say outside `StockPlaceWording`. `van_stock`,
    /// `send_to_base`, `not_from_van`, `on_van` and `for_van_stock` are identifiers in snake case,
    /// which a whole-word match does not see, so they need no exception.
    private static let words = ["van", "truck", "base", "standard load", "manuals"]

    /// Where the stock lines sit in the two files outside the folder.
    private static let markedFiles = [
        "OpenGlasses/Sources/Services/FieldAssist/Job/JobCloseSequence.swift",
        "OpenGlasses/Sources/Services/NativeTools/PartsRequestTool.swift",
    ]
    private static let begin = "stock-wording-guard:begin"
    private static let end = "stock-wording-guard:end"

    // MARK: - The scrape

    func testNoPlaceWordIsWrittenOutsideTheWording() throws {
        var offences: [String] = []
        let folderURL = Self.repoRoot.appendingPathComponent(Self.folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(files.contains("VanStockService.swift"), "the folder moved: \(folderURL.path)")
        for file in files where Self.exemptFiles[file] == nil {
            let source = try String(contentsOf: folderURL.appendingPathComponent(file), encoding: .utf8)
            offences += Self.offences(in: Self.lines(source), file: file)
        }

        let tool = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/Services/NativeTools/VanStockTool.swift"), encoding: .utf8)
        offences += Self.offences(in: Self.lines(tool), file: "VanStockTool.swift")

        for path in Self.markedFiles {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            let marked = Self.marked(source)
            XCTAssertFalse(marked.isEmpty, "\(path) has lost its \(Self.begin) / \(Self.end) markers")
            offences += Self.offences(in: marked, file: (path as NSString).lastPathComponent)
        }

        XCTAssertEqual(offences, [], "Say these through StockPlaceWording (Plan MK §3):\n" + offences.joined(separator: "\n"))
    }

    /// The guard sees what it is meant to: a place word in a plain literal, in a multi-line one,
    /// and not in a comment, an interpolation, an identifier or an exception.
    func testTheScrapeFindsWhatItShould() {
        let source = """
        // on the van, in a comment
        let a = "Loaded \\(van.name) on the \\(w.location)."
        let b = "No standard load is set."
        let c = \"\"\"
            Taken off the truck.
            \"\"\"
        let d = "call van_stock with action 'not_from_van'"
        let e = folder.appendingPathComponent("van-stock-export-1")
        let f = "nothing in the manuals"
        """
        let found = Self.offences(in: Self.lines(source), file: "Sample.swift")
        XCTAssertEqual(found.count, 3, found.joined(separator: "\n"))
        XCTAssertTrue(found.contains { $0.contains("standard load") })
        XCTAssertTrue(found.contains { $0.contains("truck") })
        XCTAssertTrue(found.contains { $0.contains("manuals") })
    }

    // MARK: - Pieces

    private struct Line {
        let number: Int
        let text: String
    }

    private static func lines(_ source: String) -> [Line] {
        source.components(separatedBy: "\n").enumerated().map { Line(number: $0.offset + 1, text: $0.element) }
    }

    /// The lines between each pair of markers.
    private static func marked(_ source: String) -> [Line] {
        var inside = false
        var kept: [Line] = []
        for line in lines(source) {
            if line.text.contains(begin) { inside = true; continue }
            if line.text.contains(end) { inside = false; continue }
            if inside { kept.append(line) }
        }
        return kept
    }

    /// Each literal that says a place word, as "File.swift:12: word in \"…\"".
    private static func offences(in lines: [Line], file: String) -> [String] {
        var found: [String] = []
        var inBlock = false
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            var literals: [String] = []
            if inBlock {
                if trimmed.hasPrefix("\"\"\"") { inBlock = false; continue }
                literals = [line.text]
            } else if trimmed.hasPrefix("//") {
                continue
            } else if trimmed.hasSuffix("\"\"\"") && trimmed.components(separatedBy: "\"\"\"").count == 2 {
                inBlock = true
                literals = []
            } else {
                literals = quoted(line.text)
            }
            for literal in literals {
                var text = withoutInterpolations(literal)
                for exception in contractExceptions { text = text.replacingOccurrences(of: exception.text, with: " ") }
                for word in words where says(word, in: text) {
                    found.append("\(file):\(line.number): \(word) in \"\(literal.trimmingCharacters(in: .whitespaces))\"")
                }
            }
        }
        return found
    }

    /// The string literals on one line, without their quotes.
    private static func quoted(_ line: String) -> [String] {
        // A trailing comment is not code; cut it where it starts outside a literal.
        var literals: [String] = []
        var current = ""
        var inside = false
        var escaped = false
        var depth = 0
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inside {
                if escaped {
                    escaped = false
                    current.append(character)
                    if character == "(" { depth += 1 }
                } else if character == "\\" {
                    escaped = true
                    current.append(character)
                } else if depth > 0 {
                    // Inside an interpolation a quote opens a nested literal; keep it with the code.
                    current.append(character)
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                } else if character == "\"" {
                    literals.append(current)
                    current = ""
                    inside = false
                } else {
                    current.append(character)
                }
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                break
            } else if character == "\"" {
                inside = true
            }
            index += 1
        }
        return literals
    }

    /// A literal with every `\( … )` taken out, so code inside it is not read as words.
    private static func withoutInterpolations(_ literal: String) -> String {
        var result = ""
        let characters = Array(literal)
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "(" {
                var depth = 1
                index += 2
                while index < characters.count, depth > 0 {
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
                result.append(" ")
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    private static func says(_ word: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
