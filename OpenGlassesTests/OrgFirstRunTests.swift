import XCTest
@testable import OpenGlasses

/// Plan CT 3a — the decisions behind the first-run "Set up with my company" branch.
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

    // The key field's formatting is `ActivationKey.formatEntry`, tested in `ActivationKeyTests`.

    func testTheCompanyRouteContinuesPastTheWelcomePageOnceTheProfileIsInForce() {
        XCTAssertTrue(OrgFirstRun.continuesFromWelcome(tookCompanyRoute: true, onWelcomePage: true,
                                                       wasManaged: false, isManaged: true))
        // A declined review or a refused enrolment leaves the phone unmanaged: nothing moves.
        XCTAssertFalse(OrgFirstRun.continuesFromWelcome(tookCompanyRoute: true, onWelcomePage: true,
                                                        wasManaged: false, isManaged: false))
        // Not from this route, or not from the welcome page.
        XCTAssertFalse(OrgFirstRun.continuesFromWelcome(tookCompanyRoute: false, onWelcomePage: true,
                                                        wasManaged: false, isManaged: true))
        XCTAssertFalse(OrgFirstRun.continuesFromWelcome(tookCompanyRoute: true, onWelcomePage: false,
                                                        wasManaged: false, isManaged: true))
        // Only the change into a managed phone counts.
        XCTAssertFalse(OrgFirstRun.continuesFromWelcome(tookCompanyRoute: true, onWelcomePage: true,
                                                        wasManaged: true, isManaged: true))
    }
}
