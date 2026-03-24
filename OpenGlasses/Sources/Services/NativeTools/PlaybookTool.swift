import Foundation

/// Native tool for managing guided task playbooks.
/// The agent uses this to navigate through step-by-step procedures,
/// add notes, and create new playbooks from scanned documents.
struct PlaybookTool: NativeTool {
    var playbookStore: PlaybookStore?

    let name = "playbook"
    let description = "Manage guided task playbooks — step-by-step procedures the agent walks the user through hands-free. Use 'create' to save recipes, checklists, repair procedures, or any multi-step workflow the user asks for — these are saved for later reuse. Meeting agendas are auto-imported from calendar events. Actions: list, start, status, next, back, add_note, finish, create."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action to perform: list, start, status, next, back, add_note, finish, create",
                "enum": ["list", "start", "status", "next", "back", "add_note", "finish", "create"]
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
                "description": "Array of step titles (for create action)",
                "items": ["type": "string"]
            ],
            "reference_text": [
                "type": "string",
                "description": "Reference material/manual text for RAG context (for create action)"
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

        default:
            return "Unknown action '\(action)'. Use: list, start, status, next, back, add_note, finish, create."
        }
    }
}
