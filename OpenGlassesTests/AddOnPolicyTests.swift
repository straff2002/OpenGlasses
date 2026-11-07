import XCTest
@testable import OpenGlasses

/// The organisation ceilings, each against each trust class.
final class AddOnPolicyTests: XCTestCase {

    private typealias P = AddOnPolicy

    private let ours = AddOnTrustClass.organisationSigned(organizationID: "acme-heating")
    private let theirs = AddOnTrustClass.organisationSigned(organizationID: "globex")

    private func policy(_ ceiling: P.Ceiling, enrolled: String? = "acme-heating") -> P {
        P(ceiling: ceiling, enrolledOrganizationID: enrolled)
    }

    func testNoCeiling() {
        let p = policy(.noCeiling)
        XCTAssertNil(p.refusal(for: .community))
        XCTAssertNil(p.refusal(for: .vendorSigned))
        XCTAssertNil(p.refusal(for: ours))
        XCTAssertEqual(p.refusal(for: theirs), .otherOrganisation(signedBy: "globex", enrolled: "acme-heating"))
    }

    func testAddOnsDisabledRefusesEveryClass() {
        let p = policy(.addOnsDisabled)
        for trust in [AddOnTrustClass.community, .vendorSigned, ours, theirs] {
            XCTAssertEqual(p.refusal(for: trust), .addOnsDisabled, "\(trust)")
            XCTAssertFalse(p.allows(trust))
        }
    }

    func testSignedOnlyRefusesCommunity() {
        let p = policy(.signedOnly)
        XCTAssertEqual(p.refusal(for: .community), .communityNotAllowed)
        XCTAssertNil(p.refusal(for: .vendorSigned))
        XCTAssertNil(p.refusal(for: ours))
        XCTAssertEqual(p.refusal(for: theirs), .otherOrganisation(signedBy: "globex", enrolled: "acme-heating"))
    }

    func testOrganisationSignedOnlyAllowsOnlyTheEnrolledOrganisation() {
        let p = policy(.organisationSignedOnly)
        XCTAssertEqual(p.refusal(for: .community), .communityNotAllowed)
        XCTAssertEqual(p.refusal(for: .vendorSigned), .notSignedByOrganisation)
        XCTAssertNil(p.refusal(for: ours))
        XCTAssertTrue(p.allows(ours))
        // Another organisation's signed add-on is not this organisation's.
        XCTAssertEqual(p.refusal(for: theirs), .otherOrganisation(signedBy: "globex", enrolled: "acme-heating"))
    }

    func testAnOrganisationAddOnNeedsTheEnrolment() {
        // Unmanaged phone: community and vendor add-ons are fine; an organisation's is not.
        let p = P.unmanaged
        XCTAssertEqual(p.ceiling, .noCeiling)
        XCTAssertNil(p.refusal(for: .community))
        XCTAssertNil(p.refusal(for: .vendorSigned))
        XCTAssertEqual(p.refusal(for: ours), .otherOrganisation(signedBy: "acme-heating", enrolled: nil))
        XCTAssertEqual(policy(.organisationSignedOnly, enrolled: nil).refusal(for: ours),
                       .otherOrganisation(signedBy: "acme-heating", enrolled: nil))
    }

    func testCeilingsOnlySubtract() {
        // Every class a stricter ceiling allows, every looser ceiling allows too.
        let classes = [AddOnTrustClass.community, .vendorSigned, ours, theirs]
        let ordered = P.Ceiling.allCases.sorted()
        XCTAssertEqual(ordered, [.noCeiling, .signedOnly, .organisationSignedOnly, .addOnsDisabled])
        for (looser, stricter) in zip(ordered, ordered.dropFirst()) {
            for trust in classes where policy(stricter).allows(trust) {
                XCTAssertTrue(policy(looser).allows(trust), "\(looser) refuses \(trust) that \(stricter) allows")
            }
        }
    }

    func testStrictestKeepsTheStricterCeiling() {
        for a in P.Ceiling.allCases {
            for b in P.Ceiling.allCases {
                let combined = P.strictest(a, b)
                XCTAssertEqual(combined, P.strictest(b, a))
                XCTAssertGreaterThanOrEqual(combined, a)
                XCTAssertGreaterThanOrEqual(combined, b)
                XCTAssertTrue([a, b].contains(combined))
            }
        }
        XCTAssertEqual(P.strictest(.noCeiling, .signedOnly), .signedOnly)
        XCTAssertEqual(P.strictest(.addOnsDisabled, .organisationSignedOnly), .addOnsDisabled)
    }
}
