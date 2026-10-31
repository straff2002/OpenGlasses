import Foundation

/// A value the technician read off the machine and said aloud (Plan GB P3).
///
/// Both field-test jobs saved `readings: []`: the only writer was the capture flow, so a spoken
/// "supply air 140" had nowhere to go and the model made it a task — and when the technician said
/// "no, 135", a second finished task. A reading is a reading, and a correction replaces what it
/// corrects instead of adding to the work.
///
/// **Speech is the technician's report (FM).** A spoken reading is recorded as reported, never as
/// observed or verified, and it cites a manual page only when that page was verified (Decision 2).
struct SpokenReading: Codable, Equatable, Identifiable {
    let id: String
    /// What was measured: "supply air", "manifold pressure".
    let quantity: String
    /// The value exactly as reported — "140", "0.28". Text, because "3.5 to 3.7" is a reading too.
    let value: String
    let unit: String?
    /// The unit (FM continuity scope) it was taken on.
    let unitScope: String
    /// The task it was taken under, when one was running (Decision 1).
    let taskId: String?
    let at: Date
    /// The reading this one corrects.
    let supersedes: String?
    /// A verified manual page it was checked against, if any.
    let citation: String?
    /// How the value was taken: nil when the technician said it, `instrument_reading` when it was
    /// read off a photograph of the instrument (Plan IS P1).
    let method: String?
    /// The job photo the value was read from (`JobMediaItem.id`), for an instrument reading.
    let photoId: String?
    /// The refrigerant the reading was taken on, when the reading is a refrigeration one, and where
    /// that designation came from ("nameplate", "technician", "display") — never assumed.
    let refrigerant: String?
    let refrigerantSource: String?
    /// For a rule chain's read-back: the steps that used a value read from a picture of a table,
    /// each as its read-back marks it ("from a picture of Table 99, page 31: check it against the
    /// page") (Plan JN P2). Nil otherwise, and not written, so a reading without one stores exactly
    /// what it stored before.
    let pictureMarks: [String]?

    /// The method recorded for a value read off a photographed instrument.
    static let instrumentReadingMethod = "instrument_reading"

    init(id: String = UUID().uuidString, quantity: String, value: String, unit: String? = nil,
         unitScope: String = "initial", taskId: String? = nil, at: Date = Date(),
         supersedes: String? = nil, citation: String? = nil, method: String? = nil,
         photoId: String? = nil, refrigerant: String? = nil, refrigerantSource: String? = nil,
         pictureMarks: [String]? = nil) {
        self.id = id
        self.quantity = quantity
        self.value = value
        self.unit = unit
        self.unitScope = unitScope
        self.taskId = taskId
        self.at = at
        self.supersedes = supersedes
        self.citation = citation
        self.method = method
        self.photoId = photoId
        self.refrigerant = refrigerant
        self.refrigerantSource = refrigerantSource
        self.pictureMarks = pictureMarks?.isEmpty == true ? nil : pictureMarks
    }

    enum CodingKeys: String, CodingKey {
        case id, quantity, value, unit, at, supersedes, citation, method, refrigerant
        case unitScope = "unit_scope"
        case taskId = "task_id"
        case photoId = "photo_id"
        case refrigerantSource = "refrigerant_source"
        case pictureMarks = "picture_marks"
    }

    /// The method recorded for a rule chain's read-back (Plan JJ P2): worked step by step from the
    /// vault's tables and the technician's answers, not said as one value.
    static let ruleChainMethod = "rule_chain"

    /// True when the value was read off a photographed instrument rather than said.
    var isInstrumentReading: Bool { method == Self.instrumentReadingMethod }

    /// True when the value is a rule chain's read-back.
    var isRuleChain: Bool { method == Self.ruleChainMethod }

    /// True when a chain's read-back used a value read from a picture of a table (Plan JN P2).
    var readFromPicture: Bool { !(pictureMarks ?? []).isEmpty }

    /// The same reading filed under another unit scope (a job split across two units).
    func movedToScope(_ scope: String) -> SpokenReading {
        SpokenReading(id: id, quantity: quantity, value: value, unit: unit, unitScope: scope, taskId: taskId,
                      at: at, supersedes: supersedes, citation: citation, method: method, photoId: photoId,
                      refrigerant: refrigerant, refrigerantSource: refrigerantSource, pictureMarks: pictureMarks)
    }

    /// "140 °F", "0.28 inWC", "140". A value that already ends in its unit prints as it is (Plan KJ
    /// P3): a model can pass the unit in both fields, and a job log held a reading with it twice.
    /// Checked here rather than when recording, so readings already stored print once too.
    var valueWithUnit: String {
        guard let unit, !unit.isEmpty else { return value }
        return Self.value(value, endsInUnit: unit) ? value : "\(value) \(unit)"
    }

    /// Whether `value` ends in `unit`, whatever the case, with the unit not starting mid-word: "5 am"
    /// does not end in the unit "m".
    private static func value(_ value: String, endsInUnit unit: String) -> Bool {
        guard let match = value.range(of: unit, options: [.caseInsensitive, .backwards, .anchored]) else {
            return false
        }
        return value[..<match.lowerBound].last?.isLetter != true
    }

    /// Spoken unit names to the symbol the record prints. Anything unrecognised is kept as said.
    static func normalisedUnit(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "f", "°f", "degf", "deg f", "fahrenheit", "degrees f", "degrees fahrenheit": return "°F"
        case "c", "°c", "degc", "deg c", "celsius", "degrees c", "degrees celsius": return "°C"
        default: return raw
        }
    }
}

/// Readings as the record prints them: each chain once, the corrections folded into it.
enum SpokenReadingLedger {

    /// One reading as reported first, and what it was corrected to, in order.
    struct Chain: Equatable {
        let original: SpokenReading
        let corrections: [SpokenReading]

        /// The value that stands.
        var current: SpokenReading { corrections.last ?? original }
    }

    static func chains(_ readings: [SpokenReading]) -> [Chain] {
        let byId = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Follow each reading back to the one nobody corrected into it.
        func root(of reading: SpokenReading) -> String {
            var current = reading
            var seen: Set<String> = [current.id]
            while let previous = current.supersedes.flatMap({ byId[$0] }), seen.insert(previous.id).inserted {
                current = previous
            }
            return current.id
        }
        var order: [String] = []
        var grouped: [String: [SpokenReading]] = [:]
        for reading in readings.sorted(by: { $0.at < $1.at }) {
            let key = root(of: reading)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(reading)
        }
        return order.compactMap { key in
            guard let members = grouped[key], let original = members.first(where: { $0.id == key }) else { return nil }
            return Chain(original: original, corrections: members.filter { $0.id != key })
        }
    }

    /// "Supply air 140 °F (corrected to 135 °F at 5:28 PM)".
    static func line(for chain: Chain, timeZone: TimeZone = .current) -> String {
        let quantity = chain.original.quantity.prefix(1).uppercased() + chain.original.quantity.dropFirst()
        var line = "\(quantity) \(chain.original.valueWithUnit)"
        if !chain.corrections.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            let corrections = chain.corrections.map {
                "corrected to \($0.valueWithUnit) at \(formatter.string(from: $0.at))"
            }
            line += " (" + corrections.joined(separator: ", then ") + ")"
        }
        if chain.current.isInstrumentReading { line += " — read from the gauge photo" }
        if let refrigerant = chain.current.refrigerant, !refrigerant.isEmpty { line += " (\(refrigerant))" }
        if let citation = chain.current.citation, !citation.isEmpty { line += " — checked against \(citation)" }
        return line
    }
}
