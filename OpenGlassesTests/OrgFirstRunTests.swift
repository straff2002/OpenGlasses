import XCTest
@testable import OpenGlasses

/// Plan CT 3a — the decisions behind the first-run "My company gave me a key or code" branch.
final class OrgFirstRunTests: XCTestCase {

    private func licence(profile: String?) -> LicenseService.LicensePayload {
        LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge Mechanical",
                                      issued: Date(timeIntervalSince1970: 1_790_000_000), expires: nil,
                                      profile: profile)
    }

    // MARK: - Holding on "Setting up for …"

    func testALicenceNamingAProfileHoldsUntilTheProfileIsInForce() {
        let named = licence(profile: "https://config.northbridge.example/profile.txt")
        XCTAssertEqual(OrgFirstRun.holdingLicensee(licence: named, isManaged: false), "Northbridge Mechanical")
        XCTAssertNil(OrgFirstRun.holdingLicensee(licence: named, isManaged: true), "in force: carry on")
    }

    func testAPlainLicenceOrNoneNeverHolds() {
        XCTAssertNil(OrgFirstRun.holdingLicensee(licence: licence(profile: nil), isManaged: false))
        XCTAssertNil(OrgFirstRun.holdingLicensee(licence: nil, isManaged: false))
    }

    // MARK: - Pages

    func testTheOrganisationsModelSkipsTheProviderAndKeyPagesBothWays() {
        XCTAssertEqual(OrgFirstRun.pageAfterWelcome(organisationChoseModel: false), 1)
        XCTAssertEqual(OrgFirstRun.pageAfterWelcome(organisationChoseModel: true), 3)
        XCTAssertEqual(OrgFirstRun.pageBefore(3, organisationChoseModel: true), 0)
        XCTAssertEqual(OrgFirstRun.pageBefore(3, organisationChoseModel: false), 2)
        XCTAssertEqual(OrgFirstRun.pageBefore(5, organisationChoseModel: true), 4)
        XCTAssertEqual(OrgFirstRun.pageBefore(0, organisationChoseModel: false), 0)
    }

    // MARK: - The key field

    func testAKeyIsGroupedInFoursAsItIsTyped() {
        XCTAssertEqual(OrgFirstRun.formatKeyEntry("k7q3"), "K7Q3")
        XCTAssertEqual(OrgFirstRun.formatKeyEntry("k7q3x"), "K7Q3-X")
        XCTAssertEqual(OrgFirstRun.formatKeyEntry("K7Q3-X9PDM2VA8RTZ"), "K7Q3-X9PD-M2VA-8RTZ")
        XCTAssertEqual(OrgFirstRun.formatKeyEntry("K7Q3-"), "K7Q3", "deleting past a dash takes the dash")
        XCTAssertEqual(OrgFirstRun.formatKeyEntry(""), "")
    }

    func testALicenceCodeIsLeftExactlyAsPasted() {
        let code = "eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0.c2lnbmF0dXJl"
        XCTAssertEqual(OrgFirstRun.formatKeyEntry(code), code)
        XCTAssertEqual(OrgFirstRun.formatKeyEntry("K7Q3-X9PD-M2VA-8RTZ-EXTRA"), "K7Q3-X9PD-M2VA-8RTZ-EXTRA",
                       "past sixteen characters it is not a key, so it is not reshaped")
    }

    func testAFormattedKeyStillReadsAsTheSameKey() {
        let key = ActivationKey.generate()
        XCTAssertEqual(ActivationKey.read(OrgFirstRun.formatKeyEntry(key.canonical.lowercased())), .key(key))
    }
}
