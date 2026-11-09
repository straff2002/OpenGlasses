import Foundation
#if canImport(OpenGlasses)
@testable import OpenGlasses
#endif

/// Invented tables for Plan JJ P0, laid out as text at known positions so a test can draw them
/// into a real PDF text layer (`TableFixtures`) or hand them to the extractor as positioned words.
///
/// Every label, designation and value here is made up — "Table 99", "QXRT", "rating group" — and
/// nothing is a fact from any book. Pure Foundation, no UIKit, so the same layouts can be drawn
/// on a Mac beside the extractor's own sources.
enum TableFixtureLayouts {

    /// One run of text: where its top-left corner sits on a US Letter page (top-down points), its
    /// point size, and whether it is bold.
    struct Item: Equatable {
        var text: String
        var x: Double
        var y: Double
        var size: Double = 9
        var bold = false
    }

    typealias Page = [Item]

    static let pageWidth = 612.0
    static let pageHeight = 792.0

    private static func caption(_ text: String, y: Double = 60) -> Item {
        Item(text: text, x: 50, y: y, size: 10, bold: true)
    }

    private static func row(_ y: Double, _ cells: [(String, Double)], size: Double = 9, bold: Bool = false) -> [Item] {
        cells.filter { !$0.0.isEmpty }.map { Item(text: $0.0, x: $0.1, y: y, size: size, bold: bold) }
    }

    /// A printed page number in the footer band, so the page has a printed label.
    private static func footer(_ number: String) -> Item {
        Item(text: number, x: 300, y: pageHeight - 40, size: 9)
    }

    /// A short paragraph above the table, so the page reads like a page of a book.
    private static func lead(_ y: Double = 30) -> Item {
        Item(text: "The values below are invented for a test and describe nothing real.", x: 50, y: y)
    }

    // MARK: - A simple grid with two row-header columns

    static let ratingColumns: [(String, Double)] = [("Designation", 50), ("Conductors", 140),
                                                    ("Rating group 1", 250), ("Rating group 2", 350),
                                                    ("Rating group 3", 450)]

    /// Table 99, a grid whose designation is printed once over the two rows under it. `offset` is
    /// added to every value, so a second invented book can print the same table with other values.
    static func simpleGrid(printed: String = "12", offset: Int = 0) -> Page {
        var items = [lead(), caption("TABLE 99 Conductor ratings")]
        items += row(90, ratingColumns, bold: true)
        let values: [[Int]] = [[25, 30, 35], [30, 35, 40], [40, 45, 50], [45, 50, 55]]
        let heads = [["QXRT", "two conductors"], ["", "three conductors"], ["QMX90", "two conductors"], ["", "three conductors"]]
        let body: [[String]] = zip(heads, values).map { head, row in head + row.map { String($0 + offset) } }
        for (index, cells) in body.enumerated() {
            items += row(106 + Double(index) * 14, zip(cells, [50, 140, 270, 370, 470]).map { ($0, $1) })
        }
        items.append(footer(printed))
        return items
    }

    // MARK: - A two-level column header

    /// Table 98: group headings each centred over three columns, the columns' own headings under
    /// them.
    static func twoLevelHeader() -> Page {
        var items = [caption("TABLE 98 Correction factors")]
        items.append(Item(text: "Rating group 1", x: 222, y: 90, bold: true))
        items.append(Item(text: "Rating group 2", x: 402, y: 90, bold: true))
        items += row(104, [("Ambient (°C)", 50), ("Band A", 200), ("Band B", 250), ("Band C", 300),
                           ("Band A", 380), ("Band B", 430), ("Band C", 480)], bold: true)
        let body: [[String]] = [
            ["7-9", "1.13", "1.09", "1.07", "1.12", "1.08", "1.06"],
            ["10-12", "0.99", "0.98", "0.97", "0.98", "0.97", "0.96"],
            ["13-15", "0.83", "0.87", "0.89", "0.82", "0.86", "0.88"],
            ["16-18", "0.71", "0.76", "0.79", "0.69", "0.74", "0.77"],
        ]
        for (index, cells) in body.enumerated() {
            items += row(120 + Double(index) * 14, zip(cells, [50, 200, 250, 300, 380, 430, 480]).map { ($0, $1) })
        }
        return items
    }

    // MARK: - Units in the header and in a cell

    /// Table 97: units in brackets in the headings, and one column whose cells carry their own.
    static func unitsInHeader() -> Page {
        var items = [caption("TABLE 97 Run lengths")]
        items += row(90, [("Size", 50), ("Length (m)", 160), ("Drop (V)", 280), ("Load", 400)], bold: true)
        let body: [[String]] = [
            ["QX4", "12.5", "0.8", "16 A"],
            ["QX6", "20", "1.1", "25 A"],
            ["QX10", "32.5", "1.4", "32 A"],
        ]
        for (index, cells) in body.enumerated() {
            items += row(106 + Double(index) * 14, zip(cells, [50, 160, 280, 400]).map { ($0, $1) })
        }
        return items
    }

