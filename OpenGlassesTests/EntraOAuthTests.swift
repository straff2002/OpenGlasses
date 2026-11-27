import XCTest
@testable import OpenGlasses

/// Plan NK §3 — signing in to a clinic's Microsoft 365: the client id (the clinic's own, else the
/// build's, else not set up), PKCE S256, the redirect and its state, the form-encoded token and
/// refresh bodies, and token parsing, with nothing that could show a token.
final class EntraOAuthTests: XCTestCase {

    private let clientID = "11111111-2222-3333-4444-555555555555"

    // MARK: - The client id

    func testTheClinicsOwnClientWinsThenTheBuildsThenNone() {
        let other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        XCTAssertEqual(EntraOAuth.client(bundled: clientID, clinic: other), .clinic(other))
        XCTAssertEqual(EntraOAuth.client(bundled: clientID, clinic: "  "), .bundled(clientID))
        XCTAssertEqual(EntraOAuth.client(bundled: clientID, clinic: "not-a-guid"), .bundled(clientID))
        XCTAssertEqual(EntraOAuth.client(bundled: clientID.uppercased(), clinic: nil), .bundled(clientID))
        // The build's default is empty; an unexpanded setting is not an id either.
        for bundled in [nil, "", "$(AVENKIN_ENTRA_CLIENT_ID)"] {
            XCTAssertEqual(EntraOAuth.client(bundled: bundled, clinic: nil), .notSetUp)
        }
        XCTAssertNil(EntraOAuth.Client.notSetUp.id)
        for bad in ["1111111-2222-3333-4444-555555555555", "11111111222233334444555555555555", "zzzzzzzz-2222-3333-4444-555555555555"] {
            XCTAssertFalse(EntraOAuth.isClientID(bad), bad)
        }
    }

