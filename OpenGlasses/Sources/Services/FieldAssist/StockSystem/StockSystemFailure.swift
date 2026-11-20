import Foundation

/// Why a call to a stock system failed, in categories every system shares (Plan MM P1). The
/// adapter maps a status and a body onto one; the sentences are common, worded with the system's
/// name, and each says what to fix. Nothing the system wrote in its own words is ever repeated:
/// a rejection keeps only a short, checked code and field name.
enum StockSystemFailure: Error, Equatable, Sendable {

    /// How the system turned the key down.
    enum Unauthorized: String, Equatable, Sendable {
        case expired, revoked, invalid
    }

    /// The key was not accepted (401). Terminal until a new key is pasted.
    case unauthorized(Unauthorized)
    /// The key lacks a permission (403), named in the system's own word. Terminal.
    case missingScope(String)
    /// The system is limiting requests (429). Back off, for `retryAfter` seconds when it says.
    case rateLimited(retryAfter: TimeInterval?)
    /// The system failed (5xx). Back off.
    case server(status: Int)
    /// The system refused the request as invalid (another 4xx), with its short code and the field
    /// it named, when they are plain words. Terminal: the same request would be refused again.
    case rejected(code: String?, field: String?)
    /// What was asked for is not there (404), or no chosen location still exists. Terminal.
    case notFound
    /// The response could not be read. After a write the outcome is uncertain: read back first.
    case malformedResponse
    /// More than the phone can safely hold. Terminal until the choice is narrowed.
    case tooLarge
    /// No connection reached the system. Back off.
    case unreachable

    /// Stop retrying: a person has to fix something first.
    var isTerminal: Bool {
        switch self {
        case .unauthorized, .missingScope, .rejected, .notFound, .tooLarge: return true
        case .rateLimited, .server, .malformedResponse, .unreachable: return false
        }
    }

    /// Back off and try again later (after a read-back, for a write).
    var isRetryable: Bool { !isTerminal }

    /// The stored word, for the support report: "unauthorized_expired", "missing_scope".
    var code: String {
        switch self {
        case .unauthorized(let kind): return "unauthorized_\(kind.rawValue)"
        case .missingScope: return "missing_scope"
        case .rateLimited: return "rate_limited"
        case .server: return "server"
        case .rejected: return "rejected"
        case .notFound: return "not_found"
        case .malformedResponse: return "malformed_response"
        case .tooLarge: return "too_large"
        case .unreachable: return "unreachable"
        }
    }

    /// Where the connection is fixed.
    static let settingsPath = "Settings › Field Assist › Stock system"

    /// What the person is told, with the system's name. Each says what to fix or what happens next.
    func sentence(system: String) -> String {
        let settings = Self.settingsPath
        switch self {
        case .unauthorized(.expired):
            return "\(system) says the key has expired. Paste a new one in \(settings)."
        case .unauthorized(.revoked):
            return "\(system) says the key was revoked. Make a new key in \(system) and paste it in \(settings)."
        case .unauthorized(.invalid):
            return "\(system) didn't accept the key. Check it, or paste a new one in \(settings)."
        case .missingScope(let scope):
            return "The \(system) key can't do this without the \(scope) permission. Make a key that has it and paste "
                + "it in \(settings)."
        case .rateLimited:
            return "\(system) is limiting requests. The phone will wait and try again."
        case .server:
            return "\(system) is having trouble right now. The phone will wait and try again."
        case .rejected(let code, let field):
            var detail = ""
            if let code { detail = " (\(code)" + (field.map { " on \($0)" } ?? "") + ")" }
            return "\(system) refused the request\(detail). Nothing more is sent until someone checks it in \(system)."
        case .notFound:
            return "\(system) no longer has what the phone asked for. Check the stock location in \(settings)."
        case .malformedResponse:
            return "\(system) sent a reply this phone couldn't read. The phone will check and try again later."
        case .tooLarge:
            return "\(system) sent more than this phone can safely hold. Choose fewer locations in \(settings)."
        case .unreachable:
            return "No connection to \(system). The last figures on this phone are still used."
        }
    }

    // MARK: - Building

    /// The longest code or field name kept from a rejection.
    static let codeCap = 48

    /// A rejection, keeping the system's code and field only when each is a short plain word
    /// (letters, digits, `_`, `.`, `-`, `[`, `]`), so no free text from the system is ever repeated.
    static func rejected(systemCode: String?, systemField: String?) -> StockSystemFailure {
        .rejected(code: plainWord(systemCode), field: plainWord(systemField))
    }

    /// The category a status stands for when the system says nothing more specific: what an
    /// adapter falls back on. Nil for a success.
    static func forStatus(_ status: Int, endpoint: StockSystemEndpoint, retryAfter: TimeInterval? = nil) -> StockSystemFailure? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized(.invalid)
        case 403: return .missingScope(endpoint.scope ?? "needed")
        case 404: return .notFound
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500...599: return .server(status: status)
        case 400..<500: return .rejected(code: nil, field: nil)
        default: return .malformedResponse
        }
    }

    /// A `Retry-After` header's delay, when it is a whole number of seconds up to a day. A date, or
    /// anything else, is nil: the caller's own back-off applies.
    static func retryAfter(_ response: StockSystemResponse) -> TimeInterval? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, raw.count <= 6, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int(raw), seconds <= 86_400 else { return nil }
        return TimeInterval(seconds)
    }

    private static func plainWord(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.count <= codeCap,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-[]".unicodeScalars.contains($0)) })
        else { return nil }
        return trimmed
    }
}