    // MARK: - Words in the cells

    /// Table 90 (Plan JJ P2): which band of Table 98 a number of conductors in a run falls in —
    /// a range key and a cell of words, which a rule chain reads into Table 98's column.
    static func groupingBands() -> Page {
        var items = [caption("TABLE 90 Grouping bands")]
        items += row(90, [("Conductors in run", 50), ("Band", 220)], bold: true)
        let body: [[String]] = [["1-3", "Band A"], ["4-6", "Band B"], ["7-9", "Band C"]]
        for (index, cells) in body.enumerated() {
            items += row(106 + Double(index) * 14, zip(cells, [50, 220]).map { ($0, $1) })
        }
        return items
    }

    // MARK: - A table continued over two pages

    /// Table 96 over two pages: the second page's caption reads "(Continued)" and repeats the
    /// header.
    static func continued() -> [Page] {
        func half(_ caption: String, _ rows: [[String]], printed: String) -> Page {
            var items = [Self.caption(caption)]
            items += row(90, [("Designation", 50), ("Spacing (mm)", 200)], bold: true)
            for (index, cells) in rows.enumerated() {
                items += row(106 + Double(index) * 14, zip(cells, [50, 210]).map { ($0, $1) })
            }
            items.append(footer(printed))
            return items
        }
        return [
            half("TABLE 96 Spacing", [["QA1", "10"], ["QA2", "12"], ["QA3", "14"]], printed: "40"),
            half("TABLE 96 (Continued)", [["QA4", "16"], ["QA5", "18"], ["QA6", "20"]], printed: "41"),
        ]
    }

    // MARK: - Footnotes

    /// Table 95: an asterisk, a superscript digit and a lettered marker on cells, and the notes
    /// printed under the table.
    static func footnotes() -> Page {
        var items = [caption("TABLE 95 Rating limits")]
        items += row(90, [("Designation", 50), ("Limit (A)", 200)], bold: true)
        items += row(106, [("QXRT", 50), ("40*", 210)])
        items += row(120, [("QMX90", 50), ("45", 210)])
        // A superscript 1, smaller and raised, right after the 45.
        items.append(Item(text: "1", x: 221, y: 118, size: 6))
        items += row(134, [("QZ12", 50), ("50 (a)", 210)])
        items.append(Item(text: "* Value for a dry location.", x: 50, y: 156, size: 8))
        items.append(Item(text: "1", x: 50, y: 168, size: 5.5))
        items.append(Item(text: "Use only with rating group 2.", x: 55, y: 170, size: 8))
        items.append(Item(text: "(a) Applies inside an enclosure.", x: 50, y: 182, size: 8))
        return items
    }

    // MARK: - A text layer with no bold

    /// Table 95 on a page set in one weight, caption, header and rows alike — a text layer with no
    /// bold anywhere. `boldElsewhere` adds one bold line above it, which makes the page one that
    /// does carry weight, where the plain caption line is not a caption.
    static func singleFontGrid(boldElsewhere: Bool = false) -> Page {
        var items: [Item] = []
        if boldElsewhere { items.append(Item(text: "Invented section heading", x: 50, y: 30, bold: true)) }
        items.append(Item(text: "Table 95 Spacing limits", x: 50, y: 60))
        items += row(90, [("Designation", 50), ("Limit (A)", 200), ("Spacing (mm)", 320)])
        let body: [[String]] = [["QA7", "14", "26"], ["QA8", "17", "31"], ["QA9", "23", "38"], ["QA11", "29", "44"]]
        for (index, cells) in body.enumerated() {
            items += row(106 + Double(index) * 14, zip(cells, [50, 210, 330]).map { ($0, $1) })
        }
        return items
    }

    /// Table 94 on a page with no bold, its long title wrapping onto two more lines under the
    /// caption before the header — lines that read as prose once there is no weight to tell them
    /// apart.
    static func singleFontWrappedTitle() -> Page {
        var items = [Item(text: "Table 94 Invented spacing limits", x: 50, y: 60),
                     Item(text: "for the invented designations set out in this example, arranged for a test", x: 50, y: 71),
                     Item(text: "of a title that wraps", x: 50, y: 82)]
        items += row(100, [("Designation", 50), ("Limit (A)", 200), ("Spacing (mm)", 320)])
        let body: [[String]] = [["QB2", "11", "19"], ["QB3", "13", "22"], ["QB5", "16", "27"]]
        for (index, cells) in body.enumerated() {
            items += row(116 + Double(index) * 14, zip(cells, [50, 210, 330]).map { ($0, $1) })
        }
        return items
    }

