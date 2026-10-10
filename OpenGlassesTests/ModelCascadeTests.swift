import XCTest
@testable import OpenGlasses

/// BK P2b — the model cascade. A turn walks an ordered candidate chain and only surfaces an error
/// when every eligible candidate is exhausted. All pure/headless: error classification, next-hop
/// selection, the candidate builder, and the driver loop over fake attempts.
final class ModelCascadeTests: XCTestCase {

    // MARK: - classify

    func testPromptTooLongNeedsBiggerWindow() {
        XCTAssertEqual(ModelFallbackChain.classify(LocalLLMError.promptTooLong(tokens: 5000, limit: 3456)),
                       .needsBiggerWindow)
    }

    func testRateLimitAndQuotaRetryOtherModel() {
        for status in [429, 402, 408, 500, 503] {
            XCTAssertEqual(
                ModelFallbackChain.classify(LLMError.apiError(provider: "x", statusCode: status, message: nil)),
                .retryOtherModel, "status \(status) should hop to another model")
        }
    }

    func testAuthErrorIsTerminalForCandidateOnly() {
        for status in [401, 403] {
            XCTAssertEqual(
                ModelFallbackChain.classify(LLMError.apiError(provider: "x", statusCode: status, message: nil)),
                .terminalForCandidate, "auth failure kills only this provider")
        }
    }

    func testMalformedRequestIsTerminalForTurn() {
        for status in [400, 422] {
            XCTAssertEqual(
                ModelFallbackChain.classify(LLMError.apiError(provider: "x", statusCode: status, message: nil)),
                .terminalForTurn, "a malformed request fails identically everywhere")
        }
    }

    func testMissingKeyIsPerCandidateAndInvalidConfigIsTerminal() {
        XCTAssertEqual(ModelFallbackChain.classify(LLMError.missingAPIKey("no key")), .terminalForCandidate)
        XCTAssertEqual(ModelFallbackChain.classify(LLMError.invalidConfiguration("bad")), .terminalForTurn)
    }

    func testEmptyCompletionAndBackgroundedRetryOtherModel() {
        XCTAssertEqual(ModelFallbackChain.classify(LLMError.invalidResponse("Local")), .retryOtherModel)
        XCTAssertEqual(ModelFallbackChain.classify(LocalLLMError.backgrounded), .retryOtherModel)
    }

    func testCancellationIsTerminalForTurn() {
        XCTAssertEqual(ModelFallbackChain.classify(CancellationError()), .terminalForTurn)
    }

    // MARK: - next

    private func cloud(_ id: String, vision: Bool = true) -> ModelFallbackChain.Candidate {
        .init(id: id, isLocalMLX: false, supportsVision: vision, contextTokens: ModelFallbackChain.cloudContextTokens)
    }
    private func local(_ id: String, window: Int = 4096) -> ModelFallbackChain.Candidate {
        .init(id: id, isLocalMLX: true, supportsVision: false, contextTokens: window)
    }
    private let anyTurn = ModelFallbackChain.TurnNeeds(requiresVision: false, isBackgrounded: false)

    func testNextReturnsFirstUntriedEligible() {
        let list = [local("a"), cloud("b")]
        let next = ModelFallbackChain.next(candidates: list, tried: ["a"], needs: anyTurn,
                                           failure: .retryOtherModel, currentWindow: 4096)
        XCTAssertEqual(next?.id, "b")
    }

    func testNextSkipsLocalMLXWhenBackgrounded() {
        let list = [local("a"), local("b"), cloud("c")]
        let next = ModelFallbackChain.next(
            candidates: list, tried: ["a"],
            needs: .init(requiresVision: false, isBackgrounded: true),
            failure: .retryOtherModel, currentWindow: 4096)
        XCTAssertEqual(next?.id, "c", "backgrounded turn skips on-device MLX candidates")
    }

    func testNextSkipsTextOnlyForVisionTurn() {
        let list = [cloud("a", vision: false), cloud("b", vision: true)]
        let next = ModelFallbackChain.next(
            candidates: list, tried: ["a"],
            needs: .init(requiresVision: true, isBackgrounded: false),
            failure: .retryOtherModel, currentWindow: ModelFallbackChain.cloudContextTokens)
        XCTAssertEqual(next?.id, "b", "a vision turn skips text-only candidates")
    }

