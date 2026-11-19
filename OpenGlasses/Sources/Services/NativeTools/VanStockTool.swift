import Foundation

/// The fields that describe one part, shared by a single-part call and each entry of `items`.
private func vanStockLineProperties() -> [String: Any] {
    [
        "part": [
            "type": "string",
            "description": "The part number, exactly as the label or the manual prints it."
        ],
        "description": [
            "type": "string",
            "description": "What the part is, in the technician's words: '45/5 capacitor'."
        ],
        "quantity": [
            "type": "integer",
            "description": "How many, as a whole number; fractions are not kept yet. Defaults to 1 for load, use and remove; required for count."
        ],
        "unit": [
            "type": "string",
            "enum": VanStockUnit.allCases.map(\.rawValue),
            "description": "How the part is counted. Defaults to each."
        ],
        "code": [
            "type": "string",
            "description": "A barcode or QR code read by scan_code, verbatim."
        ],
        "new_line": [
            "type": "boolean",
            "description": "For load or count: true when the technician says this is a different part from a similar line already on the van."
        ]
    ]
}

/// What is on the technician's own van or truck, kept by voice (Plan IH §3).
///
/// Loading happens at the shop with no job open, so unlike the other Field Assist tools this one
/// needs Field Assist switched on and nothing else. Everything it does is on the phone: it works
/// with no signal, and it never asks the office for anything — at zero it tells the model to offer
/// a request, and the request is `parts_request`'s to make once the technician has said yes.
@MainActor
final class VanStockTool: NativeTool {
    let name = "van_stock"
    let description = """
    The technician's own van or truck stock, kept on the phone. Use it whenever they ask what is \
    on the van or truck, or say they loaded, used, returned or counted parts. Works without a job \
    open and without signal. Pass 'action': 'check' (how many of one part; pass 'part' and/or \
    'description'), 'low' (what has run out or is at its minimum), 'load' (parts put on the van), \
    'use' (parts fitted from the van; tagged to the open job), 'remove' (parts taken off for \
    another reason; pass 'reason'), 'count' (a stocktake: sets the figure and says how it compares with what the log expected), 'undo' (takes back \
    the last spoken entry), 'unrecorded' (parts on this job's finished tasks with no stock entry), \
    'not_from_van' (a part on this job that was ordered in or was the customer's; pass 'part'), \
    'top_up' (what it takes to bring the van back to its standard load), 'set_standard' (how many \
    of a part this truck should carry; pass 'quantity', 0 for none), or 'send_to_base' (stages the \
    end-of-shift stock for the technician to send; it sends nothing itself). To record a top-up, \
    call 'load' with 'to_standard' true, and 'items' naming any parts that could not be filled. \
    For one part pass 'part' (the number exactly as printed), \
    'description', 'quantity' and optionally 'unit'; for several parts in one sentence pass \
    'items', each with the same fields. A scanned barcode goes in 'code'. Read the result back to \
    the technician as given: it says how each figure is known, and it spells out a part number it \
    has not met so a misheard one can be undone. Never state a quantity this tool did not return. \
    When more than one line fits, ask which one. When the result offers a replacement, ask the \
    technician before requesting one.
    """

    let parametersSchema: [String: Any] = {
        var properties = vanStockLineProperties()
        properties["action"] = [
            "type": "string",
            "enum": ["check", "low", "load", "use", "remove", "count", "undo", "unrecorded", "not_from_van",
                     "top_up", "set_standard", "send_to_base"],
            "description": "What to do."
        ]
        properties["items"] = [
            "type": "array",
            "description": "Several parts said in one sentence. Use instead of the single-part fields.",
            "items": ["type": "object", "properties": vanStockLineProperties()] as [String: Any]
        ]
        properties["to_standard"] = [
            "type": "boolean",
            "description": "For 'load': true when the technician says they topped everything up. Every short line is brought to its standard load, except the parts named in 'items'."
        ]
        properties["answered"] = [
            "type": "boolean",
            "description": "For 'send_to_base': true once the technician has answered what the first call asked about."
        ]
        properties["reason"] = [
            "type": "string",
            "enum": VanStockMovement.RemovalReason.allCases.map(\.rawValue),
            "description": "For 'remove': why it came off the van."
        ]
        return ["type": "object", "properties": properties, "required": ["action"]]
    }()

    /// The service to speak for; nil means the shared one. Injectable for tests.
    private let injectedService: VanStockService?
    private let injectedHandover: VanStockHandoverService?

    init(service: VanStockService? = nil, handover: VanStockHandoverService? = nil) {
        self.injectedService = service
        self.injectedHandover = handover
    }

