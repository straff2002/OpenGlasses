import XCTest
@testable import OpenGlasses

/// Plan KL P1 — a request fitted to the account's tokens-a-minute allowance. A free Groq key
/// allows about 8,000 tokens a minute and refused every ~11,000-token turn with 413
/// `rate_limit_exceeded` (support reports, builds 581 and 615); the app's advice, Small context,
/// removed the tools the question needed.
@MainActor
final class PerMinuteFitTests: XCTestCase {

    // MARK: - Fixtures

    /// Groq's sentence, as the reports describe it: the model, the organisation and the tier, then
    /// the two figures. The organisation id is shaped to tempt the parser.
    nonisolated static let groqMessage = "Request too large for model `qwen/qwen3.8-27b` in organization `org_01limit77requested42` "
        + "service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested 11234, please reduce "
        + "your message size and try again. Need more tokens? Upgrade to Dev Tier today."

    nonisolated static func groqRefusal(_ message: String = groqMessage) -> ProviderRejection {
        ProviderRejection(status: 413, body: ProviderRejectionTests.openAIBody(
            message: message, type: "tokens", code: "rate_limit_exceeded"), provider: .groq)
    }

    nonisolated static func refusedError(_ rejection: ProviderRejection = groqRefusal()) -> LLMError {
        .apiError(provider: LLMProvider.groq.displayName, statusCode: 413, message: nil, rejection: rejection)
    }

    /// One line of the on-demand guide: "- name: first sentence…", up to 110 characters of summary
    /// (`SystemPromptBuilder.summaryLimit`). 120 bytes is the average the fixtures assume.
    static let guideLineBytes = 120

    /// User B, build 615: `requestSent bytes=44317` at `toolExposure detail=core count=36`, with
    /// 18,814 characters of instructions — the on-demand guide for the 70 tools outside the core
    /// among them. The turn was the day's first, so the history is little more than the question.
    static let report615 = PerMinuteFit.Request(instructionBytes: 18_814, toolBytes: 24_003,
                                                historyBytes: 1_200, outputCap: 1_024)
    /// Build 581 (2026-10-29): about 43 KB and 11k tokens on the same allowance, a few turns into
    /// the conversation, so more history and slightly less of everything else.
    static let report581 = PerMinuteFit.Request(instructionBytes: 17_900, toolBytes: 21_600,
                                                historyBytes: 3_200, outputCap: 1_024)

    /// The ladder `LLMService.fitToPerMinuteAllowance` builds for a report-sized request:
    /// - rung 2 declares `lookup_tools` alone (~700 bytes) and lists the 36 core tools in the guide;
    /// - rung 3 swaps the instructions for the condensed ones (`AppleOnDeviceInstructions`'s 4,800
    ///   characters) plus the guide for all 106 tools;
    /// - rung 4 keeps two exchanges of history and halves the output cap.
    static func ladder(for request: PerMinuteFit.Request) -> PerMinuteFit.Ladder {
        let lookupTool = 700
        let guideAllTools = 450 + 106 * guideLineBytes
        let condensed = AppleOnDeviceInstructions.characterBudget + 2 + guideAllTools
        return PerMinuteFit.Ladder(
            asSent: request,
            onDemandTools: .init(instructionBytes: request.instructionBytes + 36 * guideLineBytes,
                                 toolBytes: lookupTool, historyBytes: request.historyBytes,
                                 outputCap: request.outputCap),
            condensedInstructions: .init(instructionBytes: condensed, toolBytes: lookupTool,
                                         historyBytes: request.historyBytes, outputCap: request.outputCap),
            shortHistory: .init(instructionBytes: condensed, toolBytes: lookupTool, historyBytes: 400,
                                outputCap: PerMinuteFit.shortenedOutputCap(request.outputCap)))
    }

    static func allowance(_ limit: Int, calibration: Double? = nil) -> PerMinuteAllowance {
        PerMinuteAllowance(limit: limit, calibration: calibration, fingerprint: "f")
    }

    // MARK: - Reading the figures

    func testAGroqRefusalCarriesItsAllowanceAndRequestedCount() {
        let rejection = Self.groqRefusal()
        XCTAssertEqual(rejection.reason, .requestOverTokenRateLimit)
        XCTAssertEqual(rejection.limit, 8_000)
        XCTAssertEqual(rejection.requested, 11_234)
        // The existing short fixture too.
        let short = ProviderRejection(status: 413, body: ProviderRejectionTests.groqOverLimitBody, provider: .groq)
        XCTAssertEqual(short.limit, 8_000)
        XCTAssertEqual(short.requested, 11_234)
    }

