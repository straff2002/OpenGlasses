import XCTest
@testable import OpenGlasses

/// The xAI sign-in's network edge and the routes that spend its token, over stubbed transports
/// and an in-memory credential store — never the keychain or the network. Covers the exchange,
/// discovery, the single-flight refresh, what a refresh failure does to the stored account, and
/// the xAI model route's credential choice and its one forced refresh on a 401. Values are invented.
@MainActor
final class XAIOAuthServiceTests: XCTestCase {

    private var usagePath: URL!
    private var services: [LLMService] = []
    private var trackers: [WeakTracker] = []
    private struct WeakTracker { weak var tracker: UsageTracker? }

    override func setUp() {
        super.setUp()
        CloudConsentFixture.approveShared([
            "https://api.x.ai",
            "https://auth.x.ai"
        ])
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        usagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("xai-usage-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        CloudConsentFixture.restoreShared()
        super.tearDown()
    }

    override func tearDown() async throws {
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        services.forEach { $0.usageTrackerOverride = nil }
        services = []
        // A recorded turn lands through a main-actor Task that holds its tracker; let it run so
        // the database connection is closed before the file is removed.
        var spins = 0
        while trackers.contains(where: { $0.tracker != nil }), spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        trackers = []
        try? FileManager.default.removeItem(at: usagePath)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func connectedAccount(issued: Date, session: URLSession = RecordingQueueProtocol.session())
        throws -> (XAIOAuthService, InMemoryCredentialStore) {
        let response = try OAuthRefreshFixture.decode(
            XAIOAuth.TokenResponse.self,
            OAuthRefreshFixture.tokenBody(access: "access-fixture-old", refresh: "refresh-fixture-old"))
        let holder = InMemoryCredentialStore(holding: XAIOAuth.Credentials(response: response, now: issued))
        let service = XAIOAuthService(store: holder.store, session: session,
                                      refresher: SingleFlightRefresher(), discoversEndpoints: false)
        return (service, holder)
    }

    private func signedOutAccount(discovers: Bool) -> (XAIOAuthService, InMemoryCredentialStore) {
        let holder = InMemoryCredentialStore()
        let service = XAIOAuthService(store: holder.store, session: RecordingQueueProtocol.session(),
                                      refresher: SingleFlightRefresher(), discoversEndpoints: discovers)
        return (service, holder)
    }

    private func callback(for service: XAIOAuthService) throws -> String {
        let state = try XCTUnwrap(service.pendingSignInState)
        return "http://127.0.0.1:56121/callback?code=code-fixture&state=\(state)"
    }

    private static let chatReply = #"{"choices":[{"message":{"role":"assistant","content":"It is sunny."}}],"usage":{"prompt_tokens":3,"completion_tokens":4}}"#
    private static let unauthorized = #"{"error":{"message":"invalid bearer token"}}"#

    private func xaiConfig(key: String = "") -> ModelConfig {
        ModelConfig(id: "xai", name: "xai", provider: LLMProvider.xai.rawValue, apiKey: key,
                    model: "grok-4.7", baseURL: LLMProvider.xai.defaultBaseURL)
    }

    private func route(_ account: XAIOAuthService) -> LLMService {
        let llm = LLMService()
        let session = RecordingQueueProtocol.session()
        llm.streamingSession = session
        llm.dataSession = session
        let tracker = UsageTracker(store: UsageStore(path: usagePath))
        llm.usageTrackerOverride = tracker
        llm.xaiAccountOverride = account
        services.append(llm)
        trackers.append(WeakTracker(tracker: tracker))
        return llm
    }

    // MARK: - Sign-in

    func testSignInExchangesTheCodeAndStoresTheAccount() async throws {
        let (service, holder) = signedOutAccount(discovers: false)
        let idToken = XAIOAuthTests.idToken(["email": "wearer@example.com"])
        RecordingQueueProtocol.queue = [(200, #"{"access_token":"access-fixture","refresh_token":"refresh-fixture","expires_in":3600,"id_token":"\#(idToken)"}"#)]

        let url = try XCTUnwrap(service.beginSignIn())
        XCTAssertEqual(url.host, "auth.x.ai")
        let ok = await service.completeSignIn(pastedCode: try callback(for: service))

        XCTAssertTrue(ok, service.lastError ?? "")
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.accountLabel, "wearer@example.com")
        XCTAssertNil(service.pendingSignInState)
        let stored = try XCTUnwrap(holder.decoded(XAIOAuth.Credentials.self))
        XCTAssertEqual(stored.accessToken, "access-fixture")
        XCTAssertEqual(stored.refreshToken, "refresh-fixture")

        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, "https://auth.x.ai/oauth2/token")
        XCTAssertTrue(requests.first?.bodyText.contains("grant_type=authorization_code") ?? false)
        XCTAssertTrue(requests.first?.bodyText.contains("code_verifier=") ?? false)
        XCTAssertFalse(requests.first?.bodyText.contains("client_secret") ?? true)
    }

    func testAMismatchedStateIsRefusedWithoutARequest() async throws {
        let (service, _) = signedOutAccount(discovers: false)
        _ = service.beginSignIn()
        let ok = await service.completeSignIn(
            pastedCode: "http://127.0.0.1:56121/callback?code=code-fixture&state=someone-elses")
        XCTAssertFalse(ok)
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
    }

    func testSignOutForgetsTheAccount() throws {
        let (service, holder) = try connectedAccount(issued: Date())
        XCTAssertTrue(service.isConnected)
        service.signOut()
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(holder.data)
    }

    // MARK: - Discovery

    func testDiscoveryMovesTheTokenEndpointWithinXAI() async throws {
        let (service, _) = signedOutAccount(discovers: true)
        RecordingQueueProtocol.queue = [
            (200, #"{"authorization_endpoint":"https://auth.x.ai/oauth2/v2/authorize","token_endpoint":"https://auth.x.ai/oauth2/v2/token"}"#),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture")),
        ]
        _ = service.beginSignIn()
        let ok = await service.completeSignIn(pastedCode: try callback(for: service))

        XCTAssertTrue(ok, service.lastError ?? "")
        let urls = RecordingQueueProtocol.requests.map(\.url)
        XCTAssertEqual(urls, ["https://auth.x.ai/.well-known/openid-configuration",
                              "https://auth.x.ai/oauth2/v2/token"])
        // Cached for the launch: the next sign-in opens the discovered page and asks nothing.
        let next = try XCTUnwrap(service.beginSignIn())
        XCTAssertEqual(next.path, "/oauth2/v2/authorize")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
    }

    func testAHostileDiscoveryDocumentKeepsTheStaticEndpoints() async throws {
        let (service, _) = signedOutAccount(discovers: true)
        RecordingQueueProtocol.queue = [
            (200, #"{"authorization_endpoint":"https://x.ai.evil.com/authorize","token_endpoint":"https://evil.com/x.ai/token"}"#),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture")),
        ]
        _ = service.beginSignIn()
        let ok = await service.completeSignIn(pastedCode: try callback(for: service))

        XCTAssertTrue(ok, service.lastError ?? "")
        XCTAssertEqual(RecordingQueueProtocol.requests.last?.url, "https://auth.x.ai/oauth2/token")
    }

    func testAFailedDiscoveryKeepsTheStaticEndpoints() async throws {
        let (service, _) = signedOutAccount(discovers: true)
        RecordingQueueProtocol.queue = [
            (503, #"{"error":"unavailable"}"#),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture")),
        ]
        _ = service.beginSignIn()
        let ok = await service.completeSignIn(pastedCode: try callback(for: service))

        XCTAssertTrue(ok, service.lastError ?? "")
        XCTAssertEqual(RecordingQueueProtocol.requests.last?.url, "https://auth.x.ai/oauth2/token")
    }

    // MARK: - Refresh (Plan FG P1a)

    func testConcurrentCallersSpendTheRefreshTokenOnce() async throws {
        RecordingQueueProtocol.queue = [(200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new"))]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.nearExpiryIssue)

        async let first = service.validAccessToken()
        async let second = service.validAccessToken()
        let tokens = await [first, second]

        XCTAssertEqual(tokens, ["access-fixture-new", "access-fixture-new"])
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "the rotating refresh token was spent twice")
        XCTAssertTrue(RecordingQueueProtocol.requests.first?.bodyText.contains("grant_type=refresh_token") ?? false)
        XCTAssertTrue(RecordingQueueProtocol.requests.first?.bodyText.contains("refresh-fixture-old") ?? false)
        XCTAssertEqual(holder.decoded(XAIOAuth.Credentials.self)?.refreshToken, "refresh-fixture-next")
    }

    func testADeadRefreshTokenSignsOut() async throws {
        RecordingQueueProtocol.queue = [(400, #"{"error":"invalid_grant"}"#)]
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue)

        let token = await service.validAccessToken()

        XCTAssertNil(token)
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(holder.data)
        XCTAssertEqual(service.lastError, "xAI sign-in expired — please sign in again.")
    }

    func testANetworkBlipKeepsTheAccount() async throws {
        OfflineURLProtocol.reset()
        let (service, holder) = try connectedAccount(issued: OAuthRefreshFixture.expiredIssue,
                                                     session: OfflineURLProtocol.session())

        let token = await service.validAccessToken()

        XCTAssertNil(token, "an expired token is not handed out")
        XCTAssertTrue(service.isConnected, "a dropped connection signed the wearer out")
        XCTAssertEqual(holder.decoded(XAIOAuth.Credentials.self)?.refreshToken, "refresh-fixture-old")
        XCTAssertEqual(service.lastError, "Couldn't reach the xAI sign-in service; I'll try again.")
    }

    func testARejectedTokenIsRefreshedOnceEvenBeforeItsStoredExpiry() async throws {
        RecordingQueueProtocol.queue = [(200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new"))]
        let (service, _) = try connectedAccount(issued: Date())

        let replacement = await service.accessToken(afterRejecting: "access-fixture-old")
        // Already replaced: a second caller holding the old token gets the replacement, no request.
        let again = await service.accessToken(afterRejecting: "access-fixture-old")

        XCTAssertEqual(replacement, "access-fixture-new")
        XCTAssertEqual(again, "access-fixture-new")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
    }

    // MARK: - The xAI model route

    func testAnEmptyKeySendsTheAccountToken() async throws {
        let (account, _) = try connectedAccount(issued: Date())
        let llm = route(account)
        RecordingQueueProtocol.queue = [(200, Self.chatReply)]

        let reply = try await llm.sendOpenAICompatibleForTesting("What's the weather?", config: xaiConfig(),
                                                                 includeTools: false)

        XCTAssertEqual(reply, "It is sunny.")
        let request = try XCTUnwrap(RecordingQueueProtocol.requests.first)
        XCTAssertEqual(request.url, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer access-fixture-old")
    }

    func testATypedKeyWinsOverTheSignIn() async throws {
        let (account, _) = try connectedAccount(issued: Date())
        let llm = route(account)
        RecordingQueueProtocol.queue = [(200, Self.chatReply)]

        _ = try await llm.sendOpenAICompatibleForTesting("What's the weather?", config: xaiConfig(key: "xai-key-fixture"),
                                                         includeTools: false)

        XCTAssertEqual(RecordingQueueProtocol.requests.first?.headers["Authorization"], "Bearer xai-key-fixture")
    }

    func testNoKeyAndNoAccountIsAMissingCredential() async throws {
        let (account, _) = signedOutAccount(discovers: false)
        let llm = route(account)
        do {
            _ = try await llm.sendOpenAICompatibleForTesting("hi", config: xaiConfig(), includeTools: false)
            XCTFail("an xAI model with no key and no account must not send")
        } catch LLMError.missingAPIKey(let message) {
            XCTAssertTrue(message.contains("sign in with xAI"), message)
        }
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
    }

    func testA401ForcesOneRefreshAndOneRetry() async throws {
        let (account, _) = try connectedAccount(issued: Date())
        let llm = route(account)
        RecordingQueueProtocol.queue = [
            (401, Self.unauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new")),
            (200, Self.chatReply),
        ]

        let reply = try await llm.sendOpenAICompatibleForTesting("What's the weather?", config: xaiConfig(),
                                                                 includeTools: false)

        XCTAssertEqual(reply, "It is sunny.")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer access-fixture-old")
        XCTAssertEqual(requests[1].url, "https://auth.x.ai/oauth2/token")
        XCTAssertTrue(requests[1].bodyText.contains("grant_type=refresh_token"))
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer access-fixture-new")
    }

    func testASecond401SurfacesWithoutAnotherRefresh() async throws {
        let (account, _) = try connectedAccount(issued: Date())
        let llm = route(account)
        RecordingQueueProtocol.queue = [
            (401, Self.unauthorized),
            (200, OAuthRefreshFixture.tokenBody(access: "access-fixture-new")),
            (401, Self.unauthorized),
        ]

        do {
            _ = try await llm.sendOpenAICompatibleForTesting("hi", config: xaiConfig(), includeTools: false)
            XCTFail("a second 401 should surface")
        } catch {
            XCTAssertTrue(SubscriptionAuthRetry.isUnauthorized(error), "\(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 3, "one refresh and one retry, no more")
    }

    func testA401OnATypedKeyIsNotRefreshed() async throws {
        let (account, _) = try connectedAccount(issued: Date())
        let llm = route(account)
        RecordingQueueProtocol.queue = [(401, Self.unauthorized)]

        do {
            _ = try await llm.sendOpenAICompatibleForTesting("hi", config: xaiConfig(key: "xai-key-fixture"),
                                                             includeTools: false)
            XCTFail("a refused key should surface")
        } catch {
            XCTAssertTrue(SubscriptionAuthRetry.isUnauthorized(error), "\(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "a typed key has nothing to refresh")
    }
}
