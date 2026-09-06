import XCTest
@testable import OpenGlasses

/// Plan BC (docs/plans/BC-unconditional-safety-gate.md): the unconditional actuation floor, the
/// MCP server bearer-token check, and the SSRF URL guard.
final class SafetyGateTests: XCTestCase {

    // MARK: - HighImpactToolPolicy

    func testSmartHomeUnlockRequiresConfirmation() {
        if case .requiresConfirmation = HighImpactToolPolicy.evaluate(
            tool: "smart_home", args: ["action": "unlock", "device": "front door"]) {} else {
            XCTFail("unlock must require confirmation")
        }
    }

    func testSmartHomeLightOnProceeds() {
        XCTAssertEqual(HighImpactToolPolicy.evaluate(tool: "smart_home", args: ["action": "on", "device": "lamp"]),
                       .proceed, "turning a light on is not a security actuation")
    }

    func testSmartHomeListProceeds() {
        XCTAssertEqual(HighImpactToolPolicy.evaluate(tool: "smart_home", args: ["action": "list"]), .proceed)
    }

    func testSmartHomeDisarmAndOpenRequireConfirmation() {
        for action in ["disarm", "open", "unlock", "arm"] {
            if case .requiresConfirmation = HighImpactToolPolicy.evaluate(
                tool: "smart_home", args: ["action": action]) {} else {
                XCTFail("\(action) must require confirmation")
            }
        }
    }

    func testHomeAssistantUnlockServiceRequiresConfirmation() {
        if case .requiresConfirmation = HighImpactToolPolicy.evaluate(
            tool: "home_assistant", args: ["service": "lock.unlock", "entity_id": "lock.front"]) {} else {
            XCTFail("HA lock.unlock must require confirmation")
        }
    }

    func testHomeAssistantWeatherQueryProceeds() {
        XCTAssertEqual(HighImpactToolPolicy.evaluate(tool: "home_assistant", args: ["text": "what's the temperature"]),
                       .proceed)
    }

    func testUnrelatedToolProceeds() {
        XCTAssertEqual(HighImpactToolPolicy.evaluate(tool: "get_weather", args: [:]), .proceed)
        XCTAssertFalse(HighImpactToolPolicy.mayRequireConfirmation(tool: "get_weather"))
        XCTAssertTrue(HighImpactToolPolicy.mayRequireConfirmation(tool: "smart_home"))
    }

    // MARK: - MCP server auth

    @MainActor
    func testMCPServerRejectsMissingOrWrongToken() {
        XCTAssertFalse(MCPGlassesServer.isAuthorized(bearer: nil, expected: "secret"))
        XCTAssertFalse(MCPGlassesServer.isAuthorized(bearer: "", expected: "secret"))
        XCTAssertFalse(MCPGlassesServer.isAuthorized(bearer: "wrong", expected: "secret"))
        XCTAssertFalse(MCPGlassesServer.isAuthorized(bearer: "secret", expected: ""))
    }

    @MainActor
    func testMCPServerAcceptsMatchingToken() {
        XCTAssertTrue(MCPGlassesServer.isAuthorized(bearer: "s3cr3t-token", expected: "s3cr3t-token"))
    }

    // MARK: - URLFetchGuard

    func testGuardAllowsPublicHTTPS() {
        guard case .success = URLFetchGuard.validate("https://museum.example.com/guide.json") else {
            return XCTFail("public https should pass")
        }
    }

    func testGuardRejectsAmbiguousAndDocumentOnlyAddresses() {
        for host in ["2130706433", "0177.0.0.1", "0x7f000001", "192.0.2.1",
                     "198.18.0.1", "198.51.100.2", "203.0.113.9", "2001:db8::1", "100::1"] {
            XCTAssertTrue(URLFetchGuard.isBlockedHost(host), host)
        }
    }

    func testGuardBlocksPrivateIPv4() {
        for host in ["http://192.168.1.1/x", "http://10.0.0.5/y", "http://172.16.3.4/z",
                     "http://127.0.0.1/local", "http://169.254.169.254/latest/meta-data"] {
            guard case .failure = URLFetchGuard.validate(host) else {
                return XCTFail("\(host) must be blocked")
            }
        }
    }

    func testGuardBlocksLocalhostAndDotLocal() {
        XCTAssertTrue(URLFetchGuard.isBlockedHost("localhost"))
        XCTAssertTrue(URLFetchGuard.isBlockedHost("printer.local"))
        XCTAssertTrue(URLFetchGuard.isBlockedHost("api.internal"))
        XCTAssertFalse(URLFetchGuard.isBlockedHost("example.com"))
    }

    func testGuardBlocksNonHTTPSchemes() {
        for s in ["file:///etc/passwd", "ftp://host/x", "gopher://host"] {
            guard case .failure(.disallowedScheme) = URLFetchGuard.validate(s) else {
                return XCTFail("\(s) scheme must be rejected")
            }
        }
    }

    func testGuardBlocksIPv6LoopbackAndULA() {
        XCTAssertTrue(URLFetchGuard.isBlockedHost("[::1]"))
        XCTAssertTrue(URLFetchGuard.isBlockedHost("[fe80::1]"))
        XCTAssertTrue(URLFetchGuard.isBlockedHost("[fd00::1]"))
        XCTAssertTrue(URLFetchGuard.isBlockedHost("[::ffff:192.168.0.1]"))
    }

    func testGuardBlocksCGNATAndMulticast() {
        XCTAssertTrue(URLFetchGuard.isBlockedHost("100.64.0.1"))
        XCTAssertTrue(URLFetchGuard.isBlockedHost("224.0.0.1"))
        XCTAssertFalse(URLFetchGuard.isBlockedHost("8.8.8.8"))
    }
}