    func testNeedsBiggerWindowPicksALargerWindow() {
        let list = [local("small", window: 4096), local("also-small", window: 4096), cloud("big")]
        let next = ModelFallbackChain.next(candidates: list, tried: ["small"], needs: anyTurn,
                                           failure: .needsBiggerWindow, currentWindow: 4096)
        XCTAssertEqual(next?.id, "big", "overflow skips same-size windows and picks a bigger one")
    }

    func testTerminalForTurnHasNoNext() {
        let list = [cloud("a"), cloud("b")]
        XCTAssertNil(ModelFallbackChain.next(candidates: list, tried: ["a"], needs: anyTurn,
                                             failure: .terminalForTurn, currentWindow: 0))
    }

    func testExhaustedChainHasNoNext() {
        let list = [cloud("a"), cloud("b")]
        XCTAssertNil(ModelFallbackChain.next(candidates: list, tried: ["a", "b"], needs: anyTurn,
                                             failure: .retryOtherModel, currentWindow: 0))
    }

    // MARK: - candidate builder from Config

    private func config(_ id: String, provider: LLMProvider, model: String = "m") -> ModelConfig {
        ModelConfig(id: id, name: id, provider: provider.rawValue, apiKey: "k", model: model, baseURL: "")
    }

    func testCandidatesLeadWithActiveThenFallbackThenRest() {
        let saved = [config("cloud1", provider: .anthropic),
                     config("cloud2", provider: .openai),
                     config("localm", provider: .local, model: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")]
        let chain = ModelFallbackChain.candidates(
            activeId: "localm", saved: saved, fallbackOrder: ["cloud2"])
        XCTAssertEqual(chain.map(\.id), ["localm", "cloud2", "cloud1"],
                       "active leads, then user fallback order, then the remaining saved model")
    }

    func testCandidatesDedupeAndIgnoreUnknownIds() {
        let saved = [config("a", provider: .anthropic), config("b", provider: .openai)]
        let chain = ModelFallbackChain.candidates(
            activeId: "a", saved: saved, fallbackOrder: ["a", "ghost", "b"])
        XCTAssertEqual(chain.map(\.id), ["a", "b"], "duplicates and unknown ids are dropped")
    }

    func testLocalCandidateCarriesItsRealWindow() {
        let saved = [config("localm", provider: .local, model: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")]
        let chain = ModelFallbackChain.candidates(activeId: "localm", saved: saved, fallbackOrder: [])
        XCTAssertTrue(chain[0].isLocalMLX)
        XCTAssertEqual(chain[0].contextTokens,
                       LocalModelBudget.contextWindow(for: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"))
    }

    // MARK: - driver

    private func run(_ candidates: [ModelFallbackChain.Candidate],
                     maxAttempts: Int = 4,
                     isCancelled: @escaping () -> Bool = { false },
                     attempt: @escaping (ModelFallbackChain.Candidate) async throws -> String)
    async throws -> (String, [String]) {
        var switches: [String] = []
        let out = try await ModelCascade.run(
            candidates: candidates, needs: anyTurn, maxAttempts: maxAttempts,
            isCancelled: isCancelled,
            onSwitch: { from, to, _ in switches.append("\(from.id)->\(to.id)") },
            attempt: attempt)
        return (out, switches)
    }

    func testFirstAttemptSuccessDoesNotHop() async throws {
        let (out, switches) = try await run([cloud("a"), cloud("b")]) { _ in "ok" }
        XCTAssertEqual(out, "ok")
        XCTAssertTrue(switches.isEmpty)
    }

    func testHopsOnRateLimitThenSucceeds() async throws {
        let (out, switches) = try await run([cloud("a"), cloud("b")]) { c in
            if c.id == "a" { throw LLMError.apiError(provider: "a", statusCode: 429, message: nil) }
            return "from-\(c.id)"
        }
        XCTAssertEqual(out, "from-b")
        XCTAssertEqual(switches, ["a->b"])
    }

    func testExhaustedChainThrowsLastRealError() async {
        do {
            _ = try await run([cloud("a"), cloud("b")]) { c in
                throw LLMError.apiError(provider: c.id, statusCode: 429, message: "rl-\(c.id)")
            }
            XCTFail("expected throw")
        } catch let LLMError.apiError(_, _, message, _) {
            XCTAssertEqual(message, "rl-b", "surfaces the LAST candidate's real error, not a generic line")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testAttemptCapIsHonoured() async {
        var calls = 0
        do {
            _ = try await run([cloud("a"), cloud("b"), cloud("c"), cloud("d")], maxAttempts: 2) { _ in
                calls += 1
                throw LLMError.apiError(provider: "x", statusCode: 429, message: nil)
            }
            XCTFail("expected throw")
        } catch { XCTAssertEqual(calls, 2, "stops at the attempt cap even with candidates left") }
    }

    func testTerminalForTurnDoesNotCascade() async {
        var calls = 0
        do {
            _ = try await run([cloud("a"), cloud("b")]) { _ in
                calls += 1
                throw LLMError.invalidConfiguration("malformed")
            }
            XCTFail("expected throw")
        } catch { XCTAssertEqual(calls, 1, "a turn-terminal failure never tries a second model") }
    }

    func testSingleCandidateMissingKeyThrows() async {
        do {
            _ = try await run([cloud("a")]) { _ in throw LLMError.missingAPIKey("no key") }
            XCTFail("expected throw")
        } catch let LLMError.missingAPIKey(msg) {
            XCTAssertEqual(msg, "no key")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testMissingKeyHopsToNextCandidate() async throws {
        let (out, switches) = try await run([cloud("a"), cloud("b")]) { c in
            if c.id == "a" { throw LLMError.missingAPIKey("no key for a") }
            return "from-\(c.id)"
        }
        XCTAssertEqual(out, "from-b", "a per-provider credential failure skips to the next model")
        XCTAssertEqual(switches, ["a->b"])
    }

    // MARK: - The lead candidate meets the turn's needs too

    func testVisionTurnSkipsTextOnlyLeadCandidate() async throws {
        var calls: [String] = []
        let out = try await ModelCascade.run(
            candidates: [cloud("a", vision: false), cloud("b", vision: true)],
            needs: .init(requiresVision: true, isBackgrounded: false),
            maxAttempts: 4,
            attempt: { c in
                calls.append(c.id)
                return "from-\(c.id)"
            }
        )
        XCTAssertEqual(out, "from-b")
        XCTAssertEqual(calls, ["b"], "a text-only lead must not answer a photo turn without the photo")
    }

    func testBackgroundedTurnSkipsLocalLeadCandidate() async throws {
        var calls: [String] = []
        _ = try await ModelCascade.run(
            candidates: [local("mlx"), cloud("b")],
            needs: .init(requiresVision: false, isBackgrounded: true),
            maxAttempts: 4,
            attempt: { c in
                calls.append(c.id)
                return "ok"
            }
        )
        XCTAssertEqual(calls, ["b"])
    }

    func testVisionTurnWithNoVisionCandidateThrowsAVisionReason() async {
        do {
            _ = try await ModelCascade.run(
                candidates: [cloud("a", vision: false)],
                needs: .init(requiresVision: true, isBackgrounded: false),
                maxAttempts: 4,
                attempt: { _ in "should-not-run" }
            )
            XCTFail("expected throw")
        } catch let LLMError.missingAPIKey(message) {
            XCTAssertTrue(message.localizedCaseInsensitiveContains("vision"), message)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testTextTurnStillLeadsWithTheActiveCandidate() async throws {
        var calls: [String] = []
        _ = try await ModelCascade.run(
            candidates: [cloud("a", vision: false), cloud("b", vision: true)],
            needs: .init(requiresVision: false, isBackgrounded: false),
            maxAttempts: 4,
            attempt: { c in
                calls.append(c.id)
                return "ok"
            }
        )
        XCTAssertEqual(calls, ["a"])
    }

    func testNoEligibleCandidateMessages() {
        let text = ModelFallbackChain.TurnNeeds(requiresVision: false, isBackgrounded: false)
        XCTAssertEqual(ModelCascade.noEligibleCandidateMessage(candidates: [], needs: text), "No model configured")
        let vision = ModelFallbackChain.TurnNeeds(requiresVision: true, isBackgrounded: false)
        XCTAssertTrue(ModelCascade.noEligibleCandidateMessage(candidates: [cloud("a", vision: false)], needs: vision)
            .contains("vision"))
        let background = ModelFallbackChain.TurnNeeds(requiresVision: false, isBackgrounded: true)
        XCTAssertTrue(ModelCascade.noEligibleCandidateMessage(candidates: [local("m")], needs: background)
            .contains("background"))
    }

    func testCancellationBetweenHopsStopsChain() async {
        var calls = 0
        do {
            _ = try await run([cloud("a"), cloud("b")], isCancelled: { calls >= 1 }) { _ in
                calls += 1
                throw LLMError.apiError(provider: "x", statusCode: 429, message: nil)
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(calls, 1, "a barge-in after hop 1 must not launch hop 2")
        } catch { XCTFail("unexpected \(error)") }
    }
}
