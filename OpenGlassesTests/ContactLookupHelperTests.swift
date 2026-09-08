import XCTest
@testable import OpenGlasses

/// The part of contact resolution that decides, kept away from the part that reads Contacts.
///
/// `pickEmail` is pure by design: no `CNContactStore` is touched here, so the rule about which
/// match a spoken name actually points at can be pinned headlessly.
final class ContactLookupHelperTests: XCTestCase {

    private func email(_ name: String, _ address: String, _ label: String = "work") -> ContactLookupHelper.ResolvedEmail {
        ContactLookupHelper.ResolvedEmail(name: name, address: address, label: label)
    }

    func testANameNobodyAnswersToPicksNothing() {
        XCTAssertEqual(ContactLookupHelper.pickEmail(from: []), .none)
    }

    func testOnePersonWithTwoAddressesIsStillOnePerson() {
        let matches = [email("Dave Smith", "dave@work.example", "work"),
                       email("Dave Smith", "dave@home.example", "home")]
        XCTAssertEqual(ContactLookupHelper.pickEmail(from: matches), .one(matches[0]))
    }

    func testTheSameNameOnTwoPeopleIsAmbiguousAndNamesThemInTheOrderTheyWereFound() {
        let matches = [email("Dave Smith", "dave@work.example"),
                       email("Dave Jones", "djones@work.example"),
                       email("Dave Smith", "dave@home.example")]
        XCTAssertEqual(ContactLookupHelper.pickEmail(from: matches),
                       .ambiguous(names: ["Dave Smith", "Dave Jones"]))
    }

    func testTheSameNameSpelledWithDifferentCaseIsTheSamePerson() {
        let matches = [email("Dave Smith", "dave@work.example"),
                       email("dave smith", "dave@home.example")]
        XCTAssertEqual(ContactLookupHelper.pickEmail(from: matches), .one(matches[0]))
    }
}
