import Foundation

/// Network/persistence edge for the "Sign in with ChatGPT" OAuth flow (Plan BW P3). The
/// protocol logic (PKCE, URLs, form bodies, id_token claims, expiry) is pure in
/// `ChatGPTOAuth`; this service performs the token exchange/refresh over the network and
/// keeps credentials in the keychain. Structural twin of `ClaudeOAuthService`.
@MainActor
final class ChatGPTOAuthService: ObservableObject {
    static let shared = ChatGPTOAuthService()

    /// Whether a ChatGPT account is currently connected (credentials on file).
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?
    /// Ceremony data held while the advanced device-code flow is waiting. Only the short user
    /// code is shown; the device auth id stays in memory and is never logged or persisted.
    @Published private(set) var deviceAuthorization: ChatGPTOAuth.DeviceAuthorization?
    @Published private(set) var isDeviceCodeSigningIn = false

    private static let keychainKey = "chatgptOAuthCredentials"
    /// The slot this account's refreshes share (Plan FG P1a).
    static let refreshKey = SingleFlightRefresher.Key(provider: "chatgpt")

    private let credentialStore: OAuthCredentialStore
    private let session: URLSession
    private let refresher: SingleFlightRefresher

    /// PKCE verifier + state for the sign-in currently in progress (nil between attempts).
    private var pendingVerifier: String?
    private var pendingState: String?
    private var devicePollingTask: Task<Void, Never>?

