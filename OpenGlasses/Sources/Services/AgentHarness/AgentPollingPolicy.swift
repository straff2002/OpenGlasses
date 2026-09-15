import Foundation

/// Bounded retry/backoff policy for status polling (Plan FE P0). Pure and injectable so the
/// decisions are unit-tested without anyone waiting four seconds a tick.
///
/// The rule it encodes: a poll failure is a *contact* problem, so it is retried a bounded number of
/// times with growing backoff and then reported honestly — never retried forever behind a cheerful
/// "the agent is working", and never converted into a claim that the run failed.
struct AgentPollingPolicy: Equatable {
    /// Normal cadence between polls while the endpoint is answering.
    var interval: TimeInterval = 4
    /// How many further attempts after the first failure before we give up.
    var maxRetries: Int = 4
    /// First backoff; doubles per attempt.
    var baseBackoff: TimeInterval = 2
    var maxBackoff: TimeInterval = 32
    /// How many consecutive unrecognised status values we tolerate before reporting them.
    var maxUnknownStatusTicks: Int = 5

    static let `default` = AgentPollingPolicy()

    /// Exponential backoff for the `attempt`-th consecutive failure (1-based), capped.
    func backoff(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return interval }
        let raw = baseBackoff * pow(2, Double(attempt - 1))
        return min(raw, maxBackoff)
    }

    enum Decision: Equatable {
        case retry(attempt: Int, after: TimeInterval)
        case giveUp(attempts: Int)
    }

    /// What to do after `count` consecutive failed polls (1-based). The total number of requests a
    /// dead endpoint receives is therefore `1 + maxRetries`.
    func decide(afterFailureCount count: Int) -> Decision {
        count > maxRetries ? .giveUp(attempts: count) : .retry(attempt: count, after: backoff(attempt: count))
    }

    /// 401/403 — the credential is wrong; hammering the endpoint with it is pointless and looks
    /// like an attack. Stop and say so.
    static func isAuthFailure(httpStatus: Int) -> Bool { httpStatus == 401 || httpStatus == 403 }

    /// Worth another try: a timeout, a rate limit, or anything the server blames on itself.
    /// Every other 4xx is the endpoint telling us this request will never work.
    static func isRetryable(httpStatus: Int) -> Bool {
        httpStatus == 408 || httpStatus == 429 || httpStatus >= 500
    }
}