    /// Table 96 on a page with no bold whose cells are all words: no row of numbers to find the
    /// body by, so the first run of rows of cells starts the grid and its first line heads it.
    static func singleFontTextGrid() -> Page {
        var items = [Item(text: "Table 96 Invented mounting choices", x: 50, y: 60),
                     Item(text: "for the invented designations of this example", x: 50, y: 71)]
        let body: [[String]] = [["Designation", "Indoor", "Outdoor"],
                                ["QXRT", "permitted", "not permitted"],
                                ["QMX90", "permitted", "permitted"],
                                ["QZ12", "not permitted", "permitted"]]
        for (index, cells) in body.enumerated() {
            items += row(90 + Double(index) * 14, zip(cells, [50, 200, 340]).map { ($0, $1) })
        }
        return items
    }

    /// Plain prose that begins with a reference to a table, on a page with no bold: a long line
    /// that is not a caption, then a short one that reads like one, and no grid under either.
    static func proseTableReference() -> Page {
        [Item(text: "Table 95 shows the limits that apply to every invented designation on this page and the next.", x: 50, y: 60),
         Item(text: "Each limit is described in words in the paragraph that follows the list of invented items.", x: 50, y: 74),
         Item(text: "Table 95 shows the limits.", x: 50, y: 102),
         Item(text: "Nothing on this page is set out in rows or columns of any kind, and every line is prose.", x: 50, y: 116)]
    }

    // MARK: - Labels with a letter (Plan JJ P5)

    /// A two-column bold grid under `caption`, its first values starting at `first`.
    private static func smallGrid(_ caption: String, names: [String], first: Int, printed: String? = nil) -> Page {
        var items = [Self.caption(caption)]
        items += row(90, [("Designation", 50), ("Limit (A)", 200)], bold: true)
        for (index, name) in names.enumerated() {
            items += row(106 + Double(index) * 14, [(name, 50), (String(first + 2 * index), 210)])
        }
        if let printed { items.append(footer(printed)) }
        return items
    }

    /// Four pages: Table 95, then Table 95A, then Table 95A continued, then Table 95B — four
    /// captions that share a number and differ by a letter or by none.
    static func letteredLabels() -> [Page] {
        [smallGrid("TABLE 95 Invented limits", names: ["QA1", "QA2", "QA3"], first: 10),
         smallGrid("TABLE 95A Invented clearances", names: ["QB1", "QB2", "QB3"], first: 30),
         smallGrid("TABLE 95A (Continued)", names: ["QB4", "QB5", "QB6"], first: 36),
         smallGrid("TABLE 95B Invented spacings", names: ["QC1", "QC2", "QC3"], first: 50)]
    }

    // MARK: - A table continued onto a page with no caption (Plan JJ P5)

    /// Table 96 on a page set in one weight, its rows running to the foot of the page and on over
    /// the next, which prints no caption of its own: a running head, optionally the column headings
    /// again, then more rows at the same column positions. `sameColumns: false` sets the second
    /// page's rows at other positions, as a different table's would be.
    static func captionlessContinuation(sameColumns: Bool = true, repeatHeader: Bool = false) -> [Page] {
        let heads: [(String, Double)] = [("Designation", 50), ("Indoor (mm)", 200), ("Outdoor (mm)", 330)]
        let xs: [Double] = sameColumns ? [50, 210, 340] : [50, 120, 450]
        var first: Page = [lead(), Item(text: "Table 96 Invented clearances", x: 50, y: 60)]
        first += row(90, heads)
        for (index, cells) in [["QA1", "10", "20"], ["QA2", "12", "24"], ["QA3", "14", "28"]].enumerated() {
            first += row(106 + Double(index) * 14, zip(cells, [50, 210, 340]).map { ($0, $1) })
        }
        first.append(footer("40"))
        var second: Page = [Item(text: "Invented manual, chapter nine", x: 50, y: 30)]
        var y = 60.0
        if repeatHeader {
            second += row(y, heads)
            y += 16
        }
        for (index, cells) in [["QA4", "16", "32"], ["QA5", "18", "36"], ["QA6", "20", "40"]].enumerated() {
            second += row(y + Double(index) * 14, zip(cells, xs).map { ($0, $1) })
        }
        second.append(footer("41"))
        return [first, second]
    }

    // MARK: - Marks in the cells (Plan JJ P5)

