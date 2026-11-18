import Network
import XCTest
@testable import OpenGlasses

/// `LocalNetworkAccessHint`: a failure is read as a possibly refused Local Network permission only
/// when the system said so, or when a host on the wearer's network failed the way a refused path
/// fails. Never for a public host, and never for an answer the server gave.
final class LocalNetworkAccessHintTests: XCTestCase {

    private func urlError(_ code: URLError.Code, url: String? = nil,
                          streamCode: Int32? = nil, extra: [String: Any] = [:]) -> URLError {
        var info: [String: Any] = extra
        if let url { info[NSURLErrorFailingURLErrorKey] = URL(string: url)! }
        if let streamCode {
            info["_kCFStreamErrorCodeKey"] = Int(streamCode)
            info["_kCFStreamErrorDomainKey"] = 1
        }
        return URLError(code, userInfo: info)
    }

    // MARK: - The hint applies

    func testALANHostThatLooksOfflineGetsTheHint() {
        let error = urlError(.notConnectedToInternet, url: "http://192.168.1.20:18789/health", streamCode: ENETDOWN)
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(error))
        XCTAssertEqual(LocalNetworkAccessHint.line(for: error, target: .agentGateway),
                       LocalNetworkAccessHint.message(for: .agentGateway))
    }

    func testTheHostCanBeGivenWhenTheErrorDoesNotCarryIt() {
        let error = urlError(.notConnectedToInternet)
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(error, host: "10.0.0.5"))
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(error, host: "studio.local"))
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(error, host: "169.254.10.2"))
    }

    func testAnUnreachableSocketOnALANHostGetsTheHint() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(posix, host: "192.168.0.8"))
        let wrapped = urlError(.cannotConnectToHost, url: "http://172.16.4.2:11434/v1/models",
                               extra: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENETUNREACH))])
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(wrapped))
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(NWError.posix(.ENETDOWN), host: "192.168.0.8"))
    }

    func testThePathsOwnWordIsEnoughWhateverTheHost() {
        let error = urlError(.notConnectedToInternet, url: "http://nas.example.org/",
                             extra: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, dns"])
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(error))
    }

    func testABonjourPolicyDenialGetsTheHint() {
        XCTAssertTrue(LocalNetworkAccessHint.isLikelyDenied(NWError.dns(-65570)))
    }

    // MARK: - The hint does not apply

    func testAPublicHostNeverGetsTheHint() {
        let error = urlError(.notConnectedToInternet, url: "https://api.example.com/v1/models", streamCode: ENETDOWN)
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(error))
        XCTAssertNil(LocalNetworkAccessHint.line(for: error, target: .aiServer))
    }

    func testALANHostWithAnUnrelatedFailureGetsNoHint() {
        let host = "192.168.1.20"
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(urlError(.userAuthenticationRequired), host: host),
                       "an HTTP 401 is the server answering")
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(HermesAgentAPIError.unauthorized, host: host))
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(urlError(.timedOut), host: host),
                       "a refused path fails at once, not after a timeout")
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(urlError(.secureConnectionFailed), host: host))
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(urlError(.badServerResponse), host: host))
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(urlError(.cannotConnectToHost), host: host),
                       "cannot-connect alone is a server that is down")
    }

    func testARefusedConnectionRulesThePermissionOut() {
        let refused = urlError(.notConnectedToInternet, url: "http://192.168.1.20:8642/health", streamCode: ECONNREFUSED)
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(refused))
    }

    func testLoopbackAndVPNAddressesAreNotGated() {
        let error = urlError(.notConnectedToInternet)
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(error, host: "127.0.0.1"))
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(error, host: "localhost"))
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(error, host: "100.101.102.103"))
        XCTAssertFalse(LocalNetworkAccessHint.isLikelyDenied(error), "no host, no hint")
    }

    // MARK: - Wording

    func testEveryLineNamesTheAppAndTheSettingAndHedges() {
        for target: LocalNetworkAccessHint.Target in [.agentGateway, .hermesAgent, .mcpServer, .aiServer] {
            let line = LocalNetworkAccessHint.message(for: target)
            XCTAssertTrue(line.contains("Avenkin"), line)
            XCTAssertTrue(line.contains("Local Network"), line)
            XCTAssertTrue(line.contains("If "), "the permission is a possibility, not a finding: \(line)")
            XCTAssertLessThan(line.count, 200, line)
        }
    }

    func testHermesSaysItThroughItsOwnDiagnosis() {
        XCTAssertEqual(HermesConnectionDiagnosis.localNetworkMayBeOff.explanation,
                       LocalNetworkAccessHint.message(for: .hermesAgent))
        XCTAssertEqual(HermesAgentAPIError.localNetworkMayBeOff.errorDescription,
                       LocalNetworkAccessHint.message(for: .hermesAgent))
        XCTAssertFalse(HermesConnectionDiagnosis.localNetworkMayBeOff.isSuccess)
    }

    func testAFailedTurnOnALANModelServerSaysTheHintEvenWithNarrationOff() {
        let error = urlError(.notConnectedToInternet, url: "http://192.168.1.50:11434/v1/chat/completions")
        XCTAssertEqual(ModelSwitchNarrator.failureLine(error, narrate: false),
                       LocalNetworkAccessHint.message(for: .aiServer))
        let publicError = urlError(.notConnectedToInternet, url: "https://api.example.com/v1/chat")
        XCTAssertNotEqual(ModelSwitchNarrator.failureLine(publicError, narrate: false),
                          LocalNetworkAccessHint.message(for: .aiServer))
    }
}
