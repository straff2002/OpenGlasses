import Foundation

/// Pure core for the Anthropic "Sign in with Claude" OAuth flow (Plan-style deterministic core —
/// no I/O, fully unit-testable). The network/persistence edge lives in `ClaudeOAuthService`.
///
/// Flow (authorization code + PKCE, same protocol the official `ant auth login` CLI uses):
/// 1. Build an authorize URL with a fresh PKCE verifier and open it in the browser.
/// 2. The user signs in with their claude.ai account; the callback page displays an
///    authorization code (`code#state`) which they copy and paste back into the app.
/// 3. Exchange the code for an access token (`sk-ant-oat…`) + refresh token at the token endpoint.
/// 4. API calls authenticate with `Authorization: Bearer` + the `oauth-2025-04-20` beta header
///    instead of `x-api-key`.
enum ClaudeOAuth {

    // MARK: - Protocol constants

    /// Anthropic's public OAuth client (the one issued for CLI/desktop sign-in).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = "https://claude.ai/oauth/authorize"
    static let tokenEndpoint = "https://console.anthropic.com/v1/oauth/token"
    /// Redirect target registered for the public client — a page that displays the code to paste.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"
    /// Beta header required when authenticating `/v1/messages` (and friends) with an OAuth token.
    static let oauthBetaHeader = "oauth-2025-04-20"

    /// OAuth access tokens are distinguishable from API keys by prefix
    /// (`sk-ant-oat…` vs `sk-ant-api…`).
    static func isOAuthToken(_ credential: String) -> Bool {
        credential.hasPrefix("sk-ant-oat")
    }

    // MARK: - PKCE (delegates to the shared `PKCE` enum — Plan BW extracted it)

    static func base64URL(_ data: Data) -> String { PKCE.base64URL(data) }
    static func verifier(from randomBytes: Data) -> String { PKCE.verifier(from: randomBytes) }
    static func makeVerifier() -> String { PKCE.makeVerifier() }
    static func challenge(for verifier: String) -> String { PKCE.challenge(for: verifier) }

    // MARK: - Authorize URL

    /// Build the browser authorize URL. `state` doubles as CSRF token; the token exchange
    /// sends it back alongside the code.
    static func authorizeURL(verifier: String, state: String) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    // MARK: - Pasted-code parsing

    /// The callback page shows the authorization code as `code#state`. Accept that, a bare
    /// code, or a full callback URL the user pasted (shared parser, Plan BW).
    static func parseAuthorizationInput(_ input: String) -> (code: String, state: String?)? {
        OAuthCodeInput.parse(input)
    }

    // MARK: - Token requests

    static func tokenExchangeRequest(code: String, state: String?, verifier: String) -> URLRequest {
        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        if let state { body["state"] = state }
        return jsonPOST(body: body)
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        jsonPOST(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private static func jsonPOST(body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return request
    }

    // MARK: - Token response / credentials

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    struct Credentials: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        init(response: TokenResponse, now: Date = Date(), previousRefreshToken: String? = nil) {
            accessToken = response.accessToken
            // A refresh response may omit the refresh token — keep the old one.
            refreshToken = response.refreshToken ?? previousRefreshToken
            expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
        }

        /// Refresh ahead of expiry so an in-flight request doesn't race the deadline.
        func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(leeway) >= expiresAt
        }
    }
}

/// Applies Anthropic authentication to a request: OAuth access tokens (`sk-ant-oat…`) go on
/// `Authorization: Bearer` with the OAuth beta header; anything else is a regular API key on
/// `x-api-key`. Pure — credential resolution (refresh, keychain) happens in `ClaudeOAuthService`.
enum AnthropicAuth {

    /// Which kind of credential a request was authenticated with — the one fact about a
    /// credential a support report may carry (Plan IE P0). Never any part of the value.
    enum CredentialKind: String, Sendable {
        /// An API key pasted into the model's configuration.
        case key
        /// A Claude account sign-in token.
        case accountSignIn

        /// How the support report says it.
        var reportLabel: String {
            switch self {
            case .key: return "key"
            case .accountSignIn: return "account sign-in"
            }
        }
    }

    static func kind(of credential: String) -> CredentialKind {
        ClaudeOAuth.isOAuthToken(credential) ? .accountSignIn : .key
    }

    /// The kind of credential `apply(credential:to:)` put on `request`, read back from which
    /// header it set. `nil` for a request that carries neither.
    static func credentialKind(of request: URLRequest) -> CredentialKind? {
        if request.value(forHTTPHeaderField: "Authorization") != nil { return .accountSignIn }
        if request.value(forHTTPHeaderField: "x-api-key") != nil { return .key }
        return nil
    }

    static func apply(credential: String, to request: inout URLRequest) {
        if ClaudeOAuth.isOAuthToken(credential) {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue(ClaudeOAuth.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    /// Resolve the credential for an Anthropic request: an explicit API key on the model config
    /// wins; otherwise a connected Claude account's (refreshed) OAuth access token.
    @MainActor
    static func resolveCredential(apiKey: String) async -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return await ClaudeOAuthService.shared.validAccessToken() ?? ""
    }
}
