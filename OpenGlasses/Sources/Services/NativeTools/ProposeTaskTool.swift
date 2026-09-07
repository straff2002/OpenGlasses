import Foundation

/// A recommendation as a structured act rather than a sentence.
///
/// Recommending in prose leaves nothing behind: the technician hears it, does or does not do it,
/// and the record of the visit cannot say which. This makes the recommendation an object the
/// technician decides on by voice, so what was suggested and what was decided are both on the job.
///
/// Two refusals are the point of the tool. Without a citation there is no recommendation — the
/// model may only recommend what it can point at in the book. With a procedure the vault does not
/// have there is no recommendation either, because the task would promise to run something that
/// is not there.
@MainActor
final class ProposeTaskTool: NativeTool {
    let name = "propose_task"
    let description = """
    Recommend a piece of work on the active Field Assist job, so the technician can accept or \
    decline it by voice and the record shows what was suggested. Pass 'title' (what to do), \
    'citation' (the manual page or core file the recommendation comes from — REQUIRED; a \
    recommendation you cannot cite is refused), and optionally 'why', 'procedure_id' (a procedure \
    in this vault, which starts when the technician accepts), 'parts' (part numbers, each checked \
    against the vault's parts list and manuals — one that is not found is recorded unverified and \
    you must say so), and 'safety_note'. The task starts as a recommendation and nothing more: use \
    the task tool when the technician says "do it", "skip that" or "later". Recommend once per \
    thing to be done, after you have looked the answer up. Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": [
                "type": "string",
                "description": "What is to be done, in the words the technician will hear back (e.g. 'Check the pressure switch tubing')."
            ],
            "why": [
                "type": "string",
                "description": "Why you are recommending it — the symptom or reading it follows from."
            ],
            "citation": [
                "type": "string",
                "description": "REQUIRED. The source this comes from, exactly as the retrieved passage or vault tool cited it (e.g. 'SLP99UHVK Service Manual, page 39')."
            ],
            "procedure_id": [
                "type": "string",
                "description": "A procedure in this vault to run when the technician accepts. Must exist; otherwise the recommendation is refused."
            ],
            "parts": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Part numbers this work needs, exactly as the manual prints them."
            ],
            "safety_note": [
                "type": "string",
                "description": "The safety step the technician must take first, when this work has one."
            ]
        ],
        "required": ["title", "citation"]
    ]

    /// Session to record against; nil means the shared service. Injectable for tests.
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
            return "No active Field Assist session. Start a session before recommending work."
        }
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return FieldSessionError.taskNeedsTitle.localizedDescription }

        let citation = (args["citation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !citation.isEmpty else {
            return FieldSessionError.recommendationNeedsCitation.localizedDescription
        }

        let parts = session.partsVerifier.verify(all: Self.partNumbers(args["parts"]))
        let procedureId = (args["procedure_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let task: FieldSession.Task
        do {
            task = try session.proposeTask(
                title: title,
                why: (args["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                procedureId: procedureId,
                parts: parts,
                safetyNote: (args["safety_note"] as? String),
                citation: citation)
        } catch let error as FieldSessionError {
            if case .unknownProcedure(let id) = error {
                let available = session.availableProcedures()
                let list = available.isEmpty ? "none" : available.joined(separator: "; ")
                return "There is no procedure '\(id)' in this vault, so the recommendation was not "
                    + "recorded. Recommend it without a procedure, or use one of these: \(list)."
            }
            return error.localizedDescription
        }

        var lines = ["I recommend \(task.title). Say 'do it' to add it to the job."]
        if let note = task.safetyNote, !note.isEmpty { lines.append("Safety first: \(note).") }
        if !task.parts.isEmpty {
            lines.append("Parts: " + task.parts.map(\.summary).joined(separator: "; ") + ".")
        }
        if let unverified = PartsVerifier.unverifiedNote(task.parts) { lines.append(unverified) }
        lines.append("Recorded as a recommendation (task \(task.id)). Source: \(citation).")
        return lines.joined(separator: "\n")
    }

    /// Part numbers from an array, or from a single comma-separated string — models send both.
    static func partNumbers(_ raw: Any?) -> [String] {
        if let list = raw as? [Any] {
            return list.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let text = raw as? String {
            return text.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}
