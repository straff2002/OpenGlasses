import Foundation

/// Network/persistence edge for the xAI account sign-in (a SuperGrok subscription without an API
/// key). The protocol logic (PKCE, URLs, form bodies, discovery checks, id_token claims, expiry) is
/// pure in `XAIOAuth`; this service fetches the discovery document, performs the token exchange and
/// refresh over the network, and keeps credentials in the keychain. Structural twin of
/// `ChatGPTOAuthService`, without the device-code flow.
@MainActor
final class XAIOAuthService: ObservableObject {
    static let shared = XAIOAuthService()

    /// Whether an xAI account is currently connected (credentials on file).
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    private static let keychainKey = "xaiOAuthCredentials"
    /// The slot this account's refreshes share (Plan FG P1a).
    static let refreshKey = SingleFlightRefresher.Key(provider: "xai")

    private let credentialStore: OAuthCredentialStore
    private let session: URLSession
    private let refresher: SingleFlightRefresher
    /// Whether to ask the discovery document for the endpoints. Off in tests that drive the token
    /// endpoint alone, so a canned response is never spent on the discovery fetch.
    private let discoversEndpoints: Bool

    /// PKCE verifier + state for the sign-in currently in progress (nil between attempts).
    private var pendingVerifier: String?
    private var pendingState: String?

    /// The endpoints this launch uses, once discovery has answered (or failed, which settles on
    /// the static pair). Fetched at most once per launch, and only once a sign-in is under way —
    /// never at launch, so a wearer who never uses xAI never reaches its sign-in host.
    private var discoveredEndpoints: XAIOAuth.Endpoints?
    private var discoveryTask: Task<XAIOAuth.Endpoints, Never>?

