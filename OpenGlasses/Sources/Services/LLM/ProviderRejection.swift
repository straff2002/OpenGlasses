import Foundation

/// What a model provider said when it refused a request, reduced to what may be written down
/// (Plan IE P0).
///
/// A provider's error envelope has two halves. One is machine-readable: an error type from the
/// provider's own fixed list, and an id that names the one request to the provider and nothing
/// else. The other is a sentence written for a developer, and that sentence can quote the request
/// back — a tool's name, a schema path, a fragment of a message. So the sentence is read here,
/// once, to choose a `Reason` from a closed vocabulary, and then it is let go: **this type never
/// stores the message**, and nothing built from it can log, export or keep one. It is the same
/// rule `SafeErrorSummary` applies to a peer's free-form text.
///
/// Pure: a status, a body, the response headers and the provider go in; the classification comes
/// out. No I/O and no clock, so every reason is a fixture test.
struct ProviderRejection: Equatable, Sendable {

    /// Why the request was refused, as far as the message could be matched. A wrong specific
    /// reason is worse than `other` — it sends the reader to the wrong part of the request — so
    /// the patterns below match narrowly and everything else lands in `other`.
    enum Reason: String, CaseIterable, Sendable {
        /// The model does not take a forced tool choice.
        case toolChoiceUnsupported
        /// The model does not take the thinking configuration it was sent.
        case thinkingConfigUnsupported
        /// The model does not take a sampling parameter (`temperature`, `top_p`, `top_k`).
        case samplingUnsupported
        /// A beta header value the service does not recognise.
        case betaHeaderUnknown
        /// The key or account sign-in was not accepted for this request.
        case credentialNotAccepted
        /// A tool's definition (its name or its schema) was refused.
        case toolDefinitionInvalid
        /// A replayed thinking block was not the one the model produced.
        case thinkingBlockInvalid
        /// A replayed thinking block was refused because the content before it changed.
        case historyPrefixChanged
        /// The message list itself: roles out of order, an empty message, a dangling tool call.
        case messageShape
        /// The prompt did not fit the model's context window.
        case contextTooLong
        case other

        /// The reason belongs to one model's request contract: another model may accept the very
        /// same request.
        var isModelContract: Bool {
            switch self {
            case .toolChoiceUnsupported, .thinkingConfigUnsupported, .samplingUnsupported:
                return true
            default:
                return false
            }
        }

        /// The reason belongs to this candidate — its model's contract or its credential — rather
        /// than to the request every candidate would be sent. The fallback chain reads this.
        var endsOnlyThisCandidate: Bool {
            isModelContract || self == .betaHeaderUnknown || self == .credentialNotAccepted
        }
    }

    /// The HTTP status the provider answered with. 200 for a failure reported inside a stream.
    let status: Int
    /// The provider's machine-readable error type — Anthropic `error.type`, an OpenAI-compatible
    /// `error.code` or `error.type`, Gemini `error.status`. Kept only when it has the shape of an
    /// identifier (`PrivacyToken`'s filter), so a sentence in that slot is dropped, not shortened.
    let errorType: String?
    /// The id the provider gave this request, from the response header or the body. Kept only
    /// when it has the shape of an identifier and does not look like a credential.
    let requestID: String?
    let reason: Reason

    // MARK: - Classification

    /// Classify a refused response.
    /// - Parameters:
    ///   - headers: the response's header fields. Anthropic repeats its request id in `request-id`;
    ///     OpenAI-compatible services send `x-request-id`. Names are matched without regard to case.
    init(status: Int, body: Data, headers: [AnyHashable: Any] = [:], provider: LLMProvider) {
        let envelope = Self.envelope(from: body)
        let details = envelope.flatMap { $0["error"] as? [String: Any] } ?? envelope

        let rawType: String?
        switch Self.family(of: provider) {
        case .anthropic:
            rawType = details?["type"] as? String
        case .gemini:
            rawType = details?["status"] as? String
        case .openAICompatible:
            rawType = Self.nonEmpty(details?["code"] as? String) ?? (details?["type"] as? String)
        }
        let message = details?["message"] as? String
            ?? details?["detail"] as? String
            ?? envelope?["error"] as? String

        self.status = status
        self.errorType = Self.identifier(rawType)
        self.requestID = Self.requestIdentifier(Self.header(headers, named: "request-id")
            ?? Self.header(headers, named: "x-request-id")
            ?? envelope?["request_id"] as? String
            ?? details?["request_id"] as? String)
        self.reason = Self.reason(status: status, type: rawType,
                                  code: details?["code"] as? String, message: message,
                                  parameter: details?["param"] as? String)
    }

