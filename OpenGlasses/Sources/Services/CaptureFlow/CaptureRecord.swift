import Foundation

/// A captured, typed field value (Plan U). Modelled as a struct (not an enum with associated
/// values) so it round-trips through `Codable`/JSON cleanly into the audit export and the offline
/// queue. Use the factory helpers rather than the memberwise init.
struct CaptureValue: Codable, Equatable {
    /// "text" | "number" | "option" | "photo" | "code"
    let kind: String
    let string: String?
    let number: Double?
    let unit: String?

    static func text(_ s: String) -> CaptureValue { .init(kind: "text", string: s, number: nil, unit: nil) }
    static func number(_ n: Double, unit: String?) -> CaptureValue { .init(kind: "number", string: nil, number: n, unit: unit) }
    static func option(_ s: String) -> CaptureValue { .init(kind: "option", string: s, number: nil, unit: nil) }
    static func photo(path: String) -> CaptureValue { .init(kind: "photo", string: path, number: nil, unit: nil) }
    static func code(_ s: String) -> CaptureValue { .init(kind: "code", string: s, number: nil, unit: nil) }

    /// Human-readable rendering for prompts / summaries.
    var display: String {
        switch kind {
        case "number": return unit.map { "\(trimmedNumber) \($0)" } ?? trimmedNumber
        case "photo":  return "photo"
        default:       return string ?? ""
        }
    }

    private var trimmedNumber: String {
        guard let number else { return "" }
        return number == number.rounded() ? String(Int(number)) : String(number)
    }
}

/// How a value was captured — for a defensible, audit-ready record.
struct Provenance: Codable, Equatable {
    let method: String   // "voice" | "voice_number" | "enum" | "photo" | "barcode" | "ocr"
    let at: Date
    let lat: Double?
    let lon: Double?

    init(method: String, at: Date = Date(), lat: Double? = nil, lon: Double? = nil) {
        self.method = method
        self.at = at
        self.lat = lat
        self.lon = lon
    }
}

struct CapturedField: Codable, Equatable {
    let field: String
    let value: CaptureValue
    let provenance: Provenance
}

/// The structured output of a capture flow — a first-class durable object that the [[OfflineQueue]]
/// persists and the session audit export folds in.
struct CaptureRecord: Codable, Equatable {
    let flowId: String
    let sessionId: String
    var assetId: String?
    var fields: [CapturedField]
    let startedAt: Date
    var finishedAt: Date?

    init(flowId: String, sessionId: String, assetId: String? = nil,
         fields: [CapturedField] = [], startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.flowId = flowId
        self.sessionId = sessionId
        self.assetId = assetId
        self.fields = fields
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// A stable identifier for one run of one flow, derived rather than stored so a record written
    /// before this existed still identifies itself the same way. It is what a task's `readings`
    /// list holds, so the work record can name the readings taken while that task was active.
    var id: String {
        "\(flowId)@\(ISO8601DateFormatter().string(from: startedAt))"
    }

    /// Upsert a captured field by name (a re-answer replaces the prior value).
    mutating func set(_ field: String, value: CaptureValue, provenance: Provenance) {
        let entry = CapturedField(field: field, value: value, provenance: provenance)
        if let idx = fields.firstIndex(where: { $0.field == field }) {
            fields[idx] = entry
        } else {
            fields.append(entry)
        }
    }

    func value(for field: String) -> CaptureValue? {
        fields.first { $0.field == field }?.value
    }
}

extension CaptureRecord {
    /// The append-only audit-log event for a finished record — `SessionExporter` folds these into
    /// the consolidated export (closing Plan U's "audit-ready record" promise, BM P2). Values are
    /// rendered via `display` so the export stays human-readable; the full typed record lives in
    /// the offline queue as a `.captureRecord` op.
    var auditEvent: SessionLogger.Event {
        var payload: [String: AnyCodable] = [
            "flow_id": AnyCodable(flowId),
            "fields": AnyCodable(fields.map { [
                "field": $0.field,
                "value": $0.value.display,
                "method": $0.provenance.method,
            ] }),
        ]
        if let assetId { payload["asset_id"] = AnyCodable(assetId) }
        return SessionLogger.Event(
            timestamp: finishedAt ?? startedAt, kind: .captureRecordSaved, text: flowId, payload: payload)
    }
}