    /// Table 98 on a page set in one weight, its cells marks rather than numbers — a cross, a tick,
    /// a dash — and some left blank, so no two rows need print the same columns.
    static func tickMarks() -> Page {
        var items = [Item(text: "Table 98 Invented locations", x: 50, y: 60)]
        items += row(90, [("Designation", 50), ("North", 200), ("South", 260), ("East", 320), ("West", 380)])
        let marks = [205.0, 265, 325, 385]
        let body: [(String, [String])] = [
            ("QXRT", ["X", "X", "", ""]),
            ("QMX90", ["X", "", "X", ""]),
            ("QZ12", ["", "\u{2713}", "\u{2713}", "\u{2713}"]),
            ("QA7", ["X", "X", "X", "X"]),
            ("QB2", ["\u{2014}", "X", "", "X"]),
        ]
        for (index, entry) in body.enumerated() {
            let y = 106 + Double(index) * 14
            items += row(y, [(entry.0, 50)] + zip(entry.1, marks).map { ($0, $1) })
        }
        return items
    }

    // MARK: - Two groups side by side under one caption (Plan JJ P5)

    /// Table Q7 on a page set in one weight: two designation / limit pairs side by side, the right
    /// one a row shorter. `groupHeadings` prints a heading over each pair.
    static func sideBySide(groupHeadings: Bool = false) -> Page {
        var items = [Item(text: "Table Q7 Invented band limits", x: 50, y: 60)]
        var y = 90.0
        if groupHeadings {
            items += row(y, [("Rating group 1", 60), ("Rating group 2", 330)])
            y += 14
        }
        items += row(y, [("Designation", 50), ("Limit (A)", 150), ("Designation", 320), ("Limit (A)", 420)])
        let left = [["QA1", "10"], ["QA2", "12"], ["QA3", "14"], ["QA4", "16"]]
        let right = [["QB1", "20"], ["QB2", "22"], ["QB3", "24"]]
        for index in left.indices {
            var cells = [(left[index][0], 50.0), (left[index][1], 160.0)]
            if index < right.count { cells += [(right[index][0], 320), (right[index][1], 430)] }
            items += row(y + 16 + Double(index) * 14, cells)
        }
        return items
    }

    // MARK: - Headings stacked deep (Plan JJ P5)

    /// Table 95B on a page set in one weight, its column headings wrapped over six lines, so its
    /// first row of numbers sits further under the caption than a short header reaches.
    static func deepHeadings() -> Page {
        var items = [Item(text: "Table 95B Invented ratings by band", x: 50, y: 60)]
        let stacks: [[String]] = [["Rating", "group 1", "at the", "invented", "ambient", "(A)"],
                                  ["Rating", "group 2", "at the", "invented", "ambient", "(A)"],
                                  ["Rating", "group 3", "at the", "invented", "ambient", "(A)"]]
        for level in 0..<6 {
            let y = 80 + Double(level) * 11
            var cells = stacks.enumerated().map { ($0.element[level], 200 + Double($0.offset) * 90) }
            if level == 5 { cells.insert(("Designation", 50), at: 0) }
            items += row(y, cells)
        }
        let body: [[String]] = [["QA1", "11", "12", "13"], ["QA2", "21", "22", "23"],
                                ["QA3", "31", "32", "33"], ["QA4", "41", "42", "43"]]
        for (index, cells) in body.enumerated() {
            items += row(150 + Double(index) * 14, zip(cells, [50, 210, 300, 390]).map { ($0, $1) })
        }
        return items
    }

    // MARK: - Headings printed as numbers (Plan JJ P5)

    /// Table 99 on a page set in one weight: a heading over the three value columns, and under it
    /// the columns' own headings printed as numbers on the same line as the row-header heading.
    static func numberedHeadings() -> Page {
        var items = [Item(text: "Table 99 Invented ratings by conductors", x: 50, y: 60)]
        items += row(84, [("Conductors in the run", 262)])
        items += row(98, [("Designation", 50), ("2", 212), ("3", 302), ("4 or more", 392)])
        let body: [[String]] = [["QXRT", "25", "30", "35"], ["QMX90", "30", "35", "40"], ["QZ12", "40", "45", "50"]]
        for (index, cells) in body.enumerated() {
            items += row(114 + Double(index) * 14, zip(cells, [50, 210, 300, 390]).map { ($0, $1) })
        }
        return items
    }

    // MARK: - A list of tables (Plan JJ P5)

    /// A page that lists two tables by caption, then the two tables on their own pages.
    static func listOfTables() -> [Page] {
        let list: Page = [Item(text: "Invented list of tables", x: 50, y: 40),
                          Item(text: "Table 95A Invented clearances 2", x: 50, y: 60),
                          Item(text: "Table 95B Invented spacings 3", x: 50, y: 72)]
        func grid(_ caption: String, _ names: [String], first: Int) -> Page {
            var items = [Item(text: caption, x: 50, y: 60)]
            items += row(90, [("Designation", 50), ("Limit (A)", 200)])
            for (index, name) in names.enumerated() {
                items += row(106 + Double(index) * 14, [(name, 50), (String(first + 2 * index), 210)])
            }
            return items
        }
        return [list, grid("Table 95A Invented clearances", ["QB1", "QB2", "QB3"], first: 30),
                grid("Table 95B Invented spacings", ["QC1", "QC2", "QC3"], first: 50)]
    }

