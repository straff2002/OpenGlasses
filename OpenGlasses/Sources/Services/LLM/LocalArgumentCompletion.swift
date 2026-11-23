import Foundation

/// Arguments a downloaded model left off a call although the technician said them (Plan MQ P3).
/// Pure.
///
/// On the local path the compact schema shows Gemma 4 E2B only argument names, and it never sends
/// `domain_calc`'s `wire_awg`: "work out the voltage drop at 15 amps over 50 feet of 14 gauge copper"
/// became a call with the metal and no size, the tool refused for a missing conductor, and the model
/// asked the technician for a resistance per foot they had already given as a gauge. `LocalToolLoop`
/// runs every model-made call through `complete(name:arguments:context:)` after
/// `LocalArgumentGrounding`'s filter and before it runs; a call `LocalTurnRouter` made is not
/// completed. Each rule names the calls it applies to; `rules` is the one place to add another.
///
/// ### The conductor rule (`voltage_drop`)
/// - **What was said**: a wire size and a metal, read from the turn, else from the newest earlier
///   user message that names one. AWG ("14 gauge", "14 AWG", "#14", "14 ga", "number 14 wire",
///   "1/0", "two aught") only when `ConductorTable` lists the size; an area in mm² ("2.5 mm²",
///   "2.5 sq mm", "2.5 square"); the metal as a whole word ("copper", "aluminium", "alu", "Cu",
///   "Al"). A message that names two sizes, two metals or a size the table lacks gives none, and
///   stops the search: an older message never stands in for what this one said.
/// - **Fill**: the size (`wire_awg` or `area_mm2`) and `material` the call lacks, or holds a
///   different value for. Never the phase, never `supply_v`: no size or no metal said, nothing
///   is filled for it, and the tool asks as it did.
/// - **The said conductor wins**: once a size was said, the model's resistance, factor and
///   circular-mil area are taken off (the phone's call carried `area_cmil: "115"`, the line
///   voltage), as is the other kind of size, unless the technician stated that quantity in its own
///   words ("2.5 ohms per 1000 feet", "k of 12.9", "4110 circular mils").
enum LocalArgumentCompletion {

    /// What a rule reads beside the call.
    struct Context {
        /// What the technician said, newest first: the turn, then the earlier user messages.
        let userMessages: [String]
        /// The conductor file, asked for only when a conductor rule applies.
        let conductors: () -> ConductorTable?

        init(userMessages: [String], conductors: @escaping () -> ConductorTable? = { ConductorTableCatalog.table() }) {
            self.userMessages = userMessages
            self.conductors = conductors
        }
    }

    struct Completed {
        /// The arguments to run with.
        let arguments: [String: Any]
        /// Each argument set or replaced, with the value as the note says it. Model-facing only.
        let filled: [(name: String, value: String)]
        /// The model's arguments taken off because what was said replaces them, sorted.
        let removed: [String]
        /// Whether what was said governs `name`, so a number `LocalArgumentGrounding` dropped under
        /// it is told to the model as replaced rather than as one to ask for.
        let governs: (String) -> Bool

        /// Arguments set, replaced or removed. A count only.
        var changes: Int { filled.count + removed.count }

        static func unchanged(_ arguments: [String: Any]) -> Completed {
            Completed(arguments: arguments, filled: [], removed: [], governs: { _ in false })
        }
    }

    typealias Rule = @Sendable (_ name: String, _ arguments: [String: Any], _ context: Context) -> Completed?

    /// Every rule, in order; the first that applies decides.
    static let rules: [Rule] = [voltageDropConductor]

    /// `arguments` with what the technician said filled in. Pure.
    static func complete(name: String, arguments: [String: Any], context: Context) -> Completed {
        for rule in rules {
            if let completed = rule(name, arguments, context) { return completed }
        }
        return .unchanged(arguments)
    }

