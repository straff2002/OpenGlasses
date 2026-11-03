import XCTest
@testable import OpenGlasses

/// Plan KL P0 — a model with no working sign-in or key is said by service name, once per process,
/// and shown on the status card. The User A report (build 615): ChatGPT chosen, never signed in,
/// "ChatGPT (Subscription) is unavailable" before every answer and "I don't have working
/// credentials for them" on the photo turn.
final class CredentialGapTests: XCTestCase {

    private func model(_ provider: LLMProvider, key: String = "") -> ModelConfig {
        ModelConfig(id: provider.rawValue, name: "Saved \(provider.rawValue)", provider: provider.rawValue,
                    apiKey: key, model: provider.defaultModel, baseURL: provider.defaultBaseURL)
    }

    private let notConnected = LLMError.missingAPIKey(
        "ChatGPT account not connected — sign in with ChatGPT in the model editor")

    private func status(_ code: Int, rejection: ProviderRejection? = nil) -> LLMError {
        .apiError(provider: "x", statusCode: code, message: nil, rejection: rejection)
    }

    private var credentialRejection: ProviderRejection {
        ProviderRejection(status: 401, body: ProviderRejectionTests.openAIBody(
            message: "Incorrect API key provided.", code: "invalid_api_key"), provider: .groq)
    }

