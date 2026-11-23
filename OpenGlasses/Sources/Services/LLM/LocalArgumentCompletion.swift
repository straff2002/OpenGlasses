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
/// ### The operation rule (`voltage_drop`)
/// On the phone Gemma 4 E2B also sent a voltage drop with no operation at all (`{current_a, length_ft,
/// k_factor_ohm_per_ft, material}`), so no rule saw a voltage drop and the tool refused. A
/// `domain_calc` call that names no operation, and no value naming one, whose keys are a voltage
/// drop's alone (`voltageDropShape`) gets `operation: "voltage_drop"`, so the rules after it, the
/// dispatcher's coercion and the trade gate all see the operation.
///
/// ### The conductor rule (`voltage_drop`)
/// - **What was said**: a wire size and a metal, read from the turn, else from the newest earlier
///   user message that names one. AWG ("14 gauge", "14 AWG", "#14", "14 ga", "number 14 wire",
///   "1/0", "two aught") only when `ConductorTable` lists the size; an area in mm² ("2.5 mm²",
///   "2.5 sq mm", "2.5 square"); the metal as a whole word ("copper", "aluminium", "alu", "Cu",
///   "Al"). A message that names two sizes, two metals or a size the table lacks gives none, and
///   stops the search: an older message never stands in for what this one said.
/// - **Fill**: the size (`wire_awg` or `area_mm2`) and `material` the call lacks, or holds a
///   different value for. Never the phase (the supply is the supply rule's): no size or no metal
///   said, nothing is filled for it, and the tool asks as it did.
/// - **The said conductor wins**: once a size was said, the model's resistance, factor and
///   circular-mil area are taken off (the phone's call carried `area_cmil: "115"`, the line
///   voltage), as is the other kind of size, unless the technician stated that quantity in its own
///   words ("2.5 ohms per 1000 feet", "k of 12.9", "4110 circular mils").
///
/// ### The supply rule (`voltage_drop`)
/// Gemma never sent `supply_v` either, though the two-step turn opens with the line voltage, so the
/// drop came back without its percentage. The supply is filled from the newest message that states
/// one (`supplyVoltages(in:)`): a number in volts tied to the line, the supply, the mains or the
/// incoming feed, or "line voltage … is N". A message stating two supplies gives none and stops the
/// search, and a voltage said as a drop or a limit ("a drop of 3 V", "no more than 5 V") is never one.
/// A different `supply_v` from the model is replaced: the technician's reading wins, as the metal does.
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
        /// Arguments set from the call's own shape rather than from what was said (the operation).
        /// Model-facing only.
        var inferred: [(name: String, value: String)] = []

        /// Arguments set, replaced or removed. A count only.
        var changes: Int { inferred.count + filled.count + removed.count }

        static func unchanged(_ arguments: [String: Any]) -> Completed {
            Completed(arguments: arguments, filled: [], removed: [], governs: { _ in false })
        }

        /// This completion followed by `next`, which ran on this one's arguments.
        func then(_ next: Completed) -> Completed {
            let nextNames = Set(next.filled.map { $0.name } + next.inferred.map { $0.name })
            let earlier = governs
            var combined = Completed(arguments: next.arguments,
                                     filled: filled.filter { !nextNames.contains($0.name) } + next.filled,
                                     removed: Set(removed).union(next.removed).subtracting(nextNames).sorted(),
                                     governs: { earlier($0) || next.governs($0) })
            combined.inferred = inferred.filter { !nextNames.contains($0.name) } + next.inferred
            return combined
        }
    }

    typealias Rule = @Sendable (_ name: String, _ arguments: [String: Any], _ context: Context) -> Completed?

    /// Every rule, in order, each on what the one before it left: the operation first, so the
    /// voltage-drop rules see a call that named none.
    static let rules: [Rule] = [voltageDropOperation, voltageDropConductor, voltageDropSupply]

    /// `arguments` with what the technician said filled in. Pure.
    static func complete(name: String, arguments: [String: Any], context: Context) -> Completed {
        var completed = Completed.unchanged(arguments)
        for rule in rules {
            if let next = rule(name, completed.arguments, context) { completed = completed.then(next) }
        }
        return completed
    }

    /// What the model reads after the call's result, so it works from the filled call rather than
    /// asking again. Nil when nothing changed. Never spoken.
    static func modelNote(filled: [(name: String, value: String)], inferred: [(name: String, value: String)] = [],
                          notUsed: [String]) -> String? {
        var parts: [String] = []
        if !inferred.isEmpty {
            let list = inferred.prefix(8).map { "\($0.name) \($0.value.prefix(32))" }
            parts.append("Set from the call's own arguments: \(list.joined(separator: ", ")).")
        }
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
    /// `operation` itself does not name another; a call naming no operation anywhere counts by its
    /// keys (`hasVoltageDropShape`).
    static func isVoltageDrop(name: String, arguments: [String: Any]) -> Bool {
        guard name == "domain_calc" else { return false }
        if let operation = namedOperation(arguments) { return operationKey(operation) == "voltage_drop" }
        if arguments.values.contains(where: { operationKey($0) == "voltage_drop" }) { return true }
        return hasVoltageDropShape(arguments)
    }

    // MARK: - The operation rule

    /// The keys that make a call with no operation a voltage drop, from `DomainCalcTool`'s declared
    /// properties: the current and a length, which only `voltage_drop` declares, and none of the
    /// prefixes the refrigerant operations' properties start with. One place, kept small;
    /// `LocalArgumentCompletionTests` checks it against the schema.
    static let voltageDropShape = (current: "current_a", lengths: ["length_ft", "length_m"],
                                   otherOperationPrefixes: ["refrigerant", "pressure", "temperature", "suction_",
                                                            "liquid_", "altitude", "application"])

    /// `domain_calc`'s operations, as `operationKey(_:)` reads them.
    private static let operations: Set<String> = ["pt_lookup", "superheat", "subcool", "subcooling", "voltage_drop"]

    /// Whether `arguments`, naming no operation anywhere, are a voltage drop's alone.
    static func hasVoltageDropShape(_ arguments: [String: Any]) -> Bool {
        guard namedOperation(arguments) == nil,
              !arguments.values.contains(where: { operationKey($0).map(operations.contains) ?? false }) else { return false }
        let shape = voltageDropShape
        guard arguments[shape.current] != nil, shape.lengths.contains(where: { arguments[$0] != nil }) else { return false }
        return !arguments.keys.contains { key in
            shape.otherOperationPrefixes.contains { key.lowercased().hasPrefix($0) }
        }
    }

    /// `operation: "voltage_drop"` on a call that names none and is shaped as one.
    static func voltageDropOperation(_ name: String, _ arguments: [String: Any], _ context: Context) -> Completed? {
        guard name == "domain_calc", hasVoltageDropShape(arguments) else { return nil }
        var completed = arguments
        completed["operation"] = "voltage_drop"
        var result = Completed(arguments: completed, filled: [], removed: [], governs: { _ in false })
        result.inferred = [("operation", "voltage_drop")]
        return result
    }

    /// The call's `operation` when it names one (a blank one does not).
    private static func namedOperation(_ arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String,
              !operation.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return operation
    }

    /// A value as an operation's key ("Voltage Drop" → "voltage_drop"), or nil for a non-string.
    private static func operationKey(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return text.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
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

    // MARK: - The supply rule

    static func voltageDropSupply(_ name: String, _ arguments: [String: Any], _ context: Context) -> Completed? {
        guard isVoltageDrop(name: name, arguments: arguments),
              let supply = supplyVoltage(in: context.userMessages) else { return nil }
        let governs = { (key: String) in key == "supply_v" }
        if let given = arguments["supply_v"].flatMap(number), abs(given - supply) < 1e-9 {
            return Completed(arguments: arguments, filled: [], removed: [], governs: governs)
        }
        var completed = arguments
        completed["supply_v"] = format(supply)
        return Completed(arguments: completed, filled: [("supply_v", format(supply))], removed: [], governs: governs)
    }

    /// The supply voltage from the newest message that states one; nil when none does, or when that
    /// message states two different ones (an older message never stands in for it). Pure.
    static func supplyVoltage(in messages: [String]) -> Double? {
        for message in messages {
            let stated = Set(supplyVoltages(in: message))
            if !stated.isEmpty { return stated.count == 1 ? stated.first : nil }
        }
        return nil
    }

    private static let volts = #"(?:vac|v|volts?)\b"#
    /// A number standing on its own: not part of a model number ("090XV36C") or a longer figure.
    private static let voltage = #"(?<![\w.])(\d{1,4}(?:\.\d+)?)(?![\d]|[a-uw-z])"#
    /// Not a voltage: a share, a current, a length, a size, a power, a pressure, a temperature, a phase.
    private static let notVolts = #"(?!\s*(?:%|percent|per\s*cent|amps?\b|a\b|ma\b|ohms?\b|Ω|feet\b|foot\b|ft\b|m\b|met|"#
        + #"gauge|ga\b|awg|hz\b|hertz|kw|w\b|watts?|°|degrees?|psi|inch|mm|sq|phase|ph\b|poles?\b))"#

    /// "line voltage at the 090XV36C control is 120", "line voltage 120", "supply is 230 V", "mains
    /// of 240 volts": the number straight after the words, else after the first "is", "of", "reads"
    /// in the clause. Group 1 the voltage word, 2 the number, 3 the unit: without one of those, it is
    /// not a voltage.
    private static let namedSupplyPattern = regex(#"\b(?:line|supply|mains|incoming|service|source)"#
        + #"(\s+(?:voltage|volts?))?\b(?:(?=\s+\d)|[^.;?!]{0,40}?\s*(?:\b(?:is|was|of|reads|read|reading|measures|"#
        + #"measured|showing|shows|at)\b|[=:]))\s*(?:about\s+|around\s+|roughly\s+|approximately\s+|nominally\s+)?"#
        + voltage + notVolts + #"(\s*-?\s*"# + volts + ")?")
    /// "230 volt supply", "120 V line", "240 VAC mains", "208 V incoming".
    private static let supplyAfterPattern = regex(voltage + #"\s*-?\s*"# + volts
        + #"\s+(?:ac\s+)?(?:line|supply|mains|incoming|service|feed)\b"#)
    /// "120 V at the panel", "118 volts at the control", "240 V from the disconnect".
    private static let supplyPointPattern = regex(voltage + #"\s*-?\s*"# + volts
        + #"\s+(?:at|on|from)\s+(?:the\s+)?(?:main\s+)?(?:panel|control|disconnect|breaker|board|service|meter|"#
        + #"transformer|source|supply|mains)\b"#)
    /// "118 volts line to neutral", "208 V L-L", "120 V phase to ground".
    private static let lineToPattern = regex(voltage + #"\s*-?\s*"# + volts
        + #"\s+(?:(?:line|phase)[\s-]+to[\s-]+(?:neutral|line|phase|ground)|l1?[\s-]?(?:n|l2?))\b"#)
    /// Words that make the number before it a drop or a limit, not the supply: "a drop of 3 V",
    /// "no more than 5 V", "keep it under 3 volts".
    private static let dropOrLimitBefore = regex(#"(?:\b(?:drop|loss|limit|max(?:imum)?|min(?:imum)?|allowance|allowed|"#
        + #"allowable|budget|target|tolerance|difference|delta)\b\s*(?:is|was|of|to|at|=|:|by|be|under|below)?|"#
        + #"\b(?:no more than|not more than|less than|more than|at most|up to|under|below|within|over|above|exceed(?:ing|s)?|"#
        + #"lose|losing|drops?|dropping|dropped|falls?|fell|sags?|sagged)\b)\s*(?:about\s+|around\s+|roughly\s+|only\s+|"#
        + #"just\s+|by\s+|of\s+)?$"#)
    /// "3 V drop", "5 volts of loss", "3 volts max".
    private static let dropOrLimitAfter = regex(#"^\s*(?:of\s+)?(?:drop|loss|max(?:imum)?|limit|down|lower)\b"#)

    /// Every supply voltage `text` states, above zero, with any said as a drop or a limit left out.
    static func supplyVoltages(in text: String) -> [Double] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [Double] = []
        func take(_ match: NSTextCheckingResult, number group: Int) {
            guard let numberRange = Range(match.range(at: group), in: text),
                  let value = Double(text[numberRange]), value > 0, value.isFinite else { return }
            // The clause around the number: no further back than the sentence it is in.
            let before = String(text[..<numberRange.lowerBound].suffix(40))
            let clause = before.split(omittingEmptySubsequences: false, whereSeparator: { ";?!".contains($0) }).last
                .map(String.init) ?? before
            let after = String(text[(Range(match.range, in: text)?.upperBound ?? numberRange.upperBound)...].prefix(24))
            guard !matches(dropOrLimitBefore, clause), !matches(dropOrLimitAfter, after) else { return }
            found.append(value)
        }
        for match in namedSupplyPattern.matches(in: text, range: range) {
            // A number after "line …" is a voltage only when the words or the unit say so.
            guard match.range(at: 1).location != NSNotFound || match.range(at: 3).location != NSNotFound else { continue }
            take(match, number: 2)
        }
        for pattern in [supplyAfterPattern, supplyPointPattern, lineToPattern] {
            for match in pattern.matches(in: text, range: range) { take(match, number: 1) }
        }
        return found
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
