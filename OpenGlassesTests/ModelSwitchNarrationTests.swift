import XCTest
@testable import OpenGlasses

/// BK P2c — the app narrates model switches instead of changing behaviour silently. The phrasing is
/// pure; here we assert each moment's line, that the destination is named, and — via the pure
/// cascade driver + a first-hop gate — that a multi-hop turn narrates exactly once.
final class ModelSwitchNarrationTests: XCTestCase {

    private let local = ModelSwitchNarrator.Model(name: "Qwen 0.5B", isLocal: true)
    private let claude = ModelSwitchNarrator.Model(name: "Claude", isLocal: false)
    private let gpt = ModelSwitchNarrator.Model(name: "GPT-4o", isLocal: false)

    // MARK: - Fallback phrasing

    func testLocalOverflowPhrase() {
        let p = ModelSwitchNarrator.fallbackPhrase(from: local, to: claude, failure: .needsBiggerWindow)
        XCTAssertTrue(p.contains("on-device"), "an overflow off a local model calls out the on-device model")
        XCTAssertTrue(p.contains("Claude"), "names the destination")
    }

    func testCloudRetryPhraseDiffersFromOverflow() {
        let overflow = ModelSwitchNarrator.fallbackPhrase(from: local, to: claude, failure: .needsBiggerWindow)
        let rateLimited = ModelSwitchNarrator.fallbackPhrase(from: claude, to: gpt, failure: .retryOtherModel)
        XCTAssertNotEqual(overflow, rateLimited, "overflow and rate-limit read differently")
        XCTAssertTrue(rateLimited.contains("Claude"), "names the model that failed")
        XCTAssertTrue(rateLimited.contains("GPT-4o"), "names the destination")
    }

    func testRoutingPhraseNamesDestination() {
        XCTAssertTrue(ModelSwitchNarrator.routingPhrase(to: claude).contains("Claude"))
    }

    func testPhotoCapabilitySwitchNamesClaudeAndTheReason() {
        let phrase = ModelSwitchNarrator.fallbackPhrase(
            from: .init(name: "ChatGPT", isLocal: false), to: claude, failure: .visionUnavailable)
        XCTAssertTrue(phrase.contains("ChatGPT can't analyze photos"))
        XCTAssertTrue(phrase.contains("Claude"))
    }

    // MARK: - Exhaustion phrasing (real reason, not the generic line)

    func testExhaustionReflectsRateLimit() {
        let p = ModelSwitchNarrator.exhaustionPhrase(
            lastError: LLMError.apiError(provider: "x", statusCode: 429, message: nil))
        XCTAssertTrue(p.lowercased().contains("rate-limited"))
        XCTAssertNotEqual(p, "Sorry, I encountered an error.")
    }

    func testExhaustionReflectsOverflow() {
        let p = ModelSwitchNarrator.exhaustionPhrase(
            lastError: LocalLLMError.promptTooLong(tokens: 9000, limit: 3456))
        XCTAssertTrue(p.lowercased().contains("too long"))
    }

    // MARK: - Fires once per turn across a multi-hop cascade

    func testNarratesOnlyTheFirstHopOfATwoHopCascade() async throws {
        // a (rate-limited) → b (rate-limited) → c (ok): two hops, but the narrator speaks once.
        func cloud(_ id: String) -> ModelFallbackChain.Candidate {
            .init(id: id, isLocalMLX: false, supportsVision: true,
                  contextTokens: ModelFallbackChain.cloudContextTokens)
        }
        var spokenLines: [String] = []
        var alreadyNarrated = false   // mirrors AppState.didNarrateModelSwitchThisTurn

        let out = try await ModelCascade.run(
            candidates: [cloud("a"), cloud("b"), cloud("c")],
            needs: .init(requiresVision: false, isBackgrounded: false),
            maxAttempts: 4,
            onSwitch: { from, to, failure in
                guard !alreadyNarrated else { return }   // first-hop gate
                alreadyNarrated = true
                spokenLines.append(ModelSwitchNarrator.fallbackPhrase(
                    from: .init(name: from.id, isLocal: from.isLocalMLX),
                    to: .init(name: to.id, isLocal: to.isLocalMLX),
                    failure: failure))
            },
            attempt: { c in
                if c.id == "c" { return "ok" }
                throw LLMError.apiError(provider: c.id, statusCode: 429, message: nil)
            }
        )
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(spokenLines.count, 1, "a two-hop cascade narrates exactly once")
        XCTAssertTrue(spokenLines[0].contains("b"), "the notice names the first hop's destination")
    }
}
