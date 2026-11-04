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
        /// The service does not offer the requested model to this key, account or plan: the id
        /// is unknown to it, retired, or not part of what the sign-in may use.
        case modelNotAvailable
        /// One request is larger than the account's tokens-per-minute allowance for this model.
        /// Groq answers it with 413 `rate_limit_exceeded`; unlike a rate limit, waiting does not
        /// help — every turn of that size is refused until the request shrinks or the plan grows
        /// (support report, 2026-10-29: a free Groq key refused each 11k-token turn).
        case requestOverTokenRateLimit
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

        /// The reason belongs to this candidate — its model's contract, its credential, or whether
        /// the service offers its model at all — rather than to the request every candidate would
        /// be sent. The fallback chain reads this.
        var endsOnlyThisCandidate: Bool {
            isModelContract || self == .betaHeaderUnknown || self == .credentialNotAccepted
                || self == .modelNotAvailable || self == .requestOverTokenRateLimit
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
    /// A `requestOverTokenRateLimit` refusal's own figures (Plan KL P1): the account's tokens a
    /// minute for this model, and what the provider counted this request as. Groq writes them into
    /// its sentence ("… on tokens per minute (TPM): Limit 8000, Requested 11234, …"). They are
    /// numbers, so they may be written down; the sentence around them names the organisation and
    /// the model, and only the two numbers are read out of it. Nil for every other reason, and
    /// when the sentence does not carry them.
    let limit: Int?
    let requested: Int?

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
        let reason = Self.reason(status: status, type: rawType,
                                 code: details?["code"] as? String, message: message,
                                 parameter: details?["param"] as? String)
        self.reason = reason
        let figures = reason == .requestOverTokenRateLimit
            ? Self.perMinuteFigures(in: message) : (limit: nil, requested: nil)
        self.limit = figures.limit
        self.requested = figures.requested
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
        // Anthropic answers an unknown model with a 404 whose message is the field path alone.
        case "not_found_error" where text.hasPrefix("model:"): return .modelNotAvailable
        default: break
        }
        if code?.lowercased() == "model_not_found" { return .modelNotAvailable }
        // A 413 under a rate-limit code is a size refusal, not a busy service: the request alone
        // is over the per-minute allowance. A 429 never reaches here.
        if status == 413, code?.lowercased() == "rate_limit_exceeded" || type == "tokens" {
            return .requestOverTokenRateLimit
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

    /// The allowance and the requested count from a per-minute refusal: the number after the word
    /// "limit" and the number after "requested", each on its own. Only digits are read, so nothing
    /// else in the sentence — the organisation id, the model's name, the service tier — can come
    /// out of it. A figure that is absent, or not a plausible count, is nil.
    static func perMinuteFigures(in message: String?) -> (limit: Int?, requested: Int?) {
        guard let text = message?.lowercased(), !text.isEmpty else { return (nil, nil) }
        return (number(after: "limit", in: text), number(after: "requested", in: text))
    }

    /// The whole number standing after `word` as its own word — "limit 8000", "requested: 11234" —
    /// or nil. Part of an identifier is never read: `org_limit42` or `limit-8b` is skipped, as is a
    /// run of digits that runs on into letters. A count larger than any account's allowance is not
    /// a count.
    private static func number(after word: String, in text: String) -> Int? {
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" || c == "`" }
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: word, range: search) {
            search = found.upperBound..<text.endIndex
            if found.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: found.lowerBound)]) { continue }
            let after = text[found.upperBound...]
            let rest = after.drop { $0 == " " || $0 == ":" || $0 == "=" }
            guard rest.startIndex > after.startIndex else { continue }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if let next = rest.dropFirst(digits.count).first, isWordCharacter(next) { continue }
            guard !digits.isEmpty, digits.count <= 9, let value = Int(digits), value > 0 else { continue }
            return value
        }
        return nil
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

    /// How Gemini names its thinking controls in a refusal, in words or as a field.
    private static let geminiThinkingFields = [
        "thinking level", "thinking_level", "thinkinglevel",
        "thinking budget", "thinking_budget", "thinkingbudget",
        "thinking_config", "thinkingconfig", "thinking is not supported",
    ]

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
        // Anthropic names its field paths; Gemini says it in words — "Thinking level is not
        // supported for this model." — which had read as `other` and ended the turn rather than
        // the candidate (support report, 2026-10-29).
        Row(reason: .thinkingConfigUnsupported,
            allOf: [["thinking.type"], ["budget_tokens"]]
                + geminiThinkingFields.flatMap { field in refusalWords.map { [field, $0] } }),
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
        // Below the sampling and tool-choice rows: "`temperature` is not supported for this
        // model" refuses a parameter, not the model.
        Row(reason: .modelNotAvailable, allOf: [
            // The ChatGPT subscription backend, for a model outside the account's catalog.
            ["model is not supported when using"],
            // OpenAI and compatible services.
            ["the model", "does not exist"],
            // Gemini.
            ["models/", "is not found"],
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
