import Foundation

/// Pure core for the Google OAuth flow behind the Vertex-AI Gemini provider (Plan AI).
/// Mirrors `ClaudeOAuth`: no I/O, fully unit-testable; the network/persistence edge lives in
/// `GoogleOAuthService`.
///
/// Google-specific shape (vs the Claude flow):
/// - The **client ID is the user's own** (a GCP OAuth *iOS* client they register) — nothing is
///   embedded in the app, so it's a parameter throughout, and the redirect URI is the client
///   ID's reverse-DNS form, per Google's installed-app convention.
/// - Google blocks the paste-a-code trick; the browser flow runs in
///   `ASWebAuthenticationSession` and returns via the reverse-DNS callback scheme.
/// - The token endpoint takes **form-encoded** bodies, not JSON.
enum GoogleOAuth {

    static let authorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    /// Vertex AI calls need the cloud-platform scope; there is no narrower Vertex scope.
    static let scopes = "https://www.googleapis.com/auth/cloud-platform"

    // MARK: - Client-ID derived pieces

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
    /// (Google's registered custom scheme for installed-app clients). `nil` when the client ID
    /// doesn't have the expected shape.
    static func callbackScheme(clientID: String) -> String? {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        guard trimmed.hasSuffix(suffix), trimmed.count > suffix.count else { return nil }
        let bare = String(trimmed.dropLast(suffix.count))
        guard !bare.isEmpty, !bare.contains("/"), !bare.contains(":") else { return nil }
        return "com.googleusercontent.apps.\(bare)"
    }

    static func redirectURI(clientID: String) -> String? {
        callbackScheme(clientID: clientID).map { "\($0):/oauth2redirect" }
    }

    // MARK: - Authorize URL

    /// Build the browser authorize URL (PKCE S256). `access_type=offline` + `prompt=consent`
    /// make Google issue a refresh token on first consent.
    static func authorizeURL(clientID: String, verifier: String, state: String) -> URL? {
        guard let redirect = redirectURI(clientID: clientID) else { return nil }
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    /// Extract `code`/`state` from the `ASWebAuthenticationSession` callback URL.
    static func parseCallback(url: URL) -> (code: String, state: String?)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return (code, items.first(where: { $0.name == "state" })?.value)
    }

    // MARK: - Token requests (form-encoded — Google rejects JSON bodies)

    static func tokenExchangeRequest(clientID: String, code: String, verifier: String) -> URLRequest? {
        guard let redirect = redirectURI(clientID: clientID) else { return nil }
        return formPOST(fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("redirect_uri", redirect),
            ("code_verifier", verifier),
        ])
    }

    static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        formPOST(fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(encoded)"
        }.joined(separator: "&")
    }

    private static func formPOST(fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 30
        return request
    }

    // MARK: - Token response / credentials (same shape as `ClaudeOAuth`)

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
            // Google omits the refresh token on refresh responses — keep the old one.
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

/// Vertex-AI endpoint construction + auth (pure). Regional hosts are
/// `{region}-aiplatform.googleapis.com`; the `global` region uses the bare host. OAuth Bearer
/// only — Vertex does not take API keys in query strings the way AI Studio does.
enum VertexAI {

    /// Curated region choices for the Settings picker (any string is accepted by the builder).
    static let regions = ["global", "us-central1", "us-east4", "europe-west1", "europe-west4", "asia-northeast1", "australia-southeast1"]

    /// `projects/{project}/locations/{region}/publishers/google/models/{model}:{verb}`
    static func endpointURL(projectID: String, region: String, model: String,
                            verb: String = "generateContent") -> URL? {
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !loc.isEmpty, !modelID.isEmpty,
              [project, loc, modelID].allSatisfy({ !$0.contains("/") && !$0.contains("?") && !$0.contains("#") })
        else { return nil }
        let host = loc == "global" ? "aiplatform.googleapis.com" : "\(loc)-aiplatform.googleapis.com"
        return URL(string: "https://\(host)/v1/projects/\(project)/locations/\(loc)/publishers/google/models/\(modelID):\(verb)")
    }

    /// Vertex authenticates with a Bearer token — never a key query parameter.
    static func apply(accessToken: String, to request: inout URLRequest) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
