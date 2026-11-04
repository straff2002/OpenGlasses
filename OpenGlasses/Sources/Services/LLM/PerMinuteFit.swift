import Foundation

// MARK: - Fitting a request to a per-minute allowance (Plan KL P1)
//
// A free Groq key allows about 8,000 tokens a minute, and a single request with the core tools
// and the full instructions is about 11,000 (support reports, builds 581 and 615). The provider
// refuses it whole, before anything runs, every time. The old advice — turn on Small context —
// removed every tool, and the question that needed the calendar, the reminders and the weather
// could no longer be answered. The context window (131k) was never the limit; the allowance was.
//
// Once a refusal has stated the allowance (`PerMinuteAllowance`), a request is fitted to it before
// it is sent, by the first rung of this ladder that fits:
//
//   1. the request as it would be sent today;
//   2. tool definitions on demand with the core set emptied: only `lookup_tools` and the tools this
//      conversation already used are declared, and every other tool is listed by name and one line
//      (Plan IU's on-demand guide), so each stays one lookup away;
//   3. rung 2 with the condensed instructions the on-device path already uses (decision 4: only
//      when the full ones don't fit);
//   4. rung 3 with the history cut to the last two exchanges and a smaller output cap;
//   5. nothing fits: say so, by the allowance, and leave the choice of model to the wearer.
//
// Tools are never dropped to make room, and Small context stays the wearer's own setting.
//
// **The output cap counts.** Whether the provider counts `max_tokens` toward the allowance could
// not be settled from the reports: neither kept the requested count. So the estimate includes it,
// which can only make the fit stricter than the provider, and each refusal that states its count
// calibrates the estimate (`PerMinuteAllowance.calibration`): the provider's count over the app's
// estimate of the same request. If the provider does not count the cap, the calibration comes out
// below one and later fits loosen to match.
//
// Pure: sizes go in, a rung comes out. `LLMService` measures the rungs and applies the choice.
enum PerMinuteFit {

    /// One rung's request, in the parts the ladder changes, as UTF-8 bytes of what is sent.
    struct Request: Equatable, Sendable {
        /// The system prompt, the on-demand guide included.
        var instructionBytes: Int
        /// The serialized tool definitions.
        var toolBytes: Int
        /// The serialized history the request carries, this turn's message included.
        var historyBytes: Int
        /// The request's `max_tokens`.
        var outputCap: Int

        /// The body this request comes to, with the JSON around the parts.
        var bodyBytes: Int { instructionBytes + toolBytes + historyBytes + PerMinuteFit.envelopeBytes }
    }

    /// The JSON a body carries besides the parts: the model id, the reasoning and stream fields,
    /// the message wrappers. A rounded constant; the calibration absorbs what it gets wrong.
    static let envelopeBytes = 300

    /// The share of the allowance a fitted request may take. A tenth is left for what the
    /// estimate cannot see — the provider's tokenizer, a counted image.
    static let headroom = 0.9

    /// The history a shortened request keeps from before this turn, in user–assistant exchanges.
    static let shortHistoryExchanges = 2

    /// The house estimate (four bytes to a token, `ToolExposurePolicy.estimatedTokens`) with the
    /// output cap on top: what the provider may count against the allowance.
    static func estimatedTokens(bodyBytes: Int, outputCap: Int) -> Int {
        ToolExposurePolicy.estimatedTokens(bytes: bodyBytes) + max(0, outputCap)
    }

    static func estimatedTokens(_ request: Request) -> Int {
        estimatedTokens(bodyBytes: request.bodyBytes, outputCap: request.outputCap)
    }

    /// The most a fitted request may be estimated at under `limit`.
    static func ceiling(limit: Int) -> Int { Int(Double(limit) * headroom) }

    /// A smaller output cap for the shortened rung: half, never under 512 — room for a spoken
    /// answer or a tool call, and for the little reasoning a model that cannot switch it off does.
    static func shortenedOutputCap(_ cap: Int) -> Int { max(512, cap / 2) }

    // MARK: - The ladder

    enum Rung: String, CaseIterable, Sendable {
        case asSent, onDemandTools, condensedInstructions, shortHistory, nothingFits
    }

    /// Each rung's request. A rung that cannot be built is nil and is passed over: rungs 2–4 need
    /// the lookup tool, and an organisation that pinned every definition to every request
    /// (`ToolDefinitionsMode.never`) has ruled them out.
    struct Ladder: Equatable, Sendable {
        var asSent: Request
        var onDemandTools: Request?
        var condensedInstructions: Request?
        var shortHistory: Request?

        func request(for rung: Rung) -> Request? {
            switch rung {
            case .asSent: return asSent
            case .onDemandTools: return onDemandTools
            case .condensedInstructions: return condensedInstructions
            case .shortHistory: return shortHistory
            case .nothingFits: return nil
            }
        }
    }

    struct Choice: Equatable, Sendable {
        let rung: Rung
        /// The calibrated estimate of the chosen rung's request; when nothing fits, of the smallest
        /// rung there was.
        let estimate: Int
        let ceiling: Int
    }

    /// The first rung whose calibrated estimate is within the allowance's ceiling.
    static func choose(_ ladder: Ladder, allowance: PerMinuteAllowance) -> Choice {
        let ceiling = ceiling(limit: allowance.limit)
        var smallest: Int?
        for rung in Rung.allCases {
            guard let request = ladder.request(for: rung) else { continue }
            let estimate = allowance.calibrated(estimatedTokens(request))
            if estimate <= ceiling { return Choice(rung: rung, estimate: estimate, ceiling: ceiling) }
            smallest = min(smallest ?? estimate, estimate)
        }
        return Choice(rung: .nothingFits, estimate: smallest ?? 0, ceiling: ceiling)
    }