    // MARK: - A caption at the foot of a page (Plan JJ P5)

    /// Table 96 captioned at the foot of a page of prose, its headings and rows on the next page
    /// under a running head.
    static func captionAtFoot() -> [Page] {
        var first: Page = (0..<12).map { index in
            Item(text: "Paragraph line \(index + 1) of an invented manual describes general care of the unit.",
                 x: 50, y: 80 + Double(index) * 14)
        }
        first.append(Item(text: "Table 96 Invented clearances", x: 50, y: 700))
        first.append(footer("40"))
        var second: Page = [Item(text: "Invented manual, chapter nine", x: 50, y: 30)]
        second += row(60, [("Designation", 50), ("Indoor (mm)", 200), ("Outdoor (mm)", 330)])
        for (index, cells) in [["QA1", "10", "20"], ["QA2", "12", "24"], ["QA3", "14", "28"], ["QA4", "16", "32"]].enumerated() {
            second += row(76 + Double(index) * 14, zip(cells, [50, 210, 340]).map { ($0, $1) })
        }
        second.append(footer("41"))
        return [first, second]
    }

    // MARK: - A table printed with no text (Plan JJ P5)

    /// Table 97 on a page set in one weight: its caption and a paragraph under it, then nothing
    /// until the footer — where a book prints the table as a picture, the text layer has no grid.
    static func tableWithoutText() -> Page {
        [Item(text: "Table 97 Invented resistances", x: 50, y: 60),
         Item(text: "The invented values below apply to every invented designation in this example and to", x: 50, y: 80),
         Item(text: "nothing else, and they are given here only so that a test has a paragraph to read.", x: 50, y: 92),
         footer("44")]
    }

    /// Table Q7 again, side by side, with a word over each pair's value column set on a line of its
    /// own — the left one wide enough that, stretched to the gap, it also reaches the right pair's
    /// key column, so the two pairs' headings come out as different paths that read alike.
    static func sideBySideSplitHeadings() -> Page {
        var items = [Item(text: "Table Q7 Invented band limits", x: 50, y: 60)]
        items += row(90, [("Maximum", 220), ("Maximum", 400)])
        items += row(102, [("Designation", 130), ("limit (A)", 220), ("Designation", 310), ("limit (A)", 400)])
        let left = [["QA1", "10"], ["QA2", "12"], ["QA3", "14"]]
        let right = [["QB1", "20"], ["QB2", "22"], ["QB3", "24"]]
        for index in left.indices {
            items += row(118 + Double(index) * 14, [(left[index][0], 130), (left[index][1], 222),
                                                    (right[index][0], 310), (right[index][1], 402)])
        }
        return items
    }

    // MARK: - Pages that are not tables

    /// A drawing with numbers on it, captioned as a figure: no table caption, nothing to extract.
    static func drawingFigure() -> Page {
        [Item(text: "FIGURE 94 Terminal block", x: 50, y: 60, size: 10, bold: true)] + scatteredLabels()
    }

    /// The same labels under a table caption: they do not resolve to a grid. `pitch` is the
    /// spacing of the label rows; set close, they read as rows whose columns never line up.
    static func drawingUnderTableCaption(pitch: Double = 30) -> Page {
        [caption("TABLE 93 Terminal layout")] + scatteredLabels(pitch: pitch)
    }

    private static func scatteredLabels(pitch: Double = 30) -> [Item] {
        let y = { (row: Double) in 100 + row * pitch }
        return [
            Item(text: "L1", x: 80, y: y(0), size: 7), Item(text: "24", x: 300, y: y(0), size: 7),
            Item(text: "N", x: 150, y: y(1), size: 7), Item(text: "120", x: 420, y: y(1), size: 7),
            Item(text: "T2", x: 500, y: y(1), size: 7),
            Item(text: "6", x: 60, y: y(2), size: 7), Item(text: "GND", x: 260, y: y(2), size: 7),
            Item(text: "35", x: 120, y: y(3), size: 7), Item(text: "X4", x: 330, y: y(3), size: 7),
            Item(text: "12", x: 470, y: y(3), size: 7), Item(text: "7", x: 540, y: y(3), size: 7),
            Item(text: "S3", x: 200, y: y(4), size: 7),
        ]
    }

