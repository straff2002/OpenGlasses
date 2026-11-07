import XCTest
@testable import OpenGlasses

/// Plan KR P3 — the row, the table and the heading a lookup read, and a section the turn names.
/// Every table, title, heading, value, manual and section here is invented ("Table 98", "widget",
/// "Band 7"); generic trade words (aluminum, raceway, conduit, kV) shape the tables like the ones
/// the partner's retest used, and no cell, title or heading is taken from any book.
final class KRRowTableHeadingTests: XCTestCase {

    // MARK: - The aught row says it is the size asked

    private func sizes(_ rows: [(String, Double)]) -> TableLookup.Source {
        let page = ManualTable.Page(physical: 9, printed: "31")
        let table = ManualTable(
            label: "Table 98", title: "Invented ratings of widgets by gauge", page: page, rowHeaders: ["Gauge"],
            columns: [.init(path: ["Band 2"], unit: "A")],
            rows: rows.map { size, amps in
                ManualTable.Row(path: [size], cells: [.init(text: String(Int(amps)), value: amps, unit: "A")], page: page)
            })
        return .init(documentId: "inv", documentName: "Invented Book", table: table)
    }

    func testAnAughtRowSaysTheTablePrintsTheSizeAskedAnotherWay() throws {
        let zeros = sizes([("4", 11), ("3", 13), ("0000", 47), ("250", 52)])
        for asked in ["4/0", "four aught"] {
            guard case .found(let found) = TableLookup.resolve(.init(table: "Table 98", row: asked), in: [zeros]) else {
                return XCTFail("\(asked) found nothing")
            }
            XCTAssertEqual(found.basis, .awg, asked)
            XCTAssertNil(TableLookup.mismatchLine(found), "a size printed another way is the row asked: \(asked)")
            let text = TableLookup.render(.found(found))
            XCTAssertTrue(text.contains("row 0000 (this table prints 4/0, four aught, as 0000: the size asked) (page 31) — "
                                        + "column Band 2: \"47\""), text)
            XCTAssertTrue(text.contains("say the size as the technician said it (\"\(asked)\"), not as the table prints it"), text)
            XCTAssertFalse(text.contains("not the same row"), text)
        }

        // Asked as printed, nothing more is said.
        guard case .found(let exact) = TableLookup.resolve(.init(table: "Table 98", row: "0000"), in: [zeros]) else {
            return XCTFail("0000 found nothing")
        }
        XCTAssertEqual(exact.basis, .exact)
        XCTAssertFalse(TableLookup.render(.found(exact)).contains("the size asked"))

        // A table printing 4/0, asked as "0000": the row is named in the size's own form.
        let slashes = sizes([("4", 11), ("2/0", 33), ("4/0", 47)])
        guard case .found(let slash) = TableLookup.resolve(.init(table: "Table 98", row: "0000"), in: [slashes]) else {
            return XCTFail("0000 found nothing")
        }
        XCTAssertEqual(TableLookup.aughtNote(slash, row: slash.rows[0]), "4/0, four aught: the size asked")
        guard case .found(let two) = TableLookup.resolve(.init(table: "Table 98", row: "double aught"), in: [slashes]) else {
            return XCTFail("double aught found nothing")
        }
        XCTAssertEqual(TableLookup.aughtNote(two, row: two.rows[0]), "2/0, two aught: the size asked")
    }

    // MARK: - A unit's power written as a digit

    func testASquareWrittenAsATwoNamesTheHeadingPrintedWithTheSuperscript() throws {
        XCTAssertEqual(TableLookup.normalised("Area, mm2"), TableLookup.normalised("Area, mm²"))
        XCTAssertEqual(TableLookup.significantWords("12 m³"), TableLookup.significantWords("12 m3"))
        let page = ManualTable.Page(physical: 4)
        let table = ManualTable(
            label: "Table 97", title: "Invented tubing sizes", page: page, rowHeaders: ["Trade size"],
            columns: [.init(path: ["Tubing Q", "Area, mm²"]), .init(path: ["Tubing Q", "Area, mm"]),
                      .init(path: ["Tubing R", "Area, mm²"])],
            rows: [ManualTable.Row(path: ["16"], cells: [.init(text: "200", value: 200), .init(text: "16", value: 16),
                                                          .init(text: "190", value: 190)], page: page)])
        let source = TableLookup.Source(documentId: "t", documentName: "Invented Book", table: table)
        guard case .found(let found) = TableLookup.resolve(.init(table: "Table 97", row: "16", column: "Tubing Q › Area, mm2"),
                                                           in: [source]) else {
            return XCTFail("the column written with a 2 is the one printed with ²")
        }
        XCTAssertEqual(found.columns, [0])
    }

