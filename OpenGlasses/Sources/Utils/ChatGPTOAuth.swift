import Foundation

/// Pure core for the "Sign in with ChatGPT" OAuth flow (Plan BW P1 — no I/O, fully
/// unit-testable). The network/persistence edge lives in `ChatGPTOAuthService`.
///
/// Subscription OAuth is explicitly supported for external tools, but the token it grants
/// authenticates against the **ChatGPT Codex backend** (a Responses-API surface with the codex
/// model catalog) — NOT `api.openai.com`. Two flows are modelled:
///
/// 1. **Authorization code + PKCE** in the browser. The registered redirect is a localhost URL;
///    on the phone that navigation fails to connect, and the user copies the full callback URL
///    (which still carries `code`/`state`) out of the address bar and pastes it back — the same
///    paste-back UX the Claude flow proved.
/// 2. **Device code**: show a short user code, the user enters it at the verification URL on any
///    device, and the app polls for an authorization code. This is an advanced fallback because
///    the user must explicitly enable device-code authorization in ChatGPT Security settings.
///
/// The token response carries an `id_token` (JWT) whose account-id claim must accompany every
/// API request as a header.
enum ChatGPTOAuth {

    // MARK: - Protocol constants
    //
    // ⚠️ Captured-at-implementation against the shipping auth service (Plan BW). This backend
    // is newer and driftier than a stable public API — every endpoint/id lives HERE and nowhere
    // else, so drift has a one-block blast radius. P4 (live device verification) is the gate
    // before any onboarding exposure.

    /// The public OAuth client issued for external-tool sign-in.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeEndpoint = "https://auth.openai.com/oauth/authorize"
    static let tokenEndpoint = "https://auth.openai.com/oauth/token"
    /// Codex device authorization uses a short-lived, in-memory device auth id. These endpoints
    /// intentionally mirror the current Codex device flow rather than the generic RFC 8628 grant.
    static let deviceAuthorizationEndpoint = "https://auth.openai.com/api/accounts/deviceauth/usercode"
    static let deviceTokenEndpoint = "https://auth.openai.com/api/accounts/deviceauth/token"
    static let deviceVerificationURL = "https://auth.openai.com/codex/device"
    /// Registered redirect for the public client — a localhost URL (the CLI runs a listener; on
    /// iOS the user copies the resulting address-bar URL back instead).
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scopes = "openid profile email offline_access"

    /// The Responses-API surface subscription tokens are valid against.
    static let backendResponsesURL = "https://chatgpt.com/backend-api/codex/responses"
    /// Account-scoped catalog used by Codex. Never hard-code the picker to one release family;
    /// this endpoint reflects the models enabled for the signed-in ChatGPT workspace.
    static let backendModelsURL = "https://chatgpt.com/backend-api/codex/models"
    /// Header carrying the account id extracted from the `id_token`.
    static let accountIDHeader = "chatgpt-account-id"
    /// Beta header the Responses backend expects.
    static let betaHeaderField = "OpenAI-Beta"
    static let betaHeaderValue = "responses=experimental"

    /// Used before account-scoped discovery completes. The picker replaces this with the model
    /// marked as default by the live catalog whenever possible.
    static let defaultModel = "gpt-5.6-sol"

    // MARK: - Authorize URL (browser flow)

    static func authorizeURL(verifier: String, state: String) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    /// Accepts a pasted callback URL, `code#state`, or a bare code (shared parser).
    static func parseAuthorizationInput(_ input: String) -> (code: String, state: String?)? {
        OAuthCodeInput.parse(input)
    }

    // MARK: - Token requests (form-encoded, per standard OAuth — unlike Anthropic's JSON endpoint)

    static func tokenExchangeRequest(code: String, verifier: String) -> URLRequest {
        formPOST(url: tokenEndpoint, fields: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        formPOST(url: tokenEndpoint, fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopes,
        ])
    }

    // MARK: - Device-code flow shapes

    static func deviceCodeRequest() -> URLRequest {
        jsonPOST(url: deviceAuthorizationEndpoint, body: ["client_id": clientID])
    }

    struct DeviceAuthorization: Decodable, Equatable {
        let deviceAuthID: String
        let userCode: String
        let interval: Double?

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case interval = "interval"
        }