    /// A table caption over a paragraph: a caption with no grid under it.
    static func captionOverProse() -> Page {
        [caption("TABLE 92 Wiring notes"),
         Item(text: "Each terminal in this invented example is described in the paragraph that follows,", x: 50, y: 90),
         Item(text: "which runs on for several lines and carries no columns of any kind at all, so a", x: 50, y: 104),
         Item(text: "reader sees prose where the caption promised a table of values to look up.", x: 50, y: 118)]
    }

    /// A long table, for the row-passage cap.
    static func longTable(rows count: Int) -> Page {
        var items = [caption("TABLE 91 Long list", y: 20)]
        items += row(36, [("Item", 50), ("Value", 200)], bold: true)
        for index in 0..<count {
            items += row(50 + Double(index) * 11, [("QL\(index + 1)", 50), ("\(index + 1)", 210)], size: 8)
        }
        return items
    }

    // MARK: - A margin mark, a concluding page, a folio beside the footer text (Plan JW P0)

    /// Table 99 with a revision mark set in the margin on its caption's own line, far to the left
    /// of the word TABLE, in a weight of its own. `bold` sets the caption and the header in bold,
    /// with the mark not; without, the whole page is set in one weight.
    static func markedCaption(bold: Bool = true, mark: String = "\u{0394}") -> Page {
        var items = [Item(text: mark, x: 18, y: 60, size: 10),
                     Item(text: "TABLE 99 Widget ratings", x: 50, y: 60, size: 10, bold: bold)]
        items += row(90, [("Widget", 50), ("Rating A", 200), ("Rating B", 320)], bold: bold)
        let body: [[String]] = [["W1", "11", "21"], ["W2", "13", "24"], ["W3", "17", "29"], ["W4", "19", "33"]]
        for (index, cells) in body.enumerated() {
            items += row(106 + Double(index) * 14, zip(cells, [50, 210, 330]).map { ($0, $1) })
        }
        return items
    }

    /// Table 98A over two pages, the second captioned "(Concluded)" and carrying only the table's
    /// notes. `readable` false puts prose under the first page's caption instead of a grid.
    static func concluded(readable: Bool = true) -> [Page] {
        var first = [caption("TABLE 98A Widget limits")]
        if readable {
            first += row(90, [("Widget", 50), ("Limit (A)", 200)], bold: true)
            for (index, name) in ["W5", "W6", "W7", "W8"].enumerated() {
                first += row(106 + Double(index) * 14, [(name, 50), (String(31 + 4 * index), 210)])
            }
        } else {
            first += (0..<6).map { index in
                Item(text: "Line \(index + 1) of prose under the caption describes the invented widgets in words.",
                     x: 50, y: 90 + Double(index) * 14)
            }
        }
        first.append(footer("40"))
        let second = [caption("TABLE 98A (Concluded)"),
                      Item(text: "Notes:", x: 50, y: 90, size: 8),
                      Item(text: "1) The invented limits apply to dry widgets only.", x: 50, y: 102, size: 8),
                      Item(text: "2) Every value here is made up for a test.", x: 50, y: 114, size: 8),
                      footer("41")]
        return [first, second]
    }

    /// The footer line a book prints its folio at the end of, beside a date and a copyright
    /// notice whose years are the same on every page.
    static func footerWithFolio(_ folio: Int) -> String {
        "March 2031 \u{00A9} 2031 Example Standards Body \(folio)"
    }

    /// A page of prose whose footer line ends with its folio.
    static func folioPage(_ folio: Int) -> Page {
        [lead(60), Item(text: footerWithFolio(folio), x: 50, y: pageHeight - 40, size: 8)]
    }

    // MARK: - Headings printed as quantities, a sparse first row, rows in bands, a turned page (Plan JW follow-up)

