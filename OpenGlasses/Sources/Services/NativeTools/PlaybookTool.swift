import Foundation

/// Native tool for managing guided task playbooks.
/// The agent uses this to navigate through step-by-step procedures,
/// add notes, and create new playbooks from scanned documents.
struct PlaybookTool: NativeTool {
    var playbookStore: PlaybookStore?

    let name = "playbook"
    let description = """
        Manage guided task playbooks — step-by-step procedures the agent walks the user through hands-free. \
        Supports adaptive replanning: record step results, replan remaining steps on failure, insert/remove \
        steps dynamically, and skip irrelevant steps. Actions: list, start, status, next, back, add_note, \
        finish, create, add_result, replan, insert_step, remove_step, skip.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action to perform",
                "enum": ["list", "start", "status", "next", "back", "add_note", "finish", "create",
                         "add_result", "replan", "insert_step", "remove_step", "skip"]
            ],
            "playbook_id": [
                "type": "string",
                "description": "Playbook ID or name (for start action)"
            ],
            "note": [
                "type": "string",
                "description": "Note text (for add_note action)"
            ],
            "name": [
                "type": "string",
                "description": "Playbook name (for create action)"
            ],
            "steps": [
                "type": "array",
                "description": "Array of step titles (for create and replan actions)",
                "items": ["type": "string"]
            ],
            "reference_text": [
                "type": "string",
                "description": "Reference material/manual text for RAG context (for create action)"
            ],
            "result": [
                "type": "string",
                "description": "Step outcome text (for add_result action)"
            ],
            "success": [
                "type": "boolean",
                "description": "Whether the step succeeded (for add_result action, default true)"
            ],
            "reason": [
                "type": "string",
                "description": "Why replanning is needed (for replan action), or why step is being skipped (for skip action)"
            ],
            "step_title": [
                "type": "string",
                "description": "Title for the new step (for insert_step action)"
            ],
            "step_detail": [
                "type": "string",
                "description": "Detail for the new step (for insert_step action)"
            ],
            "after_step": [
                "type": "integer",
                "description": "Insert after this step number, 1-indexed (for insert_step action). Defaults to current step."
            ],
            "step_index": [
                "type": "integer",
                "description": "Step number to remove, 1-indexed (for remove_step action)"
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let store = playbookStore else {
            return "Playbook system not initialized."
        }

        guard let action = args["action"] as? String else {
            return "Specify an action: list, start, status, next, back, add_note, finish, create"
        }

        switch action {
        case "list":
            let playbooks = await MainActor.run { store.playbooks }
            if playbooks.isEmpty {
                return "No playbooks available. Create one with action 'create'."
            }
            let active = await MainActor.run { store.activeSession?.playbookId }
            var lines = ["Available playbooks:"]
            for pb in playbooks {
                let marker = pb.id == active ? " (ACTIVE)" : ""
                lines.append("- [\(pb.id)] \(pb.name) (\(pb.steps.count) steps)\(marker)")
            }
            return lines.joined(separator: "\n")

        case "start":
            guard let idOrName = args["playbook_id"] as? String ?? args["name"] as? String else {
                return "Provide playbook_id or name to start."
            }
            return await MainActor.run {
                // Try by ID first, then by name
                if store.playbook(byId: idOrName) != nil {
                    return store.startPlaybook(idOrName)
                } else if let pb = store.playbook(byName: idOrName) {
                    return store.startPlaybook(pb.id)
                }
                return "Playbook '\(idOrName)' not found. Use 'list' to see available playbooks."
            }

        case "status":
            return await MainActor.run { store.currentStatus() }

        case "next":
            return await MainActor.run { store.nextStep() }

        case "back":
            return await MainActor.run { store.previousStep() }

        case "add_note":
            guard let note = args["note"] as? String, !note.isEmpty else {
                return "Provide a note to add."
            }
            return await MainActor.run { store.addNoteToCurrentStep(note) }

        case "finish":
            return await MainActor.run { store.finishPlaybook() }

        case "create":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "Provide a name for the new playbook."
            }
            let stepTitles: [String]
            if let titles = args["steps"] as? [String] {
                stepTitles = titles
            } else if let titlesStr = args["steps"] as? String {
                stepTitles = titlesStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                return "Provide steps as an array of step titles."
            }

            let referenceText = args["reference_text"] as? String ?? ""

            let steps = stepTitles.map { PlaybookStep(title: $0) }
            let playbook = Playbook(name: name, steps: steps, referenceText: referenceText)

            await MainActor.run { store.add(playbook) }
            return "Created playbook '\(name)' with \(steps.count) steps."

        // MARK: - Adaptive Replanning Actions

        case "add_result":
            guard let result = args["result"] as? String, !result.isEmpty else {
                return "Provide a result description."
            }
            let success = args["success"] as? Bool ?? true
            return await MainActor.run { store.addResultToCurrentStep(result, success: success) }

        case "replan":
            let reason = args["reason"] as? String ?? "Replanning based on step results"
            let stepTitles: [String]
            if let titles = args["steps"] as? [String] {
                stepTitles = titles
            } else if let titlesStr = args["steps"] as? String {
                stepTitles = titlesStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                return "Provide new steps as an array of step titles for the replan."
            }
            let newSteps = stepTitles.map { PlaybookStep(title: $0) }
            NSLog("[PlaybookTool] Replanning: %@ — %d new steps", reason, newSteps.count)
            return await MainActor.run { store.replaceRemainingSteps(newSteps) }

        case "insert_step":
            guard let title = args["step_title"] as? String, !title.isEmpty else {
                return "Provide step_title for the new step."
            }
            let detail = args["step_detail"] as? String ?? ""
            let afterStep: Int
            if let idx = args["after_step"] as? Int {
                afterStep = idx - 1 // Convert 1-indexed to 0-indexed
            } else {
                // Default: insert after current step
                let currentIdx = await MainActor.run { store.activeSession?.currentStepIndex ?? 0 }
                afterStep = currentIdx
            }
            let step = PlaybookStep(title: title, detail: detail)
            return await MainActor.run { store.insertSteps([step], after: afterStep) }

        case "remove_step":
            guard let stepNum = args["step_index"] as? Int else {
                return "Provide step_index (1-indexed) of the step to remove."
            }
            return await MainActor.run { store.removeStep(at: stepNum - 1) } // Convert 1-indexed to 0-indexed

        case "skip":
            let reason = args["reason"] as? String ?? "Skipped by agent"
            return await MainActor.run { store.skipCurrentStep(reason: reason) }

        default:
            return "Unknown action '\(action)'. Use: list, start, status, next, back, add_note, finish, create, add_result, replan, insert_step, remove_step, skip."
        }
    }
}