    // MARK: - A heading that is only a note marker

    func testANoteMarkerIsNotAHeading() {
        for marker in ["Note", "notes", "Notes 2", "(Note)", "Note below", "*", "†", "‡"] {
            XCTAssertTrue(TableExtractor.isNoteMarkerHeading(marker), marker)
        }
        for heading in ["Band 7", "Notes on widgets", "No.", "2", "(A)", "Band 8 Note", ""] {
            XCTAssertFalse(TableExtractor.isNoteMarkerHeading(heading), heading)
        }
        XCTAssertEqual(TableExtractor.withoutNoteLeaf(["Band 7‡", "Note"]), ["Band 7‡"])
        XCTAssertEqual(TableExtractor.withoutNoteLeaf(["Note"]), ["Note"], "a marker alone is kept")
        XCTAssertEqual(TableExtractor.withoutNoteLeaf(["Rating", "Band 5"]), ["Rating", "Band 5"])
    }

    /// The retest's shape, invented: a stub heading at the far left, then on one line a heading
    /// printed over only the fourth value column, and under it the columns' own headings — a
    /// "Note" under the fourth and fifth. The fourth's heading reached back over the second and
    /// third by the midpoints alone.
    private static func noteMarkedPage() -> TableFixtureLayouts.Page {
        let xs = [150.0, 210, 270, 330, 390]
        var items = [TableFixtureLayouts.Item(text: "Table 98 Invented widget ratings by band", x: 50, y: 60, size: 10, bold: true)]
        func line(_ y: Double, _ cells: [(String, Double)]) {
            items += cells.map { TableFixtureLayouts.Item(text: $0.0, x: $0.1, y: y, bold: true) }
        }
        line(84, [("Rating", 150)])
        line(98, [("Gauge,", 50), ("Band 7‡", 325), ("Band 8‡", 385)])
        line(112, [("AWG", 50), ("Band 4‡", 145), ("Band 5‡", 205), ("Band 6‡", 265), ("Note", 322), ("Note", 382)])
        let body: [[String]] = [["14", "11", "12", "13", "14", "15"], ["12", "21", "22", "23", "24", "25"],
                                ["10", "31", "32", "33", "34", "35"], ["8", "41", "42", "43", "44", "45"]]
        for (index, cells) in body.enumerated() {
            let y = 128 + Double(index) * 14
            items += zip(cells, [50.0] + xs).map { TableFixtureLayouts.Item(text: $0, x: $1, y: y) }
        }
        return items
    }

    func testAHeadingOverOneColumnHeadsThatColumnOnly() throws {
        let found = TableExtractor.extractAll(words: TableFixtureLayouts.words(Self.noteMarkedPage()),
                                              page: ManualTable.Page(physical: 1))
        let table = try XCTUnwrap(found.first?.outcome.table, "\(String(describing: found.first?.outcome))")
        let paths = table.columns.map(\.path)
        XCTAssertEqual(paths.count, 5, "\(paths)")
        let withSeven = paths.indices.filter { paths[$0].joined(separator: " ").contains("Band 7") }
        XCTAssertEqual(withSeven, [3], "the heading heads the column it is printed over, and no other: \(paths)")
        XCTAssertEqual(paths[1].last, "Band 5‡", "\(paths)")
        XCTAssertEqual(paths[2].last, "Band 6‡", "\(paths)")
        XCTAssertFalse(paths.contains { $0.last == "Note" }, "a note marker is never a column's own heading: \(paths)")
        XCTAssertFalse(paths[0].contains("Gauge,"), "the stub's heading heads the rows, not a value column: \(paths)")

        let source = TableLookup.Source(documentId: "n", documentName: "Invented Book", table: table)
        guard case .found(let seven) = TableLookup.resolve(.init(table: "Table 98", row: "12", column: "Band 7"), in: [source]) else {
            return XCTFail("Band 7 is one column")
        }
        XCTAssertEqual(seven.columns, [3])
        XCTAssertEqual(seven.rows.first?.cells[3].text, "24")
    }