    func testARefusalWithoutFiguresHasNone() {
        let rejection = Self.groqRefusal("Request too large on tokens per minute (TPM).")
        XCTAssertEqual(rejection.reason, .requestOverTokenRateLimit)
        XCTAssertNil(rejection.limit)
        XCTAssertNil(rejection.requested)
        // One figure without the other.
        let limitOnly = Self.groqRefusal("Request too large on tokens per minute (TPM): Limit 6000.")
        XCTAssertEqual(limitOnly.limit, 6_000)
        XCTAssertNil(limitOnly.requested)
    }

    func testOnlyAPerMinuteRefusalIsReadForFigures() {
        // The same words under another reason, another status or another provider family's shape.
        let context = ProviderRejection(status: 400, body: ProviderRejectionTests.openAIBody(
            message: "prompt is too long: limit 8000, requested 11234"), provider: .custom)
        XCTAssertEqual(context.reason, .contextTooLong)
        XCTAssertNil(context.limit)
        XCTAssertNil(context.requested)
        let busy = ProviderRejection(status: 429, body: ProviderRejectionTests.openAIBody(
            message: Self.groqMessage, type: "tokens", code: "rate_limit_exceeded"), provider: .groq)
        XCTAssertEqual(busy.reason, .other)
        XCTAssertNil(busy.limit)
        let anthropic = ProviderRejectionTests.anthropic("Limit 8000, Requested 11234")
        XCTAssertNil(anthropic.limit)
        XCTAssertNil(anthropic.requested)
    }

    func testAFigureInsideAnIdentifierIsNotRead() {
        XCTAssertEqual(ProviderRejection.perMinuteFigures(in: "org_limit77 requested_42").limit, nil)
        XCTAssertEqual(ProviderRejection.perMinuteFigures(in: "model `limit-8b` limit 9000").limit, 9_000)
        XCTAssertEqual(ProviderRejection.perMinuteFigures(in: "Limit 8000b, Limit 7000").limit, 7_000)
        XCTAssertNil(ProviderRejection.perMinuteFigures(in: "limit 0").limit)
        XCTAssertNil(ProviderRejection.perMinuteFigures(in: "limit 12345678901").limit)
        XCTAssertNil(ProviderRejection.perMinuteFigures(in: nil).limit)
    }

    /// The organisation id and the model in Groq's sentence go nowhere: not into the rejection,
    /// not into the stream-error line, not into the turn trace.
    func testTheOrganisationAndModelAreNeverKept() {
        let rejection = Self.groqRefusal()
        let line = PrivacyEventEncoder.encode(PrivacyLog.model(
            .streamError, provider: PrivacyToken("groq"), status: 413, bytes: 385,
            limit: rejection.limit, requested: rejection.requested))
        XCTAssertTrue(line.contains("limit=8000"), line)
        XCTAssertTrue(line.contains("requested=11234"), line)
        var timeline = TurnTimeline()
        timeline.failure = SafeErrorSummary(Self.refusedError(rejection))
        timeline.rejection = rejection
        let trace = TurnTrace(timeline, sealedAt: Date())
        XCTAssertEqual(trace.allowanceLimit, 8_000)
        XCTAssertEqual(trace.allowanceRequested, 11_234)
        let emitted = [line, String(describing: rejection), rejection.summary.description,
                       String(decoding: (try? JSONEncoder().encode(trace)) ?? Data(), as: UTF8.self)]
            .joined(separator: "\n").lowercased()
        for fragment in ["org_", "qwen", "on_demand", "upgrade", PrivacyCanary.stem.lowercased()] {
            XCTAssertFalse(emitted.contains(fragment), "\(fragment) reached an output: \(emitted)")
        }
    }

    // MARK: - The rung table

