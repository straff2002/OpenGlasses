import XCTest
@testable import OpenGlasses

/// Network allowlist entries: exact hosts and one-label wildcards; IPs, ports, paths and public
/// suffixes refused.
final class AddOnDomainRuleTests: XCTestCase {

    private func rule(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> AddOnDomainRule? {
        switch AddOnDomainRule.parse(raw) {
        case .success(let r): return r
        case .failure(let e): XCTFail("\(raw) refused: \(e)", file: file, line: line); return nil
        }
    }

    private func error(_ raw: String) -> AddOnDomainRule.ParseError? {
        if case .failure(let e) = AddOnDomainRule.parse(raw) { return e }
        return nil
    }

    func testExactHostMatchesOnlyItself() throws {
        let r = try XCTUnwrap(rule("api.frankfurter.dev"))
        XCTAssertFalse(r.isWildcard)
        XCTAssertTrue(r.matches(host: "api.frankfurter.dev"))
        XCTAssertTrue(r.matches(host: "API.Frankfurter.DEV"))
        XCTAssertTrue(r.matches(host: "api.frankfurter.dev."))
        XCTAssertFalse(r.matches(host: "x.api.frankfurter.dev"))
        XCTAssertFalse(r.matches(host: "frankfurter.dev"))
        XCTAssertFalse(r.matches(host: "api.frankfurter.dev.evil.com"))
        XCTAssertFalse(r.matches(host: "evilapi.frankfurter.dev"))
    }

    func testWildcardMatchesExactlyOneLabel() throws {
        let r = try XCTUnwrap(rule("*.wikipedia.org"))
        XCTAssertTrue(r.isWildcard)
        XCTAssertEqual(r.base, "wikipedia.org")
        XCTAssertEqual(r.display, "*.wikipedia.org")
        XCTAssertTrue(r.matches(host: "en.wikipedia.org"))
        XCTAssertTrue(r.matches(host: "DE.wikipedia.org"))
        XCTAssertFalse(r.matches(host: "wikipedia.org"))
        XCTAssertFalse(r.matches(host: "en.m.wikipedia.org"))
        XCTAssertFalse(r.matches(host: "enwikipedia.org"))
        XCTAssertFalse(r.matches(host: "en.wikipedia.org.evil.com"))
    }

    func testNormalisation() throws {
        XCTAssertEqual(rule("API.Example.ORG")?.base, "api.example.org")
        XCTAssertEqual(rule("api.example.org.")?.base, "api.example.org")
        XCTAssertEqual(rule("*.Example.org.")?.display, "*.example.org")
    }

    func testIPLiteralsAreRefused() {
        for ip in ["127.0.0.1", "10.0.0.8", "192.168.1.1", "2130706433", "0x7f.0x0.0x0.0x1", "0x7f000001", "1.2.3"] {
            XCTAssertNotNil(error(ip), ip)
        }
        XCTAssertEqual(error("127.0.0.1"), .ipLiteral)
        for ip in ["::1", "[::1]", "fe80::1", "[2001:db8::1]"] {
            XCTAssertEqual(error(ip), .ipLiteral, ip)
        }
        XCTAssertFalse(AddOnDomainRule.allows(host: "127.0.0.1", rules: [rule("*.example.org")!]))
        XCTAssertNil(AddOnDomainRule.normalisedHost("127.0.0.1"))
        XCTAssertNil(AddOnDomainRule.normalisedHost("[::1]"))
    }

    func testPortsPathsQueriesAndUserinfoAreRefused() {
        XCTAssertEqual(error("api.example.org:443"), .hasPort)
        XCTAssertEqual(error("https://api.example.org"), .notAHostName)
        XCTAssertEqual(error("api.example.org/v1"), .notAHostName)
        XCTAssertEqual(error("api.example.org?x=1"), .notAHostName)
        XCTAssertEqual(error("api.example.org#x"), .notAHostName)
        XCTAssertEqual(error("user@api.example.org"), .notAHostName)
        XCTAssertEqual(error("api example.org"), .notAHostName)
    }

    func testMalformedNamesAreRefused() {
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("api..example.org"), .emptyLabel)
        XCTAssertEqual(error(".example.org"), .emptyLabel)
        // The trailing dot goes first, leaving a bare `*`.
        XCTAssertEqual(error("*."), .misplacedWildcard)
        XCTAssertEqual(error("localhost"), .singleLabel)
        XCTAssertEqual(error("-bad.example.org"), .invalidLabel("-bad"))
        XCTAssertEqual(error("bücher.example"), .nonASCII)
        XCTAssertEqual(error(String(repeating: "a", count: 64) + ".org"), .invalidLabel(String(repeating: "a", count: 64)))
    }

    func testWildcardMustBeOneLeadingLabel() {
        XCTAssertEqual(error("api.*.example.org"), .misplacedWildcard)
        XCTAssertEqual(error("*.*.example.org"), .misplacedWildcard)
        XCTAssertEqual(error("a*.example.org"), .misplacedWildcard)
        XCTAssertEqual(error("*example.org"), .misplacedWildcard)
        XCTAssertEqual(error("*"), .misplacedWildcard)
    }

    func testWildcardOverAPublicSuffixIsRefused() {
        XCTAssertEqual(error("*.com"), .wildcardOverPublicSuffix("com"))
        XCTAssertEqual(error("*.uk"), .wildcardOverPublicSuffix("uk"))
        XCTAssertEqual(error("*.github.io"), .wildcardOverPublicSuffix("github.io"))
        XCTAssertEqual(error("*.co.uk"), .wildcardOverPublicSuffix("co.uk"))
        XCTAssertEqual(error("*.CO.UK"), .wildcardOverPublicSuffix("co.uk"))
        for suffix in ["com.au", "co.nz", "govt.nz", "co.jp", "herokuapp.com", "s3.amazonaws.com", "ngrok-free.app", "duckdns.org"] {
            XCTAssertEqual(error("*.\(suffix)"), .wildcardOverPublicSuffix(suffix), suffix)
        }
        // A real site under a suffix is fine, exactly or wildcarded.
        XCTAssertNotNil(rule("*.bbc.co.uk"))
        XCTAssertNotNil(rule("example.github.io"))
        XCTAssertNotNil(rule("*.example.github.io"))
    }

    func testAllowlistParsing() {
        let parsed = AddOnDomainRule.parseAllowlist(["api.example.org", "API.example.org", "*.github.io", "x.org"])
        XCTAssertEqual(parsed.rules.map(\.display), ["api.example.org", "x.org"])
        XCTAssertEqual(parsed.failures.map(\.entry), ["*.github.io"])
        XCTAssertFalse(parsed.tooMany)
        XCTAssertTrue(AddOnDomainRule.parseAllowlist((0...30).map { "h\($0).example.org" }).tooMany)
        XCTAssertFalse(AddOnDomainRule.parseAllowlist((0..<30).map { "h\($0).example.org" }).tooMany)
    }
}