    /// Invented: a stub heading, then on one line "Capacity" over three columns and "Weight" over
    /// two, the columns' own headings under them. `capacityX`/`weightX` say where each group
    /// heading starts — set from the left over its first column, or centred over its group.
    private static func groupedPage(capacityX: Double, weightX: Double) -> TableFixtureLayouts.Page {
        let xs = [200.0, 260, 320, 430, 490]
        var items = [TableFixtureLayouts.Item(text: "Table 95 Invented widget capacities", x: 50, y: 60, size: 10, bold: true)]
        func line(_ y: Double, _ cells: [(String, Double)]) {
            items += cells.map { TableFixtureLayouts.Item(text: $0.0, x: $0.1, y: y, bold: true) }
        }
        line(84, [("Unit", 50), ("Capacity", capacityX), ("Weight", weightX)])
        line(98, [("Model", 50), ("Low", 198), ("Mid", 258), ("High", 316), ("Net", 428), ("Gross", 485)])
        let body: [[String]] = [["W2", "11", "12", "13", "14", "15"], ["W4", "21", "22", "23", "24", "25"],
                                ["W6", "31", "32", "33", "34", "35"], ["W8", "41", "42", "43", "44", "45"]]
        for (index, cells) in body.enumerated() {
            let y = 114 + Double(index) * 14
            items += zip(cells, [50.0] + xs).map { TableFixtureLayouts.Item(text: $0, x: $1, y: y) }
        }
        return items
    }

    /// A group heading set narrow from the left over three columns, and one centred over two or
    /// three, heads every column of its group: lookups by it still resolve.
    func testAGroupHeadingSetFromTheLeftOrCentredKeepsItsLevelInEveryColumn() throws {
        // "Capacity" is 39.6 points wide and "Weight" 29.7 at the fixtures' advance.
        for (name, capacityX, weightX) in [("left-set", 195.0, 428.0), ("centred", 245.2, 450.15)] {
            let found = TableExtractor.extractAll(words: TableFixtureLayouts.words(Self.groupedPage(capacityX: capacityX,
                                                                                                     weightX: weightX)),
                                                  page: ManualTable.Page(physical: 1))
            let table = try XCTUnwrap(found.first?.outcome.table, "\(name): \(String(describing: found.first?.outcome))")
            let paths = table.columns.map(\.path)
            XCTAssertEqual(paths.count, 5, "\(name): \(paths)")
            guard paths.count == 5 else { continue }
            for column in 0..<3 {
                XCTAssertEqual(paths[column].first, "Capacity", "\(name): the group heads all three: \(paths)")
            }
            for column in 3..<5 {
                XCTAssertEqual(paths[column].first, "Weight", "\(name): the group heads both: \(paths)")
            }
            XCTAssertEqual(paths.map(\.last), ["Low", "Mid", "High", "Net", "Gross"], "\(name): \(paths)")

            let source = TableLookup.Source(documentId: "g", documentName: "Invented Book", table: table)
            for (asked, column, cell) in [("Capacity › High", 2, "33"), ("Capacity Mid", 1, "32"), ("Weight › Gross", 4, "35")] {
                guard case .found(let hit) = TableLookup.resolve(.init(table: "Table 95", row: "W6", column: asked),
                                                                 in: [source]) else {
                    XCTFail("\(name): \(asked) found nothing")
                    continue
                }
                XCTAssertEqual(hit.columns, [column], "\(name): \(asked)")
                XCTAssertEqual(hit.rows.first?.cells[column].text, cell, "\(name): \(asked)")
            }
        }
    }

