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

    /// PKCE verifier + state for the sign-in currently in progress (nil between attempts).
    private var pendingVerifier: String?
    private var pendingState: String?
    private var devicePollingTask: Task<Void, Never>?

    private var credentials: ChatGPTOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }

    /// Account id claim from the connected account's id_token — rides every API request.
    var accountID: String? { credentials?.accountID }

    init() {
        if let data = KeychainService.data(for: Self.keychainKey),
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
            lastError = "Sign-in wasn't started — tap Sign in with ChatGPT first."
            return false
        }
        guard let parsed = ChatGPTOAuth.parseAuthorizationInput(pastedCode) else {
            lastError = "That doesn't look like an authorization code or callback URL."
            return false
        }
        if let state = parsed.state, let expected = pendingState, state != expected {
            lastError = "Sign-in state mismatch — start again and use the newest browser tab."
            return false
        }
        do {
            let response = try await performTokenRequest(
                ChatGPTOAuth.tokenExchangeRequest(code: parsed.code, verifier: verifier))
            store(ChatGPTOAuth.Credentials(response: response))
            pendingVerifier = nil
            pendingState = nil
            lastError = nil
            return true
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Disconnect the ChatGPT account and wipe stored tokens.
    func signOut() {
        cancelDeviceCodeSignIn()
        credentials = nil
        _ = KeychainService.delete(Self.keychainKey)
        pendingVerifier = nil
        pendingState = nil
        lastError = nil
    }

    // MARK: - Token access

    /// The current access token, refreshed first if it's at/near expiry.
    /// Returns nil when no account is connected or the refresh fails.
    func validAccessToken() async -> String? {
        guard var current = credentials else { return nil }
        guard current.needsRefresh() else { return current.accessToken }
        guard let refreshToken = current.refreshToken else {
            return nil   // expired with no refresh token — the stored credential is dead
        }
        do {
            let response = try await performTokenRequest(
                ChatGPTOAuth.refreshRequest(refreshToken: refreshToken))
            current = ChatGPTOAuth.Credentials(
                response: response,
                previousRefreshToken: refreshToken,
                previousAccountID: current.accountID)
            store(current)
            return current.accessToken
        } catch {
            NSLog("[ChatGPTOAuth] Token refresh failed: %@", error.localizedDescription)
            lastError = "ChatGPT sign-in expired — please sign in again."
            return nil
        }
    }

    // MARK: - Internals

    private func store(_ newCredentials: ChatGPTOAuth.Credentials) {
        credentials = newCredentials
        if let data = try? JSONEncoder().encode(newCredentials) {
            _ = KeychainService.setData(data, for: Self.keychainKey)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> ChatGPTOAuth.TokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ChatGPTOAuth", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Token endpoint returned HTTP \(status)"
            ])
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
                    "Device-code sign-in isn't enabled. In ChatGPT, turn on Enable device code authorization under Settings → Security, then try again."
                )
            }
            throw deviceError(status, "ChatGPT couldn't start device-code sign-in (HTTP \(status)).")
        }
        do {
            return try JSONDecoder().decode(ChatGPTOAuth.DeviceAuthorization.self, from: data)
        } catch {
            throw deviceError(status, "ChatGPT returned an unreadable device-code response.")
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
                    store(ChatGPTOAuth.Credentials(response: token))
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
                    throw deviceError(410, "That device code expired. Start device-code sign-in again.")
                case .denied:
                    throw deviceError(403, "Device-code sign-in was declined or is no longer available.")
                case .failure(let message):
                    throw deviceError(status, "Device-code sign-in failed: \(message)")
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
        lastError = "That device code timed out. Start device-code sign-in again."
    }

    private func deviceError(_ status: Int, _ message: String) -> NSError {
        NSError(domain: "ChatGPTOAuth.DeviceCode", code: status, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
