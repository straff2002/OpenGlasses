import CryptoKit
import Foundation

// MARK: - The seam every feeder calls (Plan IW P1)

/// Where the feeders put what they saw. One small protocol so the router, the journal sink, the
/// scheduler and the notification queue can be tested with a fake; production writes to
/// `ActivityStore`.
@MainActor
protocol ActivityRecording: AnyObject {
    func record(_ entry: ActivityEntry)
    /// The operation journal settled `operationID`.
    func settle(operationID: String, outcome: ActivityOutcome)
    /// A call held for the wearer reached the authorization boundary again and was answered
    /// (Plan LE §3): the newest held entry still waiting with this `holdKey` takes the answer.
    func resolveHold(key: String, resolution: ActivityResolution, at date: Date)
}

extension ActivityRecording {
    /// A recorder with no trail to answer leaves holds alone.
    func resolveHold(key: String, resolution: ActivityResolution, at date: Date) {}
}

/// The production recorder: a thin pass-through to the store.
@MainActor
final class ActivityRecorder: ActivityRecording {
    private let store: ActivityStore

    init(store: ActivityStore) {
        self.store = store
    }

    func record(_ entry: ActivityEntry) { store.append(entry) }

    func settle(operationID: String, outcome: ActivityOutcome) {
        store.settle(operationID: operationID, outcome: outcome)
    }

    func resolveHold(key: String, resolution: ActivityResolution, at date: Date) {
        store.resolveHold(key: key, resolution: resolution, at: date)
    }
}