    /// A table already stored with the marker as a leaf, and its heading spread over its
    /// neighbours: the column whose own heading it is wins.
    func testAStoredColumnWhoseOwnHeadingMatchesWinsOverOnesThatOnlyCarryIt() throws {
        let page = ManualTable.Page(physical: 2)
        let table = ManualTable(
            label: "Table 96", title: "Invented widget ratings", page: page, rowHeaders: ["Gauge"],
            columns: [.init(path: ["Rating", "Band 7‡", "Band 5‡"]), .init(path: ["Band 7‡", "Band 6‡"]),
                      .init(path: ["Band 7‡", "Note"]), .init(path: ["Band 8‡ Note"])],
            rows: [ManualTable.Row(path: ["12"], cells: ["21", "22", "23", "24"].map { .init(text: $0, value: Double($0)) },
                                   page: page)])
        let source = TableLookup.Source(documentId: "s", documentName: "Invented Book", table: table)
        guard case .found(let found) = TableLookup.resolve(.init(table: "Table 96", row: "12", column: "Band 7"), in: [source]) else {
            return XCTFail("Band 7 is the third column's own heading")
        }
        XCTAssertEqual(found.columns, [2])
        guard case .ambiguous(.column, _, let both) = TableLookup.resolve(.init(table: "Table 96", row: "12", column: "Band"),
                                                                         in: [source]) else {
            return XCTFail("a word every heading carries still asks which")
        }
        XCTAssertEqual(both.count, 4)
    }

    // MARK: - The table hint says the conditions

    private static func entry(_ label: String, _ title: String, _ headings: [String]) -> TableReference.Entry {
        TableReference.Entry(label: label, title: title, documentName: "Invented Code Book", headings: headings)
    }

    /// Shaped like the retest's catalogue: medium-voltage buried-conduit tables that print
    /// "conduit" and a "ground wire" heading, a bonding table whose headings say "wire", and the
    /// ordinary raceway and free-air tables, which say "raceway" and "conductors".
    private static let codeBook: [TableReference.Entry] = [
        entry("Table 91", "Invented ampacities of three shielded single conductors in buried conduit, as Drawing 91",
              ["Gauge", "Shield ground wire size", "6 kV to 12 kV", "Copper", "Aluminum", "20 kV to 30 kV"]),
        entry("Table 92", "Invented ampacities of two sets of three shielded conductors in buried conduit, as Drawing 92",
              ["Gauge", "Shield ground wire size", "6 kV to 12 kV", "Copper", "Aluminum", "20 kV to 30 kV"]),
        entry("Table 93", "Invented least sizes of bonding jumpers for service conductors",
              ["Largest conductor, A", "Copper wire, AWG", "Aluminum wire, AWG", "Bus, mm²"]),
        entry("Table 94", "Invented ampacities of single aluminum conductors in free air, not over 900 V, at a 35 °C ambient",
              ["Gauge", "Rating", "Rating"]),
        entry("Table 95", "Invented ampacities of not more than three insulated copper conductors in a raceway or cable, "
              + "not over 900 V, at a 35 °C ambient", ["Gauge", "Rating › Grade 1", "Rating › Grade 2"]),
        entry("Table 97", "Invented ampacities of not more than three insulated aluminum conductors in a raceway or cable, "
              + "not over 900 V, at a 35 °C ambient", ["Gauge", "Rating › Grade 1", "Rating › Grade 2"]),
        entry("Table 99", "Invented spacing of supports for conductors in vertical raceways", ["Spacing, m", "Copper", "Aluminum"]),
        entry("Table 89", "Invented drying times for paint", ["Coat", "Hours"]),
    ] + fillers

