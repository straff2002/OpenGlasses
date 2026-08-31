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

    /// PKCE verifier + state for the sign-in currently in progress (nil between attempts).
    private var pendingVerifier: String?
    private var pendingState: String?

    private var credentials: ClaudeOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }

    init() {
        if let data = KeychainService.data(for: Self.keychainKey),
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
            lastError = "Sign-in wasn't started — tap Sign in with Claude first."
            return false
        }
        guard let parsed = ClaudeOAuth.parseAuthorizationInput(pastedCode) else {
            lastError = "That doesn't look like an authorization code."
            return false
        }
        let request = ClaudeOAuth.tokenExchangeRequest(
            code: parsed.code,
            state: parsed.state ?? pendingState,
            verifier: verifier
        )
        do {
            let response = try await performTokenRequest(request)
            store(ClaudeOAuth.Credentials(response: response))
            pendingVerifier = nil
            pendingState = nil
            lastError = nil
            return true
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Disconnect the Claude account and wipe stored tokens.
    func signOut() {
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
            // Expired with no refresh token — the stored credential is dead.
            return nil
        }
        do {
            let response = try await performTokenRequest(ClaudeOAuth.refreshRequest(refreshToken: refreshToken))
            current = ClaudeOAuth.Credentials(response: response, previousRefreshToken: refreshToken)
            store(current)
            return current.accessToken
        } catch {
            // A refresh failure's description can quote the token endpoint's response body.
            PrivacyLog.authFailed(.claude, .tokenRefresh, SafeErrorSummary(error))
            lastError = "Claude sign-in expired — please sign in again."
            return nil
        }
    }

    // MARK: - Internals

    private func store(_ newCredentials: ClaudeOAuth.Credentials) {
        credentials = newCredentials
        if let data = try? JSONEncoder().encode(newCredentials) {
            _ = KeychainService.setData(data, for: Self.keychainKey)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> ClaudeOAuth.TokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ClaudeOAuth", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Token endpoint returned HTTP \(status)"
            ])
        }
        return try JSONDecoder().decode(ClaudeOAuth.TokenResponse.self, from: data)
    }
}
