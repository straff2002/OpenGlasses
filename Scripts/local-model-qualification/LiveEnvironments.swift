import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The two real models a phone run hands the corpus to. Everything else — the case, its history,
/// the offered tools, the loop, the parser, the coercion, the scripted results, the graders — is
/// `LocalToolEval.run` exactly as CI runs it; only these closures differ from CI's scripted model.
enum LiveEnvironments {

    // MARK: - A downloaded MLX model

    /// The production `LocalLLMService`, generating each pass of the shipped loop as
    /// `LLMService.sendLocalNative` does: the case's history, the pass's call-and-result messages and
    /// the offered tools rendered by the model's own chat template (`LocalToolTurn.forLoopPass`),
    /// the Hermes instruction as its fallback, the lean on-device prompt from the fixture with the
    /// shipped native tool guide, and the model's catalog sampling
    /// (`LocalLLMService.generateParameters(for:toolTurn:)`).
    @MainActor
    static func mlx(service: LocalLLMService, fixture: LocalModelQualificationFixture,
                    modelID: String, cancellationBound: TimeInterval) -> LocalToolEval.Environment {
        LocalToolEval.Environment(
            generateTurn: { testCase, request, _ in
                let offered = testCase.offered
                let specs = offered.compactMap { fixture.toolSpec($0) }
                guard let system = fixture.systemPrompt(for: testCase, modelID: modelID,
                                                        dateTimeLine: LLMService.currentDateTimeLine()) else {
                    throw QualificationFailure.noPromptForModel
                }
                let toolTurn = LocalToolTurn.forLoopPass(
                    history: testCase.loopHistory, request: request, toolSpecs: specs,
                    fallbackInstructions: LLMService.localToolInstructions(toolNames: offered))
                // The transcript flattened, as `sendLocalNative` passes it beside the tool turn.
                let flat = LocalToolTranscript.flattened(request.messages)
                let output = try await service.generateTurn(MLXTurnInput(
                    userMessage: flat.last?.content ?? testCase.turn, systemPrompt: system,
                    history: Array(flat.dropLast()), imageData: nil, onToken: nil, toolTurn: toolTurn))
                return LocalToolLoop.Generation(text: output.text, toolCalls: output.toolCalls, stats: output.stats)
            },
            read: { _, request in
                let output = try await service.generateTurn(MLXTurnInput(
                    userMessage: request.prompt, systemPrompt: request.instructions, history: [],
                    imageData: nil, onToken: nil, toolTurn: nil))
                return LocalToolLoop.Generation(text: output.text, toolCalls: output.toolCalls, stats: output.stats)
            },
            schema: { fixture.schemaRoot($0) },
            referenceModelID: modelID,
            cancellationBound: cancellationBound)
    }

    /// One cancel-latency probe: start a long answer, cancel once the prompt has had `after`
    /// seconds, and time how long the generation takes to stop. Nil when the generation finished
    /// before the cancel landed.
    @MainActor
    static func cancelLatency(service: LocalLLMService, systemPrompt: String,
                              after delay: TimeInterval) async -> Double? {
        let task = Task { @MainActor in
            _ = try await service.generateTurn(MLXTurnInput(
                userMessage: "Walk me through a full annual service of a gas furnace, step by step, in detail.",
                systemPrompt: systemPrompt, history: [], imageData: nil, onToken: nil, toolTurn: nil))
        }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        let latency = Date().timeIntervalSince(cancelledAt)
        if case .success = result { return nil }
        return latency
    }

    // MARK: - Apple's on-device model (the baseline)

    #if canImport(FoundationModels)
    /// Apple's on-device model on the same cases. Its framework runs its own tool loop, so the
    /// shipped `LocalToolLoop` is not in the path; the tools are the shipped `AppleToolBridge`
    /// adapters (built from `OnDeviceToolSchema`, as the app's Apple path builds them), each calling
    /// the same `execute` the loop would (the case's scripted result, the same coercion and
    /// refusals), and the outcome is graded by the same graders.
    ///
    /// Its instructions are the fixture's prompt for `promptModelID` (Gemma 4 E2B's), not the
    /// shipped Apple path's `AppleOnDeviceInstructions`, which needs the running app's job service;
    /// so this measures the model on the downloaded models' prompt. Apple reports no token counts,
    /// so the zero-token and cut checks do not apply.
    @available(iOS 26.0, *)
    static func apple(fixture: LocalModelQualificationFixture, promptModelID: String) -> LocalToolEval.Environment {
        var environment = LocalToolEval.Environment(
            generateTurn: { _, _, _ in LocalToolLoop.Generation(text: "") },
            read: { _, request in
                let session = LanguageModelSession(instructions: request.instructions)
                return LocalToolLoop.Generation(text: try await session.respond(to: request.prompt).content)
            },
            schema: { fixture.schemaRoot($0) },
            // Apple's window is 4,096 tokens, the budget an uncatalogued id gets.
            referenceModelID: "apple-on-device")
        environment.runTurn = { testCase, history, execute in
            let calls = CallLog()
            var tools: [any Tool] = []
            for name in testCase.offered {
                guard let tool = fixture.tools[name] else { continue }
                tools.append(try AppleToolBridge.adapter(name: name, description: tool.description,
                                                         parameters: tool.parameters) { name, argumentsJSON in
                    let call = calls.next(name: name, argumentsJSON: argumentsJSON)
                    let result = (try? await execute(call)) ?? LocalToolLoop.ExecutionResult(text: "Error: stopped.", isError: true)
                    calls.finished(call, result)
                    return result.text
                })
            }
            guard let instructions = fixture.systemPrompt(for: testCase, modelID: promptModelID,
                                                          dateTimeLine: LLMService.currentDateTimeLine()) else {
                throw QualificationFailure.noPromptForModel
            }
            let earlier = history.map { (role: $0.role.rawValue, content: $0.content) }
            let session = LanguageModelSession(
                tools: tools,
                transcript: AppleToolBridge.transcript(instructions: instructions, tools: tools,
                                                       history: earlier, carry: earlier.count))
            let answer = try await session.respond(to: testCase.turn).content
            try Task.checkCancellation()
            let spoken = LocalOutputPolicy.classify(answer).text
            return LocalToolLoop.Outcome(
                text: spoken.isEmpty ? LLMService.localMissMessage : spoken,
                endReason: spoken.isEmpty ? .protocolOnly : .answered,
                transcript: [], executed: calls.executed, generations: 1, usedCorrection: false,
                callsFromReasoning: 0, callsNotRun: 0)
        }
        return environment
    }

    @available(iOS 26.0, *)
    static var appleModelAvailable: Bool { SystemLanguageModel.default.isAvailable }
    #endif

    /// The calls Apple's framework made, in order, with what each got back.
    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var done: [LocalToolLoop.Executed] = []

        func next(name: String, argumentsJSON: String) -> LocalToolLoop.Call {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return LocalToolLoop.Call(id: "call_\(count)", name: name,
                                      arguments: LocalToolCallEvent(name: name, argumentsJSON: argumentsJSON).arguments)
        }

        func finished(_ call: LocalToolLoop.Call, _ result: LocalToolLoop.ExecutionResult) {
            lock.lock(); done.append(.init(call: call, result: result)); lock.unlock()
        }

        var executed: [LocalToolLoop.Executed] { lock.lock(); defer { lock.unlock() }; return done }
    }
}

enum QualificationFailure: Error {
    case noPromptForModel
}