    /// A code book prints many more tables than the ones a question is between: invented ones whose
    /// words (size, copper, aluminum, conductors) are as common as a book makes them.
    private static let fillers: [TableReference.Entry] = (60..<84).map { number in
        let subjects = ["bending radius of conductors", "box volume per conductor", "lug sizes for conductors",
                        "insulation thickness of conductors", "spacing of conductors on insulators",
                        "resistance of conductors", "weights of conductors", "terminal sizes"]
        return entry("Table \(number)", "Invented \(subjects[number % subjects.count]), set \(number)",
                     number % 2 == 0 ? ["Size, AWG", "Copper", "Aluminum"] : ["Gauge", "Size"])
    }

    func testATableTitleSaysTheConditionsItHoldsFor() {
        XCTAssertEqual(TableDirectory.conditions(of: Self.codeBook[5]).map(\.text),
                       ["aluminum", "not over 900 V", "in a raceway or cable", "not more than three", "35 °C ambient"])
        XCTAssertEqual(TableDirectory.conditions(of: Self.codeBook[3]).map(\.kind), [.material, .voltage, .run, .count, .ambient])
        XCTAssertEqual(TableDirectory.conditions(of: Self.codeBook[0]).map(\.text),
                       ["6 kV to 12 kV bands", "in buried conduit", "single"])
        XCTAssertTrue(TableDirectory.isKilovoltBand(Self.codeBook[0]))
        XCTAssertFalse(TableDirectory.isKilovoltBand(Self.codeBook[5]))
        XCTAssertEqual(TableDirectory.conditions(of: Self.codeBook[7]), [], "a table that prints no condition has none")
    }

    func testAQuestionInTheTradesWordsFindsTheRacewayTableNotTheBuriedKilovoltOne() throws {
        let question = "what size aluminum wire do I need in conduit for 100 amps"
        let offered = TableDirectory.candidates(for: question, in: Self.codeBook)
        XCTAssertEqual(offered.first?.entry.label, "Table 97",
                       "\(TableDirectory.ranked(question, in: Self.codeBook, asTechnicianSaid: true).prefix(5).map { ($0.entry.label, $0.score) })")
        XCTAssertFalse(offered.contains { TableDirectory.isKilovoltBand($0.entry) },
                       "a question naming no voltage is not about a kilovolt band: \(offered.map(\.entry.label))")

        let hint = try XCTUnwrap(TableDirectory.hint(for: question, in: Self.codeBook))
        XCTAssertTrue(hint.contains("Table 97 — Invented ampacities of not more than three insulated aluminum conductors"), hint)
        XCTAssertTrue(hint.contains("[holds for: aluminum; not over 900 V; in a raceway or cable; not more than three; "
                                    + "35 °C ambient]"), hint)
        XCTAssertTrue(hint.contains("Say which table you read and the conditions you took to hold."), hint)
        XCTAssertTrue(hint.hasSuffix("ask the technician for any input the table needs."), hint)

        // Named in the book's own words, without a value word, it is still a value question.
        XCTAssertTrue(TableDirectory.asksForValue("aluminum conductors in a raceway ampacity"))
        let plain = try XCTUnwrap(TableDirectory.hint(for: "aluminum conductors in a raceway ampacity", in: Self.codeBook))
        XCTAssertTrue(plain.hasPrefix("Tables that may answer this: Table 97"), plain)

        // A question that names the band is about it.
        let banded = TableDirectory.candidates(for: "ampacity of aluminum in buried conduit at 12 kV", in: Self.codeBook)
        XCTAssertTrue(banded.first.map { TableDirectory.isKilovoltBand($0.entry) } ?? false,
                      "\(banded.map(\.entry.label))")

        // table_lookup's words are the model's, read as written.
        let asWritten = TableDirectory.ranked("buried conduit ampacities", in: Self.codeBook)
        XCTAssertTrue(["Table 91", "Table 92"].contains(asWritten.first?.entry.label ?? ""), "\(asWritten.map(\.entry.label))")
    }

