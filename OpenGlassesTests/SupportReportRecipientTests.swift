import XCTest
@testable import OpenGlasses

/// Where a support report is emailed (2026-09-26): the address set on the phone or by an
/// organisation profile; on a personal phone the developer's address as the fallback; on an
/// organisation's phone its job-report office, or no address at all — never the developer.
final class SupportReportRecipientTests: XCTestCase {

    func testAnAddressThatIsSetIsUsedTrimmed() {
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "  support@partner.example  "),
                       "support@partner.example")
    }

    func testNothingSetFallsBackToTheDevelopersAddress() {
        XCTAssertEqual(SupportReportRecipient.resolve(configured: ""), DiagnosticsReportBuilder.supportEmail)
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "   "), DiagnosticsReportBuilder.supportEmail)
    }

    func testATypoFallsBackRatherThanBecomingTheRecipient() {
        for typo in ["support", "support@", "@partner.example", "support@partner", "support@@partner.example",
                     "sup port@partner.example", "support@partner.", "support@.example"] {
            XCTAssertFalse(SupportReportRecipient.isPlausible(typo), typo)
            XCTAssertEqual(SupportReportRecipient.resolve(configured: typo), DiagnosticsReportBuilder.supportEmail, typo)
        }
    }

    // MARK: - Organisation phones never fall back to the developer

    func testAnOrganisationPhoneUsesItsOwnSupportAddressFirst() {
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "help@partner.example",
                                                      organisationPhone: true,
                                                      organisationRecipients: ["office@partner.example"]),
                       "help@partner.example")
    }

    func testAnOrganisationPhoneWithNoSupportAddressUsesItsJobReportOffice() {
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "",
                                                      organisationPhone: true,
                                                      organisationRecipients: ["  ", "office@partner.example"]),
                       "office@partner.example")
    }

    func testAnOrganisationPhoneWithNeitherHasNoAddressRatherThanTheDevelopers() {
        XCTAssertNil(SupportReportRecipient.resolve(configured: "", organisationPhone: true))
        XCTAssertNil(SupportReportRecipient.resolve(configured: "typo", organisationPhone: true,
                                                    organisationRecipients: ["also a typo"]))
    }

    func testAnOrganisationProfileMaySetItAsAStartingValueAndItsShapeIsChecked() {
        XCTAssertEqual(SettingKey.supportReportEmail.kind, .startingValue(.string))
        XCTAssertNil(SettingKey.supportReportEmail.contentProblem(.string("help@partner.example"),
                                                                  resolvableVaultIds: []))
        XCTAssertNotNil(SettingKey.supportReportEmail.contentProblem(.string("not an address"),
                                                                     resolvableVaultIds: []))
    }
}
