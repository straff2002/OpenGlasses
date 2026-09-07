import Foundation

/// What base is being asked for, and what base said back.
///
/// A request may stand on its own: a stock check goes out before anybody knows whether the repair
/// is happening, so it is tagged to the job rather than forced under a task. Every number is
/// checked against the vault's parts list and its manuals first — base validates a number that
/// came from the book, not one that fell out of a misheard sentence — and a number nothing knows
/// is recorded unverified and said out loud as unverified.
///
/// Base's answer is **reported, never acted on**: recording it attaches text to the request and
/// changes no task and no recommendation.
@MainActor
final class PartsRequestTool: NativeTool {
    let name = "parts_request"
    let description = """
    Ask base for a part on the active Field Assist job, or record base's reply. Pass 'part' (the \
    number exactly as the manual or the label prints it) with 'quantity', optionally 'task_id' to \
    tie it to a task, 'urgency' (routine, today, emergency) and 'on_van' when the technician \
    already has one. The number is checked against the vault's parts list and its manuals and the \
    page it was found on is recorded; a number that is not there is recorded unverified and you \
    must tell the technician so. A request does not need a task — a stock check can go out before \
    the repair is decided. To record what base replied, pass 'answer' with the text they sent (and \
    'part' or 'request_id' to say which request it answers): that is filed against the request and \
    read to the technician, and it never changes a task or a recommendation by itself. Requires an \
    active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "part": [
                "type": "string",
                "description": "The part number, exactly as the manual or the label prints it (e.g. '14T65')."
            ],
            "quantity": [
                "type": "integer",
                "description": "How many. Defaults to 1."
            ],
            "task_id": [
                "type": "string",
                "description": "The task this part is for, when it is for one."
            ],
            "urgency": [
                "type": "string",
                "enum": ["routine", "today", "emergency"],
                "description": "How soon it is needed. Defaults to routine."
            ],
            "on_van": [
                "type": "boolean",
                "description": "True when the technician already has one on the van and this is a replacement for stock."
            ],
            "answer": [
                "type": "string",
                "description": "Base's reply, verbatim. Recording it files the text against the request and nothing else."
            ],
            "request_id": [
                "type": "string",
                "description": "Which request the answer is for. Omit to use the most recent request for that part."
            ]
        ],
        "required": [] as [String]
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
            return "No active Field Assist session. Start a session before requesting parts."
        }

        let part = (args["part"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let answer = (args["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !answer.isEmpty {
            return record(answer: answer,
                          requestId: (args["request_id"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          part: part)
        }

        guard let part, !part.isEmpty else {
            return "Name the part number to request, or pass 'answer' to record what base replied."
        }

        let verified = session.verifyPart(part)
        let taskId = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let taskId, !taskId.isEmpty, session.task(id: taskId) == nil {
            return "There is no task \(taskId) on this job. Request the part without a task — it is tagged to the job instead."
        }
        let urgency = PartsRequest.Urgency(
            rawValue: (args["urgency"] as? String)?.lowercased() ?? "routine") ?? .routine

        guard let request = session.requestPart(
            verified,
            quantity: Self.integer(args["quantity"]) ?? 1,
            taskId: (taskId?.isEmpty == true) ? nil : taskId,
            urgency: urgency,
            onVan: (args["on_van"] as? Bool) ?? false) else {
            return "No active Field Assist session."
        }

        var lines = ["Requested \(request.quantity) × \(request.part.number) — \(urgency.rawValue)."]
        if request.part.verified {
            let described = request.part.partDescription.map { " (\($0))" } ?? ""
            lines.append("Verified\(described): \(request.part.page ?? "found in the manuals").")
        } else if let note = PartsVerifier.unverifiedNote([request.part]) {
            lines.append(note)
        }
        if request.taskId == nil { lines.append("Tagged to the job, not to a task.") }
        if let model = request.modelToken { lines.append("For the \(model).") }
        lines.append("It goes out with the job record, and on its own as soon as there is a connection.")
        return lines.joined(separator: " ")
    }

    private func record(answer: String, requestId: String?, part: String?) -> String {
        guard let updated = session.answerPartsRequest(
            id: (requestId?.isEmpty == true) ? nil : requestId, part: part, answer: answer) else {
            return "There is no parts request on this job to attach that answer to."
        }
        return "Base says, about \(updated.quantity) × \(updated.part.number): \(answer)\n"
            + "Filed against the request. It does not change the recommendation or the task — "
            + "tell the technician and let them decide."
    }

    /// Models send numbers as Int, Double or String; take all three.
    static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
