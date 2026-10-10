import XCTest
@testable import OpenGlasses

/// Plan IE P0 — where a provider's refusal is carried once it has been classified: the error
/// summary, the turn's line in the support report, the banner, the spoken reason, the fallback
/// chain, and the log line every Anthropic site writes. In all of them the provider's message and
/// the credential's value appear nowhere.
@MainActor
final class RejectedTurnReportingTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    /// A sign-in token in the shape the app tells apart from a key, built from the canary so a
    /// leak is one assertion. Not a credential.
    private let signInToken = "sk-ant-oat01-" + PrivacyCanary.secret
    private let pastedKey = "pasted-" + PrivacyCanary.secret

    override func setUp() {
        super.setUp()
        TurnRecorder.reset(ledger: TurnLedger(), now: { [epoch] in epoch }, micRoutePorts: { [] })
    }

    override func tearDown() {
        TurnRecorder.reset()
        super.tearDown()
    }

    private func rejection(_ message: String, status: Int = 400,
                           type: String = "invalid_request_error",
                           provider: LLMProvider = .anthropic) -> ProviderRejection {
        ProviderRejection(status: status, body: ProviderRejectionTests.anthropicBody(type, message),
                          provider: provider)
    }

    private func refused(_ message: String, status: Int = 400,
                         type: String = "invalid_request_error") -> LLMError {
        .apiError(provider: "Anthropic", statusCode: status,
                  message: message + ProviderRejectionTests.echo,
                  rejection: rejection(message, status: status, type: type))
    }

    /// One fixture message per reason.
    private var messageByReason: [ProviderRejection.Reason: String] {
        var map: [ProviderRejection.Reason: String] = [:]
        for (reason, message) in ProviderRejectionTests.anthropicMessages where map[reason] == nil {
            map[reason] = message
        }
        return map
    }

    private func assertNoMessageOrCredential(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.uppercased().contains(PrivacyCanary.stem), text, file: file, line: line)
        XCTAssertFalse(text.contains("Bearer"), text, file: file, line: line)
        XCTAssertFalse(text.contains("sk-ant"), text, file: file, line: line)
    }

    // MARK: - The summary rung

    func testARefusedRequestSummarisesToItsStatusAndTheProvidersErrorType() {
        let summary = SafeErrorSummary(refused("prompt is too long: 9 tokens > 8 maximum"))
        XCTAssertEqual(summary.description, "clientError(invalid_request_error)#400")
        XCTAssertEqual(summary.category, .clientError)
        XCTAssertEqual(summary.code, 400)
    }

    /// The line this plan started from read `unknown(apiError)#3`: the enum case and its ordinal.
    func testAnAPIErrorWithNoRejectionStillReadsAsItsStatus() {
        let summary = SafeErrorSummary(LLMError.apiError(provider: "x", statusCode: 400, message: "anything"))
        XCTAssertEqual(summary.description, "clientError(http)#400")
        XCTAssertEqual(SafeErrorSummary(LLMError.apiError(provider: "x", statusCode: 429, message: nil)).description,
                       "rateLimited(http)#429")
    }

    func testTheOtherModelErrorsKeepTheirCaseNameAndLoseTheOrdinal() {
        XCTAssertEqual(SafeErrorSummary(LLMError.invalidResponse(PrivacyCanary.transcript)).description,
                       "badServerResponse(invalidResponse)")
        XCTAssertEqual(SafeErrorSummary(LLMError.streamInterrupted(provider: "x", reason: PrivacyCanary.transcript)).description,
                       "badServerResponse(streamInterrupted)")
        XCTAssertEqual(SafeErrorSummary(LLMError.missingAPIKey(PrivacyCanary.transcript)).description,
                       "unknown(missingAPIKey)")
        XCTAssertEqual(SafeErrorSummary(LLMError.invalidConfiguration(PrivacyCanary.transcript)).description,
                       "unknown(invalidConfiguration)")
    }

    func testNoFixtureMessageReachesASummary() {
        for (_, message) in ProviderRejectionTests.anthropicMessages {
            assertNoMessageOrCredential(SafeErrorSummary(refused(message)).description)
        }
    }

    // MARK: - The credential kind

    func testACredentialIsKnownByItsKindOnly() {
        XCTAssertEqual(AnthropicAuth.kind(of: signInToken), .accountSignIn)
        XCTAssertEqual(AnthropicAuth.kind(of: pastedKey), .key)
        XCTAssertEqual(AnthropicAuth.CredentialKind.key.reportLabel, "key")
        XCTAssertEqual(AnthropicAuth.CredentialKind.accountSignIn.reportLabel, "account sign-in")
    }

    func testTheKindIsReadBackFromTheHeaderARequestCarries() {
        var request = URLRequest(url: URL(string: "https://api.example.test/v1/messages")!)
        XCTAssertNil(AnthropicAuth.credentialKind(of: request))
        AnthropicAuth.apply(credential: pastedKey, to: &request)
        XCTAssertEqual(AnthropicAuth.credentialKind(of: request), .key)

        var signedIn = URLRequest(url: URL(string: "https://api.example.test/v1/messages")!)
        AnthropicAuth.apply(credential: signInToken, to: &signedIn)
        XCTAssertEqual(AnthropicAuth.credentialKind(of: signedIn), .accountSignIn)
    }

    // MARK: - The recorder and the trace

    private func sealedTurn(_ body: () -> Void) -> TurnTimeline? {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        TurnRecorder.mark(.commit)
        body()
        TurnRecorder.endTurn()
        return sunk.first
    }

    func testAFailedTurnKeepsTheRejectionTheCredentialKindAndTheToolCounts() throws {
        let error = refused("tools.3.custom.input_schema: JSON schema is invalid.")
        let turn = try XCTUnwrap(sealedTurn {
            TurnRecorder.noteBackend(.direct(.anthropic), model: "claude-sonnet-5-5")
            TurnRecorder.noteCredential(AnthropicAuth.kind(of: self.signInToken))
            TurnRecorder.noteToolsSent(count: 43, fromMCP: 2)
            TurnRecorder.noteAbandoned()
            TurnRecorder.noteFailure(error)
        })
        XCTAssertEqual(turn.rejection?.reason, .toolDefinitionInvalid)
        XCTAssertEqual(turn.credential, .accountSignIn)
        XCTAssertEqual(turn.toolsSent, .init(count: 43, fromMCP: 2))

        let trace = TurnTrace(turn, sealedAt: epoch)
        XCTAssertEqual(trace.failure, "clientError(invalid_request_error)#400")
        XCTAssertEqual(trace.rejectionReason, "toolDefinitionInvalid")
        XCTAssertEqual(trace.requestId, "req_011CSHoEeqs5C35K2UUqR7Fy")
        XCTAssertEqual(trace.credential, "accountSignIn")
        XCTAssertEqual(trace.toolsSent, 43)
        XCTAssertEqual(trace.toolsFromMCP, 2)

        let stored = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        assertNoMessageOrCredential(stored)
    }

    func testAFailureThatWasNotARefusalCarriesNoRejection() throws {
        let turn = try XCTUnwrap(sealedTurn { TurnRecorder.noteFailure(URLError(.timedOut)) })
        XCTAssertNil(turn.rejection)
        XCTAssertNil(TurnTrace(turn, sealedAt: epoch).rejectionReason)
    }

    /// A cascade that hops to a provider path which records neither must not leave the previous
    /// attempt's credential kind and tool counts on the turn.
    func testANewAttemptClearsThePreviousAttemptsCredentialAndToolCounts() throws {
        let turn = try XCTUnwrap(sealedTurn {
            TurnRecorder.noteBackend(.direct(.anthropic), model: "claude-sonnet-5-5")
            TurnRecorder.noteCredential(.key)
            TurnRecorder.noteToolsSent(count: 40, fromMCP: 0)
            TurnRecorder.noteBackend(.direct(.openai), model: "another-model")
        })
        XCTAssertNil(turn.credential)
        XCTAssertNil(turn.toolsSent)
    }

    func testATraceWrittenBeforeTheseFieldsStillDecodes() throws {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: epoch)
        timeline.failure = SafeErrorSummary(category: .rateLimited, code: 429)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try encoder.encode(TurnTrace(timeline, sealedAt: epoch))) as? [String: Any])
        for key in ["rejectionReason", "requestId", "credential", "toolsSent", "toolsFromMCP"] {
            object.removeValue(forKey: key)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(TurnTrace.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.failure, "rateLimited#429")
        XCTAssertNil(old.rejectionReason)
        XCTAssertNil(old.credential)
        XCTAssertNil(old.toolsSent)
    }

    // MARK: - The report line

    private func failedTrace(_ error: LLMError, credential: AnthropicAuth.CredentialKind? = nil,
                             tools: TurnTimeline.ToolsSent? = nil) -> TurnTrace {
        var timeline = TurnTimeline(backend: .direct(.anthropic), model: "claude-sonnet-5-5")
        timeline.mark(.commit, at: epoch)
        timeline.abandoned = true
        timeline.failure = SafeErrorSummary(error)
        if case .apiError(_, _, _, let rejection) = error { timeline.rejection = rejection }
        timeline.credential = credential
        timeline.toolsSent = tools
        return TurnTrace(timeline, sealedAt: epoch)
    }

    func testTheFailedTurnLineNamesTheReasonTheCredentialKindTheToolCountsAndTheRequest() {
        let trace = failedTrace(refused("tools.3.custom.input_schema: JSON schema is invalid."),
                                credential: .accountSignIn, tools: .init(count: 43, fromMCP: 2))
        let lines = JobTranscriptExport.render(trace, stamp: "09:30")
        XCTAssertEqual(lines.first,
                       "09:30  · AI turn FAILED — clientError(invalid_request_error)#400"
                           + " · reason: toolDefinitionInvalid · auth: account sign-in"
                           + " · tools sent: 43 (2 from MCP servers)"
                           + " · request: req_011CSHoEeqs5C35K2UUqR7Fy")
    }

    func testAKeyReadsAsAKey() {
        let trace = failedTrace(refused("OAuth authentication is currently not supported.",
                                        status: 401, type: "authentication_error"),
                                credential: .key)
        XCTAssertEqual(JobTranscriptExport.render(trace, stamp: "09:30").first,
                       "09:30  · AI turn FAILED — unauthorized(authentication_error)#401"
                           + " · reason: credentialNotAccepted · auth: key"
                           + " · request: req_011CSHoEeqs5C35K2UUqR7Fy")
    }

    /// A failure with nothing more to say reads exactly as it did before.
    func testAFailureWithNoRejectionKeepsItsOldLine() {
        var timeline = TurnTimeline(backend: .direct(.anthropic), model: "claude-sonnet-5-5")
        timeline.mark(.commit, at: epoch)
        timeline.failure = SafeErrorSummary(category: .rateLimited, code: 429)
        XCTAssertEqual(JobTranscriptExport.render(TurnTrace(timeline, sealedAt: epoch), stamp: "09:30").first,
                       "09:30  · AI turn FAILED — rateLimited#429")
    }

    /// The credential kind and tool counts are on the failed line only; a turn that answered
    /// reads as before.
    func testAnAnsweredTurnsLineIsUnchanged() {
        var timeline = TurnTimeline(backend: .direct(.anthropic), model: "claude-sonnet-5-5")
        timeline.mark(.commit, at: epoch)
        timeline.credential = .key
        timeline.toolsSent = .init(count: 40, fromMCP: 0)
        XCTAssertEqual(JobTranscriptExport.render(TurnTrace(timeline, sealedAt: epoch), stamp: "09:30").first,
                       "09:30  · AI turn answered")
    }

    /// The report is masked before it is shown. The masking pass must leave these labels alone —
    /// it blanks what follows `credential:` and `key:` — and must find nothing to mask, because
    /// no part of a credential was ever on the line.
    func testTheLineSurvivesTheMaskingPassAndCarriesNoCredential() {
        for (kind, credential) in [(AnthropicAuth.CredentialKind.accountSignIn, signInToken), (.key, pastedKey)] {
            let trace = failedTrace(refused("tools.3.custom.input_schema: JSON schema is invalid."),
                                    credential: kind, tools: .init(count: 43, fromMCP: 2))
            let line = JobTranscriptExport.render(trace, stamp: "09:30").joined(separator: "\n")
            let masked = DiagnosticsRedactor.redact(line, extraSecrets: [credential])
            XCTAssertEqual(masked.redacted, line)
            XCTAssertEqual(masked.hits, [])
            XCTAssertTrue(line.contains("auth: \(kind.reportLabel)"))
            assertNoMessageOrCredential(line)
        }
    }

    func testNoFixtureMessageReachesAReportLine() {
        for (_, message) in ProviderRejectionTests.anthropicMessages {
            let trace = failedTrace(refused(message), credential: .accountSignIn,
                                    tools: .init(count: 43, fromMCP: 2))
            assertNoMessageOrCredential(JobTranscriptExport.render(trace, stamp: "09:30").joined(separator: "\n"))
        }
    }

    // MARK: - The banner

    func testTheBannerSaysARefusedRequestWasRefused() {
        XCTAssertEqual(AppState.plainReason("clientError(invalid_request_error)#400"),
                       "the AI service rejected the request")
        XCTAssertEqual(AppState.plainReason("clientError(invalid_request_error)#400", rejection: "messageShape"),
                       "the AI service rejected the request")
        XCTAssertEqual(AppState.plainReason("clientError(http)#400", rejection: "a reason from a newer build"),
                       "the AI service rejected the request")
    }

    func testTheBannerPointsAModelContractRefusalAtAnotherModel() {
        for reason in ProviderRejection.Reason.allCases where reason.isModelContract {
            let words = AppState.plainReason("clientError(invalid_request_error)#400", rejection: reason.rawValue)
            XCTAssertTrue(words.contains("try another model"), "\(reason.rawValue): \(words)")
        }
    }

    func testTheBannerPointsACredentialRefusalAtTheKeyOrTheSignIn() {
        for failure in ["clientError(invalid_request_error)#400", "unauthorized(authentication_error)#401",
                        "forbidden(permission_error)#403"] {
            let words = AppState.plainReason(failure, rejection: "credentialNotAccepted")
            XCTAssertTrue(words.contains("check the key, or sign in again"), "\(failure): \(words)")
        }
        // Without a reason, an auth status reads as it always has.
        XCTAssertEqual(AppState.plainReason("unauthorized(http)#401"), "the AI service refused the key")
        XCTAssertEqual(AppState.plainReason("forbidden(http)#403"), "the AI service refused the key")
    }

    func testEveryReasonGivesTheBannerAPlainSentence() {
        for reason in ProviderRejection.Reason.allCases {
            let words = AppState.plainReason("clientError(invalid_request_error)#400", rejection: reason.rawValue)
            XCTAssertTrue(words.hasPrefix("the AI service"), words)
            XCTAssertFalse(words.contains(reason.rawValue), "the banner never shows the token: \(words)")
        }
    }

    // MARK: - The fallback chain

    func testAReasonThatBelongsToTheCandidateEndsOnlyTheCandidate() throws {
        for reason in ProviderRejection.Reason.allCases {
            let message = try XCTUnwrap(messageByReason[reason], reason.rawValue)
            let error = refused(message)
            guard case .apiError(_, _, _, let carried?) = error else { return XCTFail("no rejection") }
            XCTAssertEqual(carried.reason, reason)
            XCTAssertEqual(ModelFallbackChain.classify(error),
                           reason.endsOnlyThisCandidate ? .terminalForCandidate : .terminalForTurn,
                           reason.rawValue)
        }
    }

    func testTheSameHoldsForA422() {
        let contract = refused(#"tool_choice: type "tool" and "any" are not supported for this model."#, status: 422)
        XCTAssertEqual(ModelFallbackChain.classify(contract), .terminalForCandidate)
        XCTAssertEqual(ModelFallbackChain.classify(refused("messages: roles must alternate", status: 422)),
                       .terminalForTurn)
    }

    /// The reason only ever softens a turn-ending status. Every other status classifies exactly
    /// as it did, whatever the rejection beside it says.
    func testTheReasonChangesNothingForOtherStatuses() {
        let contract = #"tool_choice: type "tool" and "any" are not supported for this model."#
        XCTAssertEqual(ModelFallbackChain.classify(refused(contract, status: 401)), .terminalForCandidate)
        XCTAssertEqual(ModelFallbackChain.classify(refused(contract, status: 403)), .terminalForCandidate)
        XCTAssertEqual(ModelFallbackChain.classify(refused(contract, status: 429)), .retryOtherModel)
        XCTAssertEqual(ModelFallbackChain.classify(refused(contract, status: 500)), .retryOtherModel)
        XCTAssertEqual(ModelFallbackChain.classify(refused(contract, status: 404)), .retryOtherModel)
        XCTAssertEqual(ModelFallbackChain.classify(
            LLMError.apiError(provider: "x", statusCode: 400, message: contract)), .terminalForTurn,
            "a 400 nobody classified still ends the turn")
    }

    /// A context overflow the context budget recognises is settled before the reason is read.
    func testAnOverflowTheBudgetRecognisesStillEndsTheTurn() {
        let envelope = #"{"error":{"code":"context_length_exceeded","message":"too big"}}"#
        let error = LLMError.apiError(provider: "ChatGPT", statusCode: 400, message: envelope,
                                      rejection: ProviderRejection(status: 400, body: Data(envelope.utf8),
                                                                   provider: .chatgpt))
        XCTAssertEqual(ModelFallbackChain.classify(error), .terminalForTurn)
    }

    func testTheCascadeHopsPastAModelThatRefusesTheContractAndStopsOnABadRequest() async throws {
        let candidates = ["a", "b"].map {
            ModelFallbackChain.Candidate(id: $0, isLocalMLX: false, supportsVision: true,
                                         contextTokens: ModelFallbackChain.cloudContextTokens)
        }
        let needs = ModelFallbackChain.TurnNeeds(requiresVision: false, isBackgrounded: false)
        let contract = refused(#"tool_choice: type "tool" and "any" are not supported for this model."#)
        let answer = try await ModelCascade.run(candidates: candidates, needs: needs, maxAttempts: 3) { candidate in
            if candidate.id == "a" { throw contract }
            return "answered by \(candidate.id)"
        }
        XCTAssertEqual(answer, "answered by b")

        let malformed = refused("messages: roles must alternate")
        var attempts = 0
        do {
            _ = try await ModelCascade.run(candidates: candidates, needs: needs, maxAttempts: 3) { _ in
                attempts += 1
                throw malformed
            }
            XCTFail("a malformed request must not be answered")
        } catch {
            XCTAssertEqual(attempts, 1, "a request every model would refuse is sent once")
        }
    }

    // MARK: - The spoken reason

    func testTheSpokenReasonTellsAModelRefusalFromACredentialRefusal() {
        let contract = ModelSwitchNarrator.exhaustionPhrase(
            lastError: refused(#""thinking.type.disabled" is not supported for this model."#))
        XCTAssertTrue(contract.contains("try another model"), contract)
        XCTAssertFalse(contract.contains("credentials"), contract)

        let credential = ModelSwitchNarrator.exhaustionPhrase(
            lastError: refused("OAuth authentication is currently not supported."))
        XCTAssertTrue(credential.contains("key or sign-in"), credential)

        // An auth status with nothing classified reads as it always has.
        XCTAssertTrue(ModelSwitchNarrator.exhaustionPhrase(
            lastError: LLMError.apiError(provider: "x", statusCode: 401, message: nil))
            .contains("working credentials"))
        XCTAssertTrue(ModelSwitchNarrator.exhaustionPhrase(lastError: refused("messages: roles must alternate"))
            .contains("couldn't be processed"))
    }

    func testNoFixtureMessageIsSpoken() {
        for (_, message) in ProviderRejectionTests.anthropicMessages {
            assertNoMessageOrCredential(ModelSwitchNarrator.exhaustionPhrase(lastError: refused(message)))
        }
    }

    // MARK: - The log line every Anthropic site writes

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.example.test/v1/messages")!, statusCode: status,
                        httpVersion: nil, headerFields: headers)!
    }

    private func request(credential: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.test/v1/messages")!)
        AnthropicAuth.apply(credential: credential, to: &request)
        return request
    }

    /// The `apiError` lines written while `body` runs, exactly as the log received them.
    private func apiErrorLines(_ body: () -> Void) -> [String] {
        var lines: [String] = []
        let lock = NSLock()
        let tap = PrivacyLog.addTap { _, line in
            guard line.contains("event=apiError") else { return }
            lock.lock(); lines.append(line); lock.unlock()
        }
        defer { PrivacyLog.removeTap(tap) }
        body()
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func testARefusalIsLoggedWithItsClassifiedFieldsAndNothingElse() {
        let body = ProviderRejectionTests.anthropicBody(
            "invalid_request_error", "tools.3.custom.input_schema: JSON schema is invalid.", requestID: nil)
        var returned: ProviderRejection?
        let lines = apiErrorLines {
            returned = LLMService.noteAnthropicRejection(
                response: self.response(400, headers: ["request-id": "req_fromHeader42"]), body: body,
                request: self.request(credential: self.signInToken), detail: "analyzeFrameStructured")
        }
        XCTAssertEqual(returned?.reason, .toolDefinitionInvalid)
        XCTAssertEqual(lines, [
            "[model] model event=apiError provider=anthropic status=400 bytes=\(body.count)"
                + " detail=analyzeFrameStructured reason=toolDefinitionInvalid auth=accountSignIn"
                + " request=req_fromHeader42 error=clientError(invalid_request_error)#400",
        ])
        assertNoMessageOrCredential(lines.joined())
    }

    /// The branch that used to throw without a line: a non-200 whose body is not an envelope.
    func testARefusalWithNoReadableBodyIsStillLogged() {
        let lines = apiErrorLines {
            LLMService.noteAnthropicRejection(response: self.response(400), body: Data(),
                                              request: self.request(credential: self.pastedKey))
        }
        XCTAssertEqual(lines, [
            "[model] model event=apiError provider=anthropic status=400 bytes=0"
                + " reason=other auth=key error=clientError(http)#400",
        ])
        assertNoMessageOrCredential(lines.joined())
    }

    func testAnAnswerIsNotLoggedAsARefusal() {
        var returned: ProviderRejection?
        let lines = apiErrorLines {
            returned = LLMService.noteAnthropicRejection(response: self.response(200), body: Data("{}".utf8),
                                                         request: self.request(credential: self.pastedKey))
        }
        XCTAssertNil(returned)
        XCTAssertEqual(lines, [])
    }

    /// The same lines are what the diagnostics ring keeps and the support report prints, and the
    /// report masks them first. Nothing on them may be mistaken for a secret.
    func testTheLoggedLineSurvivesTheMaskingPass() {
        for (_, message) in ProviderRejectionTests.anthropicMessages {
            let body = ProviderRejectionTests.anthropicBody("invalid_request_error", message)
            for credential in [signInToken, pastedKey] {
                let lines = apiErrorLines {
                    LLMService.noteAnthropicRejection(response: self.response(400), body: body,
                                                      request: self.request(credential: credential))
                }
                XCTAssertEqual(lines.count, 1)
                let masked = DiagnosticsRedactor.redact(lines.joined(), extraSecrets: [credential])
                XCTAssertEqual(masked.redacted, lines.joined())
                XCTAssertEqual(masked.hits, [])
                assertNoMessageOrCredential(lines.joined())
            }
        }
    }
}