    /// Classify from the response the transport handed back. A response that is not HTTP has no
    /// status and no headers, and classifies as status 0.
    init(response: URLResponse?, body: Data, provider: LLMProvider) {
        let http = response as? HTTPURLResponse
        self.init(status: http?.statusCode ?? 0, body: body,
                  headers: http?.allHeaderFields ?? [:], provider: provider)
    }

    // MARK: - What may be written down

    /// `clientError(invalid_request_error)#400` — the status's category, with the provider's own
    /// error type as the detail when it sent one.
    var summary: SafeErrorSummary {
        let base = SafeErrorSummary.http(status: status)
        // A failure reported inside a stream that opened with 200 was reached and answered; what
        // came back was not a reply.
        return SafeErrorSummary(category: status == 200 ? .badServerResponse : base.category,
                                detail: errorType.map(PrivacyToken.init) ?? base.detail,
                                code: status)
    }

    var reasonToken: PrivacyToken { PrivacyToken(reason.rawValue) }

    var requestToken: PrivacyToken? { requestID.map(PrivacyToken.init) }

    // MARK: - The message, read once

    /// Statuses whose message describes the request. A rate limit, a timeout or a server fault
    /// says nothing about what was sent, so those are never matched: their reason is `other`.
    private static func describesTheRequest(_ status: Int) -> Bool {
        status == 200 || ((400...499).contains(status) && status != 408 && status != 429)
    }

    private static func reason(status: Int, type: String?, code: String?, message: String?,
                               parameter: String?) -> Reason {
        guard describesTheRequest(status) else { return .other }
        let type = type?.lowercased() ?? ""
        let text = message?.lowercased() ?? ""

        // The machine-readable half first: a provider's own code is not a guess.
        if let code = nonEmpty(code), RequestContextBudget.isOverflow(code: code, message: nil) {
            return .contextTooLong
        }
        switch type {
        case "authentication_error", "invalid_api_key": return .credentialNotAccepted
        case "invalid_function_parameters": return .toolDefinitionInvalid
        default: break
        }
        if let parameter = parameter?.lowercased(), samplingParameters.contains(parameter) {
            return .samplingUnsupported
        }

        guard !text.isEmpty else { return .other }
        for row in table where row.matches(text) { return row.reason }
        // Last, the context budget's own test, called as it calls it — so the two cannot
        // disagree about an envelope the budget was written for.
        if RequestContextBudget.isOverflow(code: code, message: text) { return .contextTooLong }
        return .other
    }

    /// One row of the message table: the reason, and the shapes that mean it.
    private struct Row {
        let reason: Reason
        /// Each entry is a set of fragments that must all be present. Any one entry matching is
        /// enough. Fragments are lower case; the message is lowered before the test.
        var allOf: [[String]] = []
        /// A field path with an index — `tools.3.…` or `messages[2]…` — under any of these roots.
        var indexedPaths: [String] = []

        func matches(_ text: String) -> Bool {
            allOf.contains { fragments in fragments.allSatisfy { text.contains($0) } }
                || indexedPaths.contains { ProviderRejection.mentionsIndexedPath($0, in: text) }
        }
    }

    private static let samplingParameters: Set<String> = ["temperature", "top_p", "top_k"]

