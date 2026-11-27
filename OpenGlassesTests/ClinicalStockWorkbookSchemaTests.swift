import XCTest
@testable import OpenGlasses

/// Plan NK §1 — the clinic workbook's two tables: their columns in a fixed order, a row that goes
/// out and comes back as itself, no column outside NJ's allow-list, and a table refused when staff
/// add a column that reads like a patient's. Invented lines and lots only.
final class ClinicalStockWorkbookSchemaTests: XCTestCase {

    private func whole(_ n: Int) -> StockQuantity { StockQuantity(whole: n) }
    private let day = StockDay(year: 2026, month: 11, day: 25)!

    private func row(_ kind: ClinicalStockShareRow.Kind = .given, quantity: Int = 3, lot: String? = "ZZ1001",
                     reason: VanStockMovement.WasteReason? = nil, span: ClinicalStockShareRow.Span = .day) -> ClinicalStockShareRow {
        ClinicalStockShareRow(day: day, span: span, lineID: "flu", lineNumber: "8161", lineName: "Flu vaccine",
                              lotCode: lot, lotExpiry: StockDay(year: 2027, month: 3, day: 31), kind: kind,
                              quantity: whole(quantity), wasteReason: reason)
    }

    /// Cells as Graph would hand them back: the JSON round trip, apostrophes and all.
    private func roundTrip(_ keyed: [KeyedShareRow]) throws -> [[Any]] {
        let values = keyed.map { ClinicalStockWorkbookSchema.cells($0).map(\.json) }
        let data = try JSONSerialization.data(withJSONObject: values)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[Any]])
    }

    // MARK: - The columns

    func testTheColumnsAreFixedAndInOrder() {
        XCTAssertEqual(ClinicalStockWorkbookTable.movements.headers,
                       ["Day", "Span", "Line number", "Line", "Lot", "Expiry", "Kind", "Quantity", "Reason", "Row key"])
        XCTAssertEqual(ClinicalStockWorkbookTable.counts.headers, ["Day", "Line number", "Line", "Lot", "Counted", "Row key"])
        XCTAssertEqual(ClinicalStockWorkbookTable.movements.headerAddress, "A1:J1")
        XCTAssertEqual(ClinicalStockWorkbookTable.counts.headerAddress, "A1:F1")
        XCTAssertEqual(ClinicalStockWorkbookTable.allCases.map(\.rawValue), ["Movements", "Counts"])
    }

    /// Every column is a field of `ClinicalStockShareRow` or its key; nothing else can be written.
    func testNoColumnIsOutsideTheShareRowsAllowList() {
        let field: [String: String] = ["Day": "day", "Span": "span", "Line number": "lineNumber", "Line": "lineName",
                                       "Lot": "lotCode", "Expiry": "lotExpiry", "Kind": "kind", "Quantity": "quantity",
                                       "Reason": "wasteReason", "Counted": "quantity"]
        let stored = Set(Mirror(reflecting: row()).children.compactMap(\.label))
        for table in ClinicalStockWorkbookTable.allCases {
            for heading in table.headers where heading != "Row key" {
                let name = try? XCTUnwrap(field[heading], "\(heading) maps to no share-row field")
                XCTAssertTrue(name.map(stored.contains) ?? false, "\(heading) is not a share-row field")
            }
            XCTAssertTrue(ClinicalStockInboundGuard.patientFields(table.headers).isEmpty, table.rawValue)
        }
    }

    func testAMovementGoesToMovementsAndACountToCounts() {
        XCTAssertEqual(ClinicalStockWorkbookTable.of(row(.given)), .movements)
        XCTAssertEqual(ClinicalStockWorkbookTable.of(row(.wasted, reason: .coldChain)), .movements)
        XCTAssertEqual(ClinicalStockWorkbookTable.of(row(.counted)), .counts)
        XCTAssertEqual(ClinicalStockWorkbookSchema.cells(KeyedShareRow(row: row(.counted), key: "k")).count, 6)
        XCTAssertEqual(ClinicalStockWorkbookSchema.cells(KeyedShareRow(row: row(), key: "k")).count, 10)
    }

    func testTextIsSentAsTextSoExcelCannotTurnItIntoANumberOrADate() {
        let key = ClinicalStockRowKey.key(base: ClinicalStockRowKey.base(row(lot: "1E5"), seat: "seat-one"), sequence: 1)
        let keyed = KeyedShareRow(row: row(lot: "1E5"), key: key)
        let json = ClinicalStockWorkbookSchema.cells(keyed).map(\.json)
        XCTAssertEqual(json[0] as? String, "'2026-11-25")
        XCTAssertEqual(json[2] as? String, "'8161")
        XCTAssertEqual(json[4] as? String, "'1E5")
        XCTAssertEqual((json[7] as? NSDecimalNumber)?.stringValue, "3")
        XCTAssertEqual(json[9] as? String, "'" + key)
    }

    // MARK: - Reading back

    func testARowRoundTripsThroughItsTable() throws {
        let keyed = [KeyedShareRow(row: row(.wasted, quantity: 2, reason: .coldChain, span: .week), key: "k1"),
                     KeyedShareRow(row: row(.received, quantity: 20, lot: nil), key: "k2")]
        let read = try ClinicalStockWorkbookSchema.read(.movements, headers: ClinicalStockWorkbookTable.movements.headers,
                                                         rows: roundTrip(keyed)).get()
        XCTAssertEqual(read.skipped, 0)
        XCTAssertEqual(read.entries.count, 2)
        let wasted = read.entries[0]
        XCTAssertEqual(wasted.day, day)
        XCTAssertEqual(wasted.span, .week)
        XCTAssertEqual(wasted.lineNumber, "8161")
        XCTAssertEqual(wasted.lineName, "Flu vaccine")
        XCTAssertEqual(wasted.lotCode, "ZZ1001")
        XCTAssertEqual(wasted.kind, .wasted)
        XCTAssertEqual(wasted.quantity, whole(2))
        XCTAssertEqual(wasted.wasteReason, .coldChain)
        XCTAssertEqual(wasted.key, "k1")
        XCTAssertNil(read.entries[1].lotCode)
        XCTAssertEqual(read.entries[1].position, 1)

        let count = try ClinicalStockWorkbookSchema.read(.counts, headers: ClinicalStockWorkbookTable.counts.headers,
                                                          rows: roundTrip([KeyedShareRow(row: row(.counted, quantity: 12), key: "c1")])).get()
        XCTAssertEqual(count.entries.first?.kind, .counted)
        XCTAssertEqual(count.entries.first?.quantity, whole(12))
    }

    func testACorrectionReadsBackNegative() throws {
        let keyed = KeyedShareRow(row: row(quantity: 1).with(quantity: StockQuantity(scaled: -1000)), key: "k")
        let read = try ClinicalStockWorkbookSchema.read(.movements, headers: ClinicalStockWorkbookTable.movements.headers,
                                                         rows: roundTrip([keyed])).get()
        XCTAssertEqual(read.entries.first?.quantity, StockQuantity(scaled: -1000))
    }

    /// Staff type rows by hand and Excel turns a date into its serial number: both still read.
    func testRowsStaffTypedReadAsWell() throws {
        let rows: [[Any]] = [[45658, "Day", 8161, "Flu vaccine", "", "", "given", 2, "", ""],
                             ["2026-11-25", "", "", "Hep B", "HB-9", "", "Received", "4.5", "", ""]]
        let read = try ClinicalStockWorkbookSchema.read(.movements, headers: ClinicalStockWorkbookTable.movements.headers,
                                                         rows: rows).get()
        XCTAssertEqual(read.entries.count, 2)
        XCTAssertEqual(read.entries[0].day, StockDay(year: 2025, month: 1, day: 1))
        XCTAssertEqual(read.entries[0].lineNumber, "8161")
        XCTAssertNil(read.entries[0].key)
        XCTAssertEqual(read.entries[1].kind, .received)
        XCTAssertEqual(read.entries[1].quantity, StockQuantity(scaled: 4500))
    }

    func testARowThatDoesNotReadIsCountedAndLeftOut() throws {
        let rows: [[Any]] = [["not a day", "Day", "", "Flu", "", "", "given", 1, "", ""],
                             ["2026-11-25", "Day", "", "Flu", "", "", "borrowed", 1, "", ""],
                             ["2026-11-25", "Day", "", "Flu", "", "", "given", "lots", "", ""],
                             ["", "", "", "", "", "", "", "", "", ""]]
        let read = try ClinicalStockWorkbookSchema.read(.movements, headers: ClinicalStockWorkbookTable.movements.headers,
                                                         rows: rows).get()
        XCTAssertTrue(read.entries.isEmpty)
        XCTAssertEqual(read.skipped, 3, "an empty row is not a problem")
    }

    // MARK: - Columns staff added

    func testAColumnThatReadsLikeAPatientsRefusesTheTable() {
        for added in ["Patient", "Patient name", "Date of birth", "Health card", "MRN", "Appointment"] {
            let headers = ClinicalStockWorkbookTable.movements.headers + [added]
            let result = ClinicalStockWorkbookSchema.read(.movements, headers: headers, rows: [])
            XCTAssertEqual(result, .failure(.patientColumns([added])), added)
        }
        let sentence = ClinicalStockWorkbookRefusal.patientColumns(["Patient"]).sentence
        XCTAssertTrue(sentence.contains("Patient"))
        XCTAssertTrue(sentence.contains("patient details"))
    }

    func testAnyOtherColumnStaffAddedIsIgnored() throws {
        let headers = ["Notes"] + ClinicalStockWorkbookTable.counts.headers + ["Checked"]
        let rows: [[Any]] = [["fridge door", "2026-11-25", "", "Flu vaccine", "ZZ1001", 7, "k", "yes"]]
        let read = try ClinicalStockWorkbookSchema.read(.counts, headers: headers, rows: rows).get()
        XCTAssertEqual(read.entries.first?.quantity, whole(7))
        XCTAssertEqual(read.entries.first?.lotCode, "ZZ1001")
    }

    func testAMissingColumnRefusesTheTable() {
        let headers = ClinicalStockWorkbookTable.counts.headers.filter { $0 != "Counted" }
        XCTAssertEqual(ClinicalStockWorkbookSchema.read(.counts, headers: headers, rows: []),
                       .failure(.missingColumns(["Counted"])))
    }

    // MARK: - On the queue

    func testAShareRowRoundTripsThroughTheQueueWithASignedQuantity() throws {
        let original = row(.wasted, reason: .drawnUpNotGiven).with(quantity: StockQuantity(scaled: -2000))
        let data = try JSONEncoder().encode(KeyedShareRow(row: original, key: "k"))
        let back = try JSONDecoder().decode(KeyedShareRow.self, from: data)
        XCTAssertEqual(back.row, original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["row", "key"])
        let fields = try XCTUnwrap(object["row"] as? [String: Any])
        XCTAssertTrue(Set(fields.keys).isSubset(of: ["day", "span", "lineID", "lineNumber", "lineName", "lotCode",
                                                     "lotExpiry", "kind", "quantity", "wasteReason"]))
    }
}