    /// Both reports' requests against an 8,000-token allowance. Uncalibrated, the on-demand tools
    /// alone leave each a few hundred tokens over the 7,200 ceiling, so both take the condensed
    /// instructions. Build 615's report did not keep Groq's count; with a count like build 581's
    /// (11,234) against this request's estimate of 12,103, the calibration (0.93) lets the second
    /// rung fit.
    func testTheReportsRequestsAgainstAnEightThousandAllowance() {
        XCTAssertEqual(PerMinuteFit.estimatedTokens(Self.report615), 12_103,
                       "44,317 bytes at four a token, plus the 1,024-token cap")
        XCTAssertEqual(Self.report615.bodyBytes, 44_317)
        XCTAssertEqual(Self.report581.bodyBytes, 43_000)

        let uncalibrated = Self.allowance(8_000)
        let first = PerMinuteFit.choose(Self.ladder(for: Self.report615), allowance: uncalibrated)
        XCTAssertEqual(first.rung, .condensedInstructions)
        XCTAssertEqual(first.ceiling, 7_200)
        XCTAssertLessThanOrEqual(first.estimate, first.ceiling)
        XCTAssertEqual(PerMinuteFit.choose(Self.ladder(for: Self.report581), allowance: uncalibrated).rung,
                       .condensedInstructions)

        let calibrated = PerMinuteAllowance.learned(
            limit: 8_000, requested: 11_234, estimate: PerMinuteFit.estimatedTokens(Self.report615),
            previous: nil, fingerprint: "f")
        XCTAssertEqual(calibrated.calibration ?? 0, 11_234.0 / 12_103.0, accuracy: 0.0001)
        XCTAssertEqual(PerMinuteFit.choose(Self.ladder(for: Self.report615), allowance: calibrated).rung,
                       .onDemandTools)
    }

    func testATighterAllowanceReachesTheShortHistoryAndThenNothing() {
        XCTAssertEqual(PerMinuteFit.choose(Self.ladder(for: Self.report615), allowance: Self.allowance(6_000)).rung,
                       .shortHistory)
        let none = PerMinuteFit.choose(Self.ladder(for: Self.report615), allowance: Self.allowance(4_000))
        XCTAssertEqual(none.rung, .nothingFits)
        XCTAssertEqual(none.estimate,
                       PerMinuteFit.estimatedTokens(Self.ladder(for: Self.report615).shortHistory!),
                       "the smallest rung is what the turn needed")
    }

    func testARequestThatFitsIsSentAsItIs() {
        let small = PerMinuteFit.Request(instructionBytes: 8_000, toolBytes: 6_000, historyBytes: 1_000, outputCap: 1_024)
        XCTAssertEqual(PerMinuteFit.choose(Self.ladder(for: small), allowance: Self.allowance(8_000)).rung, .asSent)
    }

    /// With the lookup tool missing, or every definition pinned to every request, rungs 2–4 are
    /// not built: the request is sent as it is or not at all, never with tools taken away.
    func testWithoutTheOnDemandRungsTheChoiceIsAsSentOrNothing() {
        let ladder = PerMinuteFit.Ladder(asSent: Self.report615)
        XCTAssertEqual(PerMinuteFit.choose(ladder, allowance: Self.allowance(8_000)).rung, .nothingFits)
        XCTAssertEqual(PerMinuteFit.choose(ladder, allowance: Self.allowance(20_000)).rung, .asSent)
    }

    func testTheOutputCapCountsAndTheShortRungHalvesIt() {
        let request = PerMinuteFit.Request(instructionBytes: 400, toolBytes: 0, historyBytes: 0, outputCap: 4_096)
        XCTAssertEqual(PerMinuteFit.estimatedTokens(request), 175 + 4_096)
        XCTAssertEqual(PerMinuteFit.shortenedOutputCap(4_096), 2_048)
        XCTAssertEqual(PerMinuteFit.shortenedOutputCap(1_024), 512)
        XCTAssertEqual(PerMinuteFit.shortenedOutputCap(600), 512)
    }

    func testTheShortHistoryKeepsThisTurnWholeAndTwoExchangesBefore() {
        var history: [[String: Any]] = []
        for i in 0..<5 {
            history.append(["role": "user", "content": "question \(i)"])
            history.append(["role": "assistant", "content": "", "tool_calls": [["id": "c\(i)"]]])
            history.append(["role": "tool", "tool_call_id": "c\(i)", "content": "result \(i)"])
            history.append(["role": "assistant", "content": "answer \(i)"])
        }
        let turnStart = history.count
        history.append(["role": "user", "content": "now"])
        history.append(["role": "assistant", "content": "", "tool_calls": [["id": "now"]]])
        history.append(["role": "tool", "tool_call_id": "now", "content": "fresh"])
        let short = PerMinuteFit.shortHistory(history, turnStart: turnStart)
        let texts = short.map { $0["content"] as? String ?? "" }
        XCTAssertEqual(Array(texts.prefix(4)), ["question 3", "answer 3", "question 4", "answer 4"])
        XCTAssertEqual(short.count, 7)
        XCTAssertEqual(short.last?["tool_call_id"] as? String, "now", "the turn's own tool exchange stays whole")
    }