    /// The words a provider uses when it refuses a parameter rather than describing it.
    private static let refusalWords = [
        "not supported", "unsupported", "does not support", "may only be set", "must be unset",
        "deprecated", "not allowed", "not permitted",
    ]

    /// Every message shape this type recognises, in the order they are tried. The first match
    /// wins, so the narrow rows sit above the broad ones: a bad signature is reported at a
    /// `messages.N` path, and must be read as a thinking block before it is read as message shape.
    private static let table: [Row] = [
        Row(reason: .betaHeaderUnknown, allOf: [["anthropic-beta"]]),
        Row(reason: .credentialNotAccepted, allOf: [
            ["only authorized for use with"],
            ["oauth", "not supported"],
            ["invalid x-api-key"], ["invalid bearer token"],
            ["invalid api key"], ["incorrect api key"], ["api key not valid"],
        ]),
        Row(reason: .thinkingBlockInvalid, allOf: [["signature", "thinking"]]),
        Row(reason: .historyPrefixChanged, allOf: [["thinking", "prefix"]]),
        Row(reason: .thinkingBlockInvalid, allOf: [["thinking", "cannot be modified"]]),
        Row(reason: .toolChoiceUnsupported,
            allOf: refusalWords.map { ["tool_choice", $0] }
                + [["tool_choice", "thinking may not be enabled"]]),
        Row(reason: .thinkingConfigUnsupported, allOf: [["thinking.type"], ["budget_tokens"]]),
        Row(reason: .samplingUnsupported,
            allOf: samplingParameters.sorted().flatMap { name in refusalWords.map { [name, $0] } }),
        Row(reason: .toolDefinitionInvalid,
            allOf: [["tool names must be unique"], ["input_schema"],
                    ["invalid schema for function"], ["tools[", "function_declarations"]],
            indexedPaths: ["tools"]),
        Row(reason: .contextTooLong, allOf: [
            ["prompt is too long"], ["exceed context limit"],
            ["input token count", "exceeds the maximum"],
        ]),
        Row(reason: .messageShape,
            allOf: [["roles must alternate"], ["first message must use"],
                    ["at least one message is required"], ["must be non-empty"],
                    ["must have non-empty content"], ["messages with role"]],
            indexedPaths: ["messages"]),
    ]

    /// Whether `text` names an indexed element under `root`: `tools.3`, `messages[12]`. A bare
    /// mention of the word is not enough — "this model supports tools." names no element.
    static func mentionsIndexedPath(_ root: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: root, range: search) {
            search = found.upperBound..<text.endIndex
            // `mcp_tools.3` is somebody else's field, not the request's `tools` array.
            if found.lowerBound > text.startIndex {
                let before = text[text.index(before: found.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var rest = text[found.upperBound...]
            guard let separator = rest.first, separator == "." || separator == "[" else { continue }
            rest = rest.dropFirst()
            if let digit = rest.first, digit.isASCII, digit.isNumber { return true }
        }
        return false
    }

    // MARK: - Shape filters

    private enum Family { case anthropic, openAICompatible, gemini }

    private static func family(of provider: LLMProvider) -> Family {
        switch provider {
        case .anthropic: return .anthropic
        case .gemini, .geminiVertex: return .gemini
        default: return .openAICompatible
        }
    }

    private static func envelope(from body: Data) -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// A value from a slot the provider fills from a fixed list, kept only if it looks like it.
    private static func identifier(_ raw: String?) -> String? {
        guard let raw = nonEmpty(raw) else { return nil }
        let token = PrivacyToken(raw).description
        return token == PrivacyToken.placeholder ? nil : token
    }

    /// A request id is an identifier too, with one more test: the slot is filled by the far end,
    /// and a far end that put a credential there must not have it copied into a log.
    private static func requestIdentifier(_ raw: String?) -> String? {
        guard let id = identifier(raw), !SecretPatterns.containsSensitive(id) else { return nil }
        return id
    }

    private static func header(_ headers: [AnyHashable: Any], named name: String) -> String? {
        for (key, value) in headers {
            guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return value as? String
        }
        return nil
    }
}