        var verificationURL: URL { URL(string: ChatGPTOAuth.deviceVerificationURL)! }
    }

    static func devicePollRequest(deviceAuthID: String, userCode: String) -> URLRequest {
        jsonPOST(url: deviceTokenEndpoint, body: [
            "device_auth_id": deviceAuthID,
            "user_code": userCode,
        ])
    }

    /// The device endpoint returns a one-use authorization code plus the verifier generated for
    /// it. Tokens are still obtained from the normal OAuth token endpoint and stored in Keychain.
    struct DeviceApproval: Decodable, Equatable {
        let authorizationCode: String
        let codeVerifier: String
        let codeChallenge: String?

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
            case codeChallenge = "code_challenge"
        }
    }

    /// One poll of the token endpoint during device-code sign-in, as a value.
    enum DevicePollResult: Equatable {
        case approved(DeviceApproval)
        case pending          // keep polling at the same interval
        case slowDown         // keep polling, back off
        case expired          // user took too long — restart the flow
        case denied           // user rejected the sign-in
        case failure(String)  // anything else

        static func == (lhs: DevicePollResult, rhs: DevicePollResult) -> Bool {
            switch (lhs, rhs) {
            case (.approved(let a), .approved(let b)): return a == b
            case (.pending, .pending), (.slowDown, .slowDown),
                 (.expired, .expired), (.denied, .denied): return true
            case (.failure(let a), .failure(let b)): return a == b
            default: return false
            }
        }
    }

    /// Classify a Codex device-poll response. A 404 means the user has not approved the code yet;
    /// the initial user-code request uses a separate 404 message for the disabled-security-toggle
    /// case. JSON OAuth-style errors are accepted too so server-side transitions fail safely.
    static func parseDevicePoll(statusCode: Int, body: Data) -> DevicePollResult {
        if (200..<300).contains(statusCode),
           let approval = try? JSONDecoder().decode(DeviceApproval.self, from: body) {
            return .approved(approval)
        }
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
        switch error {
        case "authorization_pending": return .pending
        case "slow_down":             return .slowDown
        case "expired_token":         return .expired
        case "access_denied":         return .denied
        default:
            switch statusCode {
            case 404, 408, 409, 425: return .pending
            case 429: return .slowDown
            case 410: return .expired
            case 401, 403: return .denied
            default: return .failure(error ?? "HTTP \(statusCode)")
            }
        }
    }

    // MARK: - Token response / credentials

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
        }
    }

    struct Credentials: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        /// Account id extracted from the `id_token` at exchange time — rides every API request.
        var accountID: String?
        var expiresAt: Date?

        init(response: TokenResponse, now: Date = Date(),
             previousRefreshToken: String? = nil, previousAccountID: String? = nil) {
            accessToken = response.accessToken
            // A refresh response may omit fields — keep the previous values.
            refreshToken = response.refreshToken ?? previousRefreshToken
            accountID = response.idToken.flatMap(ChatGPTOAuth.accountID(fromIDToken:)) ?? previousAccountID
            expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
        }

        /// Refresh ahead of expiry so an in-flight request doesn't race the deadline.
        func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(leeway) >= expiresAt
        }
    }

    // MARK: - id_token claim extraction

    /// Pull the ChatGPT account id out of an `id_token` JWT. We consume one claim from a token we
    /// received directly over TLS from the token endpoint — no client-side signature validation
    /// (standard for public-client id_token consumption). The claim lives in a nested auth object
    /// (`https://api.openai.com/auth` → `chatgpt_account_id`), with a top-level fallback.
    static func accountID(fromIDToken idToken: String) -> String? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2, let payload = decodeBase64URL(String(segments[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        if let id = claims["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Base64url decode (JWT segments drop padding).
    static func decodeBase64URL(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    // MARK: - Internals

    private static func formPOST(url: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }   // deterministic body — testable byte-for-byte
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.timeoutInterval = 30
        return request
    }

    private static func jsonPOST(url: String, body: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 30
        return request
    }
}

/// Applies ChatGPT subscription authentication to a Responses-backend request: bearer token,
/// account-id header, and the beta header the backend expects. Pure.
enum ChatGPTAuth {
    static func apply(credential: String, accountID: String?, to request: inout URLRequest) {
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: ChatGPTOAuth.accountIDHeader)
        }
        request.setValue(ChatGPTOAuth.betaHeaderValue, forHTTPHeaderField: ChatGPTOAuth.betaHeaderField)
    }
}
