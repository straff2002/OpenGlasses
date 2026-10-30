import Foundation

/// How long a buffered request may go unanswered, for one stuck request not to cost the whole
/// 30 s request timeout.
///
/// A provider can sit on a request with no error at all while the next one comes straight back. A
/// buffered reply gives no sign of life until it is complete, so a long healthy answer and a stuck
/// one look the same until the limit: these numbers decide how many healthy turns get a second
/// request, which is why the switch is off by default.
struct FirstReplyLimits: Equatable {
    /// Send the same request again if nothing has come back by then.
    var hedgeAfter: TimeInterval?
    /// Stop waiting and let the cascade move on.
    var giveUpAfter: TimeInterval?

    static let none = FirstReplyLimits(hedgeAfter: nil, giveUpAfter: nil)
}

enum FirstReplyPolicy {

    /// Placeholders: no export yet records how long a healthy buffered turn takes.
    static let hedgeAfter: TimeInterval = 6
    static let giveUpAfter: TimeInterval = 12
    /// A turn that thinks at length, or carries a photo, is slower when nothing is wrong.
    static let slowTurnFactor: TimeInterval = 2
    /// Above this a second copy is a second upload, on what may be a weak link.
    static let largeBodyBytes = 256 * 1024

    /// - Parameters:
    ///   - hasNextCandidate: another model is left to hop to. With none, the provider's own timeout
    ///     stands: there is nowhere better to go.
    ///   - toolsAlreadyRan: an earlier request in this turn came back with tool calls. Asking again
    ///     is still safe, but a hop restarts the turn on another model and would run them twice.
    static func limits(enabled: Bool, bodyBytes: Int, thinksAtLength: Bool, hasNextCandidate: Bool,
                       toolsAlreadyRan: Bool) -> FirstReplyLimits {
        guard enabled else { return .none }
        let large = bodyBytes > largeBodyBytes
        let factor = thinksAtLength || large ? slowTurnFactor : 1
        return FirstReplyLimits(hedgeAfter: large ? nil : hedgeAfter * factor,
                                giveUpAfter: hasNextCandidate && !toolsAlreadyRan ? giveUpAfter * factor : nil)
    }

    /// Whether a Gemini request is set to think at length.
    static func thinksAtLength(_ wire: ReasoningPolicy.Resolution.Wire) -> Bool {
        switch wire {
        case .geminiThinkingLevel(.medium), .geminiThinkingLevel(.high): return true
        case .geminiThinkingBudget(let tokens): return tokens > 4_096
        default: return false
        }
    }
}

/// One request against its limits. No shared state is touched, so only the same request can race
/// itself: the turn around it writes the conversation history and the active model.
enum FirstResponseRace {

    private enum Event<Value: Sendable>: Sendable {
        case answered(Value)
        case failed(Error)
        case hedgeDue
        case gaveUp
        case timerCancelled
    }

    /// The first good answer wins and the other request is cancelled. An error ends the race only
    /// when nothing else is still running.
    ///
    /// - Parameters:
    ///   - sleep: the clock. Injected, so the timing is tested without waiting.
    ///   - onHedge: called once, when the second request goes out.
    ///   - attempt: one send. Called with 0, and with 1 for the second request.
    static func run<Value: Sendable>(
        limits: FirstReplyLimits,
        provider: String,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onHedge: @escaping @Sendable () -> Void = {},
        attempt: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> Value {
        guard limits != .none else { return try await attempt(0) }

        return try await withThrowingTaskGroup(of: Event<Value>.self) { group in
            @Sendable func send(_ index: Int) async -> Event<Value> {
                do { return .answered(try await attempt(index)) } catch { return .failed(error) }
            }
            @Sendable func timer(_ seconds: TimeInterval, _ event: Event<Value>) async -> Event<Value> {
                do { try await sleep(seconds); return event } catch { return .timerCancelled }
            }
            group.addTask { await send(0) }
            if let hedge = limits.hedgeAfter { group.addTask { await timer(hedge, .hedgeDue) } }
            if let limit = limits.giveUpAfter { group.addTask { await timer(limit, .gaveUp) } }

            var running = 1
            while let event = try await group.next() {
                switch event {
                case .answered(let value):
                    group.cancelAll()
                    return value
                case .failed(let error):
                    running -= 1
                    if running == 0 {
                        group.cancelAll()
                        throw error
                    }
                case .hedgeDue:
                    onHedge()
                    running += 1
                    group.addTask { await send(1) }
                case .gaveUp:
                    group.cancelAll()
                    throw LLMError.slowResponse(provider: provider)
                case .timerCancelled:
                    break
                }
            }
            throw CancellationError()
        }
    }
}