    /// Table 99 on a page set in one weight: a margin mark, a title wrapping three lines and a
    /// long bracketed line under it, a row-header heading wrapped over three lines with the value
    /// columns' headings printed as quantities ("40 kg‡") on the same lines, row keys with a
    /// marker glued to them, and notes keyed by the double dagger, the section sign, two
    /// asterisks and "Note:". Every word and value is invented.
    static func quantityHeadings() -> Page {
        var items = [Item(text: "\u{0394}", x: 53, y: 60, size: 12),
                     Item(text: "Table 99", x: 285, y: 60, size: 12),
                     Item(text: "Invented loads for not more than three widgets in one crate,", x: 117, y: 74, size: 12),
                     Item(text: "stacked no more than two crates high and kept dry", x: 128, y: 88, size: 12),
                     Item(text: "(based on an invented room of 20 degrees*)", x: 181, y: 102, size: 12),
                     Item(text: "(See the invented notes, the example rules and the other example tables.)",
                          x: 120, y: 116, size: 11),
                     Item(text: "Load\u{2020},\u{00A7}", x: 175, y: 146, size: 10),
                     Item(text: "Widget,", x: 106, y: 158, size: 10)]
        items += row(170, [("size or", 106), ("85 kg\u{2021}", 320), ("100 kg\u{2021}", 385), ("150 kg\u{2021}", 449)], size: 10)
        items += row(182, [("grade", 106), ("40 kg\u{2021}", 173), ("55 kg\u{2021}", 223), ("70 kg\u{2021}", 270),
                           ("See Note", 320), ("See Note", 385), ("See Note", 449)], size: 10)
        for (index, key) in quantityKeys.enumerated() {
            let values = [11, 17, 23, 29, 34, 41].map { String($0 + 10 * index) }
            items += row(198 + Double(index) * 16, zip([key] + values, [106, 173, 223, 270, 320, 385, 449]).map { ($0, $1) },
                         size: 10)
        }
        items += [Item(text: "\u{2021} The invented loads are the most one crate may carry.", x: 72, y: 300, size: 10),
                  Item(text: "\u{00A7} See the example table for invented correction factors.", x: 72, y: 312, size: 10),
                  Item(text: "** See the example rule for the smallest widgets.", x: 72, y: 324, size: 10),
                  Item(text: "Note: The invented loads apply to dry widgets only.", x: 72, y: 336, size: 10)]
        return items
    }

    static let quantityKeys = ["71**", "63**", "55", "47", "39", "31"]

    /// Table 98 on a page set in one weight, its value columns headed by a group heading over a
    /// row of numbers ("1 2 3 4") with a row of words under it ("Area,", "mm²"), a heading set
    /// alone over the rows, then rows of numbers.
    static func numberedColumnHeadings(group: String = "Plain widgets") -> Page {
        var items = [Item(text: "Table 98 Invented widget areas", x: 200, y: 60, size: 12),
                     Item(text: "Widget", x: 73, y: 90),
                     Item(text: "Number of widgets", x: 260, y: 100)]
        items += row(114, [("1", 160), ("2", 220), ("3", 280), ("4", 340)])
        items += row(126, [("Widget size", 73), ("Area,", 155), ("Area,", 215), ("Area,", 275), ("Area,", 335)])
        items += row(136, [("grade", 73), ("mm\u{00B2}", 157), ("mm\u{00B2}", 217), ("mm\u{00B2}", 277), ("mm\u{00B2}", 337)])
        items.append(Item(text: group, x: 230, y: 150))
        for (index, key) in ["W2", "W4", "W6", "W8"].enumerated() {
            let base = 5 + 2 * index
            // Spelled out in steps: as one expression it exceeds CI's type-check time limit.
            var cells: [(String, Double)] = [(key, 73)]
            for column in 1...4 {
                let x: Double = 152 + 60 * Double(column - 1)
                cells.append((String(base * column), x))
            }
            let y: Double = 166 + Double(index) * 14
            items += row(y, cells)
        }
        return items
    }

    /// Table 98 carried on to a second page (Plan KR follow-up): the page of
    /// `numberedColumnHeadings` with its heading over the rows set wider than a column, then a page
    /// that prints its headings again under a "(Concluded)" caption — or, `captioned` false, under
    /// no caption — and a second heading set alone over its rows, over rows that print the same
    /// widget sizes again.
    static func groupedRowsOverTwoPages(captioned: Bool) -> [Page] {
        let first = numberedColumnHeadings(group: "Plain widgets of every grade")
        var next: Page = captioned ? [Item(text: "Table 98 (Concluded)", x: 200, y: 30, size: 12)] : []
        next += first.filter { $0.y >= 90 && $0.y < 150 }
        next.append(Item(text: "Ringed widgets of every grade", x: 210, y: 150))
        for (index, key) in ["W2", "W4", "W6"].enumerated() {
            var cells: [(String, Double)] = [(key, 73)]
            for column in 1...4 {
                let x: Double = 152 + 60 * Double(column - 1)
                cells.append((String(100 + 10 * index + column), x))
            }
            let y: Double = 166 + Double(index) * 14
            next += row(y, cells)
        }
        return [first, next]
    }

    // MARK: - A short table under counted headings (Plan KR follow-up)

