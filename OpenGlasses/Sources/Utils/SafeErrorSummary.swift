import Foundation

/// A bounded, public description of *what went wrong* — never of *what was being sent*.
///
/// `localizedDescription` is not safe to log, and the reason is structural rather than
/// theoretical: `URLError` carries the failing URL, `DecodingError` carries the coding path and
/// frequently the offending value, and a server-shaped error routinely carries a fragment of the
/// response body. An error inherits the classification of the request that produced it, so a
/// description built from a request that carried a transcript, an entity id, or an auth code is
/// user-content class. **This type never reads one.**
///
/// What it produces instead is a category from a closed vocabulary, optionally a case/domain
/// token that has survived `PrivacyToken`'s shape filter, and optionally a number. A number
/// cannot carry content; a filtered token cannot carry a sentence.
struct SafeErrorSummary: Equatable, CustomStringConvertible {

    /// The closed vocabulary. Everything an error can be, from a log reader's point of view.
    enum Category: String {
        case cancelled
        case offline
        case timedOut
        case cannotConnect
        case tlsFailure
        case badURL
        case badServerResponse
        case decoding
        case unauthorized
        case forbidden
        case notFound
        case rateLimited
        case serverError
        case clientError
        /// An app-side policy refusal (an SSRF guard, a trust gate) rather than a transport fault.
        case refused
        /// Local storage: a database that would not open, a statement that would not run, a blob
        /// that would not read. Distinct from `decoding`, which is the shape of the bytes.
        case storage
        case unknown
    }

    let category: Category
    /// An enum case name, an error domain, or a type name — always via `PrivacyToken`, so a
    /// description-shaped string is dropped rather than shortened.
    let detail: PrivacyToken?
    /// An HTTP status or an `NSError` code.
    let code: Int?

    init(category: Category, detail: PrivacyToken? = nil, code: Int? = nil) {
        self.category = category
        self.detail = detail
        self.code = code
    }

    var description: String {
        var out = category.rawValue
        if let detail { out += "(\(detail.description))" }
        if let code { out += "#\(code)" }
        return out
    }

    // MARK: - Construction

    /// Summarise any error without reading its description.
    ///
    /// The ladder is deliberate: the types we know are mapped precisely; everything else falls
    /// through to a type name plus a domain/code pair, which is the most that can be said about
    /// an unknown error without quoting it.
    init(_ error: Error) {
        if error is CancellationError {
            self.init(category: .cancelled, detail: PrivacyToken("CancellationError"))
            return
        }
        if let urlError = error as? URLError {
            self.init(category: Self.category(for: urlError.code),
                      detail: PrivacyToken("URLError"),
                      code: urlError.errorCode)
            return
        }
        if let decoding = error as? DecodingError {
            self.init(category: .decoding,
                      detail: PrivacyToken.caseName(of: decoding) ?? PrivacyToken("DecodingError"),
                      code: Self.codingPathDepth(of: decoding))
            return
        }

        // Unknown: the enum case name if this is an enum (payloads left behind), otherwise the
        // type name; plus the bridged domain and code. Never `String(describing:)` on a value
        // whose shape we have not established.
        let bridged = error as NSError
        let detail = PrivacyToken.caseName(of: error)
            ?? PrivacyToken(String(describing: type(of: error)))
        let isKnownDomain = bridged.domain == NSURLErrorDomain || bridged.domain == NSCocoaErrorDomain
        self.init(category: isKnownDomain ? .badServerResponse : .unknown,
                  detail: detail,
                  code: bridged.code == 0 ? nil : bridged.code)
    }

    /// An HTTP response that was reached but refused.
    static func http(status: Int) -> SafeErrorSummary {
        let category: Category
        switch status {
        case 401: category = .unauthorized
        case 403: category = .forbidden
        case 404: category = .notFound
        case 429: category = .rateLimited
        case 500...599: category = .serverError
        case 400...499: category = .clientError
        default: category = .unknown
        }
        return SafeErrorSummary(category: category, detail: PrivacyToken("http"), code: status)
    }

    /// An app-side refusal: a guard said no before anything left the device. The rejection's own
    /// `description` names the host or scheme it refused, so only the case name is kept.
    static func refused(_ error: Error) -> SafeErrorSummary {
        SafeErrorSummary(category: .refused, detail: PrivacyToken.caseName(of: error))
    }

    /// A machine-readable code supplied by a remote peer (a Realtime `error.code`, say). The
    /// peer's human-readable `message` is a free-form string and is never summarised — only the
    /// code is, and it still goes through the vocabulary filter.
    static func remote(code: String?) -> SafeErrorSummary {
        SafeErrorSummary(category: .badServerResponse,
                         detail: code.map(PrivacyToken.init) ?? PrivacyToken("unknown"))
    }

    /// A SQLite fault. The result code and its extended code are a fixed numeric vocabulary
    /// defined by the library, so both are public.
    ///
    /// `sqlite3_errmsg` is not, and that is the whole reason this exists: on a prepare failure it
    /// quotes the offending SQL, and this app's stores are where memory keys, diary text and
    /// document chunks live. A message like `near "s": syntax error` is a fragment of the value
    /// that broke the statement — which is precisely the class of bug these lines are read for,
    /// and precisely the content that must not be written down.
    static func sqlite(code: Int32, extended: Int32? = nil) -> SafeErrorSummary {
        let detail = extended.map { PrivacyToken("sqlite.\($0)") } ?? PrivacyToken("sqlite")
        return SafeErrorSummary(category: .storage, detail: detail, code: Int(code))
    }

    /// How deep in the document the decoder was when it gave up — never *where*.
    ///
    /// The coding path is a list of keys, and a key is only safe when it is a fixed `CodingKeys`
    /// name. In a `[String: T]` blob — which several of these stores are — the keys are the
    /// wearer's own strings, so the path is data. Its length is not: it distinguishes "the whole
    /// file is not JSON" from "one field of one record is the wrong type", which is the only thing
    /// a salvage report needs from it.
    private static func codingPathDepth(of error: DecodingError) -> Int? {
        switch error {
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .keyNotFound(_, let context),
             .dataCorrupted(let context):
            return context.codingPath.count
        @unknown default:
            return nil
        }
    }

    private static func category(for code: URLError.Code) -> Category {
        switch code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return .offline
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .cannotConnect
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tlsFailure
        case .badURL, .unsupportedURL:
            return .badURL
        case .badServerResponse, .cannotParseResponse, .zeroByteResource:
            return .badServerResponse
        case .userAuthenticationRequired:
            return .unauthorized
        default:
            return .unknown
        }
    }
}