    func testTheBuildCarriesTheClientIDKeyEmptyAndTheRedirectScheme() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("OpenGlasses/Info.plist")), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(info[EntraOAuth.bundledClientIDKey] as? String, "$(AVENKIN_ENTRA_CLIENT_ID)")
        let schemes = ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains(EntraOAuth.callbackScheme))
        let spec = try String(contentsOf: root.appendingPathComponent("project.base.yml"), encoding: .utf8)
        XCTAssertTrue(spec.contains(#"AVENKIN_ENTRA_CLIENT_ID: """#), "the build setting defaults to empty")
    }

    // MARK: - The browser leg

    /// RFC 7636 appendix B.
    func testPKCEIsS256() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testTheAuthorizeURLAsksForTheNamedScopesWithPKCEAndState() throws {
        let url = try XCTUnwrap(EntraOAuth.authorizeURL(clientID: clientID, verifier: "verifier-1", state: "state-1"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertEqual(url.path, "/organizations/oauth2/v2.0/authorize")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], clientID)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "avenkin-entra://auth")
        XCTAssertEqual(items["scope"], "offline_access User.Read Files.ReadWrite")
        XCTAssertEqual(items["code_challenge"], PKCE.challenge(for: "verifier-1"))
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertNil(items["client_secret"], "a public client has no secret")
        XCTAssertNil(EntraOAuth.authorizeURL(clientID: "nope", verifier: "v", state: "s"))
    }

    func testTheCallbackIsReadOnlyWithTheStateSent() {
        let ok = URL(string: "avenkin-entra://auth?code=abc123&state=state-1")!
        XCTAssertEqual(EntraOAuth.parseCallback(ok, expectedState: "state-1"), .code("abc123"))
        XCTAssertEqual(EntraOAuth.parseCallback(ok, expectedState: "state-2"), .invalid)
        XCTAssertEqual(EntraOAuth.parseCallback(URL(string: "avenkin-entra://auth?state=state-1")!, expectedState: "state-1"), .invalid)
        XCTAssertEqual(EntraOAuth.parseCallback(URL(string: "evil://auth?code=abc&state=state-1")!, expectedState: "state-1"), .invalid)
        let refused = URL(string: "avenkin-entra://auth?error=consent_required&error_description=AADSTS65001%20secret&state=state-1")!
        XCTAssertEqual(EntraOAuth.parseCallback(refused, expectedState: "state-1"), .refused("consent_required"))
        XCTAssertTrue(EntraOAuth.refusalSentence("consent_required").contains("administrator"))
        XCTAssertNotEqual(EntraOAuth.refusalSentence("access_denied"), EntraOAuth.refusalSentence("other"))
    }

    // MARK: - Token requests

    private func fields(_ request: GraphRequest) -> [String: String] {
        let body = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? "")
        })
    }

    func testTheTokenAndRefreshBodiesAreFormEncodedToTheTokenEndpoint() {
        let exchange = EntraOAuth.tokenRequest(clientID: clientID, code: "c&d=e", verifier: "verifier-1")
        XCTAssertEqual(exchange.host, "login.microsoftonline.com")
        XCTAssertEqual(exchange.path, "/organizations/oauth2/v2.0/token")
        XCTAssertEqual(exchange.method, .post)
        XCTAssertEqual(exchange.contentType, "application/x-www-form-urlencoded")
        XCTAssertEqual(fields(exchange), ["client_id": clientID, "grant_type": "authorization_code", "code": "c&d=e",
                                          "redirect_uri": "avenkin-entra://auth", "code_verifier": "verifier-1",
                                          "scope": EntraOAuth.scopes])
        let refresh = EntraOAuth.refreshRequest(clientID: clientID, refreshToken: "r-1")
        XCTAssertEqual(fields(refresh), ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": "r-1",
                                         "scope": EntraOAuth.scopes])
        XCTAssertTrue(EntraOAuth.isTokenRequest(exchange))
        XCTAssertTrue(EntraOAuth.isTokenRequest(refresh))
        XCTAssertFalse(EntraOAuth.isTokenRequest(GraphRequest(method: .post, host: EntraOAuth.loginHost, path: "/common/oauth2/v2.0/token",
                                                              body: refresh.body, contentType: refresh.contentType)))
        XCTAssertFalse(EntraOAuth.isTokenRequest(GraphRequest(method: .post, host: EntraOAuth.loginHost, path: EntraOAuth.tokenPath,
                                                              body: Data("client_id=x&client_secret=y".utf8),
                                                              contentType: refresh.contentType)))
    }

    // MARK: - Token replies

    func testATokenReplyIsParsedAndKeptWithItsExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"{"token_type":"Bearer","access_token":"a.b.c","refresh_token":"r-2","expires_in":3600,"scope":"x"}"#.utf8)
        let response = try XCTUnwrap(EntraOAuth.parseToken(data))
        let credentials = EntraOAuth.Credentials(response: response, now: now)
        XCTAssertEqual(credentials.accessToken, "a.b.c")
        XCTAssertEqual(credentials.refreshToken, "r-2")
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(credentials.needsRefresh(now: now))
        XCTAssertTrue(credentials.needsRefresh(now: now.addingTimeInterval(3400)), "five minutes ahead of expiry")
        XCTAssertNil(EntraOAuth.parseToken(Data(#"{"refresh_token":"r"}"#.utf8)))
        XCTAssertNil(EntraOAuth.parseToken(Data(#"{"access_token":"a b"}"#.utf8)), "a token with a space is not sent")
    }

    func testARefreshWithoutANewRefreshTokenKeepsTheOldOne() throws {
        let response = try XCTUnwrap(EntraOAuth.parseToken(Data(#"{"access_token":"new","expires_in":60}"#.utf8)))
        let credentials = EntraOAuth.Credentials(response: response, now: Date(), previousRefreshToken: "r-old")
        XCTAssertEqual(credentials.refreshToken, "r-old")
    }

    func testNoDescriptionShowsAToken() throws {
        let response = try XCTUnwrap(EntraOAuth.parseToken(Data(#"{"access_token":"secret-access","refresh_token":"secret-refresh"}"#.utf8)))
        let credentials = EntraOAuth.Credentials(response: response, now: Date())
        let record = ClinicWorkbookConnectionRecord(clientID: clientID, credentials: credentials, account: nil,
                                                    workbook: nil, workbookName: nil, country: "CA", lastSentAt: nil)
        for text in [String(describing: credentials), String(reflecting: credentials), String(describing: record),
                     String(reflecting: record), "\(Mirror(reflecting: credentials).children.map(\.value))",
                     "\(Mirror(reflecting: record).children.map(\.value))"] {
            XCTAssertFalse(text.contains("secret"), text)
        }
    }
}
