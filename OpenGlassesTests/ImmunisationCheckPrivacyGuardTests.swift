import XCTest
@testable import OpenGlasses

/// Plan MY P3 guards — the check against the EMR never becomes a second patient log:
/// - the record type the reader returns has fields for the date, the vaccine and the lot only;
/// - invented patient details in the dropped columns appear in no output, error text or kept
///   summary, from a CSV or a workbook;
/// - the check is refused, and nothing is read, with medical mode off;
/// - the reader and the check neither log, write a file, nor reach a support report.
/// Every name and number here is invented.
@MainActor
final class ImmunisationCheckPrivacyGuardTests: XCTestCase {

    private static let patients = ["Test Person One", "Test Person Two", "ZZZ0001", "ZZZ0002", "1 Invented Street",
                                   "Allergic to nothing real"]

    private var directory: URL!
    private var store: VanStockStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var medical = true
    private let clock = Date(timeIntervalSince1970: 1_795_341_600)

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("emr-check-guard-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        suite = "emr-check-guard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        medical = true
        store.update { log in
            let flu = log.addItem(id: "flu", description: "the flu vaccine", codes: ["FLU-EMR"], batch: "b0")
            log.addLot(id: "A", itemID: flu.id, code: "ZZ1001", expiry: nil, receivedAt: clock, batch: "b1")
            log.record(.loaded, itemID: flu.id, quantity: StockQuantity(whole: 10), at: clock, batch: "b1",
                       source: .scanned, id: "m1", lotID: "A")
            log.record(.used, itemID: flu.id, quantity: StockQuantity(whole: 3), at: clock, batch: "b2",
                       source: .spoken, id: "m2", lotID: "A")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private lazy var checker = ImmunisationCheckService(store: store, medicalMode: { [unowned self] in self.medical },
                                                        now: { [unowned self] in self.clock }, calendar: calendar,
                                                        defaults: defaults)

    private let mapping = ImmunisationColumnMapping(date: "Date given", vaccine: "Vaccine", lot: "Batch")

    private var csv: Data {
        Data(("Patient name,NHI,Date given,Vaccine,Batch,Address,Notes\n"
            + "Test Person One,ZZZ0001,22/11/2026,FLU-EMR,ZZ1001,1 Invented Street,Allergic to nothing real\n"
            + "\"Test Person Two\",ZZZ0002,22/11/2026,Something else,ZZ1001,1 Invented Street,\n").utf8)
    }

    private var workbook: Data {
        let rows: [[XLSX.Cell]] = [
            ["Patient name", "NHI", "Date given", "Vaccine", "Batch", "Address", "Notes"].map { .text($0) },
            ["Test Person One", "ZZZ0001", "2026-11-22", "FLU-EMR", "ZZ1001", "1 Invented Street", "Allergic to nothing real"].map { .text($0) },
            ["Test Person Two", "ZZZ0002", "2026-11-22", "Something else", "ZZ1001", "1 Invented Street", ""].map { .text($0) },
        ]
        let sheet = XLSX.Sheet(name: "Immunisations", columns: Array(repeating: XLSX.Column(), count: 7), rows: rows)
        return XLSXWriter.data(for: XLSX.Workbook(sheets: [sheet]), modified: clock)
    }

    private func assertNoPatient(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for value in Self.patients {
            XCTAssertFalse(text.contains(value), "'\(value)' reached: \(text)", file: file, line: line)
        }
    }

    // MARK: - The record type

    func testTheRecordHasFieldsForTheDateTheVaccineAndTheLotOnly() {
        let record = ImmunisationRecord(day: StockDay(year: 2026, month: 11, day: 22)!, vaccine: "FLU-EMR", lot: "ZZ1001")
        XCTAssertEqual(Mirror(reflecting: record).children.map(\.label), ["day", "vaccine", "lot"])
        XCTAssertEqual(Mirror(reflecting: ImmunisationReconciliation.Dose(itemID: "flu", day: record.day, lot: "", count: 1))
            .children.compactMap(\.label), ["itemID", "day", "lot", "count"])
        XCTAssertEqual(Mirror(reflecting: mapping).children.compactMap(\.label), ["date", "vaccine", "lot", "dateOrder"])
    }

    // MARK: - Dropped columns

    func testNoPatientDetailReachesAnyOutputFromACSVOrAWorkbook() throws {
        for (data, format) in [(csv, ImmunisationListReader.Format.csv), (workbook, .spreadsheet)] {
            let list = try XCTUnwrap(try? ImmunisationListReader.read(data, format: format, mapping: mapping).get())
            XCTAssertEqual(list.records.count, 2)
            assertNoPatient(String(describing: list))

            guard case .done(let result, _) = checker.check(data, format: format, mapping: mapping) else {
                return XCTFail("the check should run in medical mode")
            }
            let wording = ImmunisationFindingWording(items: store.log.items)
            assertNoPatient(String(describing: result))
            assertNoPatient(wording.summary(result))
            result.findings.forEach { assertNoPatient(wording.sentence($0)) }
            XCTAssertEqual(result.unmatchedVaccines.map(\.vaccine), ["Something else"])

            let kept = try XCTUnwrap(ImmunisationCheckSummary.stored(defaults))
            assertNoPatient(String(decoding: try JSONEncoder().encode(kept), as: UTF8.self))
            let remembered = try XCTUnwrap(ImmunisationColumnMapping.stored(defaults))
            assertNoPatient(String(decoding: try JSONEncoder().encode(remembered), as: UTF8.self))
            // Every key this suite wrote, as a whole.
            assertNoPatient(String(describing: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("vaccineStock") }))
        }
    }

    func testNoPatientDetailReachesAnErrorSentence() {
        let wrong = ImmunisationColumnMapping(date: "When", vaccine: "Vaccine", lot: "Batch")
        for (data, format) in [(csv, ImmunisationListReader.Format.csv), (workbook, .spreadsheet)] {
            guard case .failed(let sentence) = checker.check(data, format: format, mapping: wrong) else {
                return XCTFail("a missing column fails")
            }
            assertNoPatient(sentence)
            XCTAssertTrue(sentence.contains("\"When\""))
        }
        for broken in [Data("Test Person One,\"ZZZ0001".utf8), Data("Test Person One ZZZ0001".utf8)] {
            if case .failed(let sentence) = checker.check(broken, format: .spreadsheet, mapping: mapping) { assertNoPatient(sentence) }
            if case .failed(let sentence) = checker.check(broken, format: .csv, mapping: mapping) { assertNoPatient(sentence) }
        }
    }

    func testTheHeaderGivesColumnNamesOnly() throws {
        let names = try XCTUnwrap(try? checker.header(csv, format: .csv).get())
        XCTAssertEqual(names, ["Patient name", "NHI", "Date given", "Vaccine", "Batch", "Address", "Notes"])
        assertNoPatient(names.joined(separator: " "))
    }

    // MARK: - Medical mode

    func testTheCheckIsRefusedWithMedicalModeOffAndNothingIsRead() {
        medical = false
        XCTAssertEqual(checker.check(csv, format: .csv, mapping: mapping), .refused(ImmunisationCheckService.medicalModeRefusal))
        XCTAssertEqual(checker.header(csv, format: .csv), .failure(.init(sentence: ImmunisationCheckService.medicalModeRefusal)))
        XCTAssertFalse(checker.match(vaccine: "Something else", to: "flu"))
        XCTAssertNil(ImmunisationCheckSummary.stored(defaults), "nothing kept")
        XCTAssertNil(ImmunisationColumnMapping.stored(defaults), "not even the mapping")
        XCTAssertTrue(ImmunisationCheckService.medicalModeRefusal.contains("medical mode"))
    }

    func testMatchingAVaccineToALineIsOneUndoableEntryInItsCodes() {
        XCTAssertTrue(checker.match(vaccine: "Something else", to: "flu"))
        XCTAssertTrue(store.log.item(id: "flu")?.codes.contains("Something else") == true)
        XCTAssertFalse(checker.match(vaccine: "Something else", to: "flu"), "already there")
    }

    // MARK: - Sources

    /// The files that touch the EMR's list neither log, write a file, nor reach a support report.
    func testTheReaderAndTheCheckNeitherLogNorWriteNorReport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
        let files = [
            "Services/FieldAssist/VanStock/ImmunisationListReader.swift",
            "Services/FieldAssist/VanStock/ImmunisationReconciliation.swift",
            "Services/FieldAssist/VanStock/ImmunisationCheckService.swift",
            "Services/FieldAssist/VanStock/CSVReader.swift",
            "App/Views/Job/ImmunisationCheckSheet.swift",
        ]
        let forbidden = ["print(", "NSLog(", "os_log", "Logger(", ".write(to", "FileManager.default.copyItem",
                         "SupportReport", "DiagnosticLog", "LLMService", "createFile("]
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(file) contains \(word)")
            }
        }
    }
}