    private var contractRejection: ProviderRejection {
        ProviderRejection(status: 400, body: ProviderRejectionTests.anthropicBody(
            "invalid_request_error", #""thinking.type.disabled" is not supported for this model."#),
                          provider: .anthropic)
    }

    private var modelNotAvailableRejection: ProviderRejection {
        ProviderRejection(status: 403, body: ProviderRejectionTests.openAIBody(
            message: "The model `gpt-9-imaginary` does not exist.", code: "model_not_found"),
                          provider: .openai)
    }

    // MARK: - Classification

    func testFixturesClassifyAsTheyClaim() {
        XCTAssertEqual(credentialRejection.reason, .credentialNotAccepted)
        XCTAssertTrue(contractRejection.reason.isModelContract)
        XCTAssertEqual(modelNotAvailableRejection.reason, .modelNotAvailable)
    }

    func testAMissingCredentialIsMissingAndNamesWhatToFix() {
        let cases: [(LLMProvider, String, CredentialGap.Credential)] = [
            (.chatgpt, "", .account), (.geminiVertex, "", .account),
            (.anthropic, "", .account), (.xai, "", .account),
            (.anthropic, "sk-test", .key), (.xai, "xai-test", .key),
            (.openai, "", .key), (.gemini, "", .key), (.groq, "", .key), (.deepseek, "", .key),
            (.mistral, "", .key), (.zai, "", .key), (.qwen, "", .key), (.minimax, "", .key),
            (.openrouter, "", .key), (.custom, "", .key),
        ]
        for (provider, key, credential) in cases {
            XCTAssertEqual(CredentialGap.classify(LLMError.missingAPIKey("no"), model: model(provider, key: key)),
                           CredentialGap(provider: provider, kind: .missing, credential: credential),
                           "\(provider) key=\(!key.isEmpty)")
        }
    }

    func testARefusedCredentialIsRefused() {
        let groq = model(.groq, key: "gsk-test")
        XCTAssertEqual(CredentialGap.classify(status(401, rejection: credentialRejection), model: groq),
                       CredentialGap(provider: .groq, kind: .refused, credential: .key))
        // An auth status the classifier could not name is the service refusing the caller.
        XCTAssertEqual(CredentialGap.classify(status(401), model: groq)?.kind, .refused)
        XCTAssertEqual(CredentialGap.classify(status(403), model: groq)?.kind, .refused)
        XCTAssertEqual(CredentialGap.classify(status(401), model: model(.chatgpt)),
                       CredentialGap(provider: .chatgpt, kind: .refused, credential: .account))
    }

    func testWhatIsNotACredentialHasNoGap() {
        let claude = model(.anthropic, key: "sk-test")
        XCTAssertNil(CredentialGap.classify(status(400, rejection: contractRejection), model: claude),
                     "a model-contract refusal is the model, not the key")
        XCTAssertNil(CredentialGap.classify(status(403, rejection: modelNotAvailableRejection), model: claude),
                     "a model the service will not serve is not the key")
        XCTAssertNil(CredentialGap.classify(LLMError.modelDeclined(provider: "Anthropic"), model: claude))
        XCTAssertNil(CredentialGap.classify(status(429), model: claude))
        XCTAssertNil(CredentialGap.classify(status(500), model: claude))
        XCTAssertNil(CredentialGap.classify(LLMError.invalidResponse("x"), model: claude))
        XCTAssertNil(CredentialGap.classify(nil, model: claude), "the capability pre-switch threw nothing")
        XCTAssertNil(CredentialGap.classify(notConnected, model: nil))
    }

    func testOnDeviceModelsNeverHaveAGap() {
        for provider in [LLMProvider.local, .appleOnDevice] {
            XCTAssertNil(CredentialGap.classify(LLMError.missingAPIKey("Apple Intelligence unavailable"),
                                                model: model(provider)))
            XCTAssertNil(CredentialGap.classify(status(401), model: model(provider)))
        }
    }

    func testAWhitespaceKeyIsNoKey() {
        XCTAssertEqual(CredentialGap.classify(notConnected, model: model(.anthropic, key: "  \n"))?.credential,
                       .account)
    }

    func testServiceNamesAreTheServicesNotThePickerLabels() {
        let expected: [LLMProvider: String] = [
            .chatgpt: "ChatGPT", .anthropic: "Claude", .openai: "OpenAI", .gemini: "Gemini",
            .geminiVertex: "Gemini", .groq: "Groq", .deepseek: "DeepSeek", .mistral: "Mistral",
            .zai: "Z.ai", .qwen: "Qwen", .minimax: "MiniMax", .xai: "xAI", .openrouter: "OpenRouter",
            .custom: "your custom server",
        ]
        for (provider, name) in expected {
            XCTAssertEqual(provider.serviceName, name)
        }
        XCTAssertNotEqual(LLMProvider.chatgpt.serviceName, LLMProvider.chatgpt.displayName)
    }

    // MARK: - The hop's line

    private let chatGPTModel = ModelSwitchNarrator.Model(name: "ChatGPT (Subscription)", isLocal: false)
    private let apple = ModelSwitchNarrator.Model(name: "Apple Intelligence", isLocal: false, isOnDevice: true)
    private let gemini = ModelSwitchNarrator.Model(name: "Gemini Flash", isLocal: false)

    func testTheHopLineNamesTheServiceAndTheFix() {
        let cases: [(CredentialGap, ModelSwitchNarrator.Model, String)] = [
            (.init(provider: .chatgpt, kind: .missing, credential: .account), apple,
             "You're not signed in to ChatGPT, so I'm answering on this phone."),
            (.init(provider: .groq, kind: .missing, credential: .key), apple,
             "There's no working key for Groq, so I'm answering on this phone."),
            (.init(provider: .chatgpt, kind: .refused, credential: .account), apple,
             "ChatGPT didn't accept the sign-in, so I'm answering on this phone."),
            (.init(provider: .groq, kind: .refused, credential: .key), apple,
             "Groq didn't accept the key, so I'm answering on this phone."),
            (.init(provider: .chatgpt, kind: .missing, credential: .account), gemini,
             "You're not signed in to ChatGPT, so I'm using Gemini Flash."),
            (.init(provider: .groq, kind: .refused, credential: .key), gemini,
             "Groq didn't accept the key, so I'm using Gemini Flash."),
            (.init(provider: .custom, kind: .refused, credential: .key), gemini,
             "Your custom server didn't accept the key, so I'm using Gemini Flash."),
        ]
        for (gap, to, line) in cases {
            let phrase = ModelSwitchNarrator.fallbackPhrase(from: chatGPTModel, to: to,
                                                            failure: .terminalForCandidate, gap: gap)
            XCTAssertEqual(phrase, line)
            XCTAssertFalse(phrase.contains("unavailable"), "a setting is never called an outage")
        }
    }

    func testTheMLXModelIsOnDeviceByDefault() {
        let mlx = ModelSwitchNarrator.Model(name: "Gemma", isLocal: true)
        XCTAssertTrue(mlx.isOnDevice)
        XCTAssertEqual(ModelSwitchNarrator.fallbackPhrase(
            from: chatGPTModel, to: mlx, failure: .terminalForCandidate,
            gap: .init(provider: .chatgpt, kind: .missing, credential: .account)),
                       "You're not signed in to ChatGPT, so I'm answering on this phone.")
    }

    func testEveryLineWithoutAGapIsUnchanged() {
        let local = ModelSwitchNarrator.Model(name: "Qwen 0.5B", isLocal: true)
        let claude = ModelSwitchNarrator.Model(name: "Claude", isLocal: false)
        let cases: [(ModelSwitchNarrator.Model, ModelSwitchNarrator.Model, ModelFallbackChain.FailureClass, String)] = [
            (claude, apple, .visionUnavailable, "Claude can't analyze photos — using Apple Intelligence for this picture."),
            (local, claude, .needsBiggerWindow, "That's a bit much for the on-device model — switching to Claude."),
            (claude, gemini, .needsBiggerWindow, "That's too long for Claude — switching to Gemini Flash."),
            (local, claude, .retryOtherModel, "The on-device model couldn't handle that — switching to Claude."),
            (claude, gemini, .retryOtherModel, "Claude is unavailable — switching to Gemini Flash."),
            (chatGPTModel, apple, .terminalForCandidate,
             "ChatGPT (Subscription) is unavailable — switching to Apple Intelligence."),
            (claude, gemini, .terminalForTurn, "Switching to Gemini Flash."),
        ]
        for (from, to, failure, line) in cases {
            XCTAssertEqual(ModelSwitchNarrator.fallbackPhrase(from: from, to: to, failure: failure), line)
        }
    }

    // MARK: - Exhaustion

    func testTheExhaustionLineNamesTheService() {
        let gap = CredentialGap(provider: .chatgpt, kind: .missing, credential: .account)
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: notConnected, gap: gap),
                       "I couldn't get a response — you're not signed in to ChatGPT.")
        XCTAssertEqual(SpokenErrorPolicy.photoFailureLine(for: notConnected, photoCaptured: true,
                                                          narrateModelFailures: true, gap: gap),
                       "I took the photo, but couldn't get an answer about it — you're not signed in to ChatGPT.")
        let refused = CredentialGap(provider: .groq, kind: .refused, credential: .key)
        XCTAssertEqual(ModelSwitchNarrator.exhaustionReason(lastError: status(401), gap: refused),
                       "Groq didn't accept the key")
        XCTAssertEqual(ModelSwitchNarrator.exhaustionReason(
            lastError: LLMError.missingAPIKey("no"), gap: .init(provider: .groq, kind: .missing, credential: .key)),
                       "there's no working key for Groq")
    }

    func testTheExhaustionLineWithoutAGapIsUnchanged() {
        XCTAssertEqual(SpokenErrorPolicy.photoFailureLine(for: notConnected, photoCaptured: true,
                                                          narrateModelFailures: true),
                       "I took the photo, but couldn't get an answer about it — I don't have working credentials for them.")
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: notConnected),
                       "I couldn't get a response — I don't have working credentials for them.")
    }

    func testAGapThatDoesNotMatchTheErrorIsIgnored() {
        let gap = CredentialGap(provider: .chatgpt, kind: .missing, credential: .account)
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: status(429), gap: gap),
                       "I couldn't get a response — the last one was rate-limited.")
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: status(401), gap: gap),
                       "I couldn't get a response — I don't have working credentials for them.",
                       "a missing gap does not explain a refusal")
    }

    // MARK: - Said once per process

    func testTheLatchSaysAGapOnceUntilTheCredentialChanges() {
        var latch = CredentialNoticeLatch()
        let gap = CredentialGap(provider: .chatgpt, kind: .missing, credential: .account)
        let signedOut = CredentialNoticeLatch.Fingerprint(accountConnected: false, hasKey: false)
        let signedIn = CredentialNoticeLatch.Fingerprint(accountConnected: true, hasKey: false)
        XCTAssertTrue(latch.shouldNarrate(gap, fingerprint: signedOut), "first said")
        XCTAssertFalse(latch.shouldNarrate(gap, fingerprint: signedOut), "silent while unchanged")
        XCTAssertFalse(latch.shouldNarrate(gap, fingerprint: signedOut))
        XCTAssertTrue(latch.shouldNarrate(gap, fingerprint: signedIn), "said again once signed in")
        XCTAssertTrue(latch.shouldNarrate(gap, fingerprint: signedOut), "and again once signed out")
        XCTAssertFalse(latch.shouldNarrate(gap, fingerprint: signedOut))
    }

    func testTheLatchIsPerService() {
        var latch = CredentialNoticeLatch()
        let none = CredentialNoticeLatch.Fingerprint(accountConnected: false, hasKey: false)
        XCTAssertTrue(latch.shouldNarrate(.init(provider: .chatgpt, kind: .missing, credential: .account),
                                          fingerprint: none))
        XCTAssertTrue(latch.shouldNarrate(.init(provider: .groq, kind: .missing, credential: .key),
                                          fingerprint: none), "another service is its own notice")
        XCTAssertFalse(latch.shouldNarrate(.init(provider: .groq, kind: .missing, credential: .key),
                                           fingerprint: none))
        // A key added and then refused is a change of state, said once more.
        XCTAssertTrue(latch.shouldNarrate(.init(provider: .groq, kind: .refused, credential: .key),
                                          fingerprint: .init(accountConnected: false, hasKey: true)))
        // So is a refused key replaced by another.
        let refused = CredentialGap(provider: .groq, kind: .refused, credential: .key)
        XCTAssertFalse(latch.shouldNarrate(refused, fingerprint: .init(accountConnected: false, hasKey: true)))
        XCTAssertTrue(latch.shouldNarrate(refused, fingerprint: .init(accountConnected: false, hasKey: true,
                                                                      keyDigest: 42)))
    }

    func testTheFingerprintReadsTheProvidersOwnAccount() {
        func connected(_ provider: LLMProvider, claude: Bool = false, chatgpt: Bool = false,
                   google: Bool = false, xai: Bool = false) -> Bool {
            CredentialNoticeLatch.Fingerprint(provider: provider, hasKey: false, claudeConnected: claude,
                                              chatgptConnected: chatgpt, googleConnected: google,
                                              xaiConnected: xai).accountConnected
        }
        XCTAssertTrue(connected(.chatgpt, chatgpt: true))
        XCTAssertFalse(connected(.chatgpt, claude: true, google: true, xai: true))
        XCTAssertTrue(connected(.anthropic, claude: true))
        XCTAssertTrue(connected(.geminiVertex, google: true))
        XCTAssertTrue(connected(.xai, xai: true))
        XCTAssertFalse(connected(.groq, claude: true, chatgpt: true, google: true, xai: true))
    }

    // MARK: - The status card's row

    private func prompt(_ model: ModelConfig?, claude: Bool = false, chatgpt: Bool = false,
                        google: Bool = false, xai: Bool = false) -> CredentialSignInPrompt? {
        CredentialSignInPrompt.resolve(model: model, claudeConnected: claude, chatgptConnected: chatgpt,
                                       googleConnected: google, xaiConnected: xai)
    }

    func testTheRowAsksForWhatIsMissing() {
        XCTAssertEqual(prompt(model(.chatgpt))?.title, "Sign in to ChatGPT")
        XCTAssertNil(prompt(model(.chatgpt), chatgpt: true))
        XCTAssertEqual(prompt(model(.geminiVertex))?.title, "Sign in to Gemini")
        XCTAssertNil(prompt(model(.geminiVertex), google: true))
        XCTAssertEqual(prompt(model(.anthropic))?.title, "Sign in to Claude")
        XCTAssertNil(prompt(model(.anthropic), claude: true))
        XCTAssertNil(prompt(model(.anthropic, key: "sk-test")))
        XCTAssertEqual(prompt(model(.xai))?.title, "Sign in to xAI")
        XCTAssertNil(prompt(model(.xai), xai: true))
        XCTAssertNil(prompt(model(.xai, key: "xai-test")))
        for provider in [LLMProvider.openai, .gemini, .groq, .deepseek, .mistral, .zai, .qwen,
                         .minimax, .openrouter] {
            XCTAssertEqual(prompt(model(provider))?.title, "Add a key for \(provider.serviceName)")
            XCTAssertNil(prompt(model(provider, key: "test")))
            XCTAssertNil(prompt(model(provider, key: "test"), claude: true, chatgpt: true))
        }
        XCTAssertEqual(prompt(model(.groq))?.credential, .key)
        XCTAssertEqual(prompt(model(.chatgpt))?.credential, .account)
    }

    func testTheRowShowsNothingForAReadyOrKeyOptionalModel() {
        XCTAssertNil(prompt(model(.custom)), "a custom server's key is optional")
        XCTAssertNil(prompt(model(.local)))
        XCTAssertNil(prompt(model(.appleOnDevice)))
        XCTAssertNil(prompt(nil))
        // Another account being connected does not stand in for this one.
        XCTAssertNotNil(prompt(model(.chatgpt), claude: true, google: true, xai: true))
    }

    // MARK: - The hop carries the error

    private func cloud(_ id: String, vision: Bool = true) -> ModelFallbackChain.Candidate {
        .init(id: id, isLocalMLX: false, supportsVision: vision, contextTokens: ModelFallbackChain.cloudContextTokens)
    }

    func testTheCascadeHandsEachHopTheErrorThatCausedIt() async throws {
        var hops: [(String, String?)] = []
        let out = try await ModelCascade.run(
            candidates: [cloud("a"), cloud("b"), cloud("c")],
            needs: .init(requiresVision: false, isBackgrounded: false),
            maxAttempts: 4,
            onSwitch: { from, _, _, error in
                hops.append((from.id, error.map { String(describing: $0) }))
            },
            attempt: { c in
                switch c.id {
                case "a": throw LLMError.missingAPIKey("no key for a")
                case "b": throw LLMError.apiError(provider: "b", statusCode: 429, message: nil)
                default: return "ok"
                }
            })
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(hops.map(\.0), ["a", "b"])
        XCTAssertEqual(hops[0].1, String(describing: LLMError.missingAPIKey("no key for a")))
        XCTAssertEqual(hops[1].1, String(describing: LLMError.apiError(provider: "b", statusCode: 429, message: nil)))
    }

    func testTheVisionPreSwitchCarriesNoError() async throws {
        var errors: [String?] = []
        var failures: [ModelFallbackChain.FailureClass] = []
        _ = try await ModelCascade.run(
            candidates: [cloud("text", vision: false), cloud("sees", vision: true)],
            needs: .init(requiresVision: true, isBackgrounded: false),
            maxAttempts: 4,
            onSwitch: { _, _, failure, error in
                failures.append(failure)
                errors.append(error.map { String(describing: $0) })
            },
            attempt: { _ in "ok" })
        XCTAssertEqual(failures, [.visionUnavailable])
        XCTAssertEqual(errors, [nil])
    }
}