/// What a held call was held *for*, as one opaque key (Plan LE P1): the dispatch seam, the tool,
/// the definition and the canonical digest of the arguments — the same fields an approval is bound
/// to (`ApprovalBinding`) minus the approval session, which rotates. A digest of digests: nothing
/// of the arguments can be read back out of it, so it is safe on the trail.
///
/// **Why not the operation id.** A held call is turned away, never dispatched; when the wearer is
/// back, the model asks again with a fresh invocation id, so the id the hold was written under is
/// never seen a second time. The same call — same tool, same arguments — is what comes back, and
/// that is what this key names.
enum ActivityHoldKey {
    static func make(seamIdentity: String, toolName: String, definitionDigest: String,
                     argumentsDigest: String) -> String {
        let material = [seamIdentity, toolName, definitionDigest, argumentsDigest].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Context that rides with a call

/// One step of an agent plan, as the plan executor hands it to the router.
struct PlannedStepContext: Sendable, Equatable {
    /// The plan's goal — the trail row's detail.
    let goal: String
    let step: PlannedStepRecord
}

/// A goal step the wearer asked the assistant to act on — "Do it" on the Goals screen (Plan IW P2).
/// The row the router writes then names the goal and the step, so the step's evidence and the
/// Activity screen's link back to the goal both have something to follow.
struct GoalStepContext: Sendable, Equatable {
    let goalID: UUID
    let stepID: UUID
}

/// What the router cannot see from the call itself: that it is running inside a scheduled task, or
/// as one step of a plan. Task-locals, like `ToolInvocationScope`, so neither the provider wires
/// nor `NativeTool.execute(args:)` change shape to carry them.
enum ActivityScope {
    /// The name of the scheduled task whose run this call belongs to.
    @TaskLocal static var scheduledTask: String?
    /// The plan step this call is.
    @TaskLocal static var plannedStep: PlannedStepContext?
    /// The goal step this call acts on, when the wearer started it from that step.
    @TaskLocal static var goalStep: GoalStepContext?
}

// MARK: - Turning a hook's facts into a row

/// How the router's authorization ladder treated a call, as the trail records it.
enum ActivityToolGate: Equatable {
    /// It was dispatched. `approvalSummary` is the line the wearer approved, when they were asked.
    case ran(approvalSummary: String?)
    /// The wearer was asked and said no.
    case declined
    /// Stopped before it ran; `code` is a stable reason code, never free text.
    case refused(code: String)
    /// Held until the wearer is back to approve it.
    case held
}

/// What became of a scheduled run, as the trail records it.
enum ScheduledRunResult: Equatable {
    case reported(String)
    case nothingToReport
    case failed
}

/// Pure builders: one function per feeder, each a fact in and at most one entry out. Nothing here
/// sees the wearer's words — titles are fixed templates, and the detail is the tool's own approval
/// line, the plan's goal, or a result the assistant produced.
enum ActivityFeed {

    /// Reason codes for the stops that are not a `ToolRefusalReason`.
    enum RefusalCode {
        static let declined = "declined"
        static let blockedBySafety = "blocked_by_safety"
        static let noConfirmation = "no_confirmation"
        static let consentWithdrawn = "consent_withdrawn"
    }

    /// The entry for one routed call, or nil when it only read (decision 4: reads are not
    /// recorded, in a plan or out of one).
    static func toolCall(tool: String, actionKey: String?, effectClass: ToolEffectClass,
                         gate: ActivityToolGate, outcome: ToolExecutionOutcome,
                         invocationOrigin: ToolInvocationOrigin,
                         scheduledTask: String?, plannedStep: PlannedStepContext?,
                         operationID: String, jobThreadID: String?,
                         goalStep: GoalStepContext? = nil, holdKey: String? = nil,
                         id: UUID = UUID(), at: Date) -> ActivityEntry? {
        let origin: ActivityOrigin
        if scheduledTask != nil {
            origin = .scheduled
        } else if plannedStep != nil {
            origin = .agent
        } else {
            origin = Self.origin(for: invocationOrigin)
        }
        let linkRefs = (jobThreadID.map { [ActivityRef.thread($0)] } ?? [])
            + (goalStep.map { [ActivityRef.goal($0.goalID.uuidString.lowercased())] } ?? [])
        let goalID = goalStep?.goalID
        let stepID = goalStep?.stepID
        let readable = readableName(tool)

        switch gate {
        case .ran(let approvalSummary):
            guard let words = ActivityTitler.title(tool: tool, actionKey: actionKey,
                                                   approvalSummary: approvalSummary,
                                                   effectClass: effectClass) else { return nil }
            return ActivityEntry(
                id: id, at: at, kind: plannedStep == nil ? .action : .plannedStep,
                title: words.title, detail: plannedStep?.goal ?? words.detail, tool: tool,
                goalID: goalID, stepID: stepID,
                authorisation: scheduledTask == nil ? .asked : .scheduled, origin: origin,
                outcome: self.outcome(of: outcome),
                refs: [.operation(operationID)] + linkRefs)

        case .declined:
            return ActivityEntry(id: id, at: at, kind: .refused,
                                 title: "Didn't use the \(readable) tool: you said no", tool: tool,
                                 goalID: goalID, stepID: stepID,
                                 authorisation: .refused(reason: RefusalCode.declined), origin: origin,
                                 outcome: .failed, refs: linkRefs)

        case .refused(let code):
            return ActivityEntry(id: id, at: at, kind: .refused,
                                 title: "Didn't use the \(readable) tool: it wasn't allowed", tool: tool,
                                 goalID: goalID, stepID: stepID,
                                 authorisation: .refused(reason: code), origin: origin,
                                 outcome: .failed, refs: linkRefs)

        case .held:
            return ActivityEntry(id: id, at: at, kind: .held,
                                 title: "Your OK to use the \(readable) tool", tool: tool,
                                 goalID: goalID, stepID: stepID,
                                 authorisation: .heldForYou, origin: origin,
                                 outcome: .waitingOnYou, refs: linkRefs, holdKey: holdKey)
        }
    }

    /// One scheduled run (the run history the scheduler owes). Recorded whether or not its result
    /// was spoken.
    static func scheduledRun(taskName: String, result: ScheduledRunResult,
                             id: UUID = UUID(), at: Date) -> ActivityEntry {
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String?
        let outcome: ActivityOutcome
        switch result {
        case .reported(let text):
            detail = lead(of: text)
            outcome = .done
        case .nothingToReport:
            detail = nil
            outcome = .done
        case .failed:
            detail = nil
            outcome = .failed
        }
        return ActivityEntry(id: id, at: at, kind: .scheduledRun,
                             title: name.isEmpty ? "Ran a scheduled task" : "Ran \(name)",
                             detail: detail, authorisation: .scheduled, origin: .scheduled,
                             outcome: outcome)
    }

    /// One goal check-in (Plan IW P2). The title is a fixed sentence and the goal travels as a
    /// link — never its title, which is the wearer's words; the Activity screen looks it up.
    static func goalCheckIn(goalID: UUID, spoken: Bool, id: UUID = UUID(), at: Date) -> ActivityEntry {
        ActivityEntry(id: id, at: at, kind: .scheduledRun, title: "Checked in on a goal",
                      detail: spoken ? "Said it out loud" : "Left it in your digest",
                      goalID: goalID, authorisation: .scheduled, origin: .scheduled, outcome: .done,
                      refs: [.goal(goalID.uuidString.lowercased())])
    }

    /// Something spoken to the wearer straight away, which therefore never reached the digest.
    static func toldYou(message: String, source: String, id: UUID = UUID(), at: Date) -> ActivityEntry {
        let origin = notificationOrigin(source)
        return ActivityEntry(id: id, at: at, kind: .toldYou, title: "Passed on an update",
                             detail: lead(of: message),
                             authorisation: origin == .scheduled ? .scheduled : .asked,
                             origin: origin, outcome: .done)
    }

    // MARK: Pieces

    static func outcome(of outcome: ToolExecutionOutcome) -> ActivityOutcome {
        switch outcome {
        case .completed: return .done
        case .outcomeUnknown: return .uncertain
        case .rejected, .failedBeforeExecution: return .failed
        }
    }

    /// The journal's word for an operation, as the trail's. Nil while it is still in flight.
    static func outcome(of state: OperationState) -> ActivityOutcome? {
        switch state {
        case .started: return nil
        case .completed: return .done
        case .failed: return .failed
        case .unknown: return .uncertain
        }
    }

    static func origin(for origin: ToolInvocationOrigin) -> ActivityOrigin {
        switch origin {
        case .model, .user, .skillPack, .siriAction: return .wearer
        case .appInternal: return .agent
        }
    }

    /// The queue's `source` is a caller's label: a scheduled task's result, the gateway, or the
    /// agent's own.
    static func notificationOrigin(_ source: String) -> ActivityOrigin {
        let label = source.lowercased()
        if label == "agent task" { return .scheduled }
        if label.hasPrefix("openclaw") { return .remote(source: "openclaw") }
        return .agent
    }

    /// "send message" for `send_message` — a name a sentence can carry.
    static func readableName(_ tool: String) -> String {
        let words = tool.replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? "unnamed" : words
    }

    /// The first 200 characters of a result, on one line.
    static func lead(of text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return ActivityEntry.clamp(collapsed, to: ActivityEntry.detailLength)
    }
}
