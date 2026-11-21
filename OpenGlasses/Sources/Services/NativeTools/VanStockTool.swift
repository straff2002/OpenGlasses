import Foundation

/// The fields that describe one part, shared by a single-part call and each entry of `items`.
private func vanStockLineProperties(_ w: StockPlaceWording, system: String? = nil) -> [String: Any] {
    var properties: [String: Any] = [
        "part": [
            "type": "string",
            "description": "The part number, exactly as the label or the manual prints it."
        ],
        "description": [
            "type": "string",
            "description": "What the part is, in \(w.person)'s words: '45/5 capacitor'."
        ],
        "quantity": [
            "type": "number",
            "description": system == nil
                ? "How much, in the line's unit. Up to 3 decimal places for m, ft, kg, lb and l (4.25 litres is 4.25); whole numbers for each and pack. Defaults to 1 for 'load', 'use' and 'remove'; required for 'count'."
                : "How much, in the line's unit. Up to 3 decimal places for m, ft, kg, lb and l (4.25 litres is 4.25); whole numbers for each and pack. Defaults to 1 for 'use' and 'remove'."
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
    ]
    // A clinic's list (Plan MY §5) takes a lot, a carton count and doses per carton. There is no
    // field for anyone a dose was given to, by design (Decision 1).
    if system == nil, w.clinical {
        properties["lot"] = [
            "type": "string",
            "description": "The lot (batch) code exactly as printed on the carton, if \(w.person) said it. It is matched only against the lots this line already holds; a new lot comes in only by scanning its carton."
        ]
        properties["cartons"] = [
            "type": "integer",
            "description": "For 'receive': how many cartons came in, instead of 'quantity'. Multiplied by the line's doses per carton."
        ]
        properties["doses_per_carton"] = [
            "type": "integer",
            "description": "For 'receive' or 'count' of a line that does not know it yet: how many doses one carton holds."
        ]
    }
    // While a business's own system holds the count nothing is loaded or counted on the phone,
    // so the field that only those take is not offered.
    if system == nil {
        properties["new_line"] = [
            "type": "boolean",
            "description": "For 'load' or 'count': true when \(w.person) says this is a different part from a similar line already \(w.location)."
        ]
    }
    return properties
}

/// What is on the technician's own van or truck, kept by voice (Plan IH §3), or in the store,
/// the warehouse or stock the list is kept in (Plan MK).
///
/// Loading happens at the shop with no job open, so unlike the other Field Assist tools this one
/// needs Field Assist switched on and nothing else. Everything it does is on the phone: it works
/// with no signal, and it never asks the office for anything — at zero it tells the model to offer
/// a request, and the request is `parts_request`'s to make once the technician has said yes.
///
/// The description and the schema are worked out from the place in force each time they are read
/// (Plan MK §3), so a place changed on the screen is in the next turn's tool definitions. The tool's
/// name and its action values stay as they were: they are contract strings the model does not
/// read for meaning.
@MainActor
final class VanStockTool: NativeTool {
    let name = "van_stock"

    /// Every action, for every kind of place: the job-only ones follow an open job, not the place
    /// (Plan MK §5).
    static let actions = ["check", "list", "low", "load", "use", "remove", "count", "undo", "unrecorded",
                          "not_from_van", "top_up", "set_standard", "send_to_base"]

    /// The actions a clinic's list adds (Plan MY §5): a dose given, wasted with its reason, and a
    /// delivery received. `give` and `receive` are `use` and `load` in the clinic's words.
    static let clinicalActions = ["give", "waste", "receive", "report"]

    var description: String {
        Self.description(for: service.place, system: service.systemName, clinical: service.isClinical)
    }

    var parametersSchema: [String: Any] {
        Self.parametersSchema(for: service.place, system: service.systemName, clinical: service.isClinical)
    }

    /// The description for a place, a system and a clinic's list (Plan MY §9).
    static func description(for kind: StockPlace.Kind, system: String?, clinical: Bool) -> String {
        guard clinical, system == nil else { return description(for: kind, system: system) }
        return description(for: kind, clinical: true)
    }

    /// The schema for a place, a system and a clinic's list.
    static func parametersSchema(for kind: StockPlace.Kind, system: String?, clinical: Bool) -> [String: Any] {
        guard clinical, system == nil else { return parametersSchema(for: kind, system: system) }
        return parametersSchema(for: kind, clinical: true)
    }

    /// The description while a business's own system holds the count (Plan MM §5): its figures,
    /// read-only, with their as-of time; a use noted on the job, or at premises on the day's list,
    /// and sent only when a person confirms; nothing received, counted, set, topped up or handed
    /// over on the phone, and never a sale. Worded for the place, naming the system.
    static func description(for kind: StockPlace.Kind, system: String?) -> String {
        guard let system else { return description(for: kind) }
        let w = StockPlaceWording(kind)
        let noJob = kind.family == .premises
            ? "on the open job, or on today's list when no job is open"
            : "on the open job; with no job open nothing is noted"
        return "The stock \(w.location), as \(system) holds it: the figures are \(system)'s, read-only, each with the "
            + "time it is as of. Use it whenever \(w.person) asks what is \(w.location), or says a part was used. Without "
            + "signal it answers from the last figures, with their age. Pass 'action': 'check' (how many of one part; "
            + "pass 'part' and/or 'description'), 'list' (\(system)'s figures for this place), 'low' (lines at or "
            + "below \(system)'s reorder point, or at none), 'use' (\(w.goods) used, noted \(noJob); it goes to "
            + "\(system) only when \(w.person) confirms the parts, and \(system)'s figure does not change until then), "
            + "'remove' (\(w.goods) written off; pass 'reason' 'damaged'; noted the same way), 'undo' (takes back the "
            + "last note), 'unrecorded' (parts on this job's finished tasks with nothing noted), or 'not_from_van' (a "
            + "part on this job that did not \(w.comeFrom); pass 'part'). Receiving stock, stocktakes, \(w.usualFigure)s "
            + "and reordering are done in \(system), not on the phone: do not offer them. A sale is never recorded "
            + "here: the till takes it off \(system)'s figure. For one part pass 'part' (the number exactly as "
            + "printed), 'description', 'quantity' and optionally 'unit'; for several parts in one sentence pass "
            + "'items', each with the same fields. A scanned barcode goes in 'code'. Read the result back to "
            + "\(w.person) as given: it names \(system) and the time of its figure, and a figure it says is unknown "
            + "is never a number. Never state a quantity this tool did not return. When more than one line fits, ask "
            + "which one."
    }

    /// The schema while a system holds the count: the same actions (contract strings), without
    /// the fields only receiving, top-ups and the handover take.
    static func parametersSchema(for kind: StockPlace.Kind, system: String?) -> [String: Any] {
        guard let system else { return parametersSchema(for: kind) }
        let w = StockPlaceWording(kind)
        var properties = vanStockLineProperties(w, system: system)
        properties["action"] = ["type": "string", "enum": actions, "description": "What to do."]
        properties["items"] = [
            "type": "array",
            "description": "Several parts said in one sentence. Use instead of the single-part fields.",
            "items": ["type": "object", "properties": vanStockLineProperties(w, system: system)] as [String: Any]
        ]
        properties["bin"] = ["type": "string", "description": "For 'list': ignored; \(system)'s figures carry no bins."]
        properties["reason"] = [
            "type": "string",
            "enum": VanStockMovement.RemovalReason.allCases.map(\.rawValue),
            "description": "For 'remove': why it \(w.cameFrom). Only 'damaged' is noted for \(system)."
        ]
        return ["type": "object", "properties": properties, "required": ["action"]]
    }

    /// Words a model might send as an action for a sale. While a system holds the count they are
    /// answered with the till's sentence rather than as an unknown action.
    private static let saleActions: Set<String> = ["sell", "sale", "sold", "sell_stock", "record_sale"]

    /// The description for a place, leading with it (Plan MK §3).
    static func description(for kind: StockPlace.Kind, clinical: Bool = false) -> String {
        let w = StockPlaceWording(kind, clinical: clinical)
        if clinical { return clinicalDescription(w) }
        return w.toolLead + " Works without a job open and without signal. Pass 'action': 'check' (how many of "
            + "one part; pass 'part' and/or 'description'), 'list' (what is there, all of it or one bin; pass "
            + "'bin'), 'low' (what has run out or is at its minimum), 'load' (\(w.goods) \(w.putThere)), "
            + "'use' (\(w.useGloss); tagged to the open job), 'remove' (\(w.goods) taken off for another reason; "
            + "pass 'reason'), 'count' (a stocktake: sets the figure and says how it compares with what the log "
            + "expected), 'undo' (takes back the last spoken entry), 'unrecorded' (parts on this job's finished "
            + "tasks with no stock entry), 'not_from_van' (a part on this job that was ordered in or was the "
            + "customer's, so it did not \(w.comeFrom); pass 'part'), 'top_up' (what it takes to bring "
            + "\(w.placeNoun) back to its \(w.usualFigure)), 'set_standard' (how many of a part \(w.setByList) "
            + "should carry; pass 'quantity', 0 for none), or 'send_to_base' (\(w.handoverGloss); it sends "
            + "nothing itself). The job actions work only while a job is open. To record a top-up, call 'load' "
            + "with 'to_standard' true, and 'items' naming any parts that could not be filled. For one part "
            + "pass 'part' (the number exactly as printed), 'description', 'quantity' and optionally 'unit'; for "
            + "several parts in one sentence pass 'items', each with the same fields. A scanned barcode goes in "
            + "'code'. Read the result back to \(w.person) as given: it says how each figure is known, and it "
            + "spells out a part number it has not met so a misheard one can be undone. Never state a quantity "
            + "this tool did not return. When more than one line fits, ask which one. When the result offers a "
            + "replacement, ask \(w.person) before requesting one."
    }

    /// A clinic's list (Plan MY §9): doses given, wasted and received, by lot, and never anyone
    /// they were given to.
    private static func clinicalDescription(_ w: StockPlaceWording) -> String {
        w.toolLead + " Works without signal. Pass 'action': 'check' (how many doses of one vaccine, by lot; "
            + "pass 'description'), 'list' (what is \(w.location)), 'low' (what has run out or is at its minimum), "
            + "'give' (doses given), 'waste' (doses \(w.wastedVerb); pass 'waste_reason'), 'receive' (a delivery; "
            + "pass 'quantity' in doses or 'cartons'), 'remove' (returned to the supplier or moved elsewhere; pass "
            + "'reason'), 'count' (a stocktake of one \(w.lotNoun): sets its figure and says how it compares), or "
            + "'undo' (takes back the last entry), or 'report' (one sentence on doses given, wasted and received, "
            + "expiring lots and counts; pass 'period': 'today' or 'this_week'). Pass 'lot' when \(w.person) says it. When a vaccine has more than "
            + "one \(w.lotNoun) \(w.location), the result lists them oldest expiry first: ask which, and call again "
            + "with 'lot'. A \(w.lotNoun) that has expired is not recorded as given; the result offers to record it "
            + "as \(w.wastedVerb) instead, and only with \(w.person)'s yes. A scanned carton's code goes in 'code'. "
            + "Read the result back as given. Never state a quantity this tool did not return. Never pass, say or "
            + "keep the name, number or any detail of a patient: this is the stock, not the patient's record."
    }

    /// The schema for a place: the same actions and fields for every kind, described in its words.
    static func parametersSchema(for kind: StockPlace.Kind, clinical: Bool = false) -> [String: Any] {
        let w = StockPlaceWording(kind, clinical: clinical)
        var properties = vanStockLineProperties(w)
        properties["action"] = [
            "type": "string",
            "enum": clinical ? actions + clinicalActions : actions,
            "description": "What to do."
        ]
        if clinical {
            properties["period"] = [
                "type": "string",
                "enum": VanStockService.ReportPeriod.allCases.map(\.rawValue),
                "description": "For 'report': today, or this week."
            ]
            properties["waste_reason"] = [
                "type": "string",
                "enum": VanStockMovement.WasteReason.allCases.map(\.rawValue),
                "description": "For 'waste': why the doses were thrown out."
            ]
        }
        properties["items"] = [
            "type": "array",
            "description": "Several parts said in one sentence. Use instead of the single-part fields.",
            "items": ["type": "object", "properties": vanStockLineProperties(w)] as [String: Any]
        ]
        properties["bin"] = [
            "type": "string",
            "description": "For 'list': the bin to read, in the words said ('main fridge'). Every word must be in the bin's label. Omit for the whole list."
        ]
        properties["to_standard"] = [
            "type": "boolean",
            "description": "For 'load': true when \(w.person) says they topped everything up. Every short line is brought to its \(w.usualFigure), except the parts named in 'items'."
        ]
        properties["answered"] = [
            "type": "boolean",
            "description": "For 'send_to_base': true once \(w.person) has answered what the first call asked about."
        ]
        properties["reason"] = [
            "type": "string",
            "enum": VanStockMovement.RemovalReason.allCases.map(\.rawValue),
            "description": "For 'remove': why it \(w.cameFrom)."
        ]
        return ["type": "object", "properties": properties, "required": ["action"]]
    }

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
        let w = service.wording
        guard !Config.organizationForbidsVanStock else {
            return "Your organisation has switched \(w.stockName) off on this phone. Nothing was looked up or changed."
        }
        let said = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // A clinic's words for two of the actions (Plan MY §5).
        let action = Self.clinicalAliases[said] ?? said
        // While a business's own system holds the count (Plan MM §5): what the system does is
        // refused before any figure is read, and what the phone never does is not offered.
        if let desk = service.systemDesk {
            switch action {
            case "load": return desk.composer.refused(.load)
            case "count": return desk.composer.refused(.count)
            case "set_standard": return desk.composer.refused(.setStandard)
            case "top_up": return desk.composer.refused(.topUp)
            case "send_to_base": return desk.composer.handoverNotOffered()
            case let sale where Self.saleActions.contains(sale): return desk.composer.noSale()
            case "check", "list", "low", "use", "remove", "undo", "unrecorded", "not_from_van", "waste":
                break
            default:
                return "Pass 'action': check, list, low, use, remove, undo, unrecorded or not_from_van."
            }
        }
        let lines: [VanStockService.Line]
        if let verb = Self.quantityVerbs[action], (args["to_standard"] as? Bool) != true {
            // Each figure is read against its own line's unit; one that does not fit refuses the
            // whole call, so nothing in it is recorded.
            let mayCreate = action == "load" || action == "count"
            switch Self.read(args, verb: verb, wording: w,
                             unit: { [service] in service.quantityUnit(for: $0, mayCreate: mayCreate) }) {
            case .success(let read): lines = read
            case .failure(let refusal): return refusal.sentence
            }
        } else {
            lines = Self.lines(args)
        }

        switch action {
        case "check":
            guard let line = lines.first else { return "Say which part to check, by number or description." }
            return await service.checkNow(line)
        case "list":
            return service.list(bin: Self.text(args["bin"]))
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
        case "waste":
            let reason = (args["waste_reason"] as? String).flatMap { VanStockMovement.WasteReason(rawValue: $0.lowercased()) }
            return service.waste(lines, reason: reason ?? .other, source: Self.source(lines))
        case "undo":
            return service.undo()
        case "report" where service.isClinical:
            let period = (args["period"] as? String).flatMap { VanStockService.ReportPeriod(rawValue: $0.lowercased()) }
            return service.spokenReport(period ?? .thisWeek)
        case "top_up":
            return service.topUp()
        case "set_standard":
            guard let line = lines.first else { return "Say which part, and how many \(w.shouldHold)." }
            return service.setStandard(line)
        case "send_to_base":
            // The handover carries descriptions that may have been dictated, so it is not staged
            // while the medical mode holds everything on the phone.
            guard !Config.hipaaMode else {
                return "\(w.handoverNotSent) while Medical Compliance mode is on. "
                    + "\(StockPlaceWording.capitalised(w.person)) can export it themselves from \(w.screen)."
            }
            if (args["answered"] as? Bool) != true, let questions = service.handoverQuestions() { return questions }
            guard handover.stage() else { return "There is no readable \(w.listNoun) to send." }
            return "Staged on the phone for \(w.person) to look at and send. Nothing has been sent. "
                + "What it says: " + service.handoverMessage()
        case "unrecorded":
            return service.unrecorded()
        case "not_from_van":
            guard let line = lines.first else { return "Say which part did not \(w.comeFrom), by its part number." }
            return service.notFromVan(line)
        default:
            return "Pass 'action': check, list, low, load, use, remove, count, undo, unrecorded, not_from_van, "
                + "top_up, set_standard or send_to_base."
        }
    }

    /// The actions that write a quantity, and how a refusal of each opens: "Nothing loaded for
    /// Wire nuts". A standard is refused in its own words (`VanStockService.standardRefusal`).
    private static let quantityVerbs: [String: String] = [
        "load": "loaded", "use": "recorded", "remove": "removed", "count": "counted", "set_standard": "set",
        "waste": "wasted",
    ]

    /// `give` is `use` and `receive` is `load`, in a clinic's words.
    private static let clinicalAliases = ["give": "use", "receive": "load"]

    /// The raw entries of one call: `items` when it is given, otherwise the single-part fields.
    private static func entries(_ args: [String: Any]) -> [[String: Any]] {
        (args["items"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? [args]
    }

    /// A call refused for a figure its line cannot hold. Nothing in it was recorded.
    struct QuantityRefusal: Error, Equatable {
        let sentence: String
    }

    /// The lines of one call, each figure read exactly against the unit `unit` gives its line
    /// (`StockQuantity.parse(json:unit:)`): 4.25 is taken for a line in litres and refused for a
    /// line in packs, and nothing is ever cut to fit. Any figure refused refuses the whole call,
    /// with a sentence per line: "Nothing recorded for Engine oil: litres are kept to 3 decimal
    /// places." Worded for the place.
    static func read(_ args: [String: Any], verb: String, wording w: StockPlaceWording,
                     unit: (VanStockService.Line) -> (unit: VanStockUnit, name: String))
        -> Result<[VanStockService.Line], QuantityRefusal> {
        var lines: [VanStockService.Line] = []
        var refused: [String] = []
        for entry in entries(args) {
            guard var line = Self.line(entry) else { continue }
            let (lineUnit, name) = unit(line)
            switch StockQuantity.parse(json: entry["quantity"], unit: lineUnit) {
            case nil: line.quantity = nil
            case .success(let quantity): line.quantity = quantity
            case .failure(let reason):
                refused.append(verb == "set"
                    ? VanStockService.standardRefusal(name, unit: lineUnit, reason: reason, wording: w)
                    : "Nothing \(verb) for \(name): \(reason.sentence(for: lineUnit)).")
            }
            lines.append(line)
        }
        guard !refused.isEmpty else { return .success(lines) }
        var sentence = refused.joined(separator: " ")
        if lines.count > refused.count { sentence += " Nothing else in this call was recorded either." }
        return .failure(QuantityRefusal(sentence: sentence + " Ask \(w.person) for the figure again."))
    }

    /// The lines of one call: `items` when it is given, otherwise the single-part fields. A
    /// figure is read against the unit the entry names, or each; one that does not fit reads as
    /// none. The writing actions go through `read(_:verb:wording:unit:)` instead, which knows the
    /// line's own unit and refuses rather than dropping a figure.
    static func lines(_ args: [String: Any]) -> [VanStockService.Line] {
        entries(args).compactMap { entry in
            guard var line = Self.line(entry) else { return nil }
            let unit = line.unit.flatMap(VanStockUnit.init(spoken:)) ?? .each
            if case .success(let quantity) = StockQuantity.parse(json: entry["quantity"], unit: unit) {
                line.quantity = quantity
            }
            return line
        }
    }

    /// One entry as a line, with no figure yet, or nil when it names no part, description or
    /// code.
    private static func line(_ entry: [String: Any]) -> VanStockService.Line? {
        let line = VanStockService.Line(part: Self.text(entry["part"]),
                                        description: Self.text(entry["description"]),
                                        unit: Self.text(entry["unit"]),
                                        code: Self.text(entry["code"]),
                                        asNew: (entry["new_line"] as? Bool) ?? false,
                                        lot: Self.text(entry["lot"]),
                                        cartons: Self.whole(entry["cartons"]),
                                        dosesPerCarton: Self.whole(entry["doses_per_carton"]))
        return line.part == nil && line.description == nil && line.code == nil ? nil : line
    }

    /// A call that carries a scanned code was scanned; anything else was said.
    private static func source(_ lines: [VanStockService.Line]) -> VanStockMovement.Source {
        lines.contains { $0.code != nil } ? .scanned : .spoken
    }

    /// A whole number sent as a number or a string; nil for anything else or a fraction.
    private static func whole(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double, value == value.rounded(), abs(value) < 1_000_000 { return Int(value) }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// Models send a part number as a string or, when it is all digits, as a number.
    private static func text(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        if let value = raw as? Int { return String(value) }
        return nil
    }
}
