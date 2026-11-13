import Foundation

// MARK: - What the router would do with one step

/// What the router's policy ladder would decide for one plan step, worked out before anything runs
/// (Plan LP §1).
///
/// Produced by the same evaluation the dispatch point runs — `ToolAuthorizationPolicy.evaluate`
/// with the step's exact arguments, after the same feature, expert and egress screens — so which
/// steps ask is never a second opinion. `PlanValidator.requiresConfirmation` is deliberately not
/// consulted: it is a reversibility flag, not the authorization ladder.
enum PlanStepPreflight: Equatable {
    /// The step would stop for the wearer. `summary` is the confirmation copy the call would have
    /// shown; `binding` is what a yes to it must be bound to.
    case confirm(summary: String, binding: ApprovalBinding)
    /// The step would run without asking, or would be refused or held without asking — either
    /// way nothing to put in front of the wearer.
    case noAsk
}

/// A plan-scoped grant handed to one step as it is dispatched. The router redeems `nonce` only
/// when the call presents the same `scope` (the plan run) it was issued under.
struct PlanStepGrant: Sendable, Equatable {
    let nonce: String
    let scope: String
}

/// Carries the step's grant from `PlanExecutor` to the router's confirmation branch for exactly
/// one root call. Task-local, so nothing outside the step's own dispatch can see it.
enum PlanApprovalScope {
    @TaskLocal static var stepGrant: PlanStepGrant?
}

// MARK: - One ask for the plan

/// The confirmable steps of a validated plan, gathered into one ask (Plan LP §1). Pure.
struct PlanApproval: Equatable {
    struct Item: Equatable {
        /// Zero-based index into the plan's steps.
        let stepIndex: Int
        /// The confirmation copy the step's own call would have shown.
        let summary: String
        let binding: ApprovalBinding
    }

    let items: [Item]
    /// The second of two halves (Risks: a long plan asks in two halves).
    let isSecondHalf: Bool

    /// How long a plan's grants stay spendable at most. The grants live as long as the plan runs
    /// and are revoked when it ends; this ceiling only bounds a run that hangs. Five minutes covers
    /// the default step budget (8) at the router's default 30 s per step with room to spare.
    static let grantLifetimeCeiling: TimeInterval = 300

    /// More confirmable steps than this and the plan asks in two halves, so no single yes covers
    /// more than a person can hold in one sentence.
    static let maxItemsPerAsk = 3

    /// What the plan's ask looks like.
    enum Shape: Equatable {
        /// Nothing in the plan asks.
        case none
        /// Exactly one step asks: it asks at its own call, exactly as before.
        case atTheCall
        /// One ask, or two halves asked one after the other before any step runs.
        case asks([PlanApproval])
    }

    /// Gather the steps that would ask into the plan's ask. `preflights` is one entry per step,
    /// in plan order.
    static func shape(for preflights: [PlanStepPreflight]) -> Shape {
        let items: [Item] = preflights.enumerated().compactMap { index, preflight in
            guard case .confirm(let summary, let binding) = preflight else { return nil }
            return Item(stepIndex: index, summary: summary, binding: binding)
        }
        switch items.count {
        case 0: return .none
        case 1: return .atTheCall
        case ...maxItemsPerAsk: return .asks([PlanApproval(items: items, isSecondHalf: false)])
        default:
            let split = (items.count + 1) / 2
            return .asks([PlanApproval(items: Array(items[..<split]), isSecondHalf: false),
                          PlanApproval(items: Array(items[split...]), isSecondHalf: true)])
        }
    }

    /// The spoken ask: "I'll send a message to Sam and lock the front door. OK?"
    var spokenPrompt: String { PlanApprovalPhraser.sentence(items.map(\.summary), then: isSecondHalf) }

    /// The card: every action, one per line, exactly as each call would have shown it.
    var cardSummary: String { PlanApprovalPhraser.card(items.map(\.summary)) }
}

/// How a plan's ask came back.
enum PlanApprovalOutcome: Equatable {
    /// A yes: one grant per item, by step index.
    case approved(grants: [Int: PlanStepGrant])
    case declined
    /// Another confirmation is already on screen, so nothing was asked.
    case busy
    /// The wearer has withdrawn consent for the assistant's asks.
    case consentWithdrawn
    /// No confirmation surface is wired; every step fails closed at its own call.
    case unavailable
}

/// The router's half of a plan approval, behind a seam so `AgentRunner` stays testable with a
/// fake. `NativeToolRouter` conforms.
@MainActor
protocol PlanApprovalAuthority: AnyObject {
    /// What the router would decide for this step as it would be dispatched, without dispatching.
    func planPreflight(name: String, args: [String: Any]) -> PlanStepPreflight
    /// Ask the wearer once for every item; on a yes, one grant per item bound exactly as the
    /// step's own call would bind it, scoped to the plan run.
    func requestPlanApproval(_ approval: PlanApproval, scope: String,
                             ttl: TimeInterval) async -> PlanApprovalOutcome
    /// Revoke whatever grants of this plan run were not spent. Returns how many went.
    @discardableResult
    func revokePlanGrants(scope: String) -> Int
}

// MARK: - Words

/// The words of a plan's ask (Plan LP §1). Pure.
enum PlanApprovalPhraser {

    /// "I'll send a message to Sam: “running late” and lock the front door. OK?" Each clause is a
    /// step's own confirmation copy, first letter lowered, trailing punctuation dropped.
    static func sentence(_ summaries: [String], then: Bool = false) -> String {
        let clauses = summaries.map(clause).filter { !$0.isEmpty }
        let opener = then ? "Then I'll" : "I'll"
        return "\(opener) \(joinClauses(clauses)). OK?"
    }

    /// One action per line.
    static func card(_ summaries: [String]) -> String {
        summaries.map { "• \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

    /// What the plan says when the wearer says no: nothing ran.
    static let declinedLine = "Okay, I won't do any of that."
    /// When another question is still on screen, nothing was asked and nothing ran.
    static let busyLine = "I'm still waiting on your answer to something else, so I haven't started that."
    /// When the wearer withdrew consent for the assistant's asks.
    static let consentWithdrawnLine = "You've turned off my asking for approvals, so I haven't started that."

    static func clause(_ summary: String) -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!".contains(last) { text.removeLast() }
        return lowerFirst(text)
    }

    /// "Send" → "send", but "TV on" and "iMessage" keep their capitals.
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let rest = text.dropFirst()
        if let second = rest.first, second.isUppercase { return text }
        return first.lowercased() + rest
    }

    /// "a, b and c".
    static func joinClauses(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
