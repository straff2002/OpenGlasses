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
    'repeat' to re-read the current step, 'status' for the current step, 'complete' to finish. \
    The current step and its branch choices are provided in the system prompt — use those choice ids.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'list', 'start', 'next', 'previous', 'repeat', 'status', or 'complete'."
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
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistEnabled else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let action = (args["action"] as? String)?.lowercased() else {
            return "No action specified. Use 'list', 'start', 'next', 'previous', 'repeat', 'status', or 'complete'."
        }

        let service = FieldSessionService.shared
        guard service.activeSession != nil || action == "list" else {
            return "No active Field Assist session. Start a session before running a procedure."
        }

        switch action {
        case "list":   return listProcedures(service)
        case "start":  return startProcedure(args: args, service: service)
        case "next":   return advance(args: args, service: service)
        case "previous", "back": return goBack(service)
        case "repeat": return repeatStep(service)
        case "status": return status(service)
        case "complete", "finish": return complete(args: args, service: service)
        default:
            return "Unknown action '\(action)'. Use 'list', 'start', 'next', 'previous', 'repeat', 'status', or 'complete'."
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
            return "Started procedure '\(service.activeProcedureTitle ?? id)'.\n\n" + present(step)
        } catch {
            return "Could not start procedure: \(error.localizedDescription)"
        }
    }

    private func advance(args: [String: Any], service: FieldSessionService) -> String {
        let choice = (args["choice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        do {
            switch try service.advanceProcedure(choice: choice) {
            case .moved(let step):
                return present(step)
            case .completed(let outcome):
                return "Procedure complete. Outcome: \(outcome)."
            }
        } catch {
            return "Could not advance: \(error.localizedDescription)"
        }
    }

    private func goBack(_ service: FieldSessionService) -> String {
        do { return "Stepped back.\n\n" + present(try service.procedureBack()) }
        catch { return "Could not step back: \(error.localizedDescription)" }
    }

    private func repeatStep(_ service: FieldSessionService) -> String {
        do { return present(try service.procedureRepeat()) }
        catch { return "Could not repeat: \(error.localizedDescription)" }
    }

    private func status(_ service: FieldSessionService) -> String {
        guard let step = service.activeProcedureStep else {
            return "No procedure is currently running."
        }
        return "Running '\(service.activeProcedureTitle ?? "")'.\n\n" + present(step)
    }

    private func complete(args: [String: Any], service: FieldSessionService) -> String {
        let outcome = (args["outcome"] as? String) ?? "resolved"
        do {
            try service.completeProcedure(outcome: outcome)
            return "Procedure marked '\(outcome)'."
        } catch {
            return "Could not complete: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatting

    /// Render a step for the tool result. Branch choices are also in the system prompt, but
    /// echoing them here keeps the model aligned even mid-turn.
    private func present(_ step: Procedure.Step) -> String {
        var lines: [String] = []
        if let note = step.safetyNote { lines.append("⚠️ SAFETY: \(note)") }
        lines.append("Step — \(step.title)")
        lines.append(step.instruction)
        if step.terminal {
            lines.append("(Terminal step — call 'complete' with outcome '\(step.outcome ?? "resolved")'.)")
        } else if step.branches.isEmpty {
            lines.append("(Call 'next' to continue.)")
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
