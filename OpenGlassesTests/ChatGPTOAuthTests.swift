import XCTest
@testable import OpenGlasses

/// Pure-logic coverage for the "Sign in with ChatGPT" OAuth core (Plan BW P1): authorize-URL
/// construction, form-encoded token requests, device-code poll classification, token-response
/// decoding, id_token account-claim extraction, and header application. The network edge
/// (`ChatGPTOAuthService`) is covered only for its refresh (Plan FG P1a), through the request
/// stubs and an in-memory credential store — never the keychain or the network.
final class ChatGPTOAuthTests: XCTestCase {

    // The request path is the subject, so sharing is approved for the services it scripts.
    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://chatgpt.com",
            "https://api.openai.com",
            "https://auth.openai.com"
        ])
    }

    override func tearDown() {
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    // MARK: - Authorize URL

    func testAuthorizeURLCarriesPKCEAndIdentity() throws {
        let url = try XCTUnwrap(ChatGPTOAuth.authorizeURL(verifier: "test-verifier", state: "test-state"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(params["client_id"], ChatGPTOAuth.clientID)
        XCTAssertEqual(params["response_type"], "code")
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["code_challenge"], PKCE.challenge(for: "test-verifier"))
        XCTAssertEqual(params["state"], "test-state")
        XCTAssertEqual(params["redirect_uri"], ChatGPTOAuth.redirectURI)
        XCTAssertEqual(params["scope"], ChatGPTOAuth.scopes)
    }

    // MARK: - Pasted-input parsing (the iOS path: copy the failed localhost URL from the address bar)

    func testParsePastedLocalhostCallbackURL() throws {
        let parsed = try XCTUnwrap(ChatGPTOAuth.parseAuthorizationInput(
            "http://localhost:1455/auth/callback?code=ac_123&state=st_456"
        ))
        XCTAssertEqual(parsed.code, "ac_123")
        XCTAssertEqual(parsed.state, "st_456")
    }

    func testParseBareCode() throws {
        let parsed = try XCTUnwrap(ChatGPTOAuth.parseAuthorizationInput("  ac_123 \n"))
        XCTAssertEqual(parsed.code, "ac_123")
        XCTAssertNil(parsed.state)
    }

    // MARK: - Token requests (form-encoded)

    func testTokenExchangeRequestIsFormEncoded() throws {
        let request = ChatGPTOAuth.tokenExchangeRequest(code: "the-code", verifier: "the-verifier")
        XCTAssertEqual(request.url?.absoluteString, ChatGPTOAuth.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (kv[0], kv.count > 1 ? kv[1].removingPercentEncoding ?? kv[1] : "")
        })
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code"], "the-code")
        XCTAssertEqual(fields["code_verifier"], "the-verifier")
        XCTAssertEqual(fields["client_id"], ChatGPTOAuth.clientID)
        XCTAssertEqual(fields["redirect_uri"], ChatGPTOAuth.redirectURI)
    }

    func testRefreshRequestBody() throws {
        let request = ChatGPTOAuth.refreshRequest(refreshToken: "rt-xyz")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-xyz"))
    }

    // MARK: - Device-code flow

    func testDeviceCodeRequestsUseCurrentCodexEndpointsWithoutPersistingSecrets() throws {
        let start = ChatGPTOAuth.deviceCodeRequest()
        XCTAssertEqual(start.url?.absoluteString, ChatGPTOAuth.deviceAuthorizationEndpoint)
        XCTAssertEqual(start.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let startBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(start.httpBody)) as? [String: String]
        )
        XCTAssertEqual(startBody, ["client_id": ChatGPTOAuth.clientID])

        let poll = ChatGPTOAuth.devicePollRequest(deviceAuthID: "auth-1", userCode: "ABCD-1234")
        XCTAssertEqual(poll.url?.absoluteString, ChatGPTOAuth.deviceTokenEndpoint)
        let pollBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(poll.httpBody)) as? [String: String]
        )
        XCTAssertEqual(pollBody["device_auth_id"], "auth-1")
        XCTAssertEqual(pollBody["user_code"], "ABCD-1234")
    }

    func testDevicePollClassification() {
        func poll(_ status: Int, _ json: String) -> ChatGPTOAuth.DevicePollResult {
            ChatGPTOAuth.parseDevicePoll(statusCode: status, body: Data(json.utf8))
        }
        XCTAssertEqual(poll(400, #"{"error":"authorization_pending"}"#), .pending)
        XCTAssertEqual(poll(400, #"{"error":"slow_down"}"#), .slowDown)
        XCTAssertEqual(poll(400, #"{"error":"expired_token"}"#), .expired)
        XCTAssertEqual(poll(403, #"{"error":"access_denied"}"#), .denied)
        XCTAssertEqual(poll(404, ""), .pending)
        XCTAssertEqual(poll(429, ""), .slowDown)
        XCTAssertEqual(poll(500, #"{"error":"kaboom"}"#), .failure("kaboom"))
        XCTAssertEqual(poll(502, "not json"), .failure("HTTP 502"))

        if case .approved(let approval) = poll(
            200,
            #"{"authorization_code":"code-1","code_verifier":"verifier-1","code_challenge":"challenge-1"}"#
        ) {
            XCTAssertEqual(approval.authorizationCode, "code-1")
            XCTAssertEqual(approval.codeVerifier, "verifier-1")
        } else {
            XCTFail("200 with a Codex device approval should be accepted")
        }
    }

    func testDeviceAuthorizationDecoding() throws {
        let json = #"{"device_auth_id":"dc","user_code":"ABCD-EFGH","interval":5}"#
        let auth = try JSONDecoder().decode(ChatGPTOAuth.DeviceAuthorization.self, from: Data(json.utf8))
        XCTAssertEqual(auth.deviceAuthID, "dc")
        XCTAssertEqual(auth.userCode, "ABCD-EFGH")
        XCTAssertEqual(auth.interval, 5)
        XCTAssertEqual(auth.verificationURL.absoluteString, ChatGPTOAuth.deviceVerificationURL)
    }

    // MARK: - id_token account claim

    /// Build an unsigned JWT with the given payload (header/signature are irrelevant to the parser).
    private func jwt(payload: [String: Any]) -> String {
        let header = PKCE.base64URL(Data(#"{"alg":"none"}"#.utf8))
        let body = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body)."
    }

    func testAccountIDFromNestedAuthClaim() {
        let token = jwt(payload: [
            "sub": "user-1",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-nested"],
        ])
        XCTAssertEqual(ChatGPTOAuth.accountID(fromIDToken: token), "acct-nested")
    }

    func testAccountIDTopLevelFallbackAndAbsence() {
        XCTAssertEqual(
            ChatGPTOAuth.accountID(fromIDToken: jwt(payload: ["chatgpt_account_id": "acct-top"])),
            "acct-top")
        XCTAssertNil(ChatGPTOAuth.accountID(fromIDToken: jwt(payload: ["sub": "user-1"])))
        XCTAssertNil(ChatGPTOAuth.accountID(fromIDToken: "not-a-jwt"))
    }

    // MARK: - Credentials

    func testCredentialsExtractAccountIDAndExpiry() throws {
        let idToken = jwt(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])
        let json = """
        {"access_token":"at-1","refresh_token":"rt-1","id_token":"\(idToken)","expires_in":3600}
        """
        let response = try JSONDecoder().decode(ChatGPTOAuth.TokenResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credentials = ChatGPTOAuth.Credentials(response: response, now: now)

        XCTAssertEqual(credentials.accountID, "acct-1")
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(credentials.needsRefresh(now: now))
        XCTAssertTrue(credentials.needsRefresh(now: now.addingTimeInterval(3600 - 200)))
    }

    func testRefreshKeepsPreviousRefreshTokenAndAccountID() throws {
        let json = #"{"access_token":"at-new","expires_in":3600}"#
        let response = try JSONDecoder().decode(ChatGPTOAuth.TokenResponse.self, from: Data(json.utf8))
        let credentials = ChatGPTOAuth.Credentials(
            response: response, previousRefreshToken: "rt-old", previousAccountID: "acct-old")
        XCTAssertEqual(credentials.refreshToken, "rt-old")
        XCTAssertEqual(credentials.accountID, "acct-old")
    }

    // MARK: - Header application

    func testAuthHeadersCarryBearerAccountAndBeta() {
        var request = URLRequest(url: URL(string: ChatGPTOAuth.backendResponsesURL)!)
        ChatGPTAuth.apply(credential: "at-1", accountID: "acct-1", to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
    }

    func testAuthHeadersOmitMissingAccountID() {
        var request = URLRequest(url: URL(string: ChatGPTOAuth.backendResponsesURL)!)
        ChatGPTAuth.apply(credential: "at-1", accountID: nil, to: &request)
        XCTAssertNil(request.value(forHTTPHeaderField: "chatgpt-account-id"))
    }

    func testAuthHeadersCarryClientIdentity() {
        // The backend keys catalog visibility on the client identity (2026-08-31 rotation
        // returned empty lists without it), so originator and User-Agent must ride every request.
        var request = URLRequest(url: URL(string: ChatGPTOAuth.backendResponsesURL)!)
        ChatGPTAuth.apply(credential: "at-1", accountID: "acct-1", to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ChatGPTOAuth.userAgentValue)
        XCTAssertTrue(ChatGPTOAuth.userAgentValue.hasPrefix("codex_cli_rs/"))
    }

    func testModelsRequestURLCarriesClientVersion() {
        let url = ChatGPTOAuth.backendModelsRequestURL
        XCTAssertTrue(url.hasPrefix(ChatGPTOAuth.backendModelsURL))
        XCTAssertTrue(url.contains("client_version=\(ChatGPTOAuth.clientVersion)"))
        XCTAssertFalse(ChatGPTOAuth.clientVersion.isEmpty)
    }

    // MARK: - Refresh (Plan FG P1a)

    @MainActor
    private func connectedAccount(issued: Date, session: URLSession = RecordingQueueProtocol.session())
        throws -> (ChatGPTOAuthService, InMemoryCredentialStore) {
        let response = try OAuthRefreshFixture.decode(
            ChatGPTOAuth.TokenResponse.self,
            OAuthRefreshFixture.tokenBody(access: "access-fixture-old", refresh: "refresh-fixture-old"))
        let holder = InMemoryCredentialStore(holding: ChatGPTOAuth.Credentials(response: response, now: issued))
        let service = ChatGPTOAuthService(store: holder.store, session: session, refresher: SingleFlightRefresher())
        return (service, holder)
    }

    @MainActor
    func testConcurrentCallersSpendTheRefreshTokenOnce() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new"))]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        let callers = (0..<10).map { _ in Task { await service.validAccessToken() } }
        var tokens: [String?] = []
        for caller in callers { tokens.append(await caller.value) }

        XCTAssertEqual(tokens, Array(repeating: "access-fixture-new", count: 10))
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "the rotating refresh token was spent twice")
        XCTAssertTrue(RecordingQueueProtocol.requests.first?.bodyText.contains("refresh-fixture-old") ?? false)
        XCTAssertEqual(holder.decoded(ChatGPTOAuth.Credentials.self)?.refreshToken, "refresh-fixture-next")
    }

    @MainActor
    func testANetworkFailureKeepsTheCredentials() async throws {
        OfflineURLProtocol.reset()
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue,
                                                     session: OfflineURLProtocol.session())

        let token = await service.validAccessToken()

        XCTAssertNil(token, "an expired token is not handed out")
        XCTAssertTrue(service.isConnected, "a dropped connection signed the wearer out")
        XCTAssertEqual(holder.decoded(ChatGPTOAuth.Credentials.self)?.refreshToken, "refresh-fixture-old")
        XCTAssertEqual(service.lastError, "Couldn't reach the ChatGPT sign-in service; I'll try again.")

        // "I'll try again" is true: the slot was released, so the next call asks again.
        _ = await service.validAccessToken()
        XCTAssertEqual(OfflineURLProtocol.attempts, 2)
    }

    @MainActor
    func testAnUnexpiredTokenStillServesWhileTheServiceIsUnreachable() async throws {
        let (service, _) = try connectedAccount(issued: OAuthRefreshFixture.nearExpiryIssue,
                                                session: OfflineURLProtocol.session())
        let token = await service.validAccessToken()
        XCTAssertEqual(token, "access-fixture-old")
    }

    @MainActor
    func testInvalidGrantDiscardsTheDeadCredential() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(400, #"{"error":"invalid_grant"}"#)]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        let token = await service.validAccessToken()

        XCTAssertNil(token)
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(holder.data)
        XCTAssertEqual(service.lastError, "ChatGPT sign-in expired — please sign in again.")
    }

    @MainActor
    private func subscriptionRoute(_ account: ChatGPTOAuthService) -> LLMService {
        let llm = LLMService()
        llm.streamingSession = RecordingQueueProtocol.session()
        llm.chatGPTAccountOverride = account
        return llm
    }

    private let subscriptionConfig = ModelConfig(id: "fg", name: "fg", provider: LLMProvider.chatgpt.rawValue,
                                                 apiKey: "", model: ChatGPTOAuth.defaultModel, baseURL: "")

    @MainActor
    func testA401ForcesOneRefreshAndOneRetry() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [
            (401, OAuthRefreshFixture.responsesUnauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new")),
            (200, OAuthRefreshFixture.responsesReply),
        ]
        // Issued just now: by the stored expiry the token is good for an hour.
        let (account, _) = try connectedAccount(issued: Date())
        let llm = subscriptionRoute(account)

        let reply = try await llm.sendChatGPT("What's the weather?", systemPrompt: "Be brief.",
                                              config: subscriptionConfig, includeTools: false, imageData: nil)

        XCTAssertEqual(reply, "It is sunny.")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer access-fixture-old")
        XCTAssertTrue(requests.dropFirst().first?.bodyText.contains("grant_type=refresh_token") ?? false)
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer access-fixture-new")
    }

    @MainActor
    func testASecond401SurfacesWithoutAnotherRefresh() async throws {
        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [
            (401, OAuthRefreshFixture.responsesUnauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new")),
            (401, OAuthRefreshFixture.responsesUnauthorized),
        ]
        let (account, _) = try connectedAccount(issued: Date())
        let llm = subscriptionRoute(account)

        do {
            _ = try await llm.sendChatGPT("What's the weather?", systemPrompt: "Be brief.",
                                          config: subscriptionConfig, includeTools: false, imageData: nil)
            XCTFail("a second 401 should surface")
        } catch {
            XCTAssertTrue(SubscriptionAuthRetry.isUnauthorized(error), "\(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 3, "one refresh and one retry, no more")
    }
}