    func testTheEmptiedCoreDeclaresOnlyWhatTheConversationUsed() {
        let decision = ToolExposurePolicy.decide(mode: .automatic, available: ["calendar", "reminder", "get_weather", "brain"],
                                                 fullSetBytes: 100_000, contextWindow: 131_072,
                                                 core: ["calendar", "reminder", "get_weather"], remembered: ["brain"])
        XCTAssertEqual(decision.declared, ["calendar", "reminder", "get_weather", "brain"])
        let emptied = ToolExposurePolicy.emptyingCore(decision, remembered: ["brain", "not_available"])
        XCTAssertEqual(emptied.exposure, .core)
        XCTAssertEqual(emptied.reason, .perMinuteAllowance)
        XCTAssertEqual(emptied.declared, ["brain"])
        XCTAssertEqual(emptied.available, decision.available, "nothing is dropped: every tool stays one lookup away")
    }

    // MARK: - The learned allowance

    private func store(_ suite: String = #function) -> (PerMinuteAllowanceStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "PerMinuteFitTests.\(suite)")!
        defaults.removePersistentDomain(forName: "PerMinuteFitTests.\(suite)")
        return (PerMinuteAllowanceStore(defaults: defaults), defaults)
    }

    private func groq(key: String = "gsk_first", model: String = "qwen/qwen3.8-27b",
                      provider: LLMProvider = .groq) -> ModelConfig {
        ModelConfig(id: "saved-groq", name: "Groq free", provider: provider.rawValue, apiKey: key,
                    model: model, baseURL: provider.defaultBaseURL)
    }

    func testAnAllowanceIsKeptAcrossLaunches() {
        let (first, defaults) = store()
        first.record(limit: 8_000, requested: 11_234, estimate: 12_103, for: groq())
        let relaunched = PerMinuteAllowanceStore(defaults: defaults)
        let kept = relaunched.allowance(for: groq())
        XCTAssertEqual(kept?.limit, 8_000)
        XCTAssertEqual(kept?.calibration ?? 0, 11_234.0 / 12_103.0, accuracy: 0.0001)
    }

    func testAChangedProviderModelOrEndpointClearsItOnRead() {
        let (store, defaults) = store()
        var endpoint = groq()
        endpoint.baseURL = "https://proxy.example.test/v1"
        for changed in [groq(model: "llama-3.3-70b-versatile"), groq(provider: .openrouter), endpoint] {
            store.record(limit: 8_000, requested: nil, estimate: nil, for: groq())
            XCTAssertNotNil(store.allowance(for: groq()))
            XCTAssertNil(store.allowance(for: changed), "\(changed.provider) \(changed.model)")
            XCTAssertNil(store.allowance(for: groq()), "cleared, not merely hidden")
            XCTAssertNil(PerMinuteAllowanceStore(defaults: defaults).allowance(for: groq()))
        }
    }

    /// A key is never part of what is kept, so a key edit is caught where the saved models are
    /// written: the models a write makes stale are the ones gone and the ones whose key, provider,
    /// model id or endpoint changed. Whitespace around the key is not a new key.
    func testAChangedKeyOrARemovedModelIsForgottenAtTheWrite() {
        let other = ModelConfig(id: "other", name: "Other", provider: LLMProvider.mistral.rawValue,
                                apiKey: "m_key", model: "mistral-small", baseURL: LLMProvider.mistral.defaultBaseURL)
        let old = [groq(), other]
        XCTAssertEqual(PerMinuteAllowance.modelsToForget(old: old, new: old), [])
        XCTAssertEqual(PerMinuteAllowance.modelsToForget(old: old, new: [groq(key: " gsk_first\n"), other]), [])
        XCTAssertEqual(PerMinuteAllowance.modelsToForget(old: old, new: [groq(key: "gsk_second"), other]), ["saved-groq"])
        XCTAssertEqual(PerMinuteAllowance.modelsToForget(old: old, new: [groq(model: "llama-3.3-70b-versatile"), other]),
                       ["saved-groq"])
        XCTAssertEqual(PerMinuteAllowance.modelsToForget(old: old, new: [other]), ["saved-groq"])
        XCTAssertEqual(PerMinuteAllowance.modelsToForget(old: [], new: old), [], "a new model has nothing to forget")

        let (store, defaults) = store()
        store.record(limit: 8_000, requested: 11_234, estimate: 12_103, for: groq())
        store.record(limit: 6_000, requested: nil, estimate: nil, for: other)
        XCTAssertEqual(store.forget(["saved-groq"]), 1)
        XCTAssertNil(PerMinuteAllowanceStore(defaults: defaults).allowance(for: groq(key: "gsk_second")))
        XCTAssertEqual(store.allowance(for: other)?.limit, 6_000, "another model's allowance is kept")
        XCTAssertEqual(store.forget(["saved-groq"]), 0)
    }

