import Foundation

/// A value the technician reads out, and its correction (Plan GB P3).
///
/// Before this there was nowhere for "supply air 140" to go, so it became a finished task — and
/// "no, 135" a second one. A reading is recorded as the technician's report (never as observed),
/// and a correction supersedes the value it corrects.
@MainActor
final class ReadingTool: NativeTool {
    let name = "reading"
    let description = """
    Record a value the technician reads off the machine ("supply air is 140 degrees", "inducer \
    pressure 0.28") with 'record_reading', or correct one they gave earlier ("135, not 140") with \
    'correct_reading' — a correction replaces the earlier value on the record; never record it as a \
    new reading or a task. Pass 'quantity' (what was measured), 'value' exactly as said, and 'unit' \
    when said. Pass 'page' only for a manual page the technician confirmed. Readings are recorded as \
    the technician's report, not as verified. Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["record_reading", "correct_reading"],
                "description": "Record a new reading, or correct an earlier one."
            ],
            "quantity": [
                "type": "string",
                "description": "What was measured, e.g. 'supply air', 'manifold pressure'. On correct_reading, which reading (omit for the latest)."
            ],
            "value": ["type": "string", "description": "The value exactly as said, e.g. '140', '0.28'."],
            "unit": ["type": "string", "description": "The unit as said, e.g. '°F', 'inWC', 'volts'."],
            "reading_id": ["type": "string", "description": "On correct_reading: the reading to correct, when known."],
            "page": ["type": "string", "description": "A manual page the technician confirmed this against."]
        ],
        "required": ["action", "value"]
    ]

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
            return "No active Field Assist session. Start a session before recording readings."
        }
        let value = (args["value"] as? String) ?? (args["value"] as? NSNumber)?.stringValue ?? ""
        let unit = args["unit"] as? String
        let page = args["page"] as? String
        switch (args["action"] as? String)?.lowercased() {
        case "record_reading":
            guard let quantity = args["quantity"] as? String,
                  let reading = session.recordReading(quantity: quantity, value: value, unit: unit, page: page) else {
                return "Say what was measured and the value."
            }
            return "Recorded \(reading.quantity) \(reading.valueWithUnit), as the technician reported it."
                + citationNote(asked: page, kept: reading.citation)
        case "correct_reading":
            guard let corrected = session.correctReading(id: args["reading_id"] as? String,
                                                         quantity: args["quantity"] as? String,
                                                         value: value, unit: unit, page: page) else {
                return "There is no earlier reading to correct. Record it with record_reading."
            }
            return "Corrected \(corrected.quantity) to \(corrected.valueWithUnit). The earlier value stays "
                + "on the record as corrected; it is not a second reading."
                + citationNote(asked: page, kept: corrected.citation)
        default:
            return "Use record_reading or correct_reading."
        }
    }

    /// A page asked for but not kept is one the technician has not confirmed (Decision 2).
    private func citationNote(asked: String?, kept: String?) -> String {
        guard let asked, !asked.isEmpty, kept == nil else { return "" }
        return " '\(asked)' was not cited: the technician has not confirmed that page."
    }
}
