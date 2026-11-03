import XCTest
@testable import OpenGlasses

/// Tests for the pure Google OAuth + Vertex endpoint logic (Plan AI). Mirrors
/// `ClaudeOAuthTests`: the network/persistence edge (`GoogleOAuthService`) is covered only for
/// its refresh (Plan FG P1a), through the request stubs and an in-memory credential store —
/// never the keychain, the browser session or the network.
final class GoogleOAuthTests: XCTestCase {

    // The request path is the subject, so sharing is approved for the services it scripts.
    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://us-central1-aiplatform.googleapis.com",
            "https://aiplatform.googleapis.com",
            "https://oauth2.googleapis.com",
            "https://generativelanguage.googleapis.com"
        ])
    }

    override func tearDown() {
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    private let clientID = "123456-abcdef.apps.googleusercontent.com"

    // MARK: - Client-ID derived pieces

    func testCallbackSchemeIsReverseDNSOfClientID() {
        XCTAssertEqual(GoogleOAuth.callbackScheme(clientID: clientID),
                       "com.googleusercontent.apps.123456-abcdef")
        XCTAssertEqual(GoogleOAuth.redirectURI(clientID: clientID),
                       "com.googleusercontent.apps.123456-abcdef:/oauth2redirect")
    }

    func testCallbackSchemeRejectsMalformedClientIDs() {
        for bad in ["", "not-a-google-id", ".apps.googleusercontent.com",
                    "a/b.apps.googleusercontent.com", "a:b.apps.googleusercontent.com"] {
            XCTAssertNil(GoogleOAuth.callbackScheme(clientID: bad), "accepted: \(bad)")
        }
        // Whitespace is tolerated (Settings paste).
        XCTAssertNotNil(GoogleOAuth.callbackScheme(clientID: " \(clientID)\n"))
    }

    // MARK: - Authorize URL

    func testAuthorizeURLCarriesPKCEIdentityAndOfflineAccess() throws {
        let verifier = "test-verifier-test-verifier-test-verifier-1"
        let url = try XCTUnwrap(GoogleOAuth.authorizeURL(clientID: clientID, verifier: verifier, state: "st4te"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "accounts.google.com")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], clientID)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.123456-abcdef:/oauth2redirect")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/cloud-platform")
        XCTAssertEqual(items["code_challenge"], PKCE.challenge(for: verifier))
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "st4te")
        // Google only issues a refresh token with offline access + forced consent.
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
    }

    func testAuthorizeURLNilForBadClientID() {
        XCTAssertNil(GoogleOAuth.authorizeURL(clientID: "nope", verifier: "v", state: "s"))
    }

    // MARK: - Callback parsing

    func testParseCallbackExtractsCodeAndState() throws {
        let url = try XCTUnwrap(URL(string:
            "com.googleusercontent.apps.123456-abcdef:/oauth2redirect?code=4%2FabcXYZ&state=st4te&scope=x"))
        let parsed = try XCTUnwrap(GoogleOAuth.parseCallback(url: url))
        XCTAssertEqual(parsed.code, "4/abcXYZ")   // percent-decoded by URLComponents
        XCTAssertEqual(parsed.state, "st4te")
    }

    func testParseCallbackRejectsMissingCode() throws {
        let url = try XCTUnwrap(URL(string: "com.googleusercontent.apps.x:/oauth2redirect?error=access_denied"))
        XCTAssertNil(GoogleOAuth.parseCallback(url: url))
    }

    // MARK: - Token requests (form-encoded)

    func testTokenExchangeRequestIsFormEncodedWithPKCE() throws {
        let request = try XCTUnwrap(GoogleOAuth.tokenExchangeRequest(
            clientID: clientID, code: "4/abc", verifier: "ver1f1er"))
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=4%2Fabc"))                       // slash percent-encoded
        XCTAssertTrue(body.contains("code_verifier=ver1f1er"))
        XCTAssertTrue(body.contains("client_id=123456-abcdef.apps.googleusercontent.com"))
        XCTAssertTrue(body.contains("redirect_uri=com.googleusercontent.apps.123456-abcdef%3A%2Foauth2redirect"))
    }

    func testRefreshRequestBody() throws {
        let request = GoogleOAuth.refreshRequest(clientID: clientID, refreshToken: "r-token")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=r-token"))
        XCTAssertFalse(body.contains("redirect_uri"))
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(GoogleOAuth.formEncode([("a", "x y&z=+")]), "a=x%20y%26z%3D%2B")
    }

    // MARK: - Token response / credentials

    func testTokenResponseDecodingAndExpiryLeeway() throws {
        let json = #"{"access_token":"ya29.abc","refresh_token":"r1","expires_in":3600}"#
        let response = try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credentials = GoogleOAuth.Credentials(response: response, now: now)
        XCTAssertEqual(credentials.accessToken, "ya29.abc")
        XCTAssertEqual(credentials.refreshToken, "r1")
        XCTAssertFalse(credentials.needsRefresh(now: now))
        XCTAssertFalse(credentials.needsRefresh(now: now.addingTimeInterval(3600 - 301)))
        XCTAssertTrue(credentials.needsRefresh(now: now.addingTimeInterval(3600 - 299)))  // inside leeway
        XCTAssertTrue(credentials.needsRefresh(now: now.addingTimeInterval(4000)))
    }

    func testRefreshResponseKeepsPreviousRefreshToken() throws {
        // Google omits refresh_token on refresh responses.
        let json = #"{"access_token":"ya29.new","expires_in":3600}"#
        let response = try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: Data(json.utf8))
        let credentials = GoogleOAuth.Credentials(response: response, previousRefreshToken: "r-old")
        XCTAssertEqual(credentials.refreshToken, "r-old")
    }

    func testCredentialsWithoutExpiryNeverNeedRefresh() throws {
        let json = #"{"access_token":"ya29.x"}"#
        let response = try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: Data(json.utf8))
        XCTAssertFalse(GoogleOAuth.Credentials(response: response).needsRefresh())
    }

    // MARK: - Vertex endpoints

    func testVertexRegionalEndpoint() {
        XCTAssertEqual(
            VertexAI.endpointURL(projectID: "my-proj", region: "us-central1", model: "gemini-2.0-flash")?.absoluteString,
            "https://us-central1-aiplatform.googleapis.com/v1/projects/my-proj/locations/us-central1/publishers/google/models/gemini-2.0-flash:generateContent")
    }

    func testVertexGlobalEndpointUsesBareHost() {
        XCTAssertEqual(
            VertexAI.endpointURL(projectID: "p", region: "Global", model: "m")?.absoluteString,
            "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models/m:generateContent")
    }

    func testVertexEndpointRejectsInvalidComponents() {
        XCTAssertNil(VertexAI.endpointURL(projectID: "", region: "us-central1", model: "m"))
        XCTAssertNil(VertexAI.endpointURL(projectID: "p", region: "", model: "m"))
        XCTAssertNil(VertexAI.endpointURL(projectID: "p", region: "us-central1", model: ""))
        XCTAssertNil(VertexAI.endpointURL(projectID: "a/b", region: "r", model: "m"))       // traversal-ish
        XCTAssertNil(VertexAI.endpointURL(projectID: "p", region: "r?x=1", model: "m"))     // query smuggling
    }

    func testVertexAuthIsBearerNotQueryKey() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com")))
        VertexAI.apply(accessToken: "ya29.tok", to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.url?.absoluteString.contains("key=") ?? true)
    }

    // MARK: - Provider surface

    func testVertexProviderNeedsNoAPIKeyAndOwnsNoListing() {
        XCTAssertFalse(LLMProvider.geminiVertex.requiresAPIKey)
        XCTAssertFalse(LLMProvider.geminiVertex.supportsModelListing)
        XCTAssertFalse(LLMProvider.geminiVertex.isOpenAICompatible)
        XCTAssertTrue(ModelConfig.inferredSupportsVision(provider: .geminiVertex, model: "gemini-2.0-flash", baseURL: ""))
    }

    // MARK: - Refresh (Plan FG P1a)

    @MainActor
    private func connectedAccount(issued: Date, session: URLSession = RecordingQueueProtocol.session())
        throws -> (GoogleOAuthService, InMemoryCredentialStore) {
        let response = try OAuthRefreshFixture.decode(
            GoogleOAuth.TokenResponse.self,
            OAuthRefreshFixture.tokenBody(access: "google-access-fixture-old", refresh: "refresh-fixture-old"))
        let holder = InMemoryCredentialStore(holding: GoogleOAuth.Credentials(response: response, now: issued))
        let service = GoogleOAuthService(store: holder.store, session: session, refresher: SingleFlightRefresher())
        return (service, holder)
    }

    @MainActor
    func testANetworkFailureKeepsTheCredentials() async throws {
        OfflineURLProtocol.reset()
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue,
                                                     session: OfflineURLProtocol.session())

        let token = await service.validAccessToken()

        XCTAssertNil(token)
        XCTAssertTrue(service.isConnected, "a dropped connection signed the wearer out")
        XCTAssertEqual(holder.decoded(GoogleOAuth.Credentials.self)?.refreshToken, "refresh-fixture-old")
        XCTAssertEqual(service.lastError, "Couldn't reach the Google sign-in service; I'll try again.")
    }

    @MainActor
    func testExpiredOrRevokedDiscardsTheCredential() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        _ = await service.validAccessToken()

        XCTAssertFalse(service.isConnected)
        XCTAssertNil(holder.data)
        XCTAssertEqual(service.lastError, "Google sign-in expired — please sign in again.")
    }

    @MainActor
    func testARefreshKeepsGooglesUnrotatedRefreshToken() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(200, OAuthRefreshFixture.tokenBody(access: "google-access-fixture-new", refresh: nil))]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        let token = await service.validAccessToken()

        XCTAssertEqual(token, "google-access-fixture-new")
        XCTAssertEqual(holder.decoded(GoogleOAuth.Credentials.self)?.refreshToken, "refresh-fixture-old")
        XCTAssertNil(service.lastError)
    }

    /// The Vertex turn reads its project from settings; the test sets one and puts the old back.
    @MainActor
    private func withVertexProject(_ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.string(forKey: "vertexProjectID")
        Config.setVertexProjectID("fixture-project")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "vertexProjectID") }
            else { UserDefaults.standard.removeObject(forKey: "vertexProjectID") }
        }
        try await body()
    }

    @MainActor
    private func vertexRoute(_ account: GoogleOAuthService) -> LLMService {
        let llm = LLMService()
        llm.dataSession = RecordingQueueProtocol.session()
        llm.googleAccountOverride = account
        return llm
    }

    private let vertexConfig = ModelConfig(id: "fg", name: "fg", provider: LLMProvider.geminiVertex.rawValue,
                                           apiKey: "", model: "gemini-2.5-flash", baseURL: "")

    @MainActor
    func testA401ForcesOneRefreshAndOneRetry() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [
            (401, OAuthRefreshFixture.vertexUnauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "google-access-fixture-new", refresh: nil)),
            (200, OAuthRefreshFixture.geminiReply),
        ]
        let (account, _) = try connectedAccount(issued: Date())
        let llm = vertexRoute(account)

        try await withVertexProject {
            let reply = try await llm.sendGemini("What's the weather?", systemPrompt: "Be brief.",
                                                 config: vertexConfig, includeTools: false, imageData: nil)
            XCTAssertEqual(reply, "It is sunny.")
        }
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer google-access-fixture-old")
        XCTAssertTrue(requests.dropFirst().first?.bodyText.contains("grant_type=refresh_token") ?? false)
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer google-access-fixture-new")
    }

    @MainActor
    func testASecond401SurfacesWithoutAnotherRefresh() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [
            (401, OAuthRefreshFixture.vertexUnauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "google-access-fixture-new", refresh: nil)),
            (401, OAuthRefreshFixture.vertexUnauthorized),
        ]
        let (account, _) = try connectedAccount(issued: Date())
        let llm = vertexRoute(account)

        await withVertexProject {
            do {
                _ = try await llm.sendGemini("What's the weather?", systemPrompt: "Be brief.",
                                             config: vertexConfig, includeTools: false, imageData: nil)
                XCTFail("a second 401 should surface")
            } catch {
                XCTAssertTrue(SubscriptionAuthRetry.isUnauthorized(error), "\(error)")
            }
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 3, "one refresh and one retry, no more")
    }
}
