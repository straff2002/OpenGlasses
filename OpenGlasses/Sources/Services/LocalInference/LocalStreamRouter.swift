import Foundation

/// One element of an on-device generation stream, as the app reads it.
///
/// mlx-swift-lm's `Generation` maps onto this in `LocalLLMService.streamPiece(_:)`; nothing here
/// imports MLX, so the routing below is testable with no model, no Metal and no `Wearables`.
/// `Info` is the runtime's completion report (`GenerateCompletionInfo` for MLX), carried opaquely.
enum LocalStreamPiece<Info: Sendable>: Sendable {
    /// Answer text (`.chunk`). The only piece that is previewed, spoken or returned.
    case answer(String)
    /// Thinking the runtime streamed apart from the answer (`.reasoning`, from mlx-swift-lm 4c21c84),
    /// its delimiters already removed. Never previewed, never spoken, never part of the answer.
    case reasoning(String)
    /// A call the runtime's parser took out of the stream (`.toolCall`).
    case toolCall(LocalToolCallEvent)
    /// The runtime's own token count and decode time (`.info`).
    case info(Info)
    /// Anything else (a rejected call, a steering outcome, an event a later release adds).
    case ignored
}

/// Splits a generation stream into the answer and everything kept beside it (Plan MQ P1).
///
/// `take(_:)` returns the answer text of a piece, or `""` for any other piece. The drain
/// (`LocalLLMService.drainTokenStream`) treats `""` as "nothing to show yet" and goes round again,
/// so it checks for barge-in and backgrounding between *every* event, reasoning included. A think
/// block of a thousand tokens must not run past a stop or into the background just because none
/// of it is answer text.
///
/// Lock-guarded because the Gemma 4 and vision drains run inside `container.perform`, off the
/// main actor, and are read back on it.
final class LocalStreamRouter<Info: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var reasoningText = ""
    private var calls: [LocalToolCallEvent] = []
    private var report: Info?

    func take(_ piece: LocalStreamPiece<Info>) -> String {
        lock.lock(); defer { lock.unlock() }
        switch piece {
        case .answer(let text): return text
        case .reasoning(let text): reasoningText += text
        case .toolCall(let call): calls.append(call)
        case .info(let info): report = info
        case .ignored: break
        }
        return ""
    }

    /// The reasoning streamed apart from the answer, untrimmed.
    var reasoning: String {
        lock.lock(); defer { lock.unlock() }
        return reasoningText
    }

    var toolCalls: [LocalToolCallEvent] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var completion: Info? {
        lock.lock(); defer { lock.unlock() }
        return report
    }
}

/// Where a turn's reasoning is, and what is left to speak once it is gone.
enum LocalReasoningRouting {
    /// Whether the answer text itself still starts inside a `<think>` block the chat template
    /// opened. True only for a model the app knows thinks (`LocalModelBudget.reasoningModelIds`)
    /// when the runtime does not route its reasoning: once it does (mlx-swift-lm resolves a
    /// `reasoningConfig`, as it does for LFM2.5 from 4c21c84), the answer text holds no thinking,
    /// and reading it as starting inside a think block would swallow the whole answer.
    static func templateOpensThink(isReasoningModel: Bool, runtimeRoutesReasoning: Bool) -> Bool {
        isReasoningModel && !runtimeRoutesReasoning
    }

    /// The speakable answer and the reasoning of one finished turn.
    ///
    /// - `answer`: the concatenated answer text, never including routed reasoning.
    /// - `routedReasoning`: what the runtime streamed as reasoning.
    /// - `stripsThink`: whether this model's answer is cleaned of an inline `<think>` block (a
    ///   reasoning model). Other models' text comes back as it was, only trimmed, so a call a model
    ///   wrote inside its own `<think>` still reaches `LocalToolLoop.parse`.
    /// - `templateOpensThink`: see `templateOpensThink(isReasoningModel:runtimeRoutesReasoning:)`.
    ///
    /// An answer that was all reasoning comes back empty, as it always has for a reserve spent
    /// mid-think: the caller's empty-completion guard turns that into a catchable error.
    static func finish(answer: String, routedReasoning: String, stripsThink: Bool,
                       templateOpensThink: Bool) -> (spoken: String, reasoning: String?) {
        var spoken = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var inline: String?
        if stripsThink {
            let hasOpen = answer.contains("<think>")
            let hasClose = answer.contains("</think>")
            if templateOpensThink || hasOpen || hasClose {
                (spoken, inline) = ThinkStreamFilter.strip(
                    answer, startsInThink: templateOpensThink || (hasClose && !hasOpen))
            }
        }
        let parts = [routedReasoning.trimmingCharacters(in: .whitespacesAndNewlines), inline ?? ""]
            .filter { !$0.isEmpty }
        return (spoken, parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
    }
}