    /// The history a shortened request carries: everything from this turn's own message on, whole,
    /// so a tool call is never parted from its result, and before it only the last
    /// `exchanges` user–assistant exchanges in plain text. Tool messages, tool calls and messages
    /// made of blocks (a photo) from earlier turns are left out.
    static func shortHistory(_ history: [[String: Any]], turnStart: Int,
                             exchanges: Int = shortHistoryExchanges) -> [[String: Any]] {
        let start = min(max(0, turnStart), history.count)
        let earlier = history[..<start].filter { message in
            let role = message["role"] as? String
            guard role == "user" || role == "assistant", message["tool_calls"] == nil,
                  let text = message["content"] as? String else { return false }
            return !text.isEmpty
        }
        return Array(earlier.suffix(max(0, exchanges) * 2)) + history[start...]
    }

    // MARK: - Nothing fits

    /// Thrown before anything is sent when no rung fits the learned allowance. Ends this model's
    /// part in the turn; another model may take it (`ModelFallbackChain.classify`).
    struct NothingFits: Error, LocalizedError, Equatable {
        let provider: LLMProvider
        let limit: Int
        /// The smallest rung's calibrated estimate.
        let needed: Int

        var errorDescription: String? {
            PerMinuteNotice(serviceName: provider.serviceName, limit: limit, carriedTools: true).sentence
        }
    }
}

/// Whether the request in flight was fitted to its shortest rung, held task-locally for the length
/// of the turn so the history selection and the output cap read the choice the turn was fitted
/// with, as `ToolExposureScope` carries the exposure.
enum PerMinuteFitScope {
    @TaskLocal static var shortened = false
}

// MARK: - The one retry

/// A refusal over the per-minute allowance arrives before the model has done anything, so the
/// same model can be asked again at once with a fitted request — once, and only while no tool has
/// run in the attempt (Plan KL P1). Pure driver: the attempt, the learning and the tool count are
/// the caller's.
enum PerMinuteRetry {

    /// - Parameters:
    ///   - attempt: one try of the turn on the current model.
    ///   - learn: records what a failure says about the allowance; true when it was a refusal over
    ///     the allowance with figures that a fitted request can answer. Called for the retry's
    ///     failure too, so what it says is kept for the next turn.
    ///   - toolRan: whether any tool was dispatched since the attempt began. A refusal after a tool
    ///     ran is never retried here: the retry would repeat the tool.
    ///   - beforeRetry: rewinds what the failed attempt left behind (history, the streamed bubble).
    ///
    /// Every closure is async so that one formed on the main actor runs there: the caller's state
    /// is main-actor state.
    static func run(attempt: () async throws -> String,
                    learn: (Error) async -> Bool,
                    toolRan: () async -> Bool,
                    beforeRetry: () async -> Void) async throws -> String {
        do {
            return try await attempt()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let refusedOverAllowance = await learn(error)
            guard refusedOverAllowance, !(await toolRan()) else { throw error }
            await beforeRetry()
            do {
                return try await attempt()
            } catch {
                if !(error is CancellationError) { _ = await learn(error) }
                throw error
            }
        }
    }
}

// MARK: - What the wearer hears

/// What a turn over the per-minute allowance says (Plan KL P1): the service's own allowance when
/// it is known, and never "turn on Small context" for a question that carried tools — that setting
/// removes them.
struct PerMinuteNotice: Equatable, Sendable {
    /// `LLMProvider.serviceName`: "Groq", not the saved model's name.
    let serviceName: String
    /// Tokens a minute, when a refusal said.
    let limit: Int?
    /// Whether the refused request carried tools. Unknown counts as yes.
    let carriedTools: Bool

    /// The notice behind `error`, or nil when it is not about the allowance.
    /// - Parameter provider: the model's provider, when the caller knows it; otherwise the error's
    ///   own provider label is used.
    static func from(_ error: Error, provider: LLMProvider? = nil, carriedTools: Bool = true) -> PerMinuteNotice? {
        if let nothing = error as? PerMinuteFit.NothingFits {
            return PerMinuteNotice(serviceName: nothing.provider.serviceName, limit: nothing.limit,
                                   carriedTools: true)
        }
        guard case LLMError.apiError(let label, _, _, let rejection?) = error,
              rejection.reason == .requestOverTokenRateLimit else { return nil }
        return PerMinuteNotice(serviceName: provider?.serviceName ?? label, limit: rejection.limit,
                               carriedTools: carriedTools)
    }

    /// "8 thousand", or the number itself under a thousand.
    static func amount(_ limit: Int) -> String {
        guard limit >= 1_000 else { return "\(limit)" }
        return "\(Int((Double(limit) / 1_000).rounded())) thousand"
    }

    /// What the account allows, opening a clause in lower case where it can.
    private var allowance: String {
        if let limit {
            return "\(serviceName)'s plan allows about \(Self.amount(limit)) tokens a minute, and this question needs more"
        }
        return "this question is bigger than \(serviceName) allows per minute on this account"
    }

    /// The reason half of the exhaustion line: what the account allows and what to do about it.
    var reason: String {
        if limit == nil, !carriedTools {
            return "\(allowance), so turn on Small context for that model in Settings, or pick another"
        }
        return "\(allowance), so pick another model in Settings"
    }

    /// The reason as its own sentence.
    var sentence: String { Self.capitalised(reason) + "." }

    /// Spoken when the turn moves on to another model.
    func switchPhrase(toName name: String, onDevice: Bool) -> String {
        Self.capitalised(allowance) + (onDevice ? ", so I'm answering on this phone." : ", so I'm using \(name).")
    }

    private static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
