import Foundation

/// Pure core for signing in to a clinic's Microsoft 365 (Plan NK §3), on `GoogleOAuth`'s pattern:
/// no I/O, fully unit-testable; the browser leg (`ASWebAuthenticationSession`), the token requests
/// and the Keychain live in `ClinicWorkbookService`.
///
/// - **The client.** One multi-tenant public client of ours (Decision 1), whose id the build
///   carries as `AvenkinEntraClientID`; the clinic's Microsoft 365 administrator consents to it
///   once. A clinic that registers its own app enters its client id instead, as `GoogleOAuth`
///   takes the user's own. With neither, the feature says it isn't set up in this build.
/// - **The authority** is `organizations`: a work or school account, which is what a clinic's
///   tenant has. A personal Microsoft account has no tenant to keep the clinic's record in.
/// - **PKCE S256**, a `state` checked on the way back, and a custom-scheme redirect registered in
///   the Info.plist. A public client has no secret.
/// - **Form-encoded** token and refresh bodies; nothing here is ever logged.
enum EntraOAuth {

    static let loginHost = "login.microsoftonline.com"
    static let authority = "organizations"
    /// `offline_access` for the refresh token, `User.Read` for the account and the organisation's
    /// country, `Files.ReadWrite` for the one workbook. P3 checks whether the selected-files
    /// permission (`Files.SelectedOperations.Selected`) can stand in for `Files.ReadWrite` with an
    /// Excel table; either way `GraphRequestBuilder` reaches only the one workbook.
    static let scopes = "offline_access User.Read Files.ReadWrite"
    static let callbackScheme = "avenkin-entra"
    static let redirectURI = callbackScheme + "://auth"
    /// The Info.plist key the bundled client id is read from.
    static let bundledClientIDKey = "AvenkinEntraClientID"

    static var authorizePath: String { "/\(authority)/oauth2/v2.0/authorize" }
    static var tokenPath: String { "/\(authority)/oauth2/v2.0/token" }

    // MARK: - The client id

    /// A client id is a GUID: 8-4-4-4-12 hex digits.
    static func isClientID(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = id.split(separator: "-", omittingEmptySubsequences: false).map(\.count)
        return groups == [8, 4, 4, 4, 12] && id.replacingOccurrences(of: "-", with: "").allSatisfy(\.isHexDigit)
    }

    /// Where the client id a sign-in uses came from.
    enum Client: Equatable, Sendable {
        /// The clinic's own app registration, entered on this phone.
        case clinic(String)
        /// The app's own registration, carried by this build.
        case bundled(String)
        /// Neither: the build carries none and the clinic entered none.
        case notSetUp

        var id: String? {
            switch self {
            case .clinic(let id), .bundled(let id): return id
            case .notSetUp: return nil
            }
        }
    }

    /// The clinic's own id when it entered a valid one, else the build's, else none.
    static func client(bundled: String?, clinic: String?) -> Client {
        if let clinic = clinic?.trimmingCharacters(in: .whitespacesAndNewlines), isClientID(clinic) {
            return .clinic(clinic.lowercased())
        }
        if let bundled = bundled?.trimmingCharacters(in: .whitespacesAndNewlines), isClientID(bundled) {
            return .bundled(bundled.lowercased())
        }
        return .notSetUp
    }

    // MARK: - The browser leg

    static func authorizeURL(clientID: String, verifier: String, state: String) -> URL? {
        guard isClientID(clientID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = loginHost
        components.path = authorizePath
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url
    }

    /// What came back to the redirect.
    enum Callback: Equatable, Sendable {
        case code(String)
        /// Microsoft refused, with its error code (`access_denied`, `consent_required`…), never
        /// its description.
        case refused(String)
        /// Not our redirect, no code, or a state that is not the one sent.
        case invalid
    }

    static func parseCallback(_ url: URL, expectedState: String) -> Callback {
        guard url.scheme?.lowercased() == callbackScheme, url.host == "auth",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return .invalid }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return .invalid }
        if let error = value("error") {
            let code = error.prefix(64).filter { $0.isASCII && ($0.isLetter || $0 == "_") }
            return .refused(code.isEmpty ? "unknown" : String(code))
        }
        guard let code = value("code"), !code.isEmpty else { return .invalid }
        return .code(code)
    }

    /// A refusal in plain words. Consent is the one a clinic can do something about.
    static func refusalSentence(_ code: String) -> String {
        switch code {
        case "consent_required", "interaction_required", "admin_consent_required":
            return String(localized: "Your clinic's Microsoft 365 administrator needs to approve the app first. They sign in once and accept the permissions it asks for; then sign in again here.",
                          comment: "Sign-in to the clinic's Microsoft 365 needs administrator consent.")
        case "access_denied":
            return String(localized: "The sign-in was declined, so nothing was connected.",
                          comment: "The person or their administrator declined the clinic workbook sign-in.")
        default:
            return String(localized: "Microsoft 365 didn't complete the sign-in, so nothing was connected. Try again.",
                          comment: "The clinic workbook sign-in failed for another reason.")
        }
    }

    // MARK: - Token requests (form-encoded)

    static func tokenRequest(clientID: String, code: String, verifier: String) -> GraphRequest {
        form([("client_id", clientID), ("grant_type", "authorization_code"), ("code", code),
              ("redirect_uri", redirectURI), ("code_verifier", verifier), ("scope", scopes)])
    }

    static func refreshRequest(clientID: String, refreshToken: String) -> GraphRequest {
        form([("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
              ("scope", scopes)])
    }

    /// Whether `request` is one of the two token requests above: the only thing ever sent to the
    /// sign-in host from the app's own transport.
    static func isTokenRequest(_ request: GraphRequest) -> Bool {
        guard request.host == loginHost, request.method == .post, request.path == tokenPath, request.query.isEmpty,
              request.contentType == "application/x-www-form-urlencoded",
              let body = request.body.flatMap({ String(data: $0, encoding: .utf8) }) else { return false }
        let names = Set(body.split(separator: "&").compactMap { $0.split(separator: "=").first.map(String.init) })
        return names == ["client_id", "grant_type", "code", "redirect_uri", "code_verifier", "scope"]
            || names == ["client_id", "grant_type", "refresh_token", "scope"]
    }

    private static func form(_ fields: [(String, String)]) -> GraphRequest {
        GraphRequest(method: .post, host: loginHost, path: tokenPath,
                     body: GoogleOAuth.formEncode(fields).data(using: .utf8),
                     contentType: "application/x-www-form-urlencoded")
    }

    // MARK: - Token replies

    struct TokenResponse: Decodable, Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    /// Nil for a reply with no usable access token.
    static func parseToken(_ data: Data) -> TokenResponse? {
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
              ClinicWorkbookBearer.isSendable(response.accessToken) else { return nil }
        return response
    }

    /// The tokens, as the Keychain keeps them. Their descriptions never show one.
    struct Credentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        init(response: TokenResponse, now: Date, previousRefreshToken: String? = nil) {
            accessToken = response.accessToken
            // Microsoft rotates the refresh token on refresh; keep the old one if it sent none.
            refreshToken = response.refreshToken ?? previousRefreshToken
            expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
        }

        /// Refresh five minutes ahead of expiry, so a request does not race the deadline.
        func needsRefresh(now: Date, leeway: TimeInterval = 300) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(leeway) >= expiresAt
        }

        var description: String { "EntraOAuth.Credentials(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["tokens": "redacted"], displayStyle: .struct) }
    }
}
