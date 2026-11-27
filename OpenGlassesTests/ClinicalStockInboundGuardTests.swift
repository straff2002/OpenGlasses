import XCTest
@testable import OpenGlasses

/// Plan NJ §1 — a sheet for a clinical list that carries a column about a patient is refused with
/// a plain sentence, never read and never quietly stripped; a van's list reads it as before; and
/// the EMR's own list (Plan MY §8) still drops those columns and is never refused. Every name and
/// number here is invented.
@MainActor
final class ClinicalStockInboundGuardTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clinical = true
    private let clock = Date(timeIntervalSince1970: 1_795_341_600)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbound-guard-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock, profileClinical: .some(nil))
        clinical = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private lazy var service = VanStockService(store: store, place: { .stock },
                                               partsIndex: { VaultPartsIndex(files: []) }, activeJob: { nil },
                                               now: { [unowned self] in self.clock },
                                               clinical: { [unowned self] in self.clinical })

    private lazy var importer = VanStockImportService(store: store, service: service, isAllowed: { nil })

    private func workbook(_ header: [String], _ rows: [[String]]) -> Data {
        let cells = ([header] + rows).map { $0.map { XLSX.Cell.text($0) } }
        return XLSXWriter.data(for: XLSX.Workbook(sheets: [XLSX.Sheet(name: "Sheet1", columns: [], rows: cells)]),
                               modified: clock)
    }

    // MARK: - The headings

    func testPatientHeadingsAreFoundAsWholeWordsWhateverTheCase() {
        for heading in ["Patient", "Patient name", "PATIENT ID", "First name", "Surname", "DOB", "Date of birth",
                        "Birth date", "Health card number", "Health number", "PHN", "MRN", "Chart #", "Appointment",
                        "Appointment time", "Address", "Phone", "Telephone", "Email", "E-mail", "Client name"] {
            XCTAssertTrue(ClinicalStockInboundGuard.isPatientHeading(heading), heading)
        }
    }

    func testTheStocksOwnHeadingsAreNotAPatients() {
        for heading in ["Description", "Tariff", "Tariff code", "Brand Names", "Brand name", "Vaccine name", "Product name",
                        "Quantity on Hand", "Category", "Immunization #", "Lot", "Expiry", "mRNA vaccine", "Charter",
                        "Addressed to supplier", "Phonetic code", "Unit", "Bin"] {
            XCTAssertFalse(ClinicalStockInboundGuard.isPatientHeading(heading), heading)
        }
    }

    func testANameColumnTheReaderTakesAsTheDescriptionIsTheStocks() throws {
        let sheets = try XCTUnwrap(try? XLSXReader.read(workbook(["Name", "Tariff", "Quantity on hand"], [["Flu", "8161", "10"]])).get())
        XCTAssertEqual(ClinicalStockInboundGuard.patientHeadings(in: sheets), [], "'Name' is read as the line's description")
        let both = try XCTUnwrap(try? XLSXReader.read(workbook(["Description", "Name", "Tariff", "Quantity on hand"],
                                                               [["Flu", "Test Person One", "8161", "10"]])).get())
        XCTAssertEqual(ClinicalStockInboundGuard.patientHeadings(in: both), ["Name"],
                       "a second 'Name' beside the description is nobody's description")
    }

    func testAFeedsFieldNamesAreCheckedTheSameWay() {
        XCTAssertEqual(ClinicalStockInboundGuard.patientFields(["sku", "quantity", "patient_name", "dob"]), ["patient_name", "dob"])
        XCTAssertEqual(ClinicalStockInboundGuard.patientFields(["sku", "quantity", "lot"]), [])
    }

    func testTheRefusalNamesTheColumnNeverAValue() {
        let sentence = ClinicalStockInboundGuard.refusal(["Patient name"])
        XCTAssertTrue(sentence.contains("Patient name"))
        XCTAssertTrue(sentence.contains("wasn't read"))
        XCTAssertFalse(sentence.contains("Test Person One"))
    }

    // MARK: - The import

    func testAClinicalListRefusesASheetWithAPatientColumnAndReadsNothing() {
        let data = workbook(["Description", "Tariff", "Quantity on hand", "Patient name"],
                            [["Flu vaccine", "8161", "10", "Test Person One"]])
        importer.handle(data: data, fileName: "stock.xlsx")
        XCTAssertEqual(importer.stage, .refused(.patientColumns(["Patient name"])))
        XCTAssertNil(importer.takeover)
        XCTAssertNil(importer.baseline)
        XCTAssertTrue(store.log.items.isEmpty, "nothing was read into the list")
    }

    func testAVanListReadsTheSameSheetAsBefore() {
        clinical = false
        let data = workbook(["Description", "Tariff", "Quantity on hand", "Patient name"],
                            [["Flu vaccine", "8161", "10", "Test Person One"]])
        importer.handle(data: data, fileName: "stock.xlsx")
        guard case .reviewing = importer.stage else { return XCTFail("\(importer.stage)") }
    }

    func testAClinicalListReadsItsOwnVaccineTable() {
        let data = workbook(["Immunization #", "Category", "Description", "Tariff", "Brand Names", "Quantity on Hand"],
                            [["FLU01", "Respiratory", "Influenza vaccine", "8161", "Fluzone", "12"]])
        importer.handle(data: data, fileName: "clinic table.xlsx")
        guard case .reviewing = importer.stage else { return XCTFail("\(importer.stage)") }
    }

    // MARK: - The EMR's list stays as built

    func testTheEMRsListStillDropsPatientColumnsAndIsNotRefused() throws {
        let csv = Data("""
            Patient name,DOB,Date given,Vaccine,Batch,Health card
            Test Person One,1990-01-01,2026-11-22,FLU-EMR,ZZ1001,ZZZ0001
            """.utf8)
        let mapping = ImmunisationColumnMapping(date: "Date given", vaccine: "Vaccine", lot: "Batch")
        let list = try XCTUnwrap(try? ImmunisationListReader.read(csv, format: .csv, mapping: mapping).get())
        XCTAssertEqual(list.records, [ImmunisationRecord(day: StockDay(year: 2026, month: 11, day: 22)!, vaccine: "FLU-EMR", lot: "ZZ1001")])
        XCTAssertFalse(String(describing: list).contains("Test Person One"))
        XCTAssertFalse(String(describing: list).contains("ZZZ0001"))
    }
}
