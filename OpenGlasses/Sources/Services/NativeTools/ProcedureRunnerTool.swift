import Foundation

/// Native tool that drives a Field Assist procedure through its branching steps.
///
/// Procedures are diagnostic/task flows shipped in the active vault. The active step (and the
/// branch choices available) are injected into the system prompt by `FieldSessionService`, so the
/// model should advance using the `choice` ids listed there. Requires an active Field Assist session.
@MainActor
final class ProcedureRunnerTool: NativeTool {
    let name = "procedure_runner"
    let description = """
    Run a guided, step-by-step Field Assist procedure (diagnostics, checklists) within an active \
    session. Actions: 'list' to see available procedures, 'start' to begin one, 'next' to advance \
    (pass 'choice' to pick a branch when the active step offers choices), 'previous' to step back, \
    'repeat' to re-read the current step, 'status' for the current step, 'complete' to finish, \
    'answer' to give a step's typed answer, 'override' to take another route than a step's rule. \
    When a step takes an answer (a reading, a choice, yes or no, a code, photos), call 'answer' with \
    'value' set to exactly what the technician said; the app reads and checks it, and on a step whose \
    route follows from the answer the app decides the route, so call 'next' with no choice (a \
    choice that disagrees with the rule is refused). A critical spoken answer is read back: say the \
    line you get, and call 'answer' with 'confirmed' true once they agree. An out-of-spec critical \
    answer needs a corrective note: ask what was done and pass their words as 'note'. Call \
    'override' only when the technician explicitly tells you to take another route, with 'branch' \
    and their own words as 'reason'; they confirm it, and you never override a rule on your own. \
    Reaching the last step does not finish anything: give the technician its instruction. When the \
    last step asks for a check (a retest), pass 'confirmed' true on 'complete' only after the \
    technician says it passed; without it the fix is recorded and a 'Verify: …' task stays open — \
    never tell them it is resolved before then. Starting a procedure opens a task for it on the \
    current unit. The current step and its branch choices are provided in the system prompt — use \
    those choice ids. Coaching steps an expert sent for the job are listed and started the same way \
    ("walk Sam's steps", "load the coaching"); read each one exactly as written.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'list', 'start', 'next', 'previous', 'repeat', 'status', 'complete', 'answer', or 'override'."
            ],
            "procedure_id": [
                "type": "string",
                "description": "On 'start': the procedure id (e.g. 'low_pressure_diagnostic'). Use 'list' to discover ids."
            ],
            "choice": [
                "type": "string",
                "description": "On 'next': the branch choice id for the current step (as listed in the ACTIVE PROCEDURE prompt section). Omit to follow the default path."
            ],
            "outcome": [
                "type": "string",
                "description": "On 'complete': 'resolved' (default), 'escalated', or 'deferred'."
            ],
            "confirmed": [
                "type": "boolean",
                "description": "On 'complete' at a last step that asks for a check: true only when the technician has said the check passed. On 'answer': true when the technician agrees with the read-back of their answer."
            ],
            "value": [
                "type": "string",
                "description": "On 'answer': exactly what the technician said or typed for the step's answer (\"4.6\", \"four point six\", \"straight\", \"yes\"). Don't round, convert or judge it. Omit on a photo step: the photos taken on the step are attached."
            ],
            "note": [
                "type": "string",
                "description": "On 'answer': a corrective note, what the technician did about an out-of-spec reading, in their words."
            ],
            "branch": [
                "type": "string",
                "description": "On 'override': the branch id the technician told you to take instead of the rule's."
            ],
            "reason": [
                "type": "string",
                "description": "On 'override': the technician's reason, in their own words. Required."
            ]
        ],
        "required": ["action"]
    ]

    /// Session to run against; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?
    /// The running procedure's coaching credit for this call, when it is an expert's coaching.
    private var coaching: Procedure.Coaching?

    init(sessionService: FieldSessionService? = nil) {
        self.injectedSession = sessionService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let action = (args["action"] as? String)?.lowercased() else {
            return "No action specified. Use 'list', 'start', 'next', 'previous', 'repeat', 'status', 'complete', 'answer', or 'override'."
        }

        let service = injectedSession ?? FieldSessionService.shared
        guard service.activeSession != nil || action == "list" else {
            return "No active Field Assist session. Start a session before running a procedure."
        }
        coaching = service.activeProcedureCoaching
        defer { coaching = nil }

        switch action {
        case "list":   return listProcedures(service)
        case "start":  return startProcedure(args: args, service: service)
        case "next":   return advance(args: args, service: service)
        case "previous", "back": return goBack(service)
        case "repeat": return repeatStep(service)
        case "status": return status(service)
        case "complete", "finish": return complete(args: args, service: service)
        case "answer": return answer(args: args, service: service)
        case "override": return override(args: args, service: service)
        default:
            return "Unknown action '\(action)'. Use 'list', 'start', 'next', 'previous', 'repeat', 'status', 'complete', 'answer', or 'override'."
        }
    }

    // MARK: - Actions

    private func listProcedures(_ service: FieldSessionService) -> String {
        let items = service.availableProcedures()
        if items.isEmpty { return "No procedures available in the active vault." }
        return "Available procedures:\n" + items.map { "• \($0)" }.joined(separator: "\n")
    }

    private func startProcedure(args: [String: Any], service: FieldSessionService) -> String {
        guard let id = args["procedure_id"] as? String, !id.isEmpty else {
            return "Specify 'procedure_id'. Use action 'list' to see available procedures."
        }
        do {
            let step = try service.startProcedure(id: id)
            coaching = service.activeProcedureCoaching
            return "Started procedure '\(service.activeProcedureTitle ?? id)'.\n\n" + present(step, service: service)
        } catch {
            return "Could not start procedure: \(error.localizedDescription)"
        }
    }

    private func advance(args: [String: Any], service: FieldSessionService) -> String {
        let choice = (args["choice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        do {
            return describe(try service.advanceProcedure(choice: choice, decidedBy: .assistant), service: service)
        } catch {
            return "Could not advance: \(error.localizedDescription)"
        }
    }

    private func describe(_ transition: ProcedureRunner.Transition, service: FieldSessionService) -> String {
        switch transition {
        case .moved(let step):
            return present(step, service: service)
        case .arrivedAtTerminal(let step):
            // The last step's instruction is the next thing the technician does; nothing is
            // complete yet (Plan GB P3).
            return "Last step.\n\n" + present(step, service: service)
        case .completed(let outcome):
            return "Procedure complete. Outcome: \(outcome)."
        }
    }

    /// Plan MN §3: the step's typed answer, as the model heard it. The app reads and checks it.
    private func answer(args: [String: Any], service: FieldSessionService) -> String {
        let value = args["value"].map { "\($0)" }
        let note = args["note"] as? String
        let confirmed = (args["confirmed"] as? Bool) ?? false
        do {
            let result = try service.answerProcedure(value: value, method: .spoken, note: note, confirmed: confirmed)
            switch result {
            case .recorded(let recorded):
                let spec = recorded.value.specStatus == .out ? " (out of spec)" : (recorded.value.specStatus == .in ? " (in spec)" : "")
                let next = service.activeProcedureStep?.isAppDecided == true
                    ? "Call 'next' with no choice: the route follows from the answer."
                    : "Call 'next' to continue."
                return "Recorded \(recorded.answer.displayLabel): \(recorded.value.display(for: recorded.answer))\(spec). \(next)"
            case .readBack(let line):
                return "Read this back to the technician and wait for them: \"\(line)\" If they agree, call 'answer' "
                    + "with confirmed true; if not, call 'answer' with the value they say now."
            case .needsNote(let line):
                return "Recorded, and it needs a corrective note before the procedure goes on: \(line) Call 'answer' "
                    + "with note set to the technician's words."
            case .askAgain(let line):
                return "Not recorded. \(line)"
            case .notAccepted(let line):
                return line
            }
        } catch {
            return "Could not record the answer: \(error.localizedDescription)"
        }
    }

    /// Plan MN decision 3: the technician's override of a rule, with their reason. Confirmed by
    /// them before it runs (`ToolAuthorizationPolicy`).
    private func override(args: [String: Any], service: FieldSessionService) -> String {
        guard let branch = (args["branch"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return "Specify 'branch': the route the technician told you to take."
        }
        let reason = (args["reason"] as? String) ?? ""
        do {
            return "Overridden on the technician's word; the record flags it.\n\n"
                + describe(try service.overrideProcedure(branch: branch, reason: reason), service: service)
        } catch {
            return "Could not override: \(error.localizedDescription)"
        }
    }

    private func goBack(_ service: FieldSessionService) -> String {
        do { return "Stepped back.\n\n" + present(try service.procedureBack(), service: service) }
        catch { return "Could not step back: \(error.localizedDescription)" }
    }

    private func repeatStep(_ service: FieldSessionService) -> String {
        do { return present(try service.procedureRepeat(), service: service) }
        catch { return "Could not repeat: \(error.localizedDescription)" }
    }

    private func status(_ service: FieldSessionService) -> String {
        guard let step = service.activeProcedureStep else {
            return "No procedure is currently running."
        }
        return "Running '\(service.activeProcedureTitle ?? "")'.\n\n" + present(step, service: service)
    }

    private func complete(args: [String: Any], service: FieldSessionService) -> String {
        let outcome = (args["outcome"] as? String) ?? "resolved"
        let confirmed = (args["confirmed"] as? Bool) ?? false
        do {
            let result = try service.completeProcedure(outcome: outcome, confirmed: confirmed)
            if let open = result.openVerification {
                return "The fix is recorded, and '\(open)' stays open on the job until the technician "
                    + "confirms it. \(VerificationRequirement.notYetVerified)"
            }
            return "Procedure marked '\(result.outcome)'."
        } catch {
            return "Could not complete: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatting

    /// Render a step for the tool result. Branch choices are also in the system prompt, but
    /// echoing them here keeps the model aligned even mid-turn.
    private func present(_ step: Procedure.Step, service: FieldSessionService) -> String {
        // The answer lines are the runner's own (the prompt context uses the same), for the
        // current step only.
        let runner = service.activeProcedureRunner
        let isCurrent = runner?.currentStepId == step.id
        var lines: [String] = []
        if let coaching {
            // An expert's coaching (Plan KM P3): the rule first, then the step exactly as written.
            lines.append(CoachingProcedure.readAsWrittenRule(credit: coaching.credit))
            lines.append(contentsOf: CoachingProcedure.stepLines(step))
        } else {
            if let note = step.safetyNote { lines.append("⚠️ SAFETY: \(note)") }
            lines.append("Step — \(step.title)")
            lines.append(step.instruction)
        }
        if isCurrent, let runner { lines.append(contentsOf: runner.answerGuidance()) }
        if step.needsConfirmation {
            lines.append("(Last step. It needs the technician's confirmation that the check passed: call "
                         + "'complete' with confirmed true once they say so. \(VerificationRequirement.notYetVerified))")
        } else if step.terminal {
            lines.append("(Terminal step — call 'complete' with outcome '\(step.outcome ?? "resolved")'.)")
        } else if step.branches.isEmpty {
            lines.append("(Call 'next' to continue.)")
        } else if step.isAppDecided {
            lines.append("The route follows from the answer: the app decides it. Call 'next' with no choice once the "
                         + "answer is recorded. Routes, for reference:")
            for branch in step.branches {
                lines.append("- \(branch.id): \(branch.condition)")
            }
        } else {
            lines.append("Choices for 'next':")
            for branch in step.branches {
                lines.append("- \(branch.id): \(branch.condition)")
            }
        }
        if !step.citations.isEmpty {
            lines.append("Source: \(step.citations.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