    private var service: VanStockService { injectedService ?? .shared }
    private var handover: VanStockHandoverService { injectedHandover ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard !Config.organizationForbidsVanStock else {
            return "Your organisation has switched van stock off on this phone. Nothing was looked up or changed."
        }
        let action = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let lines = Self.lines(args)

        if Self.quantityActions.contains(action), let refusal = Self.notWholeRefusal(args) { return refusal }

        switch action {
        case "check":
            guard let line = lines.first else { return "Say which part to check, by number or description." }
            return service.check(line)
        case "low":
            return service.low()
        case "load":
            if (args["to_standard"] as? Bool) == true { return service.loadToStandard(except: lines) }
            return service.load(lines, source: Self.source(lines))
        case "use":
            return service.use(lines, source: Self.source(lines))
        case "remove":
            let reason = (args["reason"] as? String).flatMap { VanStockMovement.RemovalReason(rawValue: $0.lowercased()) }
            return service.remove(lines, reason: reason ?? .other, source: Self.source(lines))
        case "count":
            return service.count(lines, source: Self.source(lines))
        case "undo":
            return service.undo()
        case "top_up":
            return service.topUp()
        case "set_standard":
            guard let line = lines.first else { return "Say which part, and how many the van should carry." }
            return service.setStandard(line)
        case "send_to_base":
            // The handover carries descriptions that may have been dictated, so it is not staged
            // while the medical mode holds everything on the phone.
            guard !Config.hipaaMode else {
                return "The stock is not sent to base while Medical Compliance mode is on. "
                    + "The technician can export it themselves from the Van stock screen."
            }
            if (args["answered"] as? Bool) != true, let questions = service.handoverQuestions() { return questions }
            guard handover.stage() else { return "There is no readable van list to send." }
            return "Staged on the phone for the technician to look at and send. Nothing has been sent. "
                + "What it says: " + service.handoverMessage()
        case "unrecorded":
            return service.unrecorded()
        case "not_from_van":
            guard let line = lines.first else { return "Say which part did not come off the van, by its part number." }
            return service.notFromVan(line)
        default:
            return "Pass 'action': check, low, load, use, remove, count, undo, unrecorded, not_from_van, "
                + "top_up, set_standard or send_to_base."
        }
    }

    /// The actions that write a quantity. Any of them with a figure that is not whole changes nothing.
    private static let quantityActions: Set<String> = ["load", "use", "remove", "count", "set_standard"]

    /// The raw entries of one call: `items` when it is given, otherwise the single-part fields.
    private static func entries(_ args: [String: Any]) -> [[String: Any]] {
        (args["items"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? [args]
    }

    /// A sentence refusing the whole call when any of its quantities is not a whole number, so
    /// 4.25 litres is never recorded as 4 and a standard of 0.5 never clears the standard.
    static func notWholeRefusal(_ args: [String: Any]) -> String? {
        let offending: [String] = entries(args).compactMap { entry in
            guard case .notWhole(let spelling) = PartsRequestTool.quantityArgument(entry["quantity"]),
                  let named = Self.line(entry) else { return nil }
            return "\(spelling) for \(named.reference)"
        }
        guard !offending.isEmpty else { return nil }
        let list = offending.count == 1
            ? offending[0]
            : offending.dropLast().joined(separator: ", ") + " and " + offending[offending.count - 1]
        let verdict = offending.count == 1 ? "is not a whole number" : "are not whole numbers"
        return "Nothing was changed. Van stock keeps whole numbers only for now, and \(list) \(verdict). "
            + "Ask the technician for a whole number."
    }

    /// The lines of one call: `items` when it is given, otherwise the single-part fields.
    static func lines(_ args: [String: Any]) -> [VanStockService.Line] {
        entries(args).compactMap { Self.line($0) }
    }

    /// One entry as a line, or nil when it names no part, description or code. A quantity that is
    /// not whole reads as none here; `notWholeRefusal` stops the call before that matters.
    private static func line(_ entry: [String: Any]) -> VanStockService.Line? {
        let quantity: Int?
        if case .whole(let value) = PartsRequestTool.quantityArgument(entry["quantity"]) {
            quantity = value
        } else {
            quantity = nil
        }
        let line = VanStockService.Line(part: Self.text(entry["part"]),
                                        description: Self.text(entry["description"]),
                                        quantity: quantity,
                                        unit: Self.text(entry["unit"]),
                                        code: Self.text(entry["code"]),
                                        asNew: (entry["new_line"] as? Bool) ?? false)
        return line.part == nil && line.description == nil && line.code == nil ? nil : line
    }

    /// A call that carries a scanned code was scanned; anything else was said.
    private static func source(_ lines: [VanStockService.Line]) -> VanStockMovement.Source {
        lines.contains { $0.code != nil } ? .scanned : .spoken
    }

    /// Models send a part number as a string or, when it is all digits, as a number.
    private static func text(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        if let value = raw as? Int { return String(value) }
        return nil
    }
}
