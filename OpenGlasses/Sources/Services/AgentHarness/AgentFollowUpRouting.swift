import Foundation

/// Whether a harness can take a follow-up message into a run that is already going (Plan LP §3).
enum AgentFollowUpSupport: String, Equatable, Sendable {
    /// The harness has a channel for one and has said so.
    case accepts
    /// The harness has no such channel.
    case unsupported
    /// Nobody has said. Treated as `unsupported`: an unconfirmed channel is not one to send the
    /// wearer's words down.
    case unknown
}

/// Where a remote job stands, as far as a new `start` cares.
enum AgentRunPhase: Equatable, Sendable {
    /// No job, a finished one, or one we have lost contact with and said so.
    case idle
    /// Working.
    case running
    /// Waiting on the wearer's answer to its question.
    case awaitingInput
}

/// What a new `start` does while a remote job runs (Plan LP §3). Pure.
///
/// Before this, a second `start` silently replaced the running job. Now it is either a correction
/// to that job — when the harness can take one while it is working — or a question.
enum AgentFollowUpRouting {
    enum Route: Equatable, Sendable {
        /// Nothing is running: start the new job.
        case startFresh
        /// Pass the words to the running job as a follow-up.
        case steer
        /// Ask whether to stop the running job and start this one.
        case askToReplace
    }

    static func route(phase: AgentRunPhase, support: AgentFollowUpSupport) -> Route {
        switch phase {
        case .idle:
            return .startFresh
        case .awaitingInput:
            // The job is waiting on an answer; new words sent into it could be taken for one.
            return .askToReplace
        case .running:
            return support == .accepts ? .steer : .askToReplace
        }
    }

    /// The spoken ask when a job is still going.
    static let replacePrompt = "That job's still running. Stop it and start this one instead?"
    /// The card's line for the same ask.
    static let replaceSummary = "stop the job that's running and start this one instead"
}
