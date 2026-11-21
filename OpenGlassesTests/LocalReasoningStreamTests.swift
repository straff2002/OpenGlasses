import XCTest
@testable import OpenGlasses

/// From mlx-swift-lm 4c21c84 a model's thinking streams as its own `Generation.reasoning` event,
/// apart from the `.chunk` answer text, and LFM2.5 resolves as an always-thinking model. Driven
/// headlessly through the same pieces `LocalLLMService` runs (no MLX, no model, no `Wearables`):
/// `LocalStreamRouter` in the `nextChunk` seam of `drainTokenStream`, then
/// `LocalReasoningRouting.finish` on the result.
@MainActor
final class LocalReasoningStreamTests: XCTestCase {

    private typealias Piece = LocalStreamPiece<Int>

    /// One turn the way the text path runs it: every piece through the router, the drain's
    /// preview, and the finished answer.
    private func run(_ pieces: [Piece], isReasoningModel: Bool, routesReasoning: Bool,
                     backgroundAfter: Int? = nil)
    async throws -> (spoken: String, reasoning: String?, preview: [String], router: LocalStreamRouter<Int>) {
        let router = LocalStreamRouter<Int>()
        var remaining = pieces
        var pulled = 0
        var preview: [String] = []
        let opens = LocalReasoningRouting.templateOpensThink(
            isReasoningModel: isReasoningModel, runtimeRoutesReasoning: routesReasoning)
        let filter = ThinkStreamFilter(startsInThink: opens)
        let output = try await LocalLLMService.drainTokenStream(
            nextChunk: {
                guard !remaining.isEmpty else { return nil }
                pulled += 1
                return router.take(remaining.removeFirst())
            },
            isBackgrounded: { backgroundAfter.map { pulled >= $0 } ?? false },
            onToken: { chunk in
                let visible = isReasoningModel ? filter.ingest(chunk) : chunk
                if !visible.isEmpty { preview.append(visible) }
            })
        let (spoken, reasoning) = LocalReasoningRouting.finish(
            answer: output, routedReasoning: router.reasoning,
            stripsThink: isReasoningModel, templateOpensThink: opens)
        return (spoken, reasoning, preview, router)
    }

    /// LFM2.5 on the new library: the thinking arrives as `.reasoning`, the answer as `.chunk`.
    func testRoutedReasoningIsNeverSpokenAndTheAnswerSurvives() async throws {
        let result = try await run([
            .reasoning("The user wants the superheat."), .reasoning(" Suction line 12 °C, saturation 4 °C."),
            .answer("Superheat"), .answer(" is 8 kelvin."), .info(42),
        ], isReasoningModel: true, routesReasoning: true)

        XCTAssertEqual(result.spoken, "Superheat is 8 kelvin.")
        XCTAssertEqual(result.preview.joined(), "Superheat is 8 kelvin.", "no thinking in the preview")
        XCTAssertFalse(result.spoken.contains("Suction"))
        XCTAssertEqual(result.reasoning, "The user wants the superheat. Suction line 12 °C, saturation 4 °C.")
        XCTAssertEqual(result.router.completion, 42, "the completion report is kept")
    }

    /// The bug the bump would have caused: reading routed answer text as if the template opened a
    /// `<think>` block swallows the whole answer.
    func testRoutedAnswerIsNotReadAsStartingInsideThink() {
        XCTAssertFalse(LocalReasoningRouting.templateOpensThink(isReasoningModel: true, runtimeRoutesReasoning: true))
        XCTAssertTrue(LocalReasoningRouting.templateOpensThink(isReasoningModel: true, runtimeRoutesReasoning: false))
        XCTAssertFalse(LocalReasoningRouting.templateOpensThink(isReasoningModel: false, runtimeRoutesReasoning: false))
        let swallowed = ThinkStreamFilter.strip("It's 4.", startsInThink: true)
        XCTAssertEqual(swallowed.spoken, "", "what the old reading does to a routed answer")
    }

    /// A reserve spent mid-think: nothing but reasoning. The turn comes back empty, so the caller's
    /// empty-completion guard raises a catchable error rather than speaking the thought.
    func testAnAnswerThatIsOnlyReasoningComesBackEmpty() async throws {
        let result = try await run([.reasoning("Let me think about the wiring"), .reasoning(" diagram first…")],
                                   isReasoningModel: true, routesReasoning: true)
        XCTAssertEqual(result.spoken, "")
        XCTAssertTrue(result.preview.isEmpty)
        XCTAssertEqual(result.reasoning, "Let me think about the wiring diagram first…")
        XCTAssertThrowsError(try LLMService.cleanedNonEmptyLocalAnswer(result.spoken))
    }

    /// The library without a reasoning config (the old pin's behaviour): the template-opened think
    /// block arrives inside `.chunk` and is still stripped.
    func testInlineTemplateOpenedThinkIsStillStripped() async throws {
        let result = try await run([.answer("Two plus two."), .answer("</think>\n\n"), .answer("It's 4.")],
                                   isReasoningModel: true, routesReasoning: false)
        XCTAssertEqual(result.spoken, "It's 4.")
        XCTAssertEqual(result.preview.joined(), "It's 4.")
        XCTAssertEqual(result.reasoning, "Two plus two.")
    }

    /// Reasoning from a model the app doesn't list as thinking (Gemma 4's thought channel) is
    /// dropped from the answer too, and its own text is otherwise left alone.
    func testRoutedReasoningIsDroppedForOtherModels() async throws {
        let call = LocalToolCallEvent(name: "calculate", argumentsJSON: #"{"expression":"2+2"}"#)
        let result = try await run([.reasoning("thinking"), .toolCall(call), .ignored, .answer("Done.")],
                                   isReasoningModel: false, routesReasoning: true)
        XCTAssertEqual(result.spoken, "Done.")
        XCTAssertEqual(result.preview, ["Done."])
        XCTAssertEqual(result.reasoning, "thinking")
        XCTAssertEqual(result.router.toolCalls, [call])
    }

    /// Thinking is answer-less, but the drain still checks for the background between its events:
    /// backgrounded with only reasoning produced is `.backgrounded`, not a run into Metal.
    func testBackgroundingDuringReasoningStopsBeforeTheNextPull() async {
        let pieces: [Piece] = Array(repeating: .reasoning("hmm "), count: 50) + [.answer("Late.")]
        do {
            _ = try await run(pieces, isReasoningModel: true, routesReasoning: true, backgroundAfter: 3)
            XCTFail("expected .backgrounded")
        } catch let error as LocalLLMError {
            guard case .backgrounded = error else { return XCTFail("expected .backgrounded, got \(error)") }
        } catch {
            XCTFail("expected LocalLLMError.backgrounded, got \(error)")
        }
    }

    /// Barge-in mid-thought throws, as it does mid-answer.
    func testCancellationDuringReasoningThrows() async {
        let started = XCTestExpectation(description: "pulling reasoning")
        started.assertForOverFulfill = false
        let router = LocalStreamRouter<Int>()
        let task = Task { () -> String in
            try await LocalLLMService.drainTokenStream(
                nextChunk: { started.fulfill(); await Task.yield(); return router.take(.reasoning("…")) },
                isBackgrounded: { false }, onToken: nil)
        }
        await fulfillment(of: [started], timeout: 2.0)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
