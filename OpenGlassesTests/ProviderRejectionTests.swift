import XCTest
@testable import OpenGlasses

/// Plan IE P0 — a provider's refusal, classified. Fixture bodies per reason and per provider
/// family: the error type and request id that are kept, the reason the message matched, and the
/// message itself appearing nowhere in what the classification can emit.
final class ProviderRejectionTests: XCTestCase {

    // MARK: - Fixtures

    /// Every fixture message ends in this, so one assertion can say no message reached an output.
    static let echo = " \(PrivacyCanary.stem)-ECHO of the request"

    static func anthropicBody(_ type: String, _ message: String, requestID: String? = "req_011CSHoEeqs5C35K2UUqR7Fy") -> Data {
        var envelope: [String: Any] = ["type": "error",
                                       "error": ["type": type, "message": message + echo]]
        if let requestID { envelope["request_id"] = requestID }
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    static func openAIBody(message: String, type: String? = "invalid_request_error",
                           code: String? = nil, param: String? = nil) -> Data {
        var error: [String: Any] = ["message": message + echo]
        error["type"] = type ?? NSNull()
        error["code"] = code ?? NSNull()
        error["param"] = param ?? NSNull()
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    static func geminiBody(_ status: String, _ message: String, code: Int = 400) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "error": ["code": code, "message": message + echo, "status": status],
        ])
    }

    static func anthropic(_ message: String, status: Int = 400,
                          type: String = "invalid_request_error") -> ProviderRejection {
        ProviderRejection(status: status, body: anthropicBody(type, message), provider: .anthropic)
    }

    /// The Anthropic messages this build knows, by the reason each must match.
    static let anthropicMessages: [(ProviderRejection.Reason, String)] = [
        (.toolChoiceUnsupported, #"tool_choice: type "tool" and "any" are not supported for this model."#),
        (.toolChoiceUnsupported, "Thinking may not be enabled when tool_choice forces tool use."),
        (.thinkingConfigUnsupported, #""thinking.type.disabled" is not supported for this model."#),
        (.thinkingConfigUnsupported, #""thinking.type.between_tools" is not supported for this model."#),
        (.thinkingConfigUnsupported, "thinking.enabled.budget_tokens: Input should be greater than or equal to 1024"),
        (.thinkingConfigUnsupported, "`max_tokens` must be greater than `thinking.budget_tokens`."),
        (.samplingUnsupported, "`temperature` is not supported for this model."),
        (.samplingUnsupported, "`top_p` must be unset when thinking is enabled."),
        (.samplingUnsupported, "top_k: Extra inputs are not permitted"),
        (.samplingUnsupported, "`temperature` may only be set to 1 when thinking is enabled."),
        (.betaHeaderUnknown, "Unexpected value(s) `oauth-2025-04-20` for the `anthropic-beta` header. Please consult our documentation."),
        (.credentialNotAccepted, "This credential is only authorized for use with one client and cannot be used for other API requests."),
        (.credentialNotAccepted, "OAuth authentication is currently not supported."),
        (.toolDefinitionInvalid, "tools.3.custom.input_schema: JSON schema is invalid. It must match JSON Schema draft 2020-12."),
        (.toolDefinitionInvalid, "tools.0.custom.name: String should match pattern '^[a-zA-Z0-9_-]{1,128}$'"),
        (.toolDefinitionInvalid, "tools: Tool names must be unique."),
        (.thinkingBlockInvalid, "messages.1.content.0: Invalid `signature` in `thinking` block"),
        (.thinkingBlockInvalid, "messages.1.content.0.thinking.signature: Field required"),
        (.thinkingBlockInvalid, "`thinking` or `redacted_thinking` blocks in the latest assistant message cannot be modified."),
        // The service's exact sentence for this is not pinned here; the match is a thinking
        // block and the word "prefix", and anything else about a changed history lands in
        // `messageShape` or `other`.
        (.historyPrefixChanged, "messages.3.content.0: `thinking` block is not valid because the prefix before it changed."),
        (.messageShape, #"messages: roles must alternate between "user" and "assistant", but found multiple "user" roles in a row"#),
        (.messageShape, "messages.2: `tool_use` ids were found without `tool_result` blocks immediately after: toolu_01"),
        (.messageShape, #"messages: first message must use the "user" role"#),
        (.messageShape, "messages: text content blocks must be non-empty"),
        (.messageShape, "messages: at least one message is required"),
        (.contextTooLong, "prompt is too long: 214032 tokens > 200000 maximum"),
        (.contextTooLong, "input length and `max_tokens` exceed context limit: 198000 + 8192 > 200000"),
        (.other, "max_tokens: 99999 > 64000, which is the maximum allowed number of output tokens for this model"),
        (.other, "This model supports tools. Nothing here names an element."),
    ]

    // MARK: - Anthropic

    func testEachKnownAnthropicMessageMatchesItsReason() {
        for (reason, message) in Self.anthropicMessages {
            XCTAssertEqual(Self.anthropic(message).reason, reason, message)
        }
    }

    func testEveryReasonHasAFixture() {
        let covered = Set(Self.anthropicMessages.map(\.0))
        XCTAssertEqual(covered, Set(ProviderRejection.Reason.allCases),
                       "a reason nothing can produce is a reason nobody tested")
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(Self.anthropic("PROMPT IS TOO LONG: 1 tokens > 0 maximum").reason, .contextTooLong)
        XCTAssertEqual(Self.anthropic("Tools.3.Custom.Input_Schema: bad").reason, .toolDefinitionInvalid)
    }

    func testTheAnthropicErrorTypeAndRequestIdAreKept() {
        let rejection = Self.anthropic(#"tool_choice: type "tool" and "any" are not supported for this model."#)
        XCTAssertEqual(rejection.status, 400)
        XCTAssertEqual(rejection.errorType, "invalid_request_error")
        XCTAssertEqual(rejection.requestID, "req_011CSHoEeqs5C35K2UUqR7Fy")
        XCTAssertEqual(rejection.summary.description, "clientError(invalid_request_error)#400")
    }

    func testAnAuthenticationErrorIsACredentialWhateverItsMessageSays() {
        let rejection = Self.anthropic("something this build has never seen", status: 401,
                                       type: "authentication_error")
        XCTAssertEqual(rejection.reason, .credentialNotAccepted)
        XCTAssertEqual(rejection.summary.description, "unauthorized(authentication_error)#401")
    }

    /// A rate limit, a timeout and a server fault say nothing about the request, so a message
    /// that happens to mention a parameter is not read as a refusal of it.
    func testStatusesThatDoNotDescribeTheRequestAreNeverMatched() {
        for status in [408, 429, 500, 503, 529] {
            let rejection = Self.anthropic("`temperature` is not supported for this model.",
                                           status: status, type: "overloaded_error")
            XCTAssertEqual(rejection.reason, .other, "status \(status)")
            XCTAssertEqual(rejection.errorType, "overloaded_error")
        }
    }

    func testABodyThatIsNotAnEnvelopeClassifiesAsOther() {
        for body in [Data(), Data("<html>Bad Gateway — prompt is too long</html>".utf8), Data("[1,2]".utf8)] {
            let rejection = ProviderRejection(status: 400, body: body, provider: .anthropic)
            XCTAssertEqual(rejection.reason, .other)
            XCTAssertNil(rejection.errorType)
            XCTAssertNil(rejection.requestID)
            XCTAssertEqual(rejection.summary.description, "clientError(http)#400")
        }
    }

    // MARK: - The request id

    func testTheRequestIdIsReadFromTheHeaderWhenTheBodyHasNone() {
        let body = Self.anthropicBody("invalid_request_error", "prompt is too long", requestID: nil)
        let rejection = ProviderRejection(status: 400, body: body,
                                          headers: ["Request-Id": "req_headerOnly123"], provider: .anthropic)
        XCTAssertEqual(rejection.requestID, "req_headerOnly123")
    }

    func testTheHeaderWinsOverTheBodyAndIsMatchedWithoutRegardToCase() {
        let body = Self.anthropicBody("invalid_request_error", "prompt is too long", requestID: "req_fromBody")
        for name in ["request-id", "Request-Id", "REQUEST-ID"] {
            let rejection = ProviderRejection(status: 400, body: body,
                                              headers: [name: "req_fromHeader"], provider: .anthropic)
            XCTAssertEqual(rejection.requestID, "req_fromHeader", name)
        }
        XCTAssertEqual(ProviderRejection(status: 400, body: body, provider: .anthropic).requestID, "req_fromBody")
    }

    func testAnHTTPResponseSuppliesStatusAndHeaders() {
        let response = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/messages")!,
                                       statusCode: 400, httpVersion: nil,
                                       headerFields: ["request-id": "req_fromResponse"])
        let rejection = ProviderRejection(response: response,
                                          body: Self.anthropicBody("invalid_request_error", "prompt is too long", requestID: nil),
                                          provider: .anthropic)
        XCTAssertEqual(rejection.status, 400)
        XCTAssertEqual(rejection.requestID, "req_fromResponse")
        XCTAssertEqual(ProviderRejection(response: nil, body: Data(), provider: .anthropic).status, 0)
    }

    /// The id slot is filled by the far end. A sentence there is dropped, and so is anything
    /// shaped like a credential.
    func testARequestIdThatIsNotAnIdentifierIsDropped() {
        let body = Self.anthropicBody("invalid_request_error", "prompt is too long", requestID: nil)
        let secretShaped = "sk-" + "ant-" + String(repeating: "a1B2", count: 6)
        for hostile in ["see \(PrivacyCanary.transcript)", PrivacyCanary.url, secretShaped,
                        String(repeating: "x", count: 80), ""] {
            let rejection = ProviderRejection(status: 400, body: body,
                                              headers: ["request-id": hostile], provider: .anthropic)
            XCTAssertNil(rejection.requestID, hostile)
        }
    }

    func testAnErrorTypeThatIsNotAnIdentifierIsDropped() {
        let rejection = ProviderRejection(
            status: 400, body: Self.anthropicBody(PrivacyCanary.transcript, "prompt is too long"),
            provider: .anthropic)
        XCTAssertNil(rejection.errorType)
        XCTAssertEqual(rejection.reason, .contextTooLong)
        XCTAssertEqual(rejection.summary.description, "clientError(http)#400")
    }

    // MARK: - OpenAI-compatible

    func testAnOpenAICodeIsTheErrorTypeAndDecidesContextLength() {
        let body = Self.openAIBody(message: "This model's maximum context length is 128000 tokens.",
                                   code: "context_length_exceeded", param: "messages")
        let rejection = ProviderRejection(status: 400, body: body,
                                          headers: ["x-request-id": "req_0f1e2d3c4b5a69788796a5b4c3d2e1f0"],
                                          provider: .openai)
        XCTAssertEqual(rejection.errorType, "context_length_exceeded")
        XCTAssertEqual(rejection.reason, .contextTooLong)
        XCTAssertEqual(rejection.requestID, "req_0f1e2d3c4b5a69788796a5b4c3d2e1f0")
    }

    func testWithNoCodeTheOpenAITypeIsTheErrorType() {
        let body = Self.openAIBody(message: "Invalid parameter: messages with role 'tool' must be a response to a preceeding message with 'tool_calls'.")
        let rejection = ProviderRejection(status: 400, body: body, provider: .groq)
        XCTAssertEqual(rejection.errorType, "invalid_request_error")
        XCTAssertEqual(rejection.reason, .messageShape)
    }

    func testOpenAICompatibleReasons() {
        let cases: [(ProviderRejection.Reason, Int, Data)] = [
            (.samplingUnsupported, 400, Self.openAIBody(
                message: "Unsupported value: 'temperature' does not support 0.7 with this model. Only the default (1) value is supported.",
                code: "unsupported_value", param: "temperature")),
            (.samplingUnsupported, 400, Self.openAIBody(message: "a sentence this build has not seen", param: "top_p")),
            (.toolDefinitionInvalid, 400, Self.openAIBody(
                message: "Invalid schema for function 'lookup': In context=(), 'additionalProperties' is required.",
                code: "invalid_function_parameters", param: "tools[0].function.parameters")),
            (.toolDefinitionInvalid, 400, Self.openAIBody(message: "Invalid value for 'tools[2].function.name'.")),
            (.messageShape, 400, Self.openAIBody(message: "Invalid value for 'messages[3].content'.")),
            (.credentialNotAccepted, 401, Self.openAIBody(
                message: "Incorrect API key provided: \(PrivacyCanary.secret).", code: "invalid_api_key")),
            (.contextTooLong, 400, Self.openAIBody(message: "Input exceeds the context window of this model.")),
            (.other, 400, Self.openAIBody(message: "Unsupported value: 'reasoning_effort' does not support 'high' with this model.",
                                          code: "unsupported_value", param: "reasoning_effort")),
            (.other, 400, Data(#"{"error":"a bare string, as some compatible servers send"}"#.utf8)),
        ]
        for (reason, status, body) in cases {
            XCTAssertEqual(ProviderRejection(status: status, body: body, provider: .custom).reason, reason,
                           String(decoding: body, as: UTF8.self))
        }
    }

    /// A failure reported inside a stream that opened with 200 has no `error` wrapper.
    func testAFailureInsideAStreamIsClassifiedFromItsOwnShape() {
        let body = Data(#"{"code":"context_length_exceeded","message":"too big"}"#.utf8)
        let rejection = ProviderRejection(status: 200, body: body, provider: .chatgpt)
        XCTAssertEqual(rejection.reason, .contextTooLong)
        XCTAssertEqual(rejection.summary.description, "badServerResponse(context_length_exceeded)#200")
    }

    /// The classifier's context-length verdict and the context budget's are the same test for
    /// the envelopes the budget was written for.
    func testContextLengthAgreesWithTheContextBudget() {
        let envelopes = [
            #"{"error":{"code":"context_length_exceeded","message":"too big"}}"#,
            #"{"error":{"message":"Exceeded model context window size"}}"#,
            #"{"error":{"code":"some_other_code","message":"maximum context length"}}"#,
            #"{"error":{"message":"Invalid tool schema"}}"#,
        ]
        for envelope in envelopes {
            let budget = RequestContextBudget.isOverflow(
                error: LLMError.apiError(provider: "ChatGPT", statusCode: 400, message: envelope))
            let rejection = ProviderRejection(status: 400, body: Data(envelope.utf8), provider: .chatgpt)
            XCTAssertEqual(rejection.reason == .contextTooLong, budget, envelope)
        }
    }

    // MARK: - Gemini

    func testGeminiStatusIsTheErrorTypeAndItsMessagesMatch() {
        let cases: [(ProviderRejection.Reason, String)] = [
            (.toolDefinitionInvalid, #"Invalid JSON payload received. Unknown name "additionalProperties" at 'tools[0].function_declarations[4].parameters': Cannot find field."#),
            (.contextTooLong, "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."),
            (.credentialNotAccepted, "API key not valid. Please pass a valid API key."),
            (.other, "Request contains an invalid argument."),
        ]
        for provider in [LLMProvider.gemini, .geminiVertex] {
            for (reason, message) in cases {
                let rejection = ProviderRejection(status: 400, body: Self.geminiBody("INVALID_ARGUMENT", message),
                                                  provider: provider)
                XCTAssertEqual(rejection.reason, reason, message)
                XCTAssertEqual(rejection.errorType, "INVALID_ARGUMENT")
                XCTAssertEqual(rejection.summary.description, "clientError(INVALID_ARGUMENT)#400")
            }
        }
        let limited = ProviderRejection(status: 429, body: Self.geminiBody("RESOURCE_EXHAUSTED", "Quota exceeded.", code: 429),
                                        provider: .gemini)
        XCTAssertEqual(limited.reason, .other)
        XCTAssertEqual(limited.summary.description, "rateLimited(RESOURCE_EXHAUSTED)#429")
    }

    // MARK: - Indexed paths

    func testAnIndexedPathNeedsAnIndexAndItsOwnRoot() {
        XCTAssertTrue(ProviderRejection.mentionsIndexedPath("tools", in: "tools.12.custom.name: bad"))
        XCTAssertTrue(ProviderRejection.mentionsIndexedPath("tools", in: "at 'tools[0].function'"))
        XCTAssertTrue(ProviderRejection.mentionsIndexedPath("messages", in: "see tools. then messages.4: bad"))
        XCTAssertFalse(ProviderRejection.mentionsIndexedPath("tools", in: "this model supports tools."))
        XCTAssertFalse(ProviderRejection.mentionsIndexedPath("tools", in: "tools.custom is not a path"))
        XCTAssertFalse(ProviderRejection.mentionsIndexedPath("tools", in: "mcp_tools.3 belongs to somebody else"))
        XCTAssertFalse(ProviderRejection.mentionsIndexedPath("tools", in: "tools"))
    }

    // MARK: - Which reasons end only the candidate

    func testTheReasonsThatBelongToOneModelOrOneCredential() {
        let candidateOnly: Set<ProviderRejection.Reason> = [
            .toolChoiceUnsupported, .thinkingConfigUnsupported, .samplingUnsupported,
            .betaHeaderUnknown, .credentialNotAccepted,
        ]
        for reason in ProviderRejection.Reason.allCases {
            XCTAssertEqual(reason.endsOnlyThisCandidate, candidateOnly.contains(reason), reason.rawValue)
        }
        XCTAssertEqual(Set(ProviderRejection.Reason.allCases.filter(\.isModelContract)),
                       [.toolChoiceUnsupported, .thinkingConfigUnsupported, .samplingUnsupported])
    }

    // MARK: - The message goes nowhere

    /// Everything a rejection can put into a log or a report, for every fixture in this file.
    func testNoFixtureMessageReachesAnythingARejectionEmits() {
        var rejections = Self.anthropicMessages.map { Self.anthropic($0.1) }
        rejections.append(ProviderRejection(status: 401, body: Self.openAIBody(
            message: "Incorrect API key provided: \(PrivacyCanary.secret).", code: "invalid_api_key"),
            provider: .openai))
        rejections.append(ProviderRejection(status: 400, body: Self.geminiBody(
            "INVALID_ARGUMENT", PrivacyCanary.toolResult), provider: .gemini))

        for rejection in rejections {
            let emitted = [
                rejection.summary.description,
                rejection.reasonToken.description,
                rejection.requestToken?.description ?? "",
                rejection.errorType ?? "",
                String(describing: rejection),
                PrivacyEventEncoder.encode(PrivacyLog.modelRejected(
                    rejection, provider: PrivacyToken("anthropic"), auth: .accountSignIn, bytes: 512,
                    detail: PrivacyToken("summarise"))),
            ].joined(separator: "\n")
            XCTAssertFalse(emitted.uppercased().contains(PrivacyCanary.stem), emitted)
            XCTAssertFalse(emitted.contains("of the request"), emitted)
        }
    }
}