    func testTwoTablesThatDifferInAConditionAreOfferedWithTheOneThingToAsk() throws {
        let sets = [TableDirectory.conditions(of: Self.codeBook[5]), TableDirectory.conditions(of: Self.codeBook[4])]
        XCTAssertEqual(TableDirectory.differingKinds(sets), [.material])
        let line = TableDirectory.conditionsLine(sets)
        XCTAssertTrue(line.contains("These tables differ in conductor material: read the one the technician's words fit; "
                                    + "if their words fit both, ask the one condition that decides, then read it."), line)
        XCTAssertEqual(TableDirectory.differingKinds([TableDirectory.conditions(of: Self.codeBook[5]), []]), [],
                       "a condition one table leaves unsaid decides nothing")
        XCTAssertEqual(TableDirectory.conditionsLine([[], []]), "")

        let hint = try XCTUnwrap(TableDirectory.hint(for: "what is the ampacity of insulated conductors in a raceway or cable",
                                                     in: Self.codeBook))
        XCTAssertTrue(hint.contains("Table 97") && hint.contains("Table 95"), hint)
        XCTAssertTrue(hint.contains("These tables differ in conductor material"), hint)
        XCTAssertFalse(hint.contains("\n"), hint)
    }

    // MARK: - A section the turn names, carried on