    /// What the model reads after the call's result, so it works from the filled call rather than
    /// asking again. Nil when nothing changed. Never spoken.
    static func modelNote(filled: [(name: String, value: String)], notUsed: [String]) -> String? {
        var parts: [String] = []
        if !filled.isEmpty {
            let list = filled.prefix(8).map { "\($0.name) \($0.value.prefix(32))" }
            parts.append("Filled from what the technician said: \(list.joined(separator: ", ")).")
        }
        if !notUsed.isEmpty {
            let names = notUsed.prefix(8).map { String($0.prefix(64)) }
            parts.append("Not used, because the technician named the wire: \(names.joined(separator: ", ")).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - The conductor rule

    /// A `domain_calc` voltage drop. The operation is matched before the dispatcher's coercion
    /// repairs a misnamed key (`application: "voltage_drop"`), so any value naming it counts when
    /// `operation` itself does not name another.
    static func isVoltageDrop(name: String, arguments: [String: Any]) -> Bool {
        guard name == "domain_calc" else { return false }
        func names(_ value: Any?) -> Bool {
            guard let text = value as? String else { return false }
            let key = text.lowercased().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            return key == "voltage_drop"
        }
        if arguments["operation"] is String { return names(arguments["operation"]) }
        return arguments.values.contains(where: names)
    }

    /// The conductor said, read from the messages.
    struct Conductor: Equatable {
        /// The size as the conductor file names it ("14", "1/0").
        var awg: String?
        var areaMM2: Double?
        var material: VoltageDrop.Material?
        /// Quantities the technician stated in their own words, so the model's value for them stays.
        var statesResistance = false
        var statesFactor = false
        var statesCircularMils = false

        var hasSize: Bool { awg != nil || areaMM2 != nil }
    }

    static func voltageDropConductor(_ name: String, _ arguments: [String: Any], _ context: Context) -> Completed? {
        guard isVoltageDrop(name: name, arguments: arguments) else { return nil }
        let table = context.conductors()
        let said = conductor(in: context.userMessages, table: table)
        guard said.hasSize || said.material != nil else { return .unchanged(arguments) }

        var completed = arguments
        var filled: [(name: String, value: String)] = []
        var removed: [String] = []

        if let awg = said.awg {
            let given = arguments["wire_awg"].flatMap { value -> String? in
                guard let table else { return nil }
                return VoltageDrop.WireGauge(words: "\(value)", table: table)?.name
            }
            if given != awg {
                completed["wire_awg"] = awg
                filled.append(("wire_awg", awg))
            }
        }
        if let area = said.areaMM2 {
            let given = arguments["area_mm2"].flatMap(number)
            if given.map({ abs($0 - area) > 1e-9 }) ?? true {
                completed["area_mm2"] = area
                filled.append(("area_mm2", format(area)))
            }
        }
        if let metal = said.material {
            let given = arguments["material"].flatMap { ($0 as? String).flatMap(VoltageDrop.Material.init(words:)) }
            if given != metal {
                completed["material"] = metal.rawValue
                filled.append(("material", metal.rawValue))
            }
        }
        let filledNames = Set(filled.map { $0.name })
        let superseded = { (key: String) in replaced(key, by: said) }
        for key in arguments.keys where superseded(key) && !filledNames.contains(key) {
            completed.removeValue(forKey: key)
            removed.append(key)
        }
        return Completed(arguments: completed, filled: filled, removed: removed.sorted(),
                         governs: { filledNames.contains($0) || superseded($0) })
    }

    /// Whether the model's `key` gives way to the conductor said: only once a size was said, and
    /// never for a quantity the technician stated themselves.
    private static func replaced(_ key: String, by said: Conductor) -> Bool {
        guard said.hasSize else { return false }
        let lowered = key.lowercased()
        if lowered.hasPrefix("resistance") { return !said.statesResistance }
        if lowered.hasPrefix("k_factor") { return !said.statesFactor }
        if lowered.hasPrefix("area_cmil") { return !said.statesCircularMils }
        if lowered == "area_mm2" { return said.areaMM2 == nil }
        if lowered == "wire_awg" { return said.awg == nil }
        return false
    }

    // MARK: - Reading what was said

    /// The size from the newest message that names one, the metal likewise, and the quantities any
    /// message states. A message naming two sizes or two metals, or a size `table` lacks, gives none
    /// for that part and ends its search. Pure.
    static func conductor(in messages: [String], table: ConductorTable?) -> Conductor {
        var said = Conductor()
        var sizeSettled = false
        var metalSettled = false
        for message in messages {
            if !sizeSettled {
                let gauges = gaugeWords(in: message)
                let areas = Set(metricAreas(in: message))
                if !gauges.isEmpty || !areas.isEmpty {
                    sizeSettled = true
                    if !gauges.isEmpty, let table {
                        let known = gauges.map { VoltageDrop.WireGauge(words: $0, table: table)?.name }
                        if !known.contains(nil), Set(known).count == 1 { said.awg = known.first ?? nil }
                    }
                    if areas.count == 1 { said.areaMM2 = areas.first }
                }
            }
            if !metalSettled {
                let metals = Set(self.metals(in: message))
                if !metals.isEmpty {
                    metalSettled = true
                    if metals.count == 1 { said.material = metals.first }
                }
            }
            said.statesResistance = said.statesResistance || matches(resistancePattern, message)
            said.statesFactor = said.statesFactor || matches(factorPattern, message)
            said.statesCircularMils = said.statesCircularMils || matches(circularMilPattern, message)
        }
        return said
    }

    private static let size = #"(\d{1,2}/0|0{1,4}|\d{1,2})"#

    /// "14 gauge", "14-gauge", "14 AWG", "14 ga".
    private static let gaugeUnitPattern = regex(#"(?<![\d./])"# + size + #"\s*-?\s*(?:gauge|ga|awg)\b"#)
    /// The first of two sizes said with one unit: "12 or 14 gauge".
    private static let alternativePattern = regex(#"(?<![\d./])"# + size + #"\s+(?:or|to|and)\s+(?="# + size
        + #"\s*-?\s*(?:gauge|ga|awg)\b)"#)
    /// "#14".
    private static let hashPattern = regex(#"#\s*"# + size + #"(?![\d/.])"#)
    /// "number 14 wire", "no. 12 copper".
    private static let numberPattern = regex(#"\b(?:number|no\.)\s*"# + size
        + #"\s+(?:wire|cable|conductor|copper|alumin(?:i?um)|alu)\b"#)
    /// "1/0" to "4/0" on their own.
    private static let aughtPattern = regex(#"(?<![\d/.])([1-4]/0)(?![\d/.])"#)
    /// "two aught", "2 aught".
    private static let aughtWordPattern = regex(#"\b(one|two|three|four|[1-4])[\s-]*aught\b"#)
    /// "fourteen gauge".
    private static let spelledGaugePattern = regex(
        #"\b(eighteen|sixteen|fourteen|twelve|ten|eight|six|four|three|two|one)[\s-]*(?:gauge|ga|awg)\b"#)

    private static let spelledSizes = [
        "one": "1", "two": "2", "three": "3", "four": "4", "six": "6", "eight": "8", "ten": "10",
        "twelve": "12", "fourteen": "14", "sixteen": "16", "eighteen": "18",
    ]

    /// Every AWG size `text` names, as written ("14", "1/0", "00"), before the table is asked.
    static func gaugeWords(in text: String) -> [String] {
        var found: [String] = []
        for pattern in [gaugeUnitPattern, alternativePattern, hashPattern, numberPattern, aughtPattern] {
            found += captures(pattern, text)
        }
        found += captures(aughtWordPattern, text).map { "\(spelledSizes[$0.lowercased()] ?? $0)/0" }
        found += captures(spelledGaugePattern, text).compactMap { spelledSizes[$0.lowercased()] }
        return found
    }

    /// "2.5 mm²", "2.5mm2", "2.5 sq mm", "2.5 square mm", "2.5 mm squared", "2.5 square", "2.5
    /// squared"; never "2.5 square feet".
    private static let metricPattern = regex(
        #"(?<![\d.])(\d+(?:\.\d+)?|\.\d+)\s*(?:mm²|mm2|mm\^2|sq\.?\s*mm|square\s+(?:mm|millimet(?:er|re)s?)|(?:mm|millimet(?:er|re)s?)\s+squared|squared?)(?![a-z0-9²])"#
        + #"(?!\s*(?:feet|foot|ft|met(?:er|re)s?|m|inch(?:es)?|in|yards?|yds?|cm|centimet\w*|kilomet\w*|km|miles?)\b)"#)

    /// Every area in mm² `text` names, above zero.
    static func metricAreas(in text: String) -> [Double] {
        captures(metricPattern, text).compactMap { Double($0.hasPrefix(".") ? "0" + $0 : $0) }.filter { $0 > 0 && $0.isFinite }
    }

    private static let metalWordPattern = regex(#"\b(copper|aluminium|aluminum|alu)\b"#)
    /// The symbols, as written: "Al" and "Cu", never "al" in "et al".
    private static let metalSymbolPattern = try! NSRegularExpression(pattern: #"\b(Cu|CU|Al|AL)\b"#)

    /// Every metal `text` names as a whole word.
    static func metals(in text: String) -> [VoltageDrop.Material] {
        // "alu" is the trade's short word; the tool's own reading takes "alumin…" and "Al".
        (captures(metalWordPattern, text) + captures(metalSymbolPattern, text))
            .map { $0.lowercased() == "alu" ? "aluminum" : $0 }.compactMap(VoltageDrop.Material.init(words:))
    }

    private static let resistancePattern = regex(#"\b(?:milli)?ohms?\b|Ω|\bresistance\b"#)
    private static let factorPattern = regex(#"\bk[\s-]?(?:factor|value)\b|\bk\s*(?:of|is|=|:)\s*[\d.]"#)
    private static let circularMilPattern = regex(#"\b(?:k?cmils?|circular\s+mils?|mcm)\b"#)

    // MARK: - Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func captures(_ pattern: NSRegularExpression, _ text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func number(_ value: Any) -> Double? {
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)
    }
}