    /// Table 97 on a page set in one weight, laid out like a table of fill by how many widgets share
    /// a run: a title under the caption; a heading over every value column whose second line
    /// wraps ("… or multi-" over "widget bundles", narrower, set from the same edge); the columns'
    /// own headings a row of counts with nothing at the left ("1 2 3 Over 3"); and only two rows,
    /// each name wrapping onto a line of its own. `rowNamed` prints a word at the left of the
    /// counts, as a table's own first row would.
    static func countedFillTable(rowNamed: Bool = false) -> Page {
        var items = [Item(text: "Table 97", x: 285, y: 383, size: 12),
                     Item(text: "Invented most widget fill", x: 240, y: 397, size: 12),
                     Item(text: "Most fill of a widget run, %", x: 271, y: 441, size: 11),
                     Item(text: "Number of widgets or multi-", x: 271, y: 458, size: 11),
                     Item(text: "widget bundles", x: 271, y: 470, size: 11)]
        items += row(487, [(rowNamed ? "Counted" : "", 117), ("1", 271), ("2", 318), ("3", 364), ("Over 3", 411)], size: 11)
        items += row(504, [("Plain widgets or multi-", 117), ("51", 271), ("33", 318), ("42", 364), ("44", 411)], size: 11)
        items.append(Item(text: "widget bundles (plain)", x: 117, y: 516, size: 11))
        items += row(533, [("Ringed widgets or", 117), ("57", 271), ("29", 318), ("41", 364), ("37", 411)], size: 11)
        items.append(Item(text: "widget bundles", x: 117, y: 545, size: 11))
        return items
    }

    /// Table 99 on a page set in one weight whose first row prints a value in a few columns only,
    /// a dash in the rest.
    static func sparseFirstRow() -> Page {
        var items = [Item(text: "Table 99 Invented widget sizes", x: 200, y: 60, size: 12)]
        items += row(90, [("Widget", 50), ("Inner A", 120), ("Outer A", 180), ("Inner B", 240), ("Outer B", 300),
                          ("Inner C", 360), ("Outer C", 420)])
        let body: [[String]] = [["W1", "\u{2014}", "\u{2014}", "8.7", "64", "\u{2014}", "\u{2014}"],
                                ["W2", "13.3", "143", "12.8", "131", "11.9", "118"],
                                ["W3", "17.6", "241", "16.2", "212", "15.4", "188"],
                                ["W4", "22.9", "402", "21.7", "377", "20.3", "351"]]
        for (index, cells) in body.enumerated() {
            items += row(106 + Double(index) * 14, zip(cells, [50, 122, 182, 242, 302, 362, 422]).map { ($0, $1) })
        }
        return items
    }

    /// Table 98A with its rows printed in bands of three, a wider space between the bands.
    static func bandedRows() -> Page {
        var items = [caption("TABLE 98A Invented widget currents")]
        items += row(90, [("Widget", 50), ("Low (A)", 200), ("Mid (A)", 280), ("High (A)", 360)], bold: true)
        var y = 106.0
        for index in 0..<9 {
            if index > 0, index % 3 == 0 { y += 18 }
            items += row(y, [("W\(index + 1)", 50), (String(4 + index), 210), (String(8 + 2 * index), 290),
                             (String(12 + 3 * index), 370)])
            y += 14
        }
        return items
    }

    /// The table of a page the PDF turns a quarter to show (its `/Rotate` 90), as shown: on a
    /// page as wide as `pageHeight` and as tall as `pageWidth`, Table 98A with a margin mark, a
    /// heading line and five rows. Drawn turned by `TableFixtures.turned`.
    static func turnedTable() -> Page {
        var items = [Item(text: "\u{0394}", x: 68, y: 72, size: 12),
                     Item(text: "Table 98A", x: 370, y: 72, size: 12),
                     Item(text: "Invented widget ratings across a turned page", x: 250, y: 88, size: 12)]
        items += row(130, [("Widget", 73), ("Rating A", 200), ("Rating B", 300), ("Rating C", 400)])
        for (index, key) in ["W1", "W2", "W3", "W4", "W5"].enumerated() {
            items += row(150 + Double(index) * 16, [(key, 73), (String(11 + index), 205), (String(21 + 2 * index), 305),
                                                    (String(31 + 3 * index), 405)])
        }
        return items
    }

    /// The footer of that turned page, printed the page's own way up — so on its side as shown,
    /// alongside the table's rows.
    static func turnedFooter() -> Page {
        [Item(text: "March 2031 \u{00A9} 2031 Example Standards Body 41", x: 120, y: pageHeight - 30)]
    }

    // MARK: - As positioned words

    /// The page as the extractor's input, each item split into words at the advance a typical
    /// sans-serif gives its letters — what the pure tests feed `TableExtractor` without a PDF.
    static func words(_ page: Page) -> [PositionedWord] {
        var words: [PositionedWord] = []
        for item in page {
            var x = item.x
            for word in item.text.split(separator: " ") {
                let width = Double(word.count) * item.size * 0.55
                words.append(PositionedWord(String(word), x: x, y: item.y, size: item.size, bold: item.bold,
                                            width: width))
                x += width + item.size * 0.28
            }
        }
        return words
    }
}
