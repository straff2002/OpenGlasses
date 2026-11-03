import XCTest
@testable import OpenGlasses

/// Pure-logic coverage for the "Sign in with Claude" OAuth core: PKCE derivation,
/// authorize-URL construction, pasted-code parsing, token-response decoding, expiry
/// logic, and the OAuth-vs-API-key header split. The network/persistence edge
/// (`ClaudeOAuthService`) is covered only for its refresh (Plan FG P1a), through the request
/// stubs and an in-memory credential store — never the keychain or the network.
final class ClaudeOAuthTests: XCTestCase {

    // The request path is the subject, so sharing is approved for the services it scripts.
    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://api.anthropic.com",
            "https://console.anthropic.com"
        ])
    }

    override func tearDown() {
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    // MARK: - PKCE

    func testChallengeMatchesRFC7636Vector() {
        // Appendix B of RFC 7636 — the canonical S256 test vector.
        XCTAssertEqual(
            ClaudeOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierIsBase64URLWithoutPadding() {
        // 32 bytes → 43 chars, no '+', '/', or '='.
        let verifier = ClaudeOAuth.verifier(from: Data(repeating: 0xFB, count: 32))
        XCTAssertEqual(verifier.count, 43)
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
        XCTAssertFalse(verifier.contains("="))
    }

    func testMakeVerifierIsRandomAndWellFormed() {
        let a = ClaudeOAuth.makeVerifier()
        let b = ClaudeOAuth.makeVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 43)
    }

    // MARK: - Authorize URL

    func testAuthorizeURLCarriesPKCEAndIdentity() throws {
        let url = try XCTUnwrap(ClaudeOAuth.authorizeURL(verifier: "test-verifier", state: "test-state"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.host, "claude.ai")
        XCTAssertEqual(params["client_id"], ClaudeOAuth.clientID)
        XCTAssertEqual(params["response_type"], "code")
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["code_challenge"], ClaudeOAuth.challenge(for: "test-verifier"))
        XCTAssertEqual(params["state"], "test-state")
        XCTAssertEqual(params["redirect_uri"], ClaudeOAuth.redirectURI)
        XCTAssertEqual(params["scope"], ClaudeOAuth.scopes)
    }

    // MARK: - Pasted-code parsing

    func testParseCodeHashState() throws {
        let parsed = try XCTUnwrap(ClaudeOAuth.parseAuthorizationInput("abc123#state456"))
        XCTAssertEqual(parsed.code, "abc123")
        XCTAssertEqual(parsed.state, "state456")
    }

    func testParseBareCodeAndWhitespace() throws {
        let parsed = try XCTUnwrap(ClaudeOAuth.parseAuthorizationInput("  abc123 \n"))
        XCTAssertEqual(parsed.code, "abc123")
        XCTAssertNil(parsed.state)
    }

    func testParsePastedCallbackURL() throws {
        let parsed = try XCTUnwrap(ClaudeOAuth.parseAuthorizationInput(
            "https://console.anthropic.com/oauth/code/callback?code=abc123&state=xyz"
        ))
        XCTAssertEqual(parsed.code, "abc123")
        XCTAssertEqual(parsed.state, "xyz")
    }

    func testParseRejectsEmptyInput() {
        XCTAssertNil(ClaudeOAuth.parseAuthorizationInput("   "))
        XCTAssertNil(ClaudeOAuth.parseAuthorizationInput(""))
    }

    // MARK: - Token requests

    func testTokenExchangeRequestBody() throws {
        let request = ClaudeOAuth.tokenExchangeRequest(code: "the-code", state: "the-state", verifier: "the-verifier")
        XCTAssertEqual(request.url?.absoluteString, ClaudeOAuth.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body["code"] as? String, "the-code")
        XCTAssertEqual(body["state"] as? String, "the-state")
        XCTAssertEqual(body["code_verifier"] as? String, "the-verifier")
        XCTAssertEqual(body["client_id"] as? String, ClaudeOAuth.clientID)
    }

    func testRefreshRequestBody() throws {
        let request = ClaudeOAuth.refreshRequest(refreshToken: "sk-ant-ort01-xyz")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(body["refresh_token"] as? String, "sk-ant-ort01-xyz")
    }

    // MARK: - Token response / credentials

    func testTokenResponseDecodingAndExpiry() throws {
        let json = #"{"access_token":"sk-ant-oat01-abc","refresh_token":"sk-ant-ort01-def","expires_in":3600}"#
        let response = try JSONDecoder().decode(ClaudeOAuth.TokenResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credentials = ClaudeOAuth.Credentials(response: response, now: now)

        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(credentials.refreshToken, "sk-ant-ort01-def")
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(3600))
        // Fresh token: no refresh needed…
        XCTAssertFalse(credentials.needsRefresh(now: now))
        // …but within the 5-minute leeway of expiry it is.
        XCTAssertTrue(credentials.needsRefresh(now: now.addingTimeInterval(3600 - 200)))
        XCTAssertTrue(credentials.needsRefresh(now: now.addingTimeInterval(4000)))
    }

    func testRefreshResponseKeepsPreviousRefreshToken() throws {
        let json = #"{"access_token":"sk-ant-oat01-new","expires_in":3600}"#
        let response = try JSONDecoder().decode(ClaudeOAuth.TokenResponse.self, from: Data(json.utf8))
        let credentials = ClaudeOAuth.Credentials(response: response, previousRefreshToken: "sk-ant-ort01-old")
        XCTAssertEqual(credentials.refreshToken, "sk-ant-ort01-old")
    }

    func testCredentialsWithoutExpiryNeverNeedRefresh() throws {
        let json = #"{"access_token":"sk-ant-oat01-abc"}"#
        let response = try JSONDecoder().decode(ClaudeOAuth.TokenResponse.self, from: Data(json.utf8))
        let credentials = ClaudeOAuth.Credentials(response: response)
        XCTAssertFalse(credentials.needsRefresh(now: .distantFuture))
    }

    // MARK: - Header application

    func testOAuthTokenGetsBearerAndBetaHeader() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        AnthropicAuth.apply(credential: "sk-ant-oat01-abc", to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testAPIKeyGetsXAPIKeyHeader() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        AnthropicAuth.apply(credential: "sk-ant-api03-abc", to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-abc")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testIsOAuthTokenClassification() {
        XCTAssertTrue(ClaudeOAuth.isOAuthToken("sk-ant-oat01-abc"))
        XCTAssertFalse(ClaudeOAuth.isOAuthToken("sk-ant-api03-abc"))
        XCTAssertFalse(ClaudeOAuth.isOAuthToken(""))
    }

    // MARK: - Refresh (Plan FG P1a)

    @MainActor
    private func connectedAccount(issued: Date, session: URLSession = RecordingQueueProtocol.session())
        throws -> (ClaudeOAuthService, InMemoryCredentialStore) {
        let response = try OAuthRefreshFixture.decode(
            ClaudeOAuth.TokenResponse.self,
            OAuthRefreshFixture.tokenBody(access: "sk-ant-oat-fixture-old", refresh: "refresh-fixture-old"))
        let holder = InMemoryCredentialStore(holding: ClaudeOAuth.Credentials(response: response, now: issued))
        let service = ClaudeOAuthService(store: holder.store, session: session, refresher: SingleFlightRefresher())
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
        XCTAssertEqual(holder.decoded(ClaudeOAuth.Credentials.self)?.refreshToken, "refresh-fixture-old")
        XCTAssertEqual(service.lastError, "Couldn't reach the Claude sign-in service; I'll try again.")
        XCTAssertEqual(OfflineURLProtocol.attempts, 1)
    }

    @MainActor
    func testAServerErrorKeepsTheCredentials() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(503, "")]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        _ = await service.validAccessToken()

        XCTAssertTrue(service.isConnected)
        XCTAssertNotNil(holder.data)
        XCTAssertEqual(service.lastError, "Couldn't reach the Claude sign-in service; I'll try again.")
    }

    @MainActor
    func testARevokedRefreshTokenDiscardsTheCredential() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(400, #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#)]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        let token = await service.validAccessToken()

        XCTAssertNil(token)
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(holder.data)
        XCTAssertEqual(service.lastError, "Claude sign-in expired — please sign in again.")
    }

    @MainActor
    func testAForcedRefreshIgnoresTheStoredExpiry() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(200, OAuthRefreshFixture.tokenBody(access: "sk-ant-oat-fixture-new"))]
        let (service, _) = try connectedAccount(issued: Date())

        let replacement = await service.accessToken(afterRejecting: "sk-ant-oat-fixture-old")

        XCTAssertEqual(replacement, "sk-ant-oat-fixture-new")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        // A caller whose rejected token was already replaced takes the replacement as it stands.
        let again = await service.accessToken(afterRejecting: "sk-ant-oat-fixture-old")
        XCTAssertEqual(again, "sk-ant-oat-fixture-new")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "an already-replaced token was refreshed again")
    }

    @MainActor
    private func accountRoute(_ account: ClaudeOAuthService) -> LLMService {
        let llm = LLMService()
        let session = RecordingQueueProtocol.session()
        llm.dataSession = session
        llm.streamingSession = session
        llm.claudeAccountOverride = account
        return llm
    }

    private func anthropicConfig(apiKey: String) -> ModelConfig {
        ModelConfig(id: "fg", name: "fg", provider: LLMProvider.anthropic.rawValue,
                    apiKey: apiKey, model: "claude-sonnet-5-5", baseURL: "")
    }

    @MainActor
    func testA401ForcesOneRefreshAndOneRetry() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [
            (401, OAuthRefreshFixture.anthropicUnauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "sk-ant-oat-fixture-new")),
            (200, OAuthRefreshFixture.anthropicReply),
        ]
        let (account, _) = try connectedAccount(issued: Date())
        let llm = accountRoute(account)

        let reply = try await llm.sendAnthropic("What's the weather?", systemPrompt: "Be brief.",
                                                config: anthropicConfig(apiKey: ""), includeTools: false,
                                                imageData: nil)

        XCTAssertEqual(reply, "It is sunny.")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer sk-ant-oat-fixture-old")
        XCTAssertTrue(requests.dropFirst().first?.bodyText.contains("refresh_token") ?? false)
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer sk-ant-oat-fixture-new")
    }

    @MainActor
    func testASecond401SurfacesWithoutAnotherRefresh() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [
            (401, OAuthRefreshFixture.anthropicUnauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "sk-ant-oat-fixture-new")),
            (401, OAuthRefreshFixture.anthropicUnauthorized),
        ]
        let (account, _) = try connectedAccount(issued: Date())
        let llm = accountRoute(account)

        do {
            _ = try await llm.sendAnthropic("What's the weather?", systemPrompt: "Be brief.",
                                            config: anthropicConfig(apiKey: ""), includeTools: false,
                                            imageData: nil)
            XCTFail("a second 401 should surface")
        } catch {
            XCTAssertTrue(SubscriptionAuthRetry.isUnauthorized(error), "\(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 3, "one refresh and one retry, no more")
    }

    @MainActor
    func testAPastedKeyIsNeverRefreshed() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(401, OAuthRefreshFixture.anthropicUnauthorized)]
        let (account, _) = try connectedAccount(issued: Date())
        let llm = accountRoute(account)

        do {
            _ = try await llm.sendAnthropic("What's the weather?", systemPrompt: "Be brief.",
                                            config: anthropicConfig(apiKey: "sk-ant-api-fixture"),
                                            includeTools: false, imageData: nil)
            XCTFail("a refused key should surface")
        } catch {
            XCTAssertTrue(SubscriptionAuthRetry.isUnauthorized(error), "\(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "a pasted key's 401 reached the token endpoint")
    }
}
