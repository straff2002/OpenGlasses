import Foundation

/// How well we can currently *observe* a remote agent run (Plan FE P0).
///
/// Before this existed, every transport failure and every unrecognised status string fell back to
/// "running", so a dead endpoint produced an endless, confident "the agent is working". Contact and
/// progress are different facts: this type carries the first one, and it never speaks for the
/// second — a lost connection says only that we stopped knowing.
enum AgentConnectionState: Equatable {
    /// No run is being observed.
    case idle
    /// The endpoint is answering.
    case connected
    /// A poll failed; we are backing off and will try again. `attempt` is 1-based.
    case reconnecting(attempt: Int, nextRetryIn: TimeInterval)
    /// We gave up polling. The run itself is *not* known to have ended.
    case lost(AgentContactLoss)

    var isLost: Bool {
        if case .lost = self { return true }
        return false
    }
}

/// Why we stopped polling a run. Each case is a fact about the *endpoint*, never about the run.
enum AgentContactLoss: Equatable {
    /// Repeated transport failures; `attempts` polls were made before giving up.
    case network(attempts: Int)
    /// The endpoint rejected our credentials (401/403). Retrying the same token cannot help.
    case auth(status: Int)
    /// A non-retryable HTTP answer (e.g. 404 — the run id is gone as far as this endpoint knows).
    case endpoint(status: Int)
    /// The endpoint kept answering with a status value we do not recognise. The raw label is
    /// carried (bounded and sanitised) so the user hears what their endpoint actually said.
    case unknownStatus(String)
    /// No status endpoint is configured, so the run can never be followed.
    case noStatusEndpoint

    /// Case name only — safe for the privacy log (no payload, no endpoint text).
    var tokenName: String {
        switch self {
        case .network:         return "network"
        case .auth:            return "auth"
        case .endpoint:        return "endpoint"
        case .unknownStatus:   return "unknown_status"
        case .noStatusEndpoint: return "no_status_endpoint"
        }
    }
}
