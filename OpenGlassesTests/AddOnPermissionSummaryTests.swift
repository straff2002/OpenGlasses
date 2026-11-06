import XCTest
@testable import OpenGlasses

/// The plain-words permission lines an install sheet shows.
final class AddOnPermissionSummaryTests: XCTestCase {

    private typealias Perms = RecipeAddOnManifest.Permissions

    func testNothingGrantedShowsOnlyTheFixedLine() {
        let lines = AddOnPermissionSummary.lines(for: .empty)
        XCTAssertEqual(lines.map(\.kind), [.never])
        XCTAssertEqual(lines.first?.text,
                       "It can never reach your contacts, camera, health data, messages, calendar, photos or microphone.")
    }

    func testEveryPermissionInPlainWords() {
        let perms = Perms(network: ["api.frankfurter.dev", "*.Wikipedia.org", "api.frankfurter.dev"],
                          location: true, memory: true, display: true)
        let lines = AddOnPermissionSummary.lines(for: perms)
        XCTAssertEqual(lines.map(\.kind), [.network, .location, .memory, .display, .never])
        XCTAssertEqual(lines.map(\.text), [
            "Connect to: api.frankfurter.dev, *.wikipedia.org",
            "Use your approximate location (about 1 km) when you ask it something",
            "Save things to your memory. It can't read what's already there.",
            "Show cards on your phone, watch and glasses display",
            AddOnPermissionSummary.neverLine,
        ])
    }

    func testCurrencyExampleNamesItsDomain() {
        let lines = AddOnPermissionSummary.lines(for: RecipeAddOnFixtures.currencyManifest.permissions)
        XCTAssertEqual(lines.first?.text, "Connect to: api.frankfurter.dev")
    }

    func testTheWordingNamesNoInternalPlan() {
        let all = AddOnPermissionSummary.lines(for: Perms(network: ["a.example.org"], location: true, memory: true, display: true))
        for line in all {
            XCTAssertNil(line.text.range(of: #"\bPlan [A-Z]{1,2}\b"#, options: .regularExpression), line.text)
        }
    }
}
