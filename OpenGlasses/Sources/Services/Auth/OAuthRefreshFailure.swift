import Foundation

/// What a failed token refresh means for the stored credential (Plan FG P1a). Pure.
///
/// Every refresh failure used to read as "sign-in expired, please sign in again", a dropped
/// connection included. Only the token endpoint can say a credential is dead, and it says so in
/// words: `invalid_grant`, or a code that names the refresh token as expired, reused or revoked.
/// Anything that never reached it, or reached it while it was failing, says nothing about the
/// credential at all.
enum OAuthRefreshFailure: Equatable {
    /// The refresh token is dead — expired, revoked, or already spent. Only a new sign-in helps,
    /// so the stored credential is discarded.
    case credentialDead
    /// The sign-in service was not reached, timed out, or was failing (5xx, 429,
    /// `temporarily_unavailable`). The credential is kept and the next call tries again.
    case unreachable
    /// Reached and refused for a reason that does not prove the credential dead (another 4xx, an
    /// unreadable reply, a local policy refusal). The credential is kept; the wearer is asked to
    /// sign in again, as before.
    case rejected

    static func classify(_ error: Error) -> OAuthRefreshFailure {
        if let endpoint = error as? OAuthTokenEndpointError {
            return classify(status: endpoint.status, code: endpoint.code)
        }
        if error is URLError || error is CancellationError { return .unreachable }
        if (error as NSError).domain == NSURLErrorDomain { return .unreachable }
        return .rejected
    }

    /// The token endpoint answered `status`, with `code` read from its body. The code wins over
    /// the status: an `invalid_grant` is dead whatever status carried it.
    static func classify(status: Int, code: OAuthErrorCode?) -> OAuthRefreshFailure {
        if let code {
            if code.meansCredentialDead { return .credentialDead }
            if code == .temporarilyUnavailable || code == .serverError { return .unreachable }
        }
        switch status {
        case 408, 429, 500...599: return .unreachable
        default: return .rejected
        }
    }

    /// What the sign-in row says. `provider` is the display name ("ChatGPT", "Claude", "Google").
    func message(provider: String) -> String {
        switch self {
        case .unreachable:
            return String(localized: "Couldn't reach the \(provider) sign-in service; I'll try again.")
        case .credentialDead, .rejected:
            return String(localized: "\(provider) sign-in expired — please sign in again.")
        }
    }
}

/// The machine-readable `error` a token endpoint answers with — a closed vocabulary, so nothing
/// free-form from the response body is ever kept, shown or logged.
enum OAuthErrorCode: String, CaseIterable, Sendable {
    // RFC 6749 §5.2.
    case invalidRequest = "invalid_request"
    case invalidClient = "invalid_client"
    case invalidGrant = "invalid_grant"
    case unauthorizedClient = "unauthorized_client"
    case unsupportedGrantType = "unsupported_grant_type"
    case invalidScope = "invalid_scope"
    // RFC 6749 §4.1.2.1, also seen on token endpoints.
    case serverError = "server_error"
    case temporarilyUnavailable = "temporarily_unavailable"
    // Explicit revocation, as some providers spell it.
    case tokenRevoked = "token_revoked"
    case refreshTokenExpired = "refresh_token_expired"
    case refreshTokenReused = "refresh_token_reused"
    case refreshTokenInvalidated = "refresh_token_invalidated"

    var meansCredentialDead: Bool {
        switch self {
        case .invalidGrant, .tokenRevoked, .refreshTokenExpired, .refreshTokenReused,
             .refreshTokenInvalidated:
            return true
        default:
            return false
        }
    }

    /// Read the code from a token endpoint's error body: `{"error": "invalid_grant"}` (RFC 6749),
    /// or `{"error": {"code": "refresh_token_reused"}}` (nested). Unknown codes read as nil.
    static func parse(_ body: Data) -> OAuthErrorCode? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        if let code = json["error"] as? String { return OAuthErrorCode(rawValue: code) }
        if let nested = json["error"] as? [String: Any] {
            for field in ["code", "type"] {
                if let code = (nested[field] as? String).flatMap(OAuthErrorCode.init(rawValue:)) {
                    return code
                }
            }
        }
        return (json["code"] as? String).flatMap(OAuthErrorCode.init(rawValue:))
    }
}

/// A token endpoint answered with something other than 2xx. Carries the status and the code the
/// body named, never the body: a refusal's description can quote what the request sent.
struct OAuthTokenEndpointError: LocalizedError, Equatable {
    let status: Int
    let code: OAuthErrorCode?

    init(status: Int, code: OAuthErrorCode? = nil) {
        self.status = status
        self.code = code
    }

    init(status: Int, body: Data) {
        self.init(status: status, code: OAuthErrorCode.parse(body))
    }

    var errorDescription: String? { "Token endpoint returned HTTP \(status)" }

    /// The log line's summary: the status's category and the code, both from fixed vocabularies.
    var summary: SafeErrorSummary {
        SafeErrorSummary(category: SafeErrorSummary.http(status: status).category,
                         detail: PrivacyToken(code?.rawValue ?? "http"), code: status)
    }

    /// Summarise any refresh failure for the log, keeping the endpoint's code when there is one.
    static func summary(of error: Error) -> SafeErrorSummary {
        (error as? OAuthTokenEndpointError)?.summary ?? SafeErrorSummary(error)
    }
}

/// Where a sign-in keeps its credentials: the keychain in the app, memory in a test, so a test
/// never reads or wipes the item a real sign-in holds.
struct OAuthCredentialStore {
    let load: () -> Data?
    let save: (Data) -> Void
    let remove: () -> Void

    static func keychain(_ key: String) -> OAuthCredentialStore {
        OAuthCredentialStore(
            load: { KeychainService.data(for: key) },
            save: { _ = KeychainService.setData($0, for: key) },
            remove: { _ = KeychainService.delete(key) })
    }
}
