import XCTest
@testable import OpenGlasses

/// Roadmap W02.3 — one endpoint rule across every network client.
final class EndpointPolicyTests: XCTestCase {

    // MARK: - Scheme

    func testOnlyHTTPAndHTTPSAreAccepted() {
        for scheme in ["ftp", "file", "ws", "javascript", "data"] {
            let result = EndpointPolicy.validate("\(scheme)://example.com/x", for: .webSearch, build: .release)
            XCTAssertEqual(result.rejection, .disallowedScheme(scheme), scheme)
        }
        XCTAssertNil(EndpointPolicy.validate("https://example.com", for: .webSearch, build: .release).rejection)
    }

    func testUnparseableAndHostlessURLsAreRejected() {
        XCTAssertEqual(EndpointPolicy.validate("", for: .webSearch).rejection, .invalidURL(""))
        XCTAssertEqual(EndpointPolicy.validate("https:///path", for: .webSearch).rejection, .missingHost)
    }

    // MARK: - Credentials in the URL

    func testCredentialBearingURLsAreRejectedForEveryRoute() {
        for route in NetworkRoute.allCases {
            XCTAssertEqual(
                EndpointPolicy.validate("https://user:secret@example.com/v1", for: route).rejection,
                .credentialInURL, route.rawValue)
        }
    }

    func testAUsernameAloneIsStillACredential() {
        XCTAssertEqual(EndpointPolicy.validate("https://token@example.com", for: .mcpHTTPTransport).rejection,
                       .credentialInURL)
    }

    // MARK: - Private space

    func testPrivateHostsAreRejectedForNonLocalRoutes() {
        let hosts = ["127.0.0.1", "localhost", "192.168.1.10", "10.0.0.5", "172.16.4.4",
                     "169.254.169.254", "mac.local", "[::1]"]
        for host in hosts {
            let result = EndpointPolicy.validate("https://\(host)/x", for: .llmCompletion, build: .release)
            guard case .privateHostNotPermitted = result.rejection else {
                return XCTFail("\(host) should not be reachable from a cloud route: \(String(describing: result.rejection))")
            }
        }
    }

    func testLocalRoutesMayReachPrivateSpace() {
        for route: NetworkRoute in [.mcpHTTPTransport, .hermesBridgeSession, .homeAssistantCommand,
                                    .webHUDMirrorListener, .loopbackOAuthCallback] {
            XCTAssertNil(EndpointPolicy.validate("http://192.168.1.20:8123/api", for: route, build: .release).rejection,
                         route.rawValue)
        }
    }

    /// The point of keying the exception on the route: a local exception granted to the MCP
    /// transport must not let an unrelated route address the wearer's LAN.
    func testALocalExceptionCannotAuthoriseAnUnrelatedRoute() {
        let lan = "http://192.168.1.20:8123/api"
        XCTAssertNil(EndpointPolicy.validate(lan, for: .mcpHTTPTransport, build: .release).rejection)
        for route: NetworkRoute in [.webSearch, .llmCompletion, .openClawGatewaySocket,
                                    .elevenLabsSpeechSynthesis, .fhirExport, .localModelDownload] {
            guard case .privateHostNotPermitted(_, let named)? =
                    EndpointPolicy.validate(lan, for: route, build: .release).rejection else {
                return XCTFail("\(route.rawValue) borrowed the local-network exception")
            }
            XCTAssertEqual(named, route)
        }
    }

    // MARK: - Cleartext

    func testCleartextHTTPToAPublicHostIsRejectedInRelease() {
        for route: NetworkRoute in [.webSearch, .llmCompletion, .clawHubCatalog, .openClawGatewaySocket] {
            guard case .cleartextHTTPNotPermitted? =
                    EndpointPolicy.validate("http://example.com/x", for: route, build: .release).rejection else {
                return XCTFail("\(route.rawValue) allowed cleartext to a public host")
            }
        }
    }

    /// A `localNetwork` route pointed at a public host gets no cleartext exception — the exception
    /// is about the destination being on the wearer's own network, not about the route's label.
    func testALocalRouteGetsNoCleartextExceptionOffItsOwnNetwork() {
        guard case .cleartextHTTPNotPermitted? =
                EndpointPolicy.validate("http://example.com/api", for: .homeAssistantCommand, build: .release).rejection else {
            return XCTFail("a local-network route smuggled cleartext to the public internet")
        }
    }

    func testDebugBuildsKeepTheExistingDevelopmentLoop() {
        XCTAssertNil(EndpointPolicy.validate("http://example.com/x", for: .webSearch, build: .debug).rejection)
    }

    func testHTTPSToAPublicHostIsFineEverywhere() {
        for route in NetworkRoute.allCases {
            XCTAssertNil(EndpointPolicy.validate("https://api.example.com/v1", for: route, build: .release).rejection,
                         route.rawValue)
        }
    }

    // MARK: - Combined with the medical guard

    func testRequireOpenableAppliesTheMedicalRuleBeforeTheEndpointRule() {
        let previous = MedicalEgressGuard.currentMode
        MedicalEgressGuard.currentMode = { .localOnly }
        defer { MedicalEgressGuard.currentMode = previous }

        XCTAssertThrowsError(try EndpointPolicy.requireOpenable("https://api.example.com",
                                                                for: .elevenLabsSpeechSynthesis,
                                                                build: .release)) { error in
            XCTAssertTrue(error is MedicalEgressRefusal)
        }
        XCTAssertNoThrow(try EndpointPolicy.requireOpenable("https://huggingface.co/model",
                                                            for: .localModelDownload, build: .release))
    }

    func testRejectionsDescribeThemselvesUsefully() {
        let rejection = EndpointPolicy.validate("http://10.1.1.1/x", for: .webSearch, build: .release).rejection
        XCTAssertTrue(rejection?.description.contains("webSearch") == true)
        XCTAssertTrue(rejection?.description.contains("10.1.1.1") == true)
    }
}

private extension Result where Success == URL, Failure == EndpointPolicy.Rejection {
    var rejection: EndpointPolicy.Rejection? {
        if case .failure(let rejection) = self { return rejection }
        return nil
    }
}
