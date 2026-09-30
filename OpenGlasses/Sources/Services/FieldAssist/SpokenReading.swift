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

    init(id: String = UUID().uuidString, quantity: String, value: String, unit: String? = nil,
         unitScope: String = "initial", taskId: String? = nil, at: Date = Date(),
         supersedes: String? = nil, citation: String? = nil) {
        self.id = id
        self.quantity = quantity
        self.value = value
        self.unit = unit
        self.unitScope = unitScope
        self.taskId = taskId
        self.at = at
        self.supersedes = supersedes
        self.citation = citation
    }

    enum CodingKeys: String, CodingKey {
        case id, quantity, value, unit, at, supersedes, citation
        case unitScope = "unit_scope"
        case taskId = "task_id"
    }

    /// "140 °F", "0.28 inWC", "140".
    var valueWithUnit: String {
        guard let unit, !unit.isEmpty else { return value }
        return "\(value) \(unit)"
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
        if let citation = chain.current.citation, !citation.isEmpty { line += " — checked against \(citation)" }
        return line
    }
}