    /// Through the real write: editing the key in the saved list clears the allowance, and saving
    /// the list unchanged keeps it.
    func testSavingTheModelsWithANewKeyClearsTheSharedAllowance() {
        let saved = Config.savedModels
        defer { Config.setSavedModels(saved); PerMinuteAllowanceStore.shared.forget(["saved-groq"]) }
        Config.setSavedModels([groq()])
        PerMinuteAllowanceStore.shared.record(limit: 8_000, requested: nil, estimate: nil, for: groq())
        Config.setSavedModels([groq()])
        XCTAssertEqual(PerMinuteAllowanceStore.shared.allowance(for: groq())?.limit, 8_000)
        Config.setSavedModels([groq(key: "gsk_second")])
        XCTAssertNil(PerMinuteAllowanceStore.shared.allowance(for: groq(key: "gsk_second")))
    }

    func testTheKeyIsNeverStored() {
        let (store, defaults) = store()
        store.record(limit: 8_000, requested: 11_234, estimate: 12_103, for: groq(key: "gsk_SECRETVALUE123"))
        let raw = String(decoding: defaults.data(forKey: PerMinuteAllowanceStore.defaultsKey) ?? Data(), as: UTF8.self)
        XCTAssertTrue(raw.contains("8000"), raw)
        XCTAssertFalse(raw.contains("SECRETVALUE"), raw)
        XCTAssertEqual(PerMinuteAllowance.fingerprint(for: groq(key: "gsk_SECRETVALUE123")),
                       PerMinuteAllowance.fingerprint(for: groq(key: "gsk_other")),
                       "nothing of the key, not even a digest, is in the fingerprint")
    }

    func testCalibrationFromTheFigures() {
        // Both figures: their ratio, clamped.
        XCTAssertEqual(PerMinuteAllowance.learned(limit: 8_000, requested: 11_000, estimate: 10_000,
                                                  previous: nil, fingerprint: "f").calibration ?? 0, 1.1, accuracy: 0.0001)
        XCTAssertEqual(PerMinuteAllowance.learned(limit: 8_000, requested: 50_000, estimate: 10_000,
                                                  previous: nil, fingerprint: "f").calibration, 2.0)
        // The limit alone, over an estimate that thought the request fitted: raised past the limit.
        let floor = PerMinuteAllowance.learned(limit: 8_000, requested: nil, estimate: 7_000,
                                               previous: nil, fingerprint: "f")
        XCTAssertGreaterThan(floor.calibrated(7_000), 8_000)
        // …and an earlier, higher calibration for the same fingerprint is kept.
        let earlier = Self.allowance(8_000, calibration: 1.5)
        XCTAssertEqual(PerMinuteAllowance.learned(limit: 8_000, requested: nil, estimate: 7_000,
                                                  previous: earlier, fingerprint: "f").calibration, 1.5)
        // A previous allowance for another fingerprint teaches nothing.
        XCTAssertNil(PerMinuteAllowance.learned(limit: 8_000, requested: nil, estimate: 9_000,
                                                previous: earlier, fingerprint: "other").calibration)
        // No estimate: the limit is kept, uncalibrated.
        XCTAssertNil(PerMinuteAllowance.learned(limit: 8_000, requested: 11_234, estimate: nil,
                                                previous: nil, fingerprint: "f").calibration)
    }

    // MARK: - The one retry

    private struct Refused: Error {}

    func testARefusalWithFiguresIsRetriedOnce() async throws {
        var attempts = 0, learned = 0, rewound = 0
        let reply = try await PerMinuteRetry.run(
            attempt: { attempts += 1; if attempts == 1 { throw Refused() }; return "fitted" },
            learn: { _ in learned += 1; return true },
            toolRan: { false },
            beforeRetry: { rewound += 1 })
        XCTAssertEqual(reply, "fitted")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(learned, 1)
        XCTAssertEqual(rewound, 1)
    }