    private func raw(_ index: Int, _ text: String, section: String?, sim: Float = 0, page: Int = 40) -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: "furnace", documentName: "Invented Furnace Manual", chunkIndex: index, text: text,
                              similarity: sim, page: page, section: section)
    }

    private static let heading = "Invented Cooling Start Sequence"

    private func sectionChunk(_ index: Int) -> String {
        "Step \(index - 39) of the invented cooling start sequence: the widget relay closes and the invented fan "
            + String(repeating: "turns over slowly while the invented sensor reads. ", count: 15)
    }

    private func retriever(following: [DocumentStore.Passage]?) -> VaultRetriever {
        var retriever = VaultRetriever(query: { _, _ in [
            self.raw(40, self.sectionChunk(40), section: Self.heading, sim: 0.6),
            self.raw(12, "General notes on the invented cooling start sequence and the widget relay.", section: "General", sim: 0.55),
            self.raw(2, "Contents\nGeneral ........................ 3\nInvented Cooling Start Sequence ......... 40\n"
                     + "Invented Heating Start Sequence .......... 44\nWiring ............ 50", section: nil, sim: 0.7),
        ] })
        if let following {
            retriever.followingChunks = { passage, limit in
                following.filter { $0.chunkIndex > passage.chunkIndex }.prefix(limit).map { $0 }
            }
        }
        return retriever
    }

    private var following: [DocumentStore.Passage] {
        (41...46).map { raw($0, sectionChunk($0), section: Self.heading, page: 40 + ($0 - 40) / 3) }
            + [raw(47, "Annual upkeep of the invented widget.", section: "Invented Upkeep")]
    }

    func testATableOfContentsIsNotAPassage() {
        XCTAssertTrue(VaultRetriever.isContentsList("Contents\nGeneral ........ 3\nWiring . . . . . . 12\nUpkeep ________ 40"))
        XCTAssertFalse(VaultRetriever.isContentsList("Close the relay.\nWait for the fan.\nRead the sensor at 40."))
        XCTAssertFalse(VaultRetriever.isContentsList("See page 40........ 3"), "one line is not a contents list")
        let outcome = retriever(following: nil).retrieve(.init(turn: "invented cooling start sequence"))
        XCTAssertFalse(outcome.passages.contains { $0.chunkIndex == 2 }, "\(outcome.passages.map(\.chunkIndex))")
        XCTAssertEqual(outcome.passages.first?.chunkIndex, 40)
    }

    /// Dot leaders out to a quantity or a rating are a parts list or a spec sheet, not a contents
    /// list: their numbers go up and down. Invented parts and ratings.
    func testAPartsListAndASpecSheetSetWithLeadersArePassages() {
        let parts = "Invented replacement parts\nBurner assembly ........ 2\nIgniter ........ 1\n"
            + "Flame sensor ........ 1\nGasket set ........ 4\nWiring harness ........ 1"
        let spec = "Invented widget furnace ratings\nInput, Btu/h ........ 60000\nOutput, Btu/h ........ 48000\n"
            + "Temperature rise, °F ........ 35\nBlower motor, hp ........ 1"
        XCTAssertFalse(VaultRetriever.isContentsList(parts), "a parts list is a passage")
        XCTAssertFalse(VaultRetriever.isContentsList(spec), "a spec sheet is a passage")
        XCTAssertFalse(VaultRetriever.isContentsList("Widget A ........ 2\nWidget B ........ 2\nWidget C ........ 2"),
                       "one number over and over is not pages")
        XCTAssertTrue(VaultRetriever.isContentsList("Safety ........ 2\nInstallation ........ 9\nWiring ........ 9\n"
                                                    + "Start-up ........ 17\nUpkeep ........ 31"),
                      "a contents list's pages may repeat but never fall")

        let retriever = VaultRetriever(query: { _, _ in [
            self.raw(5, parts, section: "Invented Replacement Parts", sim: 0.7),
            self.raw(2, "Contents\nGeneral ........ 3\nInvented Replacement Parts ........ 40\nWiring ........ 50",
                     section: nil, sim: 0.72),
        ] })
        let order = retriever.retrieve(.init(turn: "invented replacement parts burner assembly igniter")).passages.map(\.chunkIndex)
        XCTAssertTrue(order.contains(5), "the parts list is kept: \(order)")
        XCTAssertFalse(order.contains(2), "the contents list is still dropped: \(order)")
    }

    func testASectionNamedByItsHeadingIsCarriedOnInOrderWithinABudget() throws {
        let outcome = retriever(following: following)
            .retrieve(.init(turn: "walk me through the invented cooling start sequence"))
        let order = outcome.passages.map(\.chunkIndex)
        XCTAssertEqual(Array(order.prefix(1)), [40], "\(order)")
        let run = Array(order.dropFirst().prefix { $0 > 40 })
        XCTAssertEqual(run, Array(41...(40 + run.count)), "the section's chunks follow it in order: \(order)")
        XCTAssertGreaterThanOrEqual(run.count, 2, "\(order)")
        let carried = outcome.passages.filter { (41...47).contains($0.chunkIndex) }
        XCTAssertLessThanOrEqual(carried.map(\.text.count).reduce(0, +), VaultRetriever.sectionRunBudget)
        XCTAssertFalse(order.contains(47), "the next section is not carried: \(order)")
        XCTAssertTrue(order.contains(12), "the other passages stay: \(order)")
        XCTAssertFalse(order.contains(2), "the contents list is not a passage: \(order)")
    }

    func testATurnThatDoesNotNameTheHeadingCarriesNothingOn() {
        for turn in ["what does the cooling sequence do", "invented relay start", "is the widget relay closed"] {
            let order = retriever(following: following).retrieve(.init(turn: turn)).passages.map(\.chunkIndex)
            XCTAssertFalse(order.contains(41), "\(turn): \(order)")
        }
        XCTAssertTrue(VaultRetriever.turnNamesSection(Self.heading, turn: "what is the invented start sequence for cooling"))
        XCTAssertFalse(VaultRetriever.turnNamesSection("Gas Piping", turn: "gas piping sizes"), "a short heading is said in passing")
    }
}

/// Plan KR P3 — the store's chunks after a passage, in order.
@MainActor
final class KRFollowingChunksStoreTests: XCTestCase {

    func testTheStoreGivesTheChunksAfterAPassageInOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KRFollowing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(directory: dir)
        let text = (1...12).map { "Paragraph \($0) of the invented manual. " + String(repeating: "The widget turns. ", count: 30) }
            .joined(separator: "\n\n")
        let document = try await XCTUnwrapAsync(await store.ingest(name: "Invented Manual", text: text, namespace: "vault:kr"))
        let count = store.chunkCount(documentId: document.id)
        XCTAssertGreaterThan(count, 3)
        let after = store.passages(after: 1, documentId: document.id, namespace: "vault:kr", limit: 2)
        XCTAssertEqual(after.map(\.chunkIndex), [2, 3])
        XCTAssertEqual(store.passages(after: count - 1, documentId: document.id, limit: 4), [])
    }
}

private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                               line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