    private var credentials: ChatGPTOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }

    /// Account id claim from the connected account's id_token — rides every API request.
    var accountID: String? { credentials?.accountID }

    /// `store`, `session` and `refresher` are seams for the tests (Plan FG P1a): the app uses the
    /// keychain item, the shared session and the shared refresher.
    init(store: OAuthCredentialStore? = nil, session: URLSession = .shared,
         refresher: SingleFlightRefresher = .shared) {
        self.credentialStore = store ?? .keychain(Self.keychainKey)
        self.session = session
        self.refresher = refresher
        if let data = self.credentialStore.load(),
           let stored = try? JSONDecoder().decode(ChatGPTOAuth.Credentials.self, from: data) {
            credentials = stored
            isConnected = true
        }
    }

    // MARK: - Sign-in flow

    /// Start a sign-in attempt: mint a fresh PKCE verifier/state and return the browser URL.
    func beginSignIn() -> URL? {
        cancelDeviceCodeSignIn()
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        pendingVerifier = verifier
        pendingState = state
        lastError = nil
        return ChatGPTOAuth.authorizeURL(verifier: verifier, state: state)
    }

    /// Start the advanced/headless sign-in ceremony. ChatGPT requires the user to explicitly
    /// enable device-code authorization in Security settings; a disabled flow is explained
    /// without falling back to copying any long-lived credential.
    func beginDeviceCodeSignIn() async {
        cancelDeviceCodeSignIn()
        pendingVerifier = nil
        pendingState = nil
        isDeviceCodeSigningIn = true
        lastError = nil

        do {
            let authorization = try await requestDeviceAuthorization()
            deviceAuthorization = authorization
            devicePollingTask = Task { [weak self] in
                await self?.pollDeviceAuthorization(authorization)
            }
        } catch {
            isDeviceCodeSigningIn = false
            deviceAuthorization = nil
            lastError = error.localizedDescription
        }
    }

    /// Stop polling and discard the one-time code. Tokens already stored by a completed sign-in
    /// are unaffected.
    func cancelDeviceCodeSignIn() {
        devicePollingTask?.cancel()
        devicePollingTask = nil
        deviceAuthorization = nil
        isDeviceCodeSigningIn = false
    }

    /// The `state` minted for the sign-in currently in progress. The loopback listener validates
    /// the browser's callback against it before the code is ever handed back here (Plan DD).
    var pendingSignInState: String? { pendingState }

    /// Complete sign-in with what the user pasted back — on iOS that's usually the full
    /// localhost callback URL copied from the browser's address bar. Returns true on success.
    @discardableResult
    func completeSignIn(pastedCode: String) async -> Bool {
        guard let verifier = pendingVerifier else {
            lastError = String(localized: "Sign-in wasn't started — tap Sign in with ChatGPT first.")
            return false
        }
        guard let parsed = ChatGPTOAuth.parseAuthorizationInput(pastedCode) else {
            lastError = String(localized: "That doesn't look like an authorization code or callback URL.")
            return false
        }
        if let state = parsed.state, let expected = pendingState, state != expected {
            lastError = String(localized: "Sign-in state mismatch — start again and use the newest browser tab.")
            return false
        }
        do {
            let response = try await performTokenRequest(
                ChatGPTOAuth.tokenExchangeRequest(code: parsed.code, verifier: verifier))
            adoptSignIn(ChatGPTOAuth.Credentials(response: response))
            pendingVerifier = nil
            pendingState = nil
            lastError = nil
            return true
        } catch {
            lastError = String(localized: "Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Disconnect the ChatGPT account and wipe stored tokens.
    func signOut() {
        // First, so a refresh still in flight cannot write the account back after it is gone.
        refresher.invalidate(Self.refreshKey)
        cancelDeviceCodeSignIn()
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
            fetch: { [weak self] () async throws -> ChatGPTOAuth.Credentials? in
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
    private func fetchRefreshedCredentials(rejecting rejectedToken: String?) async throws -> ChatGPTOAuth.Credentials? {
        guard let current = credentials, let refreshToken = current.refreshToken else {
            return nil   // no refresh token — the stored credential cannot be renewed
        }
        let stillNeeded = rejectedToken.map { $0 == current.accessToken } ?? current.needsRefresh()
        guard stillNeeded else { return nil }
        let response = try await performTokenRequest(ChatGPTOAuth.refreshRequest(refreshToken: refreshToken))
        return ChatGPTOAuth.Credentials(
            response: response,
            previousRefreshToken: refreshToken,
            previousAccountID: current.accountID)
    }

    /// Commit a refresh's outcome. Runs only while the refresh still owns its slot.
    private func settleRefresh(_ outcome: Result<ChatGPTOAuth.Credentials?, Error>) {
        switch outcome {
        case .success(let refreshed?):
            store(refreshed)
            lastError = nil
        case .success(nil):
            break
        case .failure(let error):
            // A refresh failure's description can quote the token endpoint's response body.
            PrivacyLog.authFailed(.chatgpt, .tokenRefresh, OAuthTokenEndpointError.summary(of: error))
            let failure = OAuthRefreshFailure.classify(error)
            if failure == .credentialDead {
                credentials = nil
                credentialStore.remove()
            }
            lastError = failure.message(provider: "ChatGPT")
        }
    }

    /// Store a completed sign-in. Any refresh still running belongs to the account it replaces.
    private func adoptSignIn(_ newCredentials: ChatGPTOAuth.Credentials) {
        refresher.invalidate(Self.refreshKey)
        store(newCredentials)
    }

    private func store(_ newCredentials: ChatGPTOAuth.Credentials) {
        credentials = newCredentials
        if let data = try? JSONEncoder().encode(newCredentials) {
            credentialStore.save(data)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> ChatGPTOAuth.TokenResponse {
        // Linking an account is a credential leaving the device; local-only refuses it rather
        // than letting a new provider be attached while the mode is on.
        try MedicalEgressGuard.check(.chatGPTOAuthToken)
        _ = try EndpointPolicy.require(url: request.url ?? URL(fileURLWithPath: "/"), for: .chatGPTOAuthToken)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw OAuthTokenEndpointError(status: status, body: data)
        }
        return try JSONDecoder().decode(ChatGPTOAuth.TokenResponse.self, from: data)
    }

    private func requestDeviceAuthorization() async throws -> ChatGPTOAuth.DeviceAuthorization {
        let (data, response) = try await URLSession.shared.data(for: ChatGPTOAuth.deviceCodeRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if status == 404 || status == 403 {
                throw deviceError(
                    status,
                    String(localized: "Device-code sign-in isn't enabled. In ChatGPT, turn on Enable device code authorization under Settings → Security, then try again.")
                )
            }
            throw deviceError(status, String(localized: "ChatGPT couldn't start device-code sign-in (HTTP \(status))."))
        }
        do {
            return try JSONDecoder().decode(ChatGPTOAuth.DeviceAuthorization.self, from: data)
        } catch {
            throw deviceError(status, String(localized: "ChatGPT returned an unreadable device-code response."))
        }
    }

    private func pollDeviceAuthorization(_ authorization: ChatGPTOAuth.DeviceAuthorization) async {
        var interval = max(authorization.interval ?? 5, 1)
        let deadline = Date().addingTimeInterval(15 * 60)

        while !Task.isCancelled, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let request = ChatGPTOAuth.devicePollRequest(
                    deviceAuthID: authorization.deviceAuthID,
                    userCode: authorization.userCode
                )
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                switch ChatGPTOAuth.parseDevicePoll(statusCode: status, body: data) {
                case .approved(let approval):
                    let token = try await performTokenRequest(
                        ChatGPTOAuth.tokenExchangeRequest(
                            code: approval.authorizationCode,
                            verifier: approval.codeVerifier
                        )
                    )
                    adoptSignIn(ChatGPTOAuth.Credentials(response: token))
                    deviceAuthorization = nil
                    isDeviceCodeSigningIn = false
                    devicePollingTask = nil
                    lastError = nil
                    return
                case .pending:
                    continue
                case .slowDown:
                    interval = min(interval + 5, 30)
                case .expired:
                    throw deviceError(410, String(localized: "That device code expired. Start device-code sign-in again."))
                case .denied:
                    throw deviceError(403, String(localized: "Device-code sign-in was declined or is no longer available."))
                case .failure(let message):
                    throw deviceError(status, String(localized: "Device-code sign-in failed: \(message)"))
                }
            } catch is CancellationError {
                return
            } catch {
                deviceAuthorization = nil
                isDeviceCodeSigningIn = false
                devicePollingTask = nil
                lastError = error.localizedDescription
                return
            }
        }

        guard !Task.isCancelled else { return }
        deviceAuthorization = nil
        isDeviceCodeSigningIn = false
        devicePollingTask = nil
        lastError = String(localized: "That device code timed out. Start device-code sign-in again.")
    }

    private func deviceError(_ status: Int, _ message: String) -> NSError {
        NSError(domain: "ChatGPTOAuth.DeviceCode", code: status, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
