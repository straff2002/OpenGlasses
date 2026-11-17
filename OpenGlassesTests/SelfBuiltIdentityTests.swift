import XCTest
@testable import OpenGlasses

/// The id, version and author a self-built add-on gets from the app, never from the model.
final class SelfBuiltIdentityTests: XCTestCase {

    func testSlugs() {
        XCTAssertEqual(SelfBuiltIdentity.slug(from: "Tide Times"), "tide-times")
        XCTAssertEqual(SelfBuiltIdentity.slug(from: "  Café — Opening hours!! "), "cafe-opening-hours")
        XCTAssertEqual(SelfBuiltIdentity.slug(from: "潮汐"), SelfBuiltIdentity.fallbackSlug)
        XCTAssertEqual(SelfBuiltIdentity.slug(from: ""), SelfBuiltIdentity.fallbackSlug)
        let long = SelfBuiltIdentity.slug(from: String(repeating: "word ", count: 40))
        XCTAssertLessThanOrEqual(long.count, SelfBuiltIdentity.maxSlugLength)
        XCTAssertFalse(long.hasSuffix("-"))
    }

    func testIDsAreValidAndCollisionSuffixed() {
        let first = SelfBuiltIdentity.id(forName: "Tide Times", taken: [])
        XCTAssertEqual(first, "local.assistant.tide-times")
        XCTAssertTrue(RecipeAddOnValidator.isValidID(first))
        XCTAssertEqual(SelfBuiltIdentity.id(forName: "Tide Times", taken: [first]), "local.assistant.tide-times-2")
        XCTAssertEqual(SelfBuiltIdentity.id(forName: "Tide Times", taken: [first, first + "-2"]),
                       "local.assistant.tide-times-3")
        let long = SelfBuiltIdentity.id(forName: String(repeating: "abcdefgh ", count: 20), taken: [])
        XCTAssertTrue(RecipeAddOnValidator.isValidID(long))
        XCTAssertTrue(RecipeAddOnValidator.isValidID(SelfBuiltIdentity.id(forName: String(repeating: "abcdefgh ", count: 20),
                                                                          taken: [long])))
        XCTAssertTrue(SelfBuiltIdentity.isSelfBuiltID(first))
        XCTAssertFalse(SelfBuiltIdentity.isSelfBuiltID("org.example.tides"))
    }

    func testVersions() {
        XCTAssertEqual(SelfBuiltIdentity.firstVersion, "1.0.0")
        XCTAssertEqual(SelfBuiltIdentity.nextVersion(after: "1.0.0"), "1.1.0")
        XCTAssertEqual(SelfBuiltIdentity.nextVersion(after: "2.3.4"), "2.4.0")
        XCTAssertEqual(SelfBuiltIdentity.nextVersion(after: "1.2.0-rc.1+7"), "1.3.0")
        XCTAssertTrue(AddOnVersion.isNewer(SelfBuiltIdentity.nextVersion(after: "1.9.9"), than: "1.9.9"))
    }

    func testAuthorWebIsAPageThatWasReadOrTheServiceItself() throws {
        let docs = try XCTUnwrap(URL(string: "https://docs.example.org/tides?ref=search#top"))
        XCTAssertEqual(SelfBuiltIdentity.authorWeb(claimed: docs.absoluteString, fetched: [docs], serviceHosts: []),
                       "https://docs.example.org/tides")
        // A page the model names but never read is not the one shown.
        XCTAssertEqual(SelfBuiltIdentity.authorWeb(claimed: "https://elsewhere.example.com/", fetched: [docs],
                                                   serviceHosts: []), "https://docs.example.org/tides")
        XCTAssertEqual(SelfBuiltIdentity.authorWeb(claimed: "https://elsewhere.example.com/", fetched: [],
                                                   serviceHosts: ["tides.example.net"]), "https://tides.example.net")
        XCTAssertNil(SelfBuiltIdentity.authorWeb(claimed: nil, fetched: [], serviceHosts: []))
        let longPath = try XCTUnwrap(URL(string: "https://docs.example.org/" + String(repeating: "a", count: 300)))
        XCTAssertEqual(SelfBuiltIdentity.shown(longPath), "https://docs.example.org")
    }
}