    private var credentials: XAIOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }

    /// Who is signed in, for the account row: the id_token's email or name, nil when it had
    /// neither. Display only — never logged.
    var accountLabel: String? { credentials?.accountLabel }

    /// `store`, `session`, `refresher` and `discoversEndpoints` are seams for the tests: the app
    /// uses the keychain item, the shared session, the shared refresher and discovery.
    init(store: OAuthCredentialStore? = nil, session: URLSession = .shared,
         refresher: SingleFlightRefresher = .shared, discoversEndpoints: Bool = true) {
        self.credentialStore = store ?? .keychain(Self.keychainKey)
        self.session = session
        self.refresher = refresher
        self.discoversEndpoints = discoversEndpoints
        if let data = self.credentialStore.load(),
           let stored = try? JSONDecoder().decode(XAIOAuth.Credentials.self, from: data) {
            credentials = stored
            isConnected = true
        }
    }

    // MARK: - Sign-in flow

    /// Start a sign-in attempt: mint a fresh PKCE verifier/state and return the browser URL.
    /// The authorize endpoint is the discovered one once this launch has it, else the static one;
    /// discovery starts here so the token exchange that follows can use its answer.
    func beginSignIn() -> URL? {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        pendingVerifier = verifier
        pendingState = state
        lastError = nil
        startDiscoveryIfNeeded()
        return XAIOAuth.authorizeURL(verifier: verifier, state: state,
                                     endpoints: discoveredEndpoints ?? .standard)
    }

    /// The `state` minted for the sign-in currently in progress. The loopback listener validates
    /// the browser's callback against it before the code is ever handed back here.
    var pendingSignInState: String? { pendingState }

    /// Complete sign-in with the code the loopback listener captured, or with what the user pasted
    /// back — the full `127.0.0.1` callback URL copied from the address bar. Returns true on success.
    @discardableResult
    func completeSignIn(pastedCode: String) async -> Bool {
        guard let verifier = pendingVerifier else {
            lastError = String(localized: "Sign-in wasn't started — tap Sign in with xAI first.")
            return false
        }
        guard let parsed = XAIOAuth.parseAuthorizationInput(pastedCode) else {
            lastError = String(localized: "That doesn't look like an authorization code or callback URL.")
            return false
        }
        if let state = parsed.state, let expected = pendingState, state != expected {
            lastError = String(localized: "Sign-in state mismatch — start again and use the newest browser tab.")
            return false
        }
        do {
            let endpoints = await resolvedEndpoints()
            let response = try await performTokenRequest(
                XAIOAuth.tokenExchangeRequest(code: parsed.code, verifier: verifier, endpoints: endpoints))
            adoptSignIn(XAIOAuth.Credentials(response: response))
            pendingVerifier = nil
            pendingState = nil
            lastError = nil
            return true
        } catch {
            lastError = String(localized: "Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Disconnect the xAI account and wipe stored tokens.
    func signOut() {
        // First, so a refresh still in flight cannot write the account back after it is gone.
        refresher.invalidate(Self.refreshKey)
        credentials = nil
        credentialStore.remove()
        pendingVerifier = nil
        pendingState = nil
        lastError = nil
    }

    // MARK: - Token access

    /// The current access token, refreshed first if it's at/near expiry.
    /// Returns nil when no account is connected or no usable token is left after the refresh.
    func validAccessToken() async -> String? {
        guard let current = credentials else { return nil }
        guard current.needsRefresh() else { return current.accessToken }
        return await refreshedAccessToken(rejecting: nil)
    }

    /// A replacement for `rejectedToken`, which the API just refused with a 401 (Plan FG P1a).
    /// Refreshes whatever the stored expiry says — unless another caller has already replaced
    /// that token, in which case the replacement is returned as it stands. Returns nil when no
    /// account is connected or the refresh did not produce a new token.
    func accessToken(afterRejecting rejectedToken: String) async -> String? {
        guard credentials != nil else { return nil }
        return await refreshedAccessToken(rejecting: rejectedToken)
    }

    // MARK: - Discovery

    private func startDiscoveryIfNeeded() {
        guard discoversEndpoints, discoveredEndpoints == nil, discoveryTask == nil else { return }
        let session = self.session
        discoveryTask = Task {
            // Local-only refuses this host like the token endpoint; the static pair is then moot.
            guard MedicalEgressGuard.allows(.xaiOAuthToken) else { return .standard }
            let request = XAIOAuth.discoveryRequest()
            guard let answer = try? await session.data(for: request),
                  let status = (answer.1 as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status) else {
                return .standard
            }
            return XAIOAuth.endpoints(fromDiscovery: answer.0)
        }
    }

    /// The endpoints to use now: discovery's answer (cached for the launch), or the static pair
    /// when discovery is off, failed, or was slow.
    private func resolvedEndpoints() async -> XAIOAuth.Endpoints {
        if let discoveredEndpoints { return discoveredEndpoints }
        guard discoversEndpoints else { return .standard }
        startDiscoveryIfNeeded()
        guard let task = discoveryTask else { return .standard }
        let endpoints = await task.value
        discoveredEndpoints = endpoints
        discoveryTask = nil
        return endpoints
    }

    // MARK: - Internals

    /// Refresh through the single-flight slot, then read what the settled state leaves usable.
    private func refreshedAccessToken(rejecting rejectedToken: String?) async -> String? {
        await refresher.refresh(
            Self.refreshKey,
            fetch: { [weak self] () async throws -> XAIOAuth.Credentials? in
                guard let self else { return nil }
                return try await self.fetchRefreshedCredentials(rejecting: rejectedToken)
            },
            commit: { [weak self] outcome in self?.settleRefresh(outcome) })
        guard let current = credentials else { return nil }
        if let rejectedToken { return current.accessToken == rejectedToken ? nil : current.accessToken }
        // A refresh that could not reach the service keeps the credential; its token still serves
        // until it actually expires.
        return current.needsRefresh(leeway: 0) ? nil : current.accessToken
    }

    /// The token request, made only if it is still needed when the slot's turn comes: nil when
    /// there is nothing to refresh, or a refresh that landed first already did the job.
    private func fetchRefreshedCredentials(rejecting rejectedToken: String?) async throws -> XAIOAuth.Credentials? {
        guard let current = credentials, let refreshToken = current.refreshToken else {
            return nil   // no refresh token — the stored credential cannot be renewed
        }
        let stillNeeded = rejectedToken.map { $0 == current.accessToken } ?? current.needsRefresh()
        guard stillNeeded else { return nil }
        let endpoints = await resolvedEndpoints()
        let response = try await performTokenRequest(
            XAIOAuth.refreshRequest(refreshToken: refreshToken, endpoints: endpoints))
        return XAIOAuth.Credentials(response: response, previous: current)
    }

    /// Commit a refresh's outcome. Runs only while the refresh still owns its slot.
    private func settleRefresh(_ outcome: Result<XAIOAuth.Credentials?, Error>) {
        switch outcome {
        case .success(let refreshed?):
            store(refreshed)
            lastError = nil
        case .success(nil):
            break
        case .failure(let error):
            // A refresh failure's description can quote the token endpoint's response body.
            PrivacyLog.authFailed(.xai, .tokenRefresh, OAuthTokenEndpointError.summary(of: error))
            let failure = OAuthRefreshFailure.classify(error)
            if failure == .credentialDead {
                credentials = nil
                credentialStore.remove()
            }
            lastError = failure.message(provider: "xAI")
        }
    }

    /// Store a completed sign-in. Any refresh still running belongs to the account it replaces.
    private func adoptSignIn(_ newCredentials: XAIOAuth.Credentials) {
        refresher.invalidate(Self.refreshKey)
        store(newCredentials)
    }

    private func store(_ newCredentials: XAIOAuth.Credentials) {
        credentials = newCredentials
        if let data = try? JSONEncoder().encode(newCredentials) {
            credentialStore.save(data)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> XAIOAuth.TokenResponse {
        // Linking an account is a credential leaving the device; local-only refuses it rather
        // than letting a new provider be attached while the mode is on.
        try MedicalEgressGuard.check(.xaiOAuthToken)
        _ = try EndpointPolicy.require(url: request.url ?? URL(fileURLWithPath: "/"), for: .xaiOAuthToken)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw OAuthTokenEndpointError(status: status, body: data)
        }
        return try JSONDecoder().decode(XAIOAuth.TokenResponse.self, from: data)
    }
}
