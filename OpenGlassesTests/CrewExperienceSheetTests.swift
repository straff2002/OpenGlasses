import XCTest
@testable import OpenGlasses

/// Plan NF P0 — the crew experience sheet's shared core (`Tools/LicenceIssuance/…/CrewExperience.swift`,
/// compiled into this bundle) against the golden fixtures the licence core's tests read too, plus
/// what only the phone can check: that the redaction patterns are the phone's own, that the wire
/// entry decodes as the phone's entry, and that a catalog carrying `experience` is one the phone
/// already reads. Invented brands, models, codes and people only.
final class CrewExperienceSheetTests: XCTestCase {

    typealias Sheet = CrewExperienceSheet

    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CrewExperienceSheetTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "crew-experience-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: fixture(name))
    }

    static func ids(from start: Int = 1) -> () -> String {
        var next = start
        return {
            defer { next += 1 }
            let digits = String(next, radix: 16)
            return String(repeating: "0", count: 32 - digits.count) + digits
        }
    }

    static let vault = Sheet.Vault(vaultId: "fixture-crew-units", modelSpellings: ["QXRT-990", "QXRT990", "ZPL-2040", "ZPL2040"],
                                   equipmentTypes: ["rooftop unit", "walk-in cooler"])

    func parse(_ text: String, vault: Sheet.Vault = CrewExperienceSheetTests.vault) throws -> Sheet.Parsed {
        try Sheet.parse(csv: Data(text.utf8), vault: vault)
    }

    func parsed(_ name: String, vault: String = "vault.json") throws -> Sheet.Parsed {
        try Sheet.parse(csv: Self.fixture(name), vault: Self.decode(Sheet.Vault.self, vault))
    }

    // MARK: - The golden fixtures

    func testTheCleanSheetMatchesItsGoldenReportAndEntries() throws {
        let sheet = try parsed("clean.csv")
        XCTAssertEqual(Sheet.report(sheet), try Self.decode(Sheet.Report.self, "clean.expected.json"))
        let entries = Sheet.entries(from: sheet, approvedBy: try Self.decode(Sheet.Approval.self, "approval.json"), newID: Self.ids())
        XCTAssertEqual(entries, try Self.decode([CrewExperienceSet.Entry].self, "clean.entries.json"))
    }

    func testEveryRefusalInTheFixtureIsNamedWithItsRow() throws {
        let report = Sheet.report(try parsed("refusals.csv", vault: "vault-with-set.json"))
        XCTAssertEqual(report, try Self.decode(Sheet.Report.self, "refusals.expected.json"))
        XCTAssertEqual(report.toFix, 16)
        XCTAssertTrue(report.rows.allSatisfy { row in row.problems.allSatisfy { $0.message.hasPrefix("Row \(row.number): ") } })
        XCTAssertEqual(report.rows.first { $0.number == 8 }?.problems.first?.message, "Row 8: the fix is 640 characters; at most 500.")
        XCTAssertEqual(report.rows.first { $0.number == 2 }?.problems.first?.message, "Row 2: no model and no equipment type.")
    }

    func testTheRedactionFixture() throws {
        let sheet = try parsed("redaction.csv")
        XCTAssertEqual(Sheet.report(sheet), try Self.decode(Sheet.Report.self, "redaction.expected.json"))
        let first = try XCTUnwrap(sheet.rows.first)
        XCTAssertEqual(first.status, .changedByRedaction)
        XCTAssertTrue(first.isPublishable)
        XCTAssertEqual(first.symptom, "E999: Customer asked us to call ‹redacted› when done")
        XCTAssertEqual(first.fix, "Sent the photos to ‹redacted›")
        // A date and a pressure are not a phone number.
        XCTAssertEqual(sheet.rows[2].status, .ready)
    }

    func testEverySheetRefusalInTheFixture() throws {
        struct Case: Decodable { let `case`: String; let csvBase64: String; let refusal: String }
        for item in try Self.decode([Case].self, "sheet-refusals.json") {
            let data = try XCTUnwrap(Data(base64Encoded: item.csvBase64))
            XCTAssertThrowsError(try Sheet.parse(csv: data, vault: Self.vault), item.case) {
                XCTAssertEqual(($0 as? Sheet.SheetRefusal)?.name, item.refusal, item.case)
            }
        }
    }

    func testTheReuploadDiffIsNewChangedAndRemoved() throws {
        struct Reupload: Decodable { let entries: [CrewExperienceSet.Entry]; let diff: Sheet.Diff }
        let current = try Self.decode(CrewExperienceSet.self, "set-v1.json").entries
        let sheet = try parsed("reupload.csv", vault: "vault-reupload.json")
        let later = Sheet.Approval(role: "Service manager", name: "Avery Example", approvedAt: 1_795_564_800 + 21 * 86_400)
        let entries = Sheet.entries(from: sheet, approvedBy: later, current: current, newID: Self.ids(from: 5))
        let expected = try Self.decode(Reupload.self, "reupload.expected.json")
        XCTAssertEqual(entries, expected.entries)
        XCTAssertEqual(Sheet.diff(current: current, next: entries), expected.diff)
        XCTAssertEqual(expected.diff.summary, "2 new, 1 changed, 1 removed")
        // An unchanged row keeps its first approval; a changed one carries the new one.
        XCTAssertEqual(entries.first { $0.entryID == current[0].entryID }?.approvedAt, current[0].approvedAt)
        XCTAssertEqual(entries.first { $0.entryID == current[1].entryID }?.approvedAt, later.approvedAt)
    }

    // MARK: - The dialect

    func testQuotedCommasDoubledQuotesAndLineBreaksInsideCells() throws {
        let csv = "model,symptom,fix,notes\r\n"
            + "QXRT-990,\"Trips on start, fan runs\",\"Says \"\"LO\"\" then resets\",\"First line\r\nsecond line\"\r\n"
        let row = try XCTUnwrap(try parse(csv).rows.first)
        XCTAssertEqual(row.number, 2)
        XCTAssertEqual(row.symptom, "Trips on start, fan runs")
        XCTAssertEqual(row.fix, "Says \"LO\" then resets")
        XCTAssertEqual(row.finding, "First line\nsecond line", "notes keep their line break, as LF")
        XCTAssertEqual(row.status, .ready)
    }

    func testALineBreakOutsideNotesBecomesASpace() throws {
        let row = try XCTUnwrap(try parse("model,symptom,fix\nQXRT-990,\"Trips\non start\",Reseated\n").rows.first)
        XCTAssertEqual(row.symptom, "Trips on start")
    }

    func testCRLFLoneCRAndLFAllEndARecordAndRowNumbersCountRecords() throws {
        let csv = "model,symptom,fix\r\nQXRT-990,a,b\rZPL-2040,c,d\nQXRT990,\"e\r\nstill e\",f\r\n"
        let rows = try parse(csv).rows
        XCTAssertEqual(rows.map(\.number), [2, 3, 4])
        XCTAssertEqual(rows.map(\.modelToken), ["QXRT-990", "ZPL-2040", "QXRT-990"])
    }

    func testAByteOrderMarkAndBlankTrailingRowsAreIgnored() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("model,symptom,fix\r\nQXRT-990,a,b\r\n,,\r\n\r\n   ,  ,\r\n".utf8))
        let sheet = try Sheet.parse(csv: data, vault: Self.vault)
        XCTAssertEqual(sheet.rows.count, 1)
        XCTAssertEqual(sheet.ignoredColumns, [])
    }

    func testABlankRowInTheMiddleKeepsTheSheetsRowNumbers() throws {
        let rows = try parse("model,symptom,fix\nQXRT-990,a,b\n,,\nZPL-2040,c,d\n").rows
        XCTAssertEqual(rows.map(\.number), [2, 4])
    }

    func testHeadersAreMatchedLooselyAndUnknownColumnsAreNamed() throws {
        let sheet = try parse(" Model ,Fault code,SYMPTOM,fix,Photo,,Job ref\nQXRT-990,E999,Trips,Reseated,img,x,J-1\n")
        XCTAssertEqual(sheet.ignoredColumns, ["Photo", "Job ref"])
        XCTAssertEqual(sheet.rows.first?.faultCode, "E999")
        XCTAssertEqual(sheet.rows.first?.status, .ready)
    }

    func testAShortRowReadsItsMissingCellsAsEmpty() throws {
        let row = try XCTUnwrap(try parse("model,symptom,fix,notes,how_sure\nQXRT-990,Trips,Reseated\n").rows.first)
        XCTAssertEqual(row.status, .ready)
        XCTAssertNil(row.howSure)
    }

    // MARK: - Row rules and mapping

    func testTheModelIsStoredAsTheVaultsOwnSpelling() throws {
        let rows = try parse("model,symptom,fix\nqxrt 990,a,b\nzpl2040,c,d\n").rows
        XCTAssertEqual(rows.map(\.modelToken), ["QXRT-990", "ZPL-2040"])
    }

    func testTheFaultCodeLeadsTheSymptomAndTheFindingDefaultsToCodeAndFix() throws {
        let rows = try parse("model,fault_code,symptom,fix\nQXRT-990,E999,Trips on start,Reseated\nQXRT-990,E999,E999 after a minute,Reseated\n").rows
        XCTAssertEqual(rows[0].symptom, "E999: Trips on start")
        XCTAssertEqual(rows[0].finding, "E999: Reseated")
        XCTAssertEqual(rows[1].symptom, "E999 after a minute", "a symptom that names the code is left as written")
    }

    func testAnEquipmentTypeAloneBecomesASymptomSubject() throws {
        let sheet = try parse("equipment_type,symptom,fix\nWalk-in  Cooler,Door sweats,Replaced the heater fuse\n")
        let entry = try XCTUnwrap(Sheet.entries(from: sheet, approvedBy: .init(role: "Owner", name: nil, approvedAt: 1_795_564_800),
                                                newID: Self.ids()).first)
        XCTAssertEqual(entry.subject, .symptom(equipmentType: "walk-in cooler", phrase: "Door sweats"))
        XCTAssertEqual(entry.origin, "recollection")
        XCTAssertFalse(entry.authorIsApprover)
        XCTAssertEqual(entry.citationName, "Crew experience · walk-in cooler · 2026-11-25 · approved by Owner")
    }

    func testAuthorIsApproverWhenAddedByMatchesThePublisher() throws {
        let sheet = try parse("model,symptom,fix,added_by\nQXRT-990,a,b,avery  EXAMPLE\nQXRT-990,c,d,Jordan Sample\n")
        let entries = Sheet.entries(from: sheet, approvedBy: .init(role: "Owner", name: "Avery Example", approvedAt: 1), newID: Self.ids())
        XCTAssertEqual(entries.map(\.authorIsApprover), [true, false])
    }

    func testANumberForHowSureIsRefusedButWordsAreKept() throws {
        let rows = try parse("model,symptom,fix,how_sure\nQXRT-990,a,b,9/10\nQXRT-990,a,b,fixed it 2 times out of 3\n").rows
        XCTAssertEqual(rows[0].problems, [.howSureIsANumber])
        XCTAssertEqual(rows[1].status, .ready)
    }

    func testDatesAreISODaysOfRealDates() throws {
        let rows = try parse("model,symptom,fix,date\nQXRT-990,a,b,2028-02-29\nQXRT-990,a,b,2026-02-29\nQXRT-990,a,b,2026-11-25T08:00:00Z\n").rows
        XCTAssertEqual(rows.map(\.date), ["2028-02-29", nil, "2026-11-25"])
        XCTAssertEqual(rows[1].problems, [.badDate])
    }

    func testAControlCharacterIsNamedOnceNotAlsoAsMissing() throws {
        let row = try XCTUnwrap(try parse("model,symptom,fix\nQXRT-990,a\u{0}b,fix\n").rows.first)
        XCTAssertEqual(row.problems, [.controlCharacter(.symptom)])
    }

    // MARK: - Ids

    func testTheDownloadedSheetRoundTripsEveryId() throws {
        let entries = try Self.decode([CrewExperienceSet.Entry].self, "clean.entries.json")
        XCTAssertEqual(Sheet.csv(entries: entries), String(decoding: try Self.fixture("current-sheet.csv"), as: UTF8.self))
        let vault = Sheet.Vault(vaultId: Self.vault.vaultId, modelSpellings: Self.vault.modelSpellings,
                                equipmentTypes: Self.vault.equipmentTypes, currentEntryIDs: entries.map(\.entryID))
        let again = try Sheet.parse(csv: Data(Sheet.csv(entries: entries).utf8), vault: vault)
        XCTAssertEqual(again.rows.map(\.id), entries.map(\.entryID))
        let republished = Sheet.entries(from: again, approvedBy: .init(role: "Owner", name: nil, approvedAt: 2_000_000_000),
                                        current: entries, newID: Self.ids(from: 99))
        XCTAssertEqual(republished, entries, "an unedited sheet publishes the same set, approvals and all")
    }

    // MARK: - Redaction is the phone's own

    func testTheRedactionPatternsAreThePhonesSecretPatternsThenPhone() {
        let core = CrewExperienceRedaction.patterns
        let phone = SecretPatterns.all
        XCTAssertEqual(core.count, phone.count + 1)
        for (mine, theirs) in zip(core, phone) {
            XCTAssertEqual(mine.name, theirs.name)
            XCTAssertEqual(mine.expression, theirs.regex.pattern, theirs.name)
        }
        XCTAssertEqual(core.last?.name, "phone")
        XCTAssertEqual(CrewExperienceRedaction.placeholder, SecretPatterns.redactionPlaceholder)
    }

    func testPhoneNumbersAreRedactedAndReadingsAreNot() {
        for text in ["call 021 555 0199", "ring +64 21 555 0100 first", "office (09) 555 0123", "on 555-555-0123 after five"] {
            XCTAssertEqual(CrewExperienceRedaction.redact(text).hits, ["phone"], text)
        }
        for text in ["set to 350 kPa", "on 2026-11-25", "model QXRT-990", "fault E999 at 24 V", "555-0199", "serial 1234567890123456"] {
            XCTAssertEqual(CrewExperienceRedaction.redact(text).hits, [], text)
        }
    }

    // MARK: - The wire entry is the phone's entry

    func testAWireEntryDecodesAsThePhonesBundleEntryAndSubject() throws {
        let data = try Self.fixture("clean.entries.json")
        let phone = try JSONDecoder().decode([LearningBundle.Entry].self, from: data)
        XCTAssertEqual(phone.map(\.origin), Array(repeating: .recollection, count: 4))
        XCTAssertEqual(phone.map(\.entryID), try Self.decode([CrewExperienceSet.Entry].self, "clean.entries.json").map(\.entryID))
        XCTAssertEqual(phone[0].subject, .model(modelToken: "QXRT-990", manufacturer: "Fixturetherm", equipmentType: "rooftop unit"))
        XCTAssertEqual(phone[3].subject, .symptom(equipmentType: "walk-in cooler", phrase: "Door frame sweats in summer"))
        XCTAssertNil(phone[0].confirmedJobCount, "a recollection was confirmed on no job")
    }

    func testTheCitationDateIsThePhonesUTCDate() throws {
        struct Citation: Decodable { let subject: String; let approvedAt: Int64; let role: String; let name: String }
        for item in try Self.decode([Citation].self, "citations.json") {
            let date = TeamLearningCitation.utcDate(Date(timeIntervalSince1970: TimeInterval(item.approvedAt)))
            XCTAssertEqual(item.name, "Crew experience · \(item.subject) · \(date) · approved by \(item.role)")
        }
        XCTAssertEqual(Sheet.leadIn, "From your company's experience (not the manufacturer's manual):")
    }

    // MARK: - The catalog field

    func testACatalogWithExperienceIsOneThePhoneAlreadyReads() throws {
        let payload = try Self.fixture("catalog-experience-v1.json")
        XCTAssertNoThrow(try CompanyVaultContract.check(try CompanyVaultContract.decoder().decode(CompanyVaultContract.Catalog.self, from: payload)))
        let phone = try CompanyVaultCatalog.decoder.decode(CompanyVaultCatalog.Payload.self, from: payload)
        let screened = CompanyVaultCatalog.screen(phone)
        XCTAssertEqual(screened.vaults.map(\.vaultId), ["fixture-crew-units"])
        XCTAssertEqual(screened.problems, [:])
    }

    func testEveryNegativeExperienceCatalogIsRefusedInItsWords() throws {
        struct Negative: Decodable { let name: String; let payload: CompanyVaultContract.Catalog; let refusal: String }
        for item in try CompanyVaultContract.decoder().decode([Negative].self, from: Self.fixture("negative-catalogs.json")) {
            XCTAssertThrowsError(try CompanyVaultContract.check(item.payload), item.name) {
                XCTAssertEqual($0 as? CompanyVaultContract.Refusal, .invalid(item.refusal), item.name)
            }
        }
    }

    func testTheSetFixtureChecks() throws {
        let set = try Self.decode(CrewExperienceSet.self, "set-v1.json")
        XCTAssertNoThrow(try CrewExperienceSet.check(set))
        XCTAssertEqual(set.profileId, "fixture-company")
        XCTAssertEqual(set.vaultId, "fixture-crew-units")
    }
}
