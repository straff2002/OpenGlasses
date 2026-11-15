import Foundation

/// Network/persistence edge for the "Sign in with Claude" OAuth flow. The protocol logic
/// (PKCE, URLs, request bodies, expiry) is pure in `ClaudeOAuth`; this service performs the
/// token exchange/refresh over the network and keeps credentials in the keychain.
@MainActor
final class ClaudeOAuthService: ObservableObject {
    static let shared = ClaudeOAuthService()

    /// Whether a Claude account is currently connected (credentials on file).
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    private static let keychainKey = "claudeOAuthCredentials"
    /// The slot this account's refreshes share (Plan FG P1a).
    static let refreshKey = SingleFlightRefresher.Key(provider: "claude")

    private let credentialStore: OAuthCredentialStore
    private let session: URLSession
    private let refresher: SingleFlightRefresher

    /// PKCE verifier + state for the sign-in currently in progress (nil between attempts).
    private var pendingVerifier: String?
    private var pendingState: String?

    private var credentials: ClaudeOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }

    /// `store`, `session` and `refresher` are seams for the tests (Plan FG P1a): the app uses the
    /// keychain item, the shared session and the shared refresher.
    init(store: OAuthCredentialStore? = nil, session: URLSession = .shared,
         refresher: SingleFlightRefresher = .shared) {
        self.credentialStore = store ?? .keychain(Self.keychainKey)
        self.session = session
        self.refresher = refresher
        if let data = self.credentialStore.load(),
           let stored = try? JSONDecoder().decode(ClaudeOAuth.Credentials.self, from: data) {
            credentials = stored
            isConnected = true
        }
    }

    // MARK: - Sign-in flow

    /// Start a sign-in attempt: mint a fresh PKCE verifier/state and return the browser URL.
    func beginSignIn() -> URL? {
        let verifier = ClaudeOAuth.makeVerifier()
        let state = ClaudeOAuth.makeVerifier()
        pendingVerifier = verifier
        pendingState = state
        lastError = nil
        return ClaudeOAuth.authorizeURL(verifier: verifier, state: state)
    }

    /// The `state` minted for the sign-in currently in progress. Unused by this provider's
    /// redirect (a hosted page, not a loopback URL), but part of the shared sign-in contract.
    var pendingSignInState: String? { pendingState }

    /// Complete sign-in with the code the user pasted from the callback page.
    /// Returns true on success.
    @discardableResult
    func completeSignIn(pastedCode: String) async -> Bool {
        guard let verifier = pendingVerifier else {
            lastError = String(localized: "Sign-in wasn't started — tap Sign in with Claude first.")
            return false
        }
        guard let parsed = ClaudeOAuth.parseAuthorizationInput(pastedCode) else {
            lastError = String(localized: "That doesn't look like an authorization code.")
            return false
        }
        let request = ClaudeOAuth.tokenExchangeRequest(
            code: parsed.code,
            state: parsed.state ?? pendingState,
            verifier: verifier
        )
        do {
            let response = try await performTokenRequest(request)
            adoptSignIn(ClaudeOAuth.Credentials(response: response))
            pendingVerifier = nil
            pendingState = nil
            lastError = nil
            return true
        } catch {
            lastError = String(localized: "Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Disconnect the Claude account and wipe stored tokens.
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

    /// A replacement for `rejectedToken`, which the model endpoint just refused with a 401
    /// (Plan FG P1a). Refreshes whatever the stored expiry says — unless another caller has
    /// already replaced that token, in which case the replacement is returned as it stands.
    /// Returns nil when no account is connected or the refresh did not produce a new token.
    func accessToken(afterRejecting rejectedToken: String) async -> String? {
        guard credentials != nil else { return nil }
        return await refreshedAccessToken(rejecting: rejectedToken)
    }

    // MARK: - Internals

    /// Refresh through the single-flight slot, then read what the settled state leaves usable.
    private func refreshedAccessToken(rejecting rejectedToken: String?) async -> String? {
        await refresher.refresh(
            Self.refreshKey,
            fetch: { [weak self] () async throws -> ClaudeOAuth.Credentials? in
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
    private func fetchRefreshedCredentials(rejecting rejectedToken: String?) async throws -> ClaudeOAuth.Credentials? {
        guard let current = credentials, let refreshToken = current.refreshToken else {
            return nil   // no refresh token — the stored credential cannot be renewed
        }
        let stillNeeded = rejectedToken.map { $0 == current.accessToken } ?? current.needsRefresh()
        guard stillNeeded else { return nil }
        let response = try await performTokenRequest(ClaudeOAuth.refreshRequest(refreshToken: refreshToken))
        return ClaudeOAuth.Credentials(response: response, previousRefreshToken: refreshToken)
    }

    /// Commit a refresh's outcome. Runs only while the refresh still owns its slot.
    private func settleRefresh(_ outcome: Result<ClaudeOAuth.Credentials?, Error>) {
        switch outcome {
        case .success(let refreshed?):
            store(refreshed)
            lastError = nil
        case .success(nil):
            break
        case .failure(let error):
            // A refresh failure's description can quote the token endpoint's response body.
            PrivacyLog.authFailed(.claude, .tokenRefresh, OAuthTokenEndpointError.summary(of: error))
            let failure = OAuthRefreshFailure.classify(error)
            if failure == .credentialDead {
                credentials = nil
                credentialStore.remove()
            }
            lastError = failure.message(provider: "Claude")
        }
    }

    /// Store a completed sign-in. Any refresh still running belongs to the account it replaces.
    private func adoptSignIn(_ newCredentials: ClaudeOAuth.Credentials) {
        refresher.invalidate(Self.refreshKey)
        store(newCredentials)
    }

    private func store(_ newCredentials: ClaudeOAuth.Credentials) {
        credentials = newCredentials
        if let data = try? JSONEncoder().encode(newCredentials) {
            credentialStore.save(data)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> ClaudeOAuth.TokenResponse {
        // Linking an account is a credential leaving the device; local-only refuses it rather
        // than letting a new provider be attached while the mode is on.
        try MedicalEgressGuard.check(.claudeOAuthToken)
        _ = try EndpointPolicy.require(url: request.url ?? URL(fileURLWithPath: "/"), for: .claudeOAuthToken)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw OAuthTokenEndpointError(status: status, body: data)
        }
        return try JSONDecoder().decode(ClaudeOAuth.TokenResponse.self, from: data)
    }
}