    func testASecondRefusalIsNotRetriedButIsLearnedFrom() async {
        var attempts = 0, learned = 0
        do {
            _ = try await PerMinuteRetry.run(
                attempt: { attempts += 1; throw Refused() },
                learn: { _ in learned += 1; return true },
                toolRan: { false }, beforeRetry: {})
            XCTFail("the second refusal goes to the chain")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        XCTAssertEqual(attempts, 2, "exactly one retry")
        XCTAssertEqual(learned, 2)
    }

    func testARefusalAfterAToolRanIsNeverRetried() async {
        var attempts = 0
        do {
            _ = try await PerMinuteRetry.run(
                attempt: { attempts += 1; throw Refused() },
                learn: { _ in true }, toolRan: { true }, beforeRetry: { XCTFail("no rewind") })
            XCTFail("thrown on")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }

    func testOtherFailuresAndCancellationAreNotRetried() async {
        var attempts = 0
        do {
            _ = try await PerMinuteRetry.run(attempt: { attempts += 1; throw Refused() },
                                             learn: { _ in false }, toolRan: { false }, beforeRetry: {})
        } catch {}
        XCTAssertEqual(attempts, 1)
        attempts = 0
        do {
            _ = try await PerMinuteRetry.run(attempt: { attempts += 1; throw CancellationError() },
                                             learn: { _ in XCTFail("not learned"); return true },
                                             toolRan: { false }, beforeRetry: {})
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - What the wearer hears

    func testNothingFitsNamesTheServiceAndTheAllowance() {
        let error = PerMinuteFit.NothingFits(provider: .groq, limit: 8_000, needed: 9_100)
        let reason = ModelSwitchNarrator.exhaustionReason(lastError: error)
        XCTAssertEqual(reason, "Groq's plan allows about 8 thousand tokens a minute, and this question needs more, "
                       + "so pick another model in Settings")
        XCTAssertEqual(ModelSwitchNarrator.exhaustionPhrase(lastError: error),
                       "I couldn't get a response — \(reason).")
        XCTAssertEqual(error.localizedDescription,
                       "Groq's plan allows about 8 thousand tokens a minute, and this question needs more, "
                       + "so pick another model in Settings.")
        XCTAssertEqual(SpokenErrorPolicy.photoFailureLine(for: error, photoCaptured: true, narrateModelFailures: true),
                       "I took the photo, but couldn't get an answer about it — \(reason).")
        XCTAssertEqual(ModelFallbackChain.classify(error), .terminalForCandidate,
                       "another model may take the turn whole")
        XCTAssertNil(CredentialGap.kind(of: error))
        XCTAssertEqual(SafeErrorSummary(error).description, "overAllowance(beforeSending)")
    }

    func testASurvivingRefusalWithFiguresSaysTheAllowance() {
        let reason = ModelSwitchNarrator.exhaustionReason(lastError: Self.refusedError())
        XCTAssertTrue(reason.hasPrefix("Groq's plan allows about 8 thousand tokens a minute"), reason)
        XCTAssertFalse(reason.contains("Small context"), reason)
        // The caller's context names the service when the label is a picker's.
        let named = ModelSwitchNarrator.exhaustionReason(
            lastError: Self.refusedError(),
            perMinute: PerMinuteNotice.from(Self.refusedError(), provider: .custom, carriedTools: true))
        XCTAssertTrue(named.hasPrefix("your custom server's plan allows"), named)
    }

    /// Small context removes the tools, so it is said only to a question that carried none.
    func testSmallContextIsAdvisedOnlyForAQuestionWithoutTools() {
        let bare = Self.refusedError(Self.groqRefusal("Request too large on tokens per minute (TPM)."))
        let withTools = ModelSwitchNarrator.exhaustionReason(
            lastError: bare, perMinute: PerMinuteNotice.from(bare, provider: .groq, carriedTools: true))
        XCTAssertEqual(withTools, "this question is bigger than Groq allows per minute on this account, so pick another model in Settings")
        let noTools = ModelSwitchNarrator.exhaustionReason(
            lastError: bare, perMinute: PerMinuteNotice.from(bare, provider: .groq, carriedTools: false))
        XCTAssertTrue(noTools.contains("turn on Small context"), noTools)
        // Unknown counts as tools.
        XCTAssertFalse(ModelSwitchNarrator.exhaustionReason(lastError: bare).contains("Small context"))
    }

    func testTheHopAwaySaysTheAllowanceNotAnOutage() {
        let phrase = ModelSwitchNarrator.fallbackPhrase(
            from: .init(name: "Groq free", isLocal: false), to: .init(name: "Claude", isLocal: false),
            failure: .terminalForCandidate,
            perMinute: PerMinuteNotice.from(PerMinuteFit.NothingFits(provider: .groq, limit: 8_000, needed: 9_000)))
        XCTAssertEqual(phrase, "Groq's plan allows about 8 thousand tokens a minute, and this question needs more, so I'm using Claude.")
        let onPhone = ModelSwitchNarrator.fallbackPhrase(
            from: .init(name: "Groq free", isLocal: false),
            to: .init(name: "Apple Intelligence", isLocal: false, isOnDevice: true),
            failure: .retryOtherModel, perMinute: PerMinuteNotice.from(Self.refusedError(), provider: .groq))
        XCTAssertTrue(onPhone.hasSuffix("so I'm answering on this phone."), onPhone)
        XCTAssertFalse(onPhone.contains("unavailable"))
    }

    func testAmounts() {
        XCTAssertEqual(PerMinuteNotice.amount(8_000), "8 thousand")
        XCTAssertEqual(PerMinuteNotice.amount(6_400), "6 thousand")
        XCTAssertEqual(PerMinuteNotice.amount(12_500), "13 thousand")
        XCTAssertEqual(PerMinuteNotice.amount(800), "800")
    }

    func testTheBannerNamesTheAllowanceAndKeepsSmallContextForToolFreeRequests() {
        let failure = "clientError(rate_limit_exceeded)#413"
        let known = AppState.plainReason(failure, rejection: "requestOverTokenRateLimit", toolsSent: 37, allowance: 8_000)
        XCTAssertEqual(known, "the AI service allows this account about 8 thousand tokens a minute, fewer than this question needs — choose another model")
        let withTools = AppState.plainReason(failure, rejection: "requestOverTokenRateLimit", toolsSent: 37)
        XCTAssertFalse(withTools.contains("Small context"), withTools)
        let noTools = AppState.plainReason(failure, rejection: "requestOverTokenRateLimit", toolsSent: 0)
        XCTAssertTrue(noTools.contains("Small context"), noTools)
        let beforeSending = AppState.plainReason("overAllowance(beforeSending)", allowance: 8_000)
        XCTAssertEqual(beforeSending, known)
    }
}

/// Plan KL P1 through the real `LLMService`: a Groq model with the registry's tools, a recording
/// transport, and a refusal with figures.
@MainActor
final class PerMinuteRetryTurnTests: XCTestCase {
    private var savedModels: [ModelConfig] = []
    private var activeID = ""
    private var cascade = false
    private var agent = false
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        savedModels = Config.savedModels
        activeID = Config.activeModelId
        cascade = Config.modelCascadeEnabled
        agent = Config.agentModeEnabled
        Config.modelCascadeEnabled = true
        Config.setAgentModeEnabled(false)
        Config.setSavedModels([ModelConfig(id: "groq-free", name: "Groq free", provider: LLMProvider.groq.rawValue,
                                           apiKey: "gsk_test", model: "qwen/qwen3.8-27b",
                                           baseURL: LLMProvider.groq.defaultBaseURL)])
        Config.setActiveModelId("groq-free")
        defaults = UserDefaults(suiteName: "PerMinuteRetryTurnTests")
        defaults.removePersistentDomain(forName: "PerMinuteRetryTurnTests")
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        Config.setSavedModels(savedModels)
        Config.setActiveModelId(activeID)
        Config.modelCascadeEnabled = cascade
        Config.setAgentModeEnabled(agent)
        defaults.removePersistentDomain(forName: "PerMinuteRetryTurnTests")
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private func service() -> LLMService {
        let service = LLMService()
        service.processingConsent = CloudConsentFixture.conversation(origins: ["https://api.groq.com"])
        let session = RecordingQueueProtocol.session()
        service.dataSession = session
        service.streamingSession = session
        service.nativeToolRouter = NativeToolRouter(registry: NativeToolRegistry(locationService: LocationService()))
        service.perMinuteAllowances = PerMinuteAllowanceStore(defaults: defaults)
        return service
    }

    private let answer = #"{"choices":[{"message":{"role":"assistant","content":"It's sunny."}}]}"#

    private func refusal(limit: Int, requested: Int) -> String {
        let body: [String: Any] = ["error": [
            "message": "Request too large for model `qwen/qwen3.8-27b` in organization `org_test` service tier "
                + "`on_demand` on tokens per minute (TPM): Limit \(limit), Requested \(requested), please reduce "
                + "your message size and try again.",
            "type": "tokens", "code": "rate_limit_exceeded"]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private func toolNames(_ request: RecordingQueueProtocol.Recorded) -> [String] {
        ((request.json?["tools"] as? [[String: Any]]) ?? []).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
    }

    /// The size the turn's first request comes to, measured on an answered turn, so the refusal's
    /// figures can be written against it.
    private func measuredEstimate() async throws -> Int {
        RecordingQueueProtocol.queue = [(200, answer)]
        _ = try await service().sendMessageCascading("What's the weather?")
        let request = try XCTUnwrap(RecordingQueueProtocol.requests.first)
        RecordingQueueProtocol.reset()
        let cap = request.json?["max_tokens"] as? Int ?? request.json?["max_completion_tokens"] as? Int ?? 0
        return PerMinuteFit.estimatedTokens(bodyBytes: request.body.count, outputCap: cap)
    }

    func testARefusalWithFiguresIsAnsweredOnTheSameModelWithTheToolsOnDemand() async throws {
        let estimate = try await measuredEstimate()
        let llm = service()
        RecordingQueueProtocol.queue = [(413, refusal(limit: estimate * 95 / 100, requested: estimate)), (200, answer)]
        var switches = 0
        let reply = try await llm.sendMessageCascading("What's the weather?",
                                                       onModelSwitch: { _, _, _, _ in switches += 1 })
        XCTAssertEqual(reply, "It's sunny.")
        XCTAssertEqual(switches, 0, "no hop: the same model answered")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 2, "one refusal, one fitted retry")
        XCTAssertLessThan(requests[1].body.count, requests[0].body.count)
        XCTAssertGreaterThan(toolNames(requests[0]).count, 1)
        XCTAssertTrue(toolNames(requests[1]).contains(ToolLookupTool.toolName), "tools are on demand, never dropped")
        XCTAssertEqual(toolNames(requests[1]).count, 1, "the core set is emptied")
        let messages = requests[1].json?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.filter { $0["role"] as? String == "user" }.count, 1,
                       "the retry starts from the turn's own history, not on top of the refused attempt")
        let learned = try XCTUnwrap(llm.perMinuteAllowances.allowance(for: Config.savedModels[0]))
        XCTAssertEqual(learned.limit, estimate * 95 / 100)

        // The next turn on the same model is fitted before it is sent: no refusal needed.
        RecordingQueueProtocol.reset()
        RecordingQueueProtocol.queue = [(200, answer)]
        _ = try await llm.sendMessageCascading("And tomorrow?")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        XCTAssertEqual(toolNames(try XCTUnwrap(RecordingQueueProtocol.requests.first)), [ToolLookupTool.toolName])
    }

    /// The saved list always carries Apple Intelligence, so with the chain on a failure here would
    /// hop to the real on-device model. These two turns are about this model alone.
    private func withoutTheChain() { Config.modelCascadeEnabled = false }

    func testARefusalAfterAToolRanIsNotSentAgain() async throws {
        withoutTheChain()
        let llm = service()
        let toolCall = #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_datetime","arguments":"{}"}}]}}]}"#
        RecordingQueueProtocol.queue = [(200, toolCall), (413, refusal(limit: 8_000, requested: 11_234)), (200, answer)]
        do {
            _ = try await llm.sendMessageCascading("What time is it?")
            XCTFail("the refusal after the tool is the turn's error: it is not sent again")
        } catch {
            XCTAssertNotNil(PerMinuteNotice.from(error))
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2, "the tool's turn is never repeated")
        XCTAssertEqual(llm.perMinuteAllowances.allowance(for: Config.savedModels[0])?.limit, 8_000,
                       "but the allowance is learned for the next turn")
    }

    func testNothingFitsSendsNothing() async throws {
        withoutTheChain()
        let llm = service()
        llm.perMinuteAllowances.record(limit: 500, requested: nil, estimate: nil, for: Config.savedModels[0])
        do {
            _ = try await llm.sendMessageCascading("What's the weather?")
            XCTFail("no rung fits 500 tokens a minute")
        } catch let error as PerMinuteFit.NothingFits {
            XCTAssertEqual(error.limit, 500)
            XCTAssertEqual(error.provider, .groq)
            XCTAssertTrue(ModelSwitchNarrator.exhaustionReason(
                lastError: error, perMinute: llm.perMinuteNotice(behind: error)).hasPrefix("Groq's plan allows about 500 tokens a minute"))
        }
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
    }
}
