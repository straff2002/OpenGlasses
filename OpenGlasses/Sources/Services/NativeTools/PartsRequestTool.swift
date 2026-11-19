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
///
/// `send` emails the job's waiting requests to the office as an order of their own — staged, like
/// the job report, so the composer opens on the phone and the technician taps Send. The requests
/// are marked sent only once it goes. Without it, a technician who asked for "an email to order a
/// new one" got the whole job report offered instead, because nothing else could carry an order.
@MainActor
final class PartsRequestTool: NativeTool {
    let name = "parts_request"
    let description = """
    Ask base for a part on the active Field Assist job, or record base's reply. Pass 'part' (the \
    number exactly as the manual or the label prints it) with 'quantity', optionally 'task_id' to \
    tie it to a task, 'urgency' (routine, today, emergency), 'on_van' when the technician \
    already has one, and 'for_van_stock' when the part is to restock the van rather than to be \
    fitted on this job. The number is checked against the vault's parts list and its manuals and the \
    page it was found on is recorded; a number that is not there is recorded unverified and you \
    must tell the technician so. A request does not need a task — a stock check can go out before \
    the repair is decided. To record what base replied, pass 'answer' with the text they sent (and \
    'part' or 'request_id' to say which request it answers): that is filed against the request and \
    read to the technician, and it never changes a task or a recommendation by itself. To email \
    the office a parts order, pass action 'send' (optionally 'to' with an address or contact, \
    'request_id' for one request only, and 'note'); the composer opens on the technician's phone \
    and they tap Send; the request is marked sent once it goes. This is separate from the job \
    report — do not use deliver_report or send_message to order a part. Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["request", "send"],
                "description": "'request' (the default) asks for a part or, with 'answer', records base's reply. 'send' emails the office an order for this job's parts requests that have not gone yet."
            ],
            "to": [
                "type": "string",
                "description": "With action 'send': an email address or contact name to send the order to. Omit to use the configured office recipients."
            ],
            "note": [
                "type": "string",
                "description": "With action 'send': a line from the technician to add to the order."
            ],
            "part": [
                "type": "string",
                "description": "The part number, exactly as the manual or the label prints it (e.g. '14T65')."
            ],
            "quantity": [
                "type": "integer",
                "description": "How many parts, as a whole number. Defaults to 1."
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
            "for_van_stock": [
                "type": "boolean",
                "description": "True when the part is to restock the van, for example after van_stock reported the last one used. The van list then shows it as asked for until it is loaded."
            ],
            "answer": [
                "type": "string",
                "description": "Base's reply, verbatim. Recording it files the text against the request and nothing else."
            ],
            "request_id": [
                "type": "string",
                "description": "Which request the answer is for, or with action 'send' the one request to order. Omit to use the most recent request for that part, or to order every request still waiting."
            ]
        ],
        "required": [] as [String]
    ]

    /// Session to record against; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?
    /// The van's stock, told when a replacement for it is asked for (Plan IH P1); nil means the
    /// shared one. Injectable for tests.
    private let injectedVanStock: VanStockService?

    /// The delivery rules in force, for where an order goes. Injectable so a test does not depend
    /// on this device's settings.
    private let settings: () -> DeliverySettings
    /// Contact-name → email resolution, injected so a headless test never touches Contacts.
    private let resolveEmail: (String) -> [ContactLookupHelper.ResolvedEmail]

    init(sessionService: FieldSessionService? = nil, vanStock: VanStockService? = nil,
         settings: @escaping () -> DeliverySettings = { DeliverySettings.load() },
         resolveEmail: @escaping (String) -> [ContactLookupHelper.ResolvedEmail] = { name in
             ContactLookupHelper.resolveEmails(name: name)
         }) {
        self.injectedSession = sessionService
        self.injectedVanStock = vanStock
        self.settings = settings
        self.resolveEmail = resolveEmail
    }

    private var session: FieldSessionService { injectedSession ?? .shared }
    private var vanStock: VanStockService { injectedVanStock ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard session.activeSession != nil else {
            return "No active Field Assist session. Start a session before requesting parts."
        }

        let part = (args["part"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestId = (args["request_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let action = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if action == "send" || action == "order" || action == "email" {
            return sendOrder(to: args["to"] as? String,
                             requestId: (requestId?.isEmpty == true) ? nil : requestId,
                             note: args["note"] as? String)
        }

        if let answer = (args["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !answer.isEmpty {
            return record(answer: answer, requestId: requestId, part: part)
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

        let quantity: Int
        switch Self.quantityArgument(args["quantity"]) {
        case .absent: quantity = 1
        case .whole(let value): quantity = value
        case .notWhole(let spelling):
            return "Nothing was requested. A parts request is a whole number of parts, and \(spelling) is not one. Ask how many."
        }

        let onVan = (args["on_van"] as? Bool) ?? false
        guard let request = session.requestPart(
            verified,
            quantity: quantity,
            taskId: (taskId?.isEmpty == true) ? nil : taskId,
            urgency: urgency,
            onVan: onVan) else {
            return "No active Field Assist session."
        }
        // A replacement for stock is something the van is waiting for; a part to be fitted is not.
        let forVanStock = onVan || ((args["for_van_stock"] as? Bool) ?? false)
        let vanNote = forVanStock
            ? vanStock.noteOrdered(number: request.part.number, quantity: request.quantity, requestID: request.id)
            : nil

        var lines = ["Requested \(request.quantity) × \(request.part.number) — \(urgency.rawValue)."]
        if request.part.verified {
            let described = request.part.partDescription.map { " (\($0))" } ?? ""
            lines.append("Verified\(described): \(request.part.page ?? "found in the manuals").")
        } else if let note = PartsVerifier.unverifiedNote([request.part]) {
            lines.append(note)
        }
        if request.taskId == nil { lines.append("Tagged to the job, not to a task.") }
        if let model = request.modelToken { lines.append("For the \(model).") }
        lines.append("It goes out with the job record, and on its own as soon as there is a connection. "
                     + "If the technician wants it emailed to the office now, call parts_request with action 'send'.")
        // stock-wording-guard:begin — the stock lines, worded for the place (Plan MK §3).
        if let vanNote {
            lines.append(vanNote)
        } else if forVanStock {
            lines.append("It is not a line on \(vanStock.wording.list), so the list does not show it as asked for.")
        }
        // stock-wording-guard:end
        return lines.joined(separator: " ")
    }

    /// Stage the order for the open job's waiting requests. Nothing is sent here: the composer is
    /// what sends, and only a person taps Send.
    private func sendOrder(to raw: String?, requestId: String?, note: String?) -> String {
        guard let order = session.partsOrder(requestId: requestId, note: note) else {
            if let requestId {
                return "There is no parts request \(requestId) on this job waiting to be ordered. "
                    + "A request already sent or answered is not ordered again."
            }
            return "Nothing on this job is waiting to be ordered: every parts request has been sent or answered. "
                + "Ask for the part first, with 'part'."
        }
        let wanted = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var spoken: [String] = []
        if !wanted.isEmpty {
            if wanted.contains("@") {
                spoken = [wanted]
            } else {
                switch ContactLookupHelper.pickEmail(from: resolveEmail(wanted)) {
                case .one(let match): spoken = [match.address]
                case .none:
                    return "No contact matching '\(wanted)' has an email address I can use. "
                        + "Say the address, or leave it out to send it to the office."
                case .ambiguous(let names):
                    return "'\(wanted)' could be \(names.joined(separator: " or ")). Say which one, or say the address."
                }
            }
        }
        switch PartsOrder.route(policy: DeliveryPolicy(settings: settings()), spoken: spoken) {
        case .refused(let reason):
            return reason
        case .ready(let channel, let recipients):
            let request = DeliveryRequest.make(partsOrder: order, channel: channel, recipients: recipients)
            session.stageDelivery(request)
            return request.confirmation
        }
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

    /// A quantity as the model sent it, read without cutting it.
    enum QuantityArgument: Equatable {
        /// Nothing was sent, so the caller's default applies.
        case absent
        /// A whole number, whatever shape it arrived in ("4", 4.0, 4).
        case whole(Int)
        /// Something that is not a whole number, spelled as it arrived ("4.25", "two"), so the
        /// refusal can say what it was given.
        case notWhole(String)
    }

    /// Reads a quantity without cutting a fraction: 4.25 is `.notWhole("4.25")`, never 4. A stock
    /// or parts figure that is not whole is refused with a sentence until measured quantities are
    /// kept exactly. Negative whole numbers stay whole; the services refuse them in their own words.
    static func quantityArgument(_ raw: Any?) -> QuantityArgument {
        guard let raw, !(raw is NSNull) else { return .absent }
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .notWhole(number.boolValue ? "true" : "false")
        }
        if let value = raw as? Int { return .whole(value) }
        if let value = raw as? Double { return wholeOrNot(value, spelling: "\(value)") }
        if let number = raw as? NSNumber { return wholeOrNot(number.doubleValue, spelling: "\(number.doubleValue)") }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .absent }
            if let value = Int(trimmed) { return .whole(value) }
            if let value = Double(trimmed) { return wholeOrNot(value, spelling: trimmed) }
            return .notWhole(trimmed)
        }
        return .notWhole("\(raw)")
    }

    private static func wholeOrNot(_ value: Double, spelling: String) -> QuantityArgument {
        guard value.isFinite, value.rounded() == value, abs(value) < 1_000_000_000 else { return .notWhole(spelling) }
        return .whole(Int(value))
    }

    /// Models send numbers as Int, Double or String; take all three.
    static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
