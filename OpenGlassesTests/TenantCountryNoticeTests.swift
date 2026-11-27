import XCTest
@testable import OpenGlasses

/// Plan NK §3, Decision 4 — a tenant in Canada gives no notice; any other country, or none given,
/// gives the notice; nothing blocks.
final class TenantCountryNoticeTests: XCTestCase {

    func testCanadaGivesNoNotice() {
        for code in ["CA", "ca", " CA "] {
            XCTAssertEqual(TenantCountryNotice(countryLetterCode: code), .none, code)
        }
        XCTAssertNil(TenantCountryNotice.none.sentence)
    }

    func testAnotherCountryGivesTheNoticeAndDoesNotBlock() throws {
        for code in ["US", "nz", "GB", "AU"] {
            let notice = TenantCountryNotice(countryLetterCode: code)
            XCTAssertEqual(notice, .notice(country: code.uppercased()), code)
            XCTAssertFalse(notice.blocks, code)
            let sentence = try XCTUnwrap(notice.sentence)
            XCTAssertTrue(sentence.contains("outside Canada"), sentence)
            XCTAssertTrue(sentence.contains("no patient details"), sentence)
        }
    }

    func testNoCountryGivenIsANoticeToo() throws {
        for code in [nil, "", "  "] as [String?] {
            let notice = TenantCountryNotice(countryLetterCode: code)
            XCTAssertEqual(notice, .notice(country: nil))
            XCTAssertFalse(notice.blocks)
            XCTAssertTrue(try XCTUnwrap(notice.sentence).contains("outside Canada"))
        }
    }

    func testTheNoticeNeverStopsTheConnection() {
        XCTAssertFalse(TenantCountryNotice.none.blocks)
        XCTAssertFalse(TenantCountryNotice.notice(country: nil).blocks)
        // The gate that decides whether rows go knows nothing of the country.
        XCTAssertEqual(ClinicStockRouteGate(clinical: true, client: .bundled("11111111-2222-3333-4444-555555555555"),
                                            signedIn: true, workbook: GraphWorkbook(driveID: "b!d", itemID: "01")), .allowed)
    }
}
