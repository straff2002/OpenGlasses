import XCTest
@testable import OpenGlasses

/// A tester's afternoon on a degraded Gemini: every turn started on Gemini, waited out its 503 and
/// its retry's timeout, hopped to ChatGPT, and was answered in seconds — four times in twenty
/// minutes, forty-plus seconds each. `ModelCascadeMemory` carries the hop into the next turns.
final class ModelCascadeMemoryTests: XCTestCase {

    private func candidate(_ id: String) -> ModelFallbackChain.Candidate {
        ModelFallbackChain.Candidate(id: id, isLocalMLX: false, supportsVision: true,
                                     contextTokens: ModelFallbackChain.cloudContextTokens)
    }

    private let gemini = "gemini"
    private let chatgpt = "chatgpt"
    private let claude = "claude"
    private var chain: [ModelFallbackChain.Candidate] {
        [candidate(gemini), candidate(chatgpt), candidate(claude)]
    }
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Recording

    func testAHopAwayFromTheLeadAnsweredElsewhereStartsAHold() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        XCTAssertEqual(memory.deferral,
                       .init(lead: gemini, preferred: chatgpt,
                             until: t0.addingTimeInterval(ModelCascadeMemory.holdSeconds)))
    }

    func testTheLeadAnsweringEndsItsHold() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        memory.recordTurn(lead: gemini, answeredBy: gemini, hop: nil, now: t0.addingTimeInterval(60))
        XCTAssertNil(memory.deferral, "the lead is healthy again")
    }

    func testOnlyATransientFailureStartsAHold() {
        for failure in [ModelFallbackChain.FailureClass.terminalForCandidate, .visionUnavailable,
                        .needsBiggerWindow, .terminalForTurn] {
            var memory = ModelCascadeMemory()
            memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: failure, now: t0)
            XCTAssertNil(memory.deferral, "\(failure) is not the lead being degraded")
        }
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: nil, now: t0)
        XCTAssertNil(memory.deferral, "the chain started elsewhere; the lead was never tried")
    }

    func testAHeldTurnAnsweredByThePreferredModelKeepsTheHoldAsItWas() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let held = memory.deferral
        // The next turn starts on ChatGPT (no hop from the lead) and ChatGPT answers.
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: nil, now: t0.addingTimeInterval(120))
        XCTAssertEqual(memory.deferral, held, "neither extended nor cleared")
    }

    // MARK: - Start order (the routing line reads it too)

    /// Support report, build 728: Gemini timed out, Grok answered, and on the next turn the
    /// routing line still named Gemini while the held chain started on Grok. The line asks
    /// `startOrder`, which is what the cascade tries.
    func testAHeldLeadStartsOnThePreferredModel() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let order = memory.startOrder(chain, lead: gemini, visionModelId: nil, now: t0.addingTimeInterval(60))
        XCTAssertEqual(order.map(\.id), [chatgpt, gemini, claude])
        let later = memory.startOrder(chain, lead: gemini, visionModelId: nil,
                                      now: t0.addingTimeInterval(ModelCascadeMemory.holdSeconds + 1))
        XCTAssertEqual(later.first?.id, gemini, "the hold has ended")
    }

    func testAChosenVisionModelAtTheFrontKeepsItsPlace() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let order = memory.startOrder(chain, lead: gemini, visionModelId: gemini, now: t0.addingTimeInterval(60))
        XCTAssertEqual(order.map(\.id), [gemini, chatgpt, claude])
    }

    func testWithoutAHoldTheChainIsUnchanged() {
        let order = ModelCascadeMemory().startOrder(chain, lead: gemini, visionModelId: nil, now: t0)
        XCTAssertEqual(order.map(\.id), [gemini, chatgpt, claude])
    }

    func testADifferentLeadIsItsOwnHold() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        memory.recordTurn(lead: claude, answeredBy: claude, hop: nil, now: t0.addingTimeInterval(1))
        XCTAssertEqual(memory.deferral?.lead, gemini, "Claude answering says nothing about Gemini")
        memory.recordTurn(lead: claude, answeredBy: chatgpt, hop: .retryOtherModel, now: t0.addingTimeInterval(2))
        XCTAssertEqual(memory.deferral?.lead, claude, "one hold at a time: the latest hop")
    }

    // MARK: - Ordering

    func testTheChainStartsOnTheModelThatAnsweredWithTheLeadSecond() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let ordered = memory.ordered(chain, lead: gemini, now: t0.addingTimeInterval(60))
        XCTAssertEqual(ordered.map(\.id), [chatgpt, gemini, claude])
    }

    func testTheHoldExpires() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let later = t0.addingTimeInterval(ModelCascadeMemory.holdSeconds)
        XCTAssertNil(memory.activeDeferral(lead: gemini, now: later))
        XCTAssertEqual(memory.ordered(chain, lead: gemini, now: later).map(\.id), [gemini, chatgpt, claude])
        XCTAssertNotNil(memory.activeDeferral(lead: gemini, now: later.addingTimeInterval(-1)))
    }

    func testTheHoldIsForItsLeadOnly() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let claudeFirst = [candidate(claude), candidate(gemini), candidate(chatgpt)]
        XCTAssertEqual(memory.ordered(claudeFirst, lead: claude, now: t0).map(\.id), [claude, gemini, chatgpt],
                       "the wearer switched to Claude: their choice leads")
    }

    func testAPreferredModelNoLongerInTheChainChangesNothing() {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let withoutChatGPT = [candidate(gemini), candidate(claude)]
        XCTAssertEqual(memory.ordered(withoutChatGPT, lead: gemini, now: t0).map(\.id), [gemini, claude])
    }

    func testNoHoldLeavesTheOrderAlone() {
        XCTAssertEqual(ModelCascadeMemory().ordered(chain, lead: gemini, now: t0).map(\.id),
                       [gemini, chatgpt, claude])
    }

    func testTheHoldIsLongEnoughNotToReprobeEveryTurnAndShortEnoughToEnd() {
        XCTAssertGreaterThanOrEqual(ModelCascadeMemory.holdSeconds, 5 * 60)
        XCTAssertLessThanOrEqual(ModelCascadeMemory.holdSeconds, 15 * 60)
    }

    // MARK: - Through the driver

    /// The order the memory produces is what `ModelCascade.run` tries: the preferred model
    /// answers and the degraded lead is never called.
    func testADeferredLeadIsNotCalledWhenThePreferredModelAnswers() async throws {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let ordered = memory.ordered(chain, lead: gemini, now: t0.addingTimeInterval(30))
        var tried: [String] = []
        let answer = try await ModelCascade.run(
            candidates: ordered, needs: .init(requiresVision: false, isBackgrounded: false),
            maxAttempts: 3
        ) { candidate in
            tried.append(candidate.id)
            return "from \(candidate.id)"
        }
        XCTAssertEqual(answer, "from \(chatgpt)")
        XCTAssertEqual(tried, [chatgpt])
    }

    /// And when the preferred model fails during the hold, the lead is next, not skipped.
    func testADeferredLeadIsStillTheSecondHop() async throws {
        var memory = ModelCascadeMemory()
        memory.recordTurn(lead: gemini, answeredBy: chatgpt, hop: .retryOtherModel, now: t0)
        let ordered = memory.ordered(chain, lead: gemini, now: t0.addingTimeInterval(30))
        var tried: [String] = []
        let answer = try await ModelCascade.run(
            candidates: ordered, needs: .init(requiresVision: false, isBackgrounded: false),
            maxAttempts: 3
        ) { candidate in
            tried.append(candidate.id)
            if candidate.id == self.chatgpt {
                throw LLMError.apiError(provider: "ChatGPT", statusCode: 503, message: nil)
            }
            return "from \(candidate.id)"
        }
        XCTAssertEqual(answer, "from \(gemini)")
        XCTAssertEqual(tried, [chatgpt, gemini])
    }
}
