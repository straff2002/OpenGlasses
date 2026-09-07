import Foundation

/// The voice verbs that move a task: "do it", "skip that", "later", "done", "add a task".
///
/// Voice verbs are ambiguous — "done" could close a task or a procedure step — so this resolves
/// against the active task first, falls back to the latest recommendation when nothing is running,
/// and **says out loud what it changed**. A confirmation the technician can contradict is the only
/// safe way to run a state machine by voice.
@MainActor
final class TaskTool: NativeTool {
    let name = "task"
    let description = """
    Move a task on the active Field Assist job when the technician decides something. Pass 'verb': \
    'accept' ("do it", "yes, do that") starts the recommendation and its procedure if it names \
    one; 'decline' ("skip that", "no") and 'defer' ("later", "next visit") keep it on the record as \
    recommended-but-not-done; 'start' picks up a task accepted earlier; 'done' closes the task the \
    technician is working on, with 'completion_note' for what they said they did ("replaced the \
    ignitor, 47 ohms before"); 'abandon' gives one up; 'add' with 'title' records work the \
    technician did that nobody recommended ("add a task: cleaned the condensate trap") and starts \
    it immediately. Omit 'task_id' and the verb applies to the task in progress, or to the latest \
    recommendation when none is running. Pass 'read_back' to hear the whole job so far. Repeat the \
    confirmation this returns to the technician. Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "verb": [
                "type": "string",
                "enum": ["accept", "decline", "defer", "start", "done", "abandon", "add"],
                "description": "What the technician decided."
            ],
            "task_id": [
                "type": "string",
                "description": "The task to move. Omit to use the task in progress, or the latest recommendation."
            ],
            "title": [
                "type": "string",
                "description": "For 'add': what the technician did or is doing."
            ],
            "why": [
                "type": "string",
                "description": "For 'add': why, when the technician says."
            ],
            "completion_note": [
                "type": "string",
                "description": "For 'done' / 'abandon': what the technician said they did, in their words."
            ],
            "read_back": [
                "type": "boolean",
                "description": "Read the whole job back: equipment, tasks by status with their evidence, parts, pages verified and time."
            ]
        ],
        "required": [] as [String]
    ]

    /// Session to act on; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?

    init(sessionService: FieldSessionService? = nil) {
        self.injectedSession = sessionService
    }

    private var session: FieldSessionService { injectedSession ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard session.activeSession != nil else {
            return "No active Field Assist session. Start a session before recording work."
        }

        if (args["read_back"] as? Bool) == true, args["verb"] == nil {
            return readBack()
        }

        let verb = (args["verb"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch verb {
        case "add":
            return add(args: args)
        case "accept", "decline", "defer":
            return decide(verb: verb!, args: args)
        case "start":
            return start(args: args)
        case "done", "abandon":
            return close(verb: verb!, args: args)
        case nil, "":
            return "Say what to do with the task: accept, decline, defer, start, done, abandon, or add."
        default:
            return "'\(verb!)' is not a task verb. Use accept, decline, defer, start, done, abandon, or add."
        }
    }

    // MARK: - Verbs

    private func add(args: [String: Any]) -> String {
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return "Say what the task is — \"add a task: cleaned the condensate trap\"."
        }
        do {
            let task = try session.addOperatorTask(
                title: title,
                why: (args["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            return "Added \(task.title) to the job and started it. Nobody recommended this one — "
                + "it is recorded as the technician's own. Say 'done' when it is finished."
        } catch {
            return error.localizedDescription
        }
    }

    private func decide(verb: String, args: [String: Any]) -> String {
        guard let task = resolveTask(args: args, preferringActive: false) else {
            return "There is no recommendation waiting on this job. Name the task, or ask me to look something up first."
        }
        let decision: FieldSessionService.TaskDecision = verb == "accept" ? .accept
            : (verb == "decline" ? .decline : .defer_)
        do {
            let result = try session.decideTask(id: task.id, decision: decision)
            switch decision {
            case .decline:
                return "Declined \(result.task.title). It stays on the record as recommended and not done."
            case .defer_:
                return "Deferred \(result.task.title). It stays on the record for the next visit."
            case .accept:
                var lines = ["Accepted \(result.task.title)."]
                if let step = result.procedureStep {
                    lines.append("Starting \(result.task.procedureId ?? "the procedure"): \(step.title). \(step.instruction)")
                    lines.append("The procedure's outcome will close this task.")
                } else if let problem = result.procedureProblem {
                    lines.append("The procedure did not start: \(problem) Work through it yourself and say 'done' when finished.")
                } else if result.task.status == .accepted {
                    lines.append("Another task is still in progress, so this one is queued. Say 'start' when you get to it.")
                } else {
                    lines.append("It is the task in progress now — readings, photos and pages go on it. Say 'done' when finished.")
                }
                if let note = result.task.safetyNote, !note.isEmpty {
                    lines.insert("Safety first: \(note).", at: 1)
                }
                return lines.joined(separator: " ")
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func start(args: [String: Any]) -> String {
        let named = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (named?.isEmpty == false)
            ? resolveTask(args: args, preferringActive: false)
            : (session.activeSession?.nextStartable ?? session.latestRecommendation)
        guard let task = resolved else {
            return "There is nothing waiting to start on this job."
        }
        do {
            let started = try session.startTask(id: task.id)
            return "Started \(started.title). Readings, photos and pages go on it from here."
        } catch {
            return error.localizedDescription
        }
    }

    private func close(verb: String, args: [String: Any]) -> String {
        guard let task = resolveTask(args: args, preferringActive: true) else {
            return "Nothing is in progress on this job, so there is nothing to close. "
                + "Say \"add a task: …\" to record what you did."
        }
        let note = (args["completion_note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let closed = verb == "done"
                ? try session.completeTask(id: task.id, note: note)
                : try session.abandonTask(id: task.id, note: note)
            var line = verb == "done" ? "Closed \(closed.title) as done." : "Marked \(closed.title) abandoned."
            if let note, !note.isEmpty { line += " Noted: \(note)." }
            if !closed.parts.isEmpty {
                line += " Parts on it: " + closed.parts.map(\.number).joined(separator: ", ") + "."
            }
            return line
        } catch {
            return error.localizedDescription
        }
    }

    private func readBack() -> String {
        guard let record = session.workRecord() else {
            return "No active Field Assist session."
        }
        return record.summary
    }

    // MARK: - Resolution

    /// "The latest recommendation" when the technician names nothing: the task in progress for a
    /// closing verb, the newest undecided recommendation for a deciding one.
    private func resolveTask(args: [String: Any], preferringActive: Bool) -> FieldSession.Task? {
        if let id = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return session.task(id: id) ?? session.activeSession?.tasks.first {
                $0.title.lowercased() == id.lowercased()
            }
        }
        if preferringActive {
            return session.activeTask ?? session.latestRecommendation
        }
        return session.latestRecommendation ?? session.activeTask
    }
}
