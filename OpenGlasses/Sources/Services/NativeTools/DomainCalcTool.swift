import Foundation

/// Refrigeration domain math: saturation (P-T) lookup, superheat and subcooling (Plan IS P0).
///
/// The numbers come from the bundled saturation tables (`SaturationTableCatalog`), generated offline
/// from CoolProp at a pinned version — not from the vault's prompt text, which only points here
/// (decision 2). Superheat is measured from the dew point and subcooling from the bubble point, and
/// the answer says which, how much glide the blend has at that pressure, and the data's source.
///
/// Either unit set is accepted: psig with °F, or kPa(g) / bar(g) with °C. The pressure argument picks
/// the answer's units (psig → °F; kPa or bar → °C and kelvin differences). Gauge readings are taken
/// against sea-level atmosphere unless an altitude is given, and the answer says which. A pressure or
/// temperature outside the table is refused by name, never extrapolated, and the refrigerant is never
/// assumed (decision 3).
///
/// A spoken superheat or subcool gets the same treatment as one read off the gauges (Plan IS, the
/// trade presets' voice fallback): the pressure is checked against the refrigerant's band
/// (`InstrumentPlausibility.refrigerantBand`), so an out-of-band value is asked again rather than
/// answered, and with a job open the pressure and line temperature are recorded as spoken readings
/// with the refrigerant and its source, once per call.
///
/// **Voltage drop** (Plan JJ P4) is its electrical domain: `voltage_drop` over [[VoltageDrop]], from
/// the phase, the current, the one-way length and the conductor's resistance per unit length (or a
/// factor and the conductor's area, or an AWG size and its metal), in metric or imperial units, with
/// every input said back. No limit is built in, nor any resistance or factor beyond the usual one for
/// a wire size's metal, which the answer names; a missing one is refused. The trade gate takes the
/// tool's operations by trade (`FieldTradeGate.operationTrades`): the saturation math is
/// refrigeration's and voltage drop is electrical's.
@MainActor
final class DomainCalcTool: NativeTool {
    let name = "domain_calc"
    let description = """
    Refrigerant saturation math from CoolProp tables: pt_lookup, superheat (dew point), subcool \
    (bubble point). 'pt_lookup' gives the dew and bubble saturation temperatures at a gauge pressure, or \
    the saturation pressures at a temperature. 'superheat' is suction line temperature minus the dew-point \
    temperature at suction pressure; 'subcool' is the bubble-point temperature at liquid pressure minus \
    liquid line temperature. Pressures in psig (answer in °F) or kPa/bar gauge (answer in °C and K). \
    Gauge pressure assumes sea level unless altitude_ft or altitude_m is given. Never assume the \
    refrigerant: take it from the nameplate or ask. Use superheat/subcool for values the technician \
    says when refrigerant_gauges has no usable picture: a pressure implausible for the refrigerant is \
    asked again, and with a job open the spoken pressure and line temperature are recorded. \
    'voltage_drop' (electrical): the drop along a run from 'phase' ('single' or 'three'), 'current_a', the \
    one-way length ('length_m' or 'length_ft') and the conductor: 'wire_awg' with 'material' is enough, or a \
    resistance per unit length ('resistance_ohm_per_km', '_per_m', '_per_1000ft' or '_per_ft'), or a factor \
    with the area ('k_factor_ohm_mm2_per_m' with 'area_mm2', or 'k_factor_ohm_cmil_per_ft' with \
    'area_cmil'), which win over the gauge; 'supply_v' adds the drop as a percentage. A resistance or factor \
    comes from the technician or the organisation's own book, never from memory; never assume the phase, \
    the material or a resistance.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            // Choices, so a model that names the operation under another key gets it moved back
            // (`OnDeviceArgumentCoercion`, Plan MQ P3).
            "operation": [
                "type": "string",
                "enum": ["pt_lookup", "superheat", "subcool", "voltage_drop"],
                "description": "pt_lookup, superheat, subcool (refrigerant); voltage_drop (electrical)."
            ],
            "refrigerant": [
                "type": "string",
                "description": "Refrigerant designation, from the nameplate or the technician: " +
                    SaturationTableCatalog.designations.joined(separator: ", ") + "."
            ],
            "pressure_psig": [
                "type": "number",
                "description": "For 'pt_lookup': the gauge pressure (psig)."
            ],
            "pressure_kpa": [
                "type": "number",
                "description": "For 'pt_lookup': the gauge pressure (kPa)."
            ],
            "pressure_bar": [
                "type": "number",
                "description": "For 'pt_lookup': the gauge pressure (bar)."
            ],
            "temperature_f": [
                "type": "number",
                "description": "For 'pt_lookup' instead of a pressure: a saturation temperature (°F); answers in psig."
            ],
            "temperature_c": [
                "type": "number",
                "description": "For 'pt_lookup' instead of a pressure: a saturation temperature (°C); answers in kPa(g)."
            ],
            "suction_pressure_psig": [
                "type": "number",
                "description": "For 'superheat': suction-side gauge pressure (psig)."
            ],
            "suction_pressure_kpa": [
                "type": "number",
                "description": "For 'superheat': suction-side gauge pressure (kPa)."
            ],
            "suction_pressure_bar": [
                "type": "number",
                "description": "For 'superheat': suction-side gauge pressure (bar)."
            ],
            "suction_line_temp_f": [
                "type": "number",
                "description": "For 'superheat': measured suction line temperature (°F)."
            ],
            "suction_line_temp_c": [
                "type": "number",
                "description": "For 'superheat': measured suction line temperature (°C)."
            ],
            "liquid_pressure_psig": [
                "type": "number",
                "description": "For 'subcool': liquid-side gauge pressure (psig)."
            ],
            "liquid_pressure_kpa": [
                "type": "number",
                "description": "For 'subcool': liquid-side gauge pressure (kPa)."
            ],
            "liquid_pressure_bar": [
                "type": "number",
                "description": "For 'subcool': liquid-side gauge pressure (bar)."
            ],
            "liquid_line_temp_f": [
                "type": "number",
                "description": "For 'subcool': measured liquid line temperature (°F)."
            ],
            "liquid_line_temp_c": [
                "type": "number",
                "description": "For 'subcool': measured liquid line temperature (°C)."
            ],
            "pressure_reference": [
                "type": "string",
                "description": "'gauge' (default) or 'absolute' when the instrument reads absolute (psia, kPa abs, bar abs)."
            ],
            "altitude_ft": [
                "type": "number",
                "description": "Optional site altitude (feet) to correct gauge pressure for local atmosphere."
            ],
            "altitude_m": [
                "type": "number",
                "description": "Optional site altitude (metres) to correct gauge pressure for local atmosphere."
            ],
            "refrigerant_source": [
                "type": "string",
                "enum": ["nameplate", "technician", "display"],
                "description": "Where 'refrigerant' came from: the nameplate, the technician, or the unit's display. Default 'technician'."
            ],
            "application": [
                "type": "string",
                "enum": ["cooling", "heating", "refrigeration"],
                "description": "For 'superheat'/'subcool', what the system is doing if the technician said: comfort cooling, heat pump heating, or refrigeration. Narrows the plausibility check."
            ],
            "phase": [
                "type": "string",
                "enum": ["single", "three"],
                "description": "For 'voltage_drop': a single-phase or a three-phase run. Never assumed."
            ],
            "current_a": ["type": "number", "description": "For 'voltage_drop': the current the run carries (A)."],
            "length_m": ["type": "number", "description": "For 'voltage_drop': the run's one-way length (m)."],
            "length_ft": ["type": "number", "description": "For 'voltage_drop': the run's one-way length (ft)."],
            "resistance_ohm_per_km": ["type": "number", "description": "For 'voltage_drop': conductor resistance (Ω/km)."],
            "resistance_ohm_per_m": ["type": "number", "description": "For 'voltage_drop': conductor resistance (Ω/m)."],
            "resistance_ohm_per_1000ft": ["type": "number", "description": "For 'voltage_drop': conductor resistance (Ω per 1000 ft)."],
            "resistance_ohm_per_ft": ["type": "number", "description": "For 'voltage_drop': conductor resistance (Ω/ft)."],
            "k_factor_ohm_mm2_per_m": ["type": "number", "description": "For 'voltage_drop' instead of a resistance: the factor (Ω·mm²/m), with 'area_mm2'."],
            "area_mm2": ["type": "number", "description": "For 'voltage_drop': the conductor's area (mm²), with 'k_factor_ohm_mm2_per_m'."],
            "k_factor_ohm_cmil_per_ft": ["type": "number", "description": "For 'voltage_drop' instead of a resistance: the factor (Ω·cmil/ft), with 'area_cmil'."],
            "area_cmil": ["type": "number", "description": "For 'voltage_drop': the conductor's area (circular mils), with 'k_factor_ohm_cmil_per_ft'."],
            "wire_awg": ["type": "string", "description": "For 'voltage_drop': the wire's AWG size ('14', '1/0'), with 'material'. Enough without a resistance or area."],
            "material": ["type": "string", "enum": ["copper", "aluminum"], "description": "For 'voltage_drop' with 'wire_awg': the conductor's metal. Never assumed."],
            "supply_v": ["type": "number", "description": "For 'voltage_drop': the supply voltage, for the drop as a percentage."]
        ],
        "required": ["operation"]
    ]

    private let bundle: Bundle
    /// Where a spoken superheat or subcool is filed. Nil records nothing (the tool outside a job,
    /// and tests that only check the arithmetic); the app passes the shared session service.
    private let recorder: (any RefrigerantReadingFiling)?
    private let now: () -> Date

    init(bundle: Bundle = .main, recorder: (any RefrigerantReadingFiling)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.bundle = bundle
        self.recorder = recorder
        self.now = now
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let operation = (args["operation"] as? String)?.lowercased() else {
            return "Specify 'operation': 'pt_lookup', 'superheat', or 'subcool' (refrigerant), or 'voltage_drop' (electrical)."
        }
        if operation == "voltage_drop" { return Self.voltageDrop(args) }
        guard let rawRefrigerant = (args["refrigerant"] as? String)?.trimmingCharacters(in: .whitespaces),
              !rawRefrigerant.isEmpty else {
            return "Specify 'refrigerant' (e.g. 'R-410A'), from the nameplate or the technician. It is never assumed."
        }
        guard let table = SaturationTableCatalog.table(for: rawRefrigerant, bundle: bundle) else {
            return "No saturation table for '\(rawRefrigerant)'. Tables: " +
                SaturationTableCatalog.designations.joined(separator: ", ") +
                ". Give the pressures only, and confirm the refrigerant from the nameplate."
        }
        let site: Site
        switch Self.site(args) {
        case .success(let value): site = value
        case .failure(let message): return message.text
        }
        let absolute = (args["pressure_reference"] as? String)?.lowercased() == "absolute"

        switch operation {
        case "pt_lookup":
            return ptLookup(table: table, args: args, site: site, absolute: absolute)

        case "superheat":
            guard let reading = Self.pressure(args, prefix: "suction_pressure"),
                  let line = Self.temperature(args, prefix: "suction_line_temp") else {
                return "Specify a suction pressure ('suction_pressure_psig', '_kpa' or '_bar') and the suction " +
                    "line temperature ('suction_line_temp_f' or '_c') for superheat."
            }
            return lineCalculation(.superheat, table: table, reading: reading, line: line,
                                   site: site, absolute: absolute, spoken: Self.spokenContext(args))

        case "subcool", "subcooling":
            guard let reading = Self.pressure(args, prefix: "liquid_pressure"),
                  let line = Self.temperature(args, prefix: "liquid_line_temp") else {
                return "Specify a liquid pressure ('liquid_pressure_psig', '_kpa' or '_bar') and the liquid " +
                    "line temperature ('liquid_line_temp_f' or '_c') for subcool."
            }
            return lineCalculation(.subcool, table: table, reading: reading, line: line,
                                   site: site, absolute: absolute, spoken: Self.spokenContext(args))

        default:
            return "Unknown operation '\(operation)'. Use 'pt_lookup', 'superheat', 'subcool', or 'voltage_drop'."
        }
    }

    // MARK: - Voltage drop (Plan JJ P4)

    /// The drop along a run, or what is missing. Every input is the technician's or a table's in
    /// the organisation's own book; none is assumed.
    nonisolated static func voltageDrop(_ args: [String: Any]) -> String {
        guard let phase = (args["phase"] as? String).flatMap(VoltageDrop.Phase.init(words:)) else {
            return "Specify 'phase': 'single' or 'three'. The phase is never assumed: ask the technician."
        }
        guard let current = number(args["current_a"]) else {
            return "Specify 'current_a', the current the run carries in amps."
        }
        let length: (Double, VoltageDrop.LengthUnit)
        if let metres = number(args["length_m"]) { length = (metres, .metres) }
        else if let feet = number(args["length_ft"]) { length = (feet, .feet) }
        else { return "Specify the run's one-way length, 'length_m' or 'length_ft'." }

        let resistances: [(String, VoltageDrop.ResistanceUnit)] = [
            ("resistance_ohm_per_km", .ohmsPerKilometre), ("resistance_ohm_per_m", .ohmsPerMetre),
            ("resistance_ohm_per_1000ft", .ohmsPerThousandFeet), ("resistance_ohm_per_ft", .ohmsPerFoot),
        ]
        var conductor: VoltageDrop.Conductor?
        var sizing: VoltageDrop.Sizing?
        for (key, unit) in resistances {
            if let value = number(args[key]) { conductor = .resistance(value, unit); break }
        }
        if conductor == nil {
            let cmilFactor = number(args["k_factor_ohm_cmil_per_ft"])
            let cmilArea = number(args["area_cmil"])
            let gaugeWords = text(args["wire_awg"])
            if let k = number(args["k_factor_ohm_mm2_per_m"]) {
                guard let area = number(args["area_mm2"]) else {
                    return "A factor in Ω·mm²/m needs the conductor's area in mm² ('area_mm2'). It is never assumed."
                }
                conductor = .factor(k, .ohmSquareMillimetresPerMetre, area: area)
            } else if cmilFactor != nil || cmilArea != nil || gaugeWords != nil {
                // A wire size gives the area and the material the factor (Plan MQ P3); a factor or an
                // area that was given wins over them.
                var gauge: VoltageDrop.WireGauge?
                if cmilArea == nil, let gaugeWords {
                    guard let size = VoltageDrop.WireGauge(words: gaugeWords) else {
                        return "'wire_awg' must be an AWG size from 18 to 4/0 (18, 16, 14, 12, 10, 8, 6, 4, 3, 2, 1, "
                            + "1/0, 2/0, 3/0 or 4/0); '\(gaugeWords)' is not one. For another size, give the "
                            + "conductor's resistance per unit length or its area in circular mils ('area_cmil')."
                    }
                    gauge = size
                }
                guard let area = cmilArea ?? gauge?.circularMils else {
                    return "A factor in Ω·cmil/ft needs the conductor's area in circular mils ('area_cmil') or its "
                        + "AWG size ('wire_awg'). It is never assumed."
                }
                var material: VoltageDrop.Material?
                if cmilFactor == nil {
                    guard let metal = text(args["material"]).flatMap(VoltageDrop.Material.init(words:)) else {
                        return "Specify 'material': 'copper' or 'aluminum', the conductor's metal. It is never "
                            + "assumed: ask the technician."
                    }
                    material = metal
                }
                conductor = .factor(cmilFactor ?? material?.factor ?? 0, .ohmCircularMilsPerFoot, area: area)
                if gauge != nil || material != nil { sizing = VoltageDrop.Sizing(gauge: gauge, material: material) }
            }
        }
        guard let conductor else {
            return "Specify the conductor's resistance per unit length ('resistance_ohm_per_km', 'resistance_ohm_per_m', "
                + "'resistance_ohm_per_1000ft' or 'resistance_ohm_per_ft'), or a factor with the conductor's area "
                + "('k_factor_ohm_mm2_per_m' with 'area_mm2', or 'k_factor_ohm_cmil_per_ft' with 'area_cmil'), as the "
                + "technician gives it or a table in the organisation's own book prints it, or the wire's AWG size with "
                + "its metal ('wire_awg' with 'material'). No resistance or factor is assumed: ask, or look it up with "
                + "table_lookup."
        }
        let input = VoltageDrop.Input(phase: phase, current: current, length: length.0, lengthUnit: length.1,
                                      conductor: conductor, supply: number(args["supply_v"]), sizing: sizing)
        switch VoltageDrop.compute(input) {
        case .success(let output): return VoltageDrop.render(output)
        case .failure(.notPositive(let name)): return "The \(name) must be a number above zero."
        }
    }

    // MARK: - Operations

    private enum LineCalculation {
        case superheat, subcool

        var kind: RefrigerantLineCalculation.Kind { self == .superheat ? .superheat : .subcool }
        var title: String { self == .superheat ? "Superheat" : "Subcooling" }
        var point: String { self == .superheat ? "dew point" : "bubble point" }
        var side: String { self == .superheat ? "suction" : "liquid" }
        var role: GaugeRole { self == .superheat ? .suction : .liquid }
    }

    /// What the technician said about the system and the refrigerant, for the plausibility band
    /// and the record.
    private struct SpokenContext {
        var application: InstrumentPlausibility.RefrigerantApplication = .unspecified
        var refrigerantSource: RefrigerantSource = .technician
    }

    private static func spokenContext(_ args: [String: Any]) -> SpokenContext {
        var context = SpokenContext()
        if let raw = (args["application"] as? String)?.lowercased(),
           let application = InstrumentPlausibility.RefrigerantApplication(rawValue: raw) {
            context.application = application
        }
        if let raw = (args["refrigerant_source"] as? String)?.lowercased(),
           let source = RefrigerantSource(rawValue: raw) {
            context.refrigerantSource = source
        }
        return context
    }

    private func lineCalculation(_ calculation: LineCalculation, table: SaturationTable,
                                 reading: PressureReading, line: TemperatureReading,
                                 site: Site, absolute: Bool, spoken: SpokenContext) -> String {
        let atmosphere = site.atmosphere
        let scale = reading.unit.answerScale
        let pressureKPa = reading.absoluteKPa(atmosphere: atmosphere, absolute: absolute)
        // The same lookup the gauge chain uses (Plan IS P1), so a spoken and a photographed
        // reading give the same number.
        let output: RefrigerantLineCalculation.Output
        switch RefrigerantLineCalculation.compute(calculation.kind, table: table, absoluteKPa: pressureKPa,
                                                  lineTemperature: line.value, lineScale: line.scale,
                                                  scale: scale) {
        case .success(let value): output = value
        case .failure(let error):
            return refusal(error, table: table, reading: reading, atmosphere: atmosphere, absolute: absolute)
        }
        let saturation = output.saturation
        // The band the gauge chain applies to a photographed gauge: a saturation temperature no
        // working system of this kind shows is a misheard number, a swapped hose or real trouble,
        // and in every case it is asked again, not answered.
        if let band = InstrumentPlausibility.refrigerantBand(table: table, role: calculation.role,
                                                             application: spoken.application),
           !band.contains(absoluteKPa: pressureKPa) {
            return askAgain(calculation, band: band, saturation: saturation, scale: scale,
                            table: table, reading: reading, absolute: absolute, application: spoken.application)
        }
        let lineTemp = output.line
        let result = output.difference
        let deg = scale.symbol
        let diff = scale.differenceSymbol
        var answer = "\(calculation.title) ≈ \(fmt(result))\(diff) for \(table.designation): " +
            "\(calculation.side) \(reading.text(absolute: absolute)) is \(fmt(saturation))\(deg) at the " +
            "\(calculation.point), \(calculation.side) line \(fmt(lineTemp))\(deg). "
        answer += glideSentence(table: table, pressureKPa: pressureKPa, scale: scale,
                                using: calculation.point)
        if calculation == .superheat, result < 0 {
            answer += "Negative superheat suggests liquid floodback — recheck readings. "
        }
        if calculation == .subcool, result < 0 {
            answer += "Negative subcool suggests undercharge or flash gas — recheck. "
        }
        answer += atmosphereSentence(site, absolute: absolute)
        answer += "Saturation data: \(table.sourceName), \(calculation.point). (Source: superheat_subcool.md)"
        if let note = recordSpoken(calculation, reading: reading, line: line, absolute: absolute,
                                   table: table, source: spoken.refrigerantSource) {
            answer += " " + note
        }
        return answer
    }

    /// "That's a -16°F dew point for R-410A, outside the 14 to 68°F range for a suction line in
    /// cooling. Did you say 30 psig? Check the reading before I work it out."
    private func askAgain(_ calculation: LineCalculation, band: InstrumentPlausibility.RefrigerantPressureBand,
                          saturation: Double, scale: TemperatureScale, table: SaturationTable,
                          reading: PressureReading, absolute: Bool,
                          application: InstrumentPlausibility.RefrigerantApplication) -> String {
        let deg = scale.symbol
        let low = fmt(scale.fromKelvin(band.windowKelvin.lowerBound))
        let window = band.highKPa == nil
            ? "below the \(low)\(deg) minimum"
            : "outside the \(low) to \(fmt(scale.fromKelvin(band.windowKelvin.upperBound)))\(deg) range"
        return "That's a \(fmt(saturation))\(deg) \(calculation.point) for \(table.designation), \(window) for a "
            + "\(calculation.side) line\(application.phrase). Did you say \(reading.text(absolute: absolute))? "
            + "Check the reading before I work it out."
    }

    /// Files the spoken pressure and line temperature on the open job — each once, with the
    /// refrigerant and where it came from — and says so. Nil with no job open, or no recorder.
    private func recordSpoken(_ calculation: LineCalculation, reading: PressureReading, line: TemperatureReading,
                              absolute: Bool, table: SaturationTable, source: RefrigerantSource) -> String? {
        guard let recorder, recorder.isOpenForEvidence else { return nil }
        let at = now()
        let entries: [(quantity: String, value: String, unit: String)] = [
            ("\(calculation.side) pressure", fmt(reading.value),
             absolute ? reading.unit.absoluteSymbol : reading.unit.gaugeSymbol),
            ("\(calculation.side) line temperature", fmt(line.value), line.scale.symbol),
        ]
        var recorded = 0
        for entry in entries {
            // No method: said aloud is how `SpokenReading` has always recorded a reading.
            if recorder.recordInstrumentReading(quantity: entry.quantity, value: entry.value, unit: entry.unit,
                                                method: nil, photoId: nil, refrigerant: table.designation,
                                                refrigerantSource: source.rawValue, at: at) != nil {
                recorded += 1
            }
        }
        guard recorded > 0 else { return nil }
        return recorded == 1 ? "Recorded 1 reading on the job." : "Recorded \(recorded) readings on the job."
    }

    private func ptLookup(table: SaturationTable, args: [String: Any], site: Site,
                          absolute: Bool) -> String {
        let atmosphere = site.atmosphere
        if let reading = Self.pressure(args, prefix: "pressure") {
            let scale = reading.unit.answerScale
            let pressureKPa = reading.absoluteKPa(atmosphere: atmosphere, absolute: absolute)
            let dew = table.temperature(atAbsoluteKPa: pressureKPa, scale: scale, curve: .dew)
            let bubble = table.temperature(atAbsoluteKPa: pressureKPa, scale: scale, curve: .bubble)
            switch (dew, bubble) {
            case (.success(let dewTemp), .success(let bubbleTemp)):
                var answer = "\(table.designation) at \(reading.text(absolute: absolute)): "
                let deg = scale.symbol
                if table.isSingleComponent {
                    answer += "saturation \(fmt(dewTemp))\(deg) (single component, no glide). "
                } else {
                    answer += "dew point \(fmt(dewTemp))\(deg), bubble point \(fmt(bubbleTemp))\(deg) " +
                        "(glide \(fmt(dewTemp - bubbleTemp))\(scale.differenceSymbol)). " +
                        "Use the dew point for superheat and the bubble point for subcooling. "
                }
                answer += atmosphereSentence(site, absolute: absolute)
                answer += "Saturation data: \(table.sourceName), \(table.isSingleComponent ? "saturation" : "dew and bubble points")."
                return answer
            case (.failure(let error), _), (_, .failure(let error)):
                return refusal(error, table: table, reading: reading, atmosphere: atmosphere, absolute: absolute)
            }
        }
        if let temperature = Self.temperature(args, prefix: "temperature") {
            let scale = temperature.scale
            let unit: RefrigerantPressure.Unit = scale == .fahrenheit ? .psi : .kPa
            let dew = table.absolutePressureKPa(atTemperature: temperature.value, scale: scale, curve: .dew)
            let bubble = table.absolutePressureKPa(atTemperature: temperature.value, scale: scale, curve: .bubble)
            switch (dew, bubble) {
            case (.success(let dewKPa), .success(let bubbleKPa)):
                let show: (Double) -> String = { kPa in
                    absolute
                        ? "\(self.fmt(kPa / unit.kPa)) \(unit.absoluteSymbol)"
                        : "\(self.fmt(RefrigerantPressure.gauge(absoluteKPa: kPa, unit: unit, atmosphere: atmosphere))) \(unit.gaugeSymbol)"
                }
                var answer = "\(table.designation) at \(fmt(temperature.value))\(scale.symbol): "
                if table.isSingleComponent {
                    answer += "saturation pressure \(show(dewKPa)). "
                } else {
                    answer += "dew pressure \(show(dewKPa)), bubble pressure \(show(bubbleKPa)). "
                }
                answer += atmosphereSentence(site, absolute: absolute)
                answer += "Saturation data: \(table.sourceName), \(table.isSingleComponent ? "saturation" : "dew and bubble points")."
                return answer
            case (.failure(let error), _), (_, .failure(let error)):
                if case .temperatureOutOfTable(_, let minimum, let maximum, _) = error {
                    return "\(fmt(temperature.value))\(scale.symbol) is outside the \(table.designation) table " +
                        "(\(fmt(minimum))\(scale.symbol) to \(fmt(maximum))\(scale.symbol)). " +
                        "No saturation pressure is given outside it."
                }
                return "\(fmt(temperature.value))\(scale.symbol) is outside the \(table.designation) table."
            }
        }
        return "Specify a gauge pressure ('pressure_psig', 'pressure_kpa' or 'pressure_bar') or a temperature " +
            "('temperature_f' or 'temperature_c') for pt_lookup."
    }

    // MARK: - Sentences

    private func glideSentence(table: SaturationTable, pressureKPa: Double, scale: TemperatureScale,
                               using point: String) -> String {
        if table.isSingleComponent {
            return "\(table.designation) is a single component: no glide. "
        }
        guard case .success(let glide) = table.glide(atAbsoluteKPa: pressureKPa, scale: scale) else {
            return "Uses the \(point). "
        }
        return "Glide \(fmt(glide))\(scale.differenceSymbol) at this pressure; this uses the \(point). "
    }

    private func atmosphereSentence(_ site: Site, absolute: Bool) -> String {
        if absolute { return "Absolute pressure: no atmospheric correction. " }
        guard let altitude = site.altitudeText, !site.atmosphere.assumesSeaLevel else {
            return "Assumes sea-level atmosphere (101.325 kPa); give an altitude to correct it. "
        }
        return "Corrected for altitude \(altitude): atmosphere \(fmt(site.atmosphere.pressureKPa)) kPa. "
    }

    private func refusal(_ error: SaturationLookupError, table: SaturationTable, reading: PressureReading,
                         atmosphere: Atmosphere, absolute: Bool) -> String {
        let scale = reading.unit.answerScale
        let grid = table.grid(scale)
        let edge: (Double) -> String = { kPa in
            absolute
                ? "\(self.fmt(kPa / reading.unit.kPa)) \(reading.unit.absoluteSymbol)"
                : "\(self.fmt(RefrigerantPressure.gauge(absoluteKPa: kPa, unit: reading.unit, atmosphere: atmosphere))) \(reading.unit.gaugeSymbol)"
        }
        switch error {
        case .pressureBelowTable(_, let minimum):
            return "\(reading.text(absolute: absolute)) is below the \(table.designation) table, which starts at " +
                "\(fmt(grid.start))\(scale.symbol) (\(edge(minimum))). No saturation temperature is given outside it."
        case .pressureAboveTable(_, let maximum, let aboveCritical):
            if aboveCritical {
                let critical = scale.fromKelvin(table.criticalTemperatureK)
                return "\(reading.text(absolute: absolute)) is above the \(table.designation) table, which ends near " +
                    "its critical point (\(fmt(critical))\(scale.symbol)); above it there is no saturation " +
                    "temperature. The table's last point is \(fmt(grid.end))\(scale.symbol) (\(edge(maximum)))."
            }
            return "\(reading.text(absolute: absolute)) is above the \(table.designation) table, which ends at " +
                "\(fmt(grid.end))\(scale.symbol) (\(edge(maximum))). No saturation temperature is given outside it."
        case .temperatureOutOfTable(_, let minimum, let maximum, let scale):
            return "Outside the \(table.designation) table (\(fmt(minimum))\(scale.symbol) to \(fmt(maximum))\(scale.symbol))."
        }
    }

    // MARK: - Arguments

    private struct PressureReading {
        let value: Double
        let unit: RefrigerantPressure.Unit

        func absoluteKPa(atmosphere: Atmosphere, absolute: Bool) -> Double {
            absolute
                ? RefrigerantPressure.absoluteKPa(absolute: value, unit: unit)
                : RefrigerantPressure.absoluteKPa(gauge: value, unit: unit, atmosphere: atmosphere)
        }

        func text(absolute: Bool) -> String {
            "\(DomainCalcTool.oneDecimal(value)) \(absolute ? unit.absoluteSymbol : unit.gaugeSymbol)"
        }
    }

    private struct TemperatureReading {
        let value: Double
        let scale: TemperatureScale
    }

    private struct ArgumentProblem: Error { let text: String }

    /// The first pressure given under `<prefix>_psig`, `<prefix>_kpa` or `<prefix>_bar`.
    private static func pressure(_ args: [String: Any], prefix: String) -> PressureReading? {
        if let value = number(args["\(prefix)_psig"]) { return PressureReading(value: value, unit: .psi) }
        if let value = number(args["\(prefix)_kpa"]) { return PressureReading(value: value, unit: .kPa) }
        if let value = number(args["\(prefix)_bar"]) { return PressureReading(value: value, unit: .bar) }
        return nil
    }

    /// The temperature given under `<prefix>_f` or `<prefix>_c`.
    private static func temperature(_ args: [String: Any], prefix: String) -> TemperatureReading? {
        if let value = number(args["\(prefix)_f"]) { return TemperatureReading(value: value, scale: .fahrenheit) }
        if let value = number(args["\(prefix)_c"]) { return TemperatureReading(value: value, scale: .celsius) }
        return nil
    }

    /// The atmosphere the gauge reads against, and the altitude as it was given.
    private struct Site {
        let atmosphere: Atmosphere
        let altitudeText: String?
    }

    private static func site(_ args: [String: Any]) -> Result<Site, ArgumentProblem> {
        if let metres = number(args["altitude_m"]) {
            guard let atmosphere = Atmosphere.at(altitudeMetres: metres) else {
                return .failure(ArgumentProblem(text: altitudeRefusal))
            }
            return .success(Site(atmosphere: atmosphere, altitudeText: "\(wholeNumber(metres)) m"))
        }
        if let feet = number(args["altitude_ft"]) {
            guard let atmosphere = Atmosphere.at(altitudeFeet: feet) else {
                return .failure(ArgumentProblem(text: altitudeRefusal))
            }
            return .success(Site(atmosphere: atmosphere, altitudeText: "\(wholeNumber(feet)) ft"))
        }
        return .success(Site(atmosphere: .seaLevel, altitudeText: nil))
    }

    private static func wholeNumber(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private static let altitudeRefusal =
        "The altitude is outside what the correction accepts (−500 m to 6,000 m, about −1,640 ft to 19,690 ft)."

    /// Text, or a number said as text ("14" for a wire size sent as 14); nil when empty.
    nonisolated private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return number(value).map(VoltageDrop.given)
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let d = value as? Double { parsed = d }
        else if let i = value as? Int { parsed = Double(i) }
        else if let s = value as? String { parsed = Double(s.trimmingCharacters(in: .whitespaces)) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    // MARK: - Helpers

    private func fmt(_ value: Double) -> String { Self.oneDecimal(value) }

    /// One decimal place, dropped when it is zero: "39.8", "40", "-40".
    nonisolated static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0" }
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

private extension RefrigerantPressure.Unit {
    /// psig answers in °F; kPa and bar answer in °C.
    var answerScale: TemperatureScale { self == .psi ? .fahrenheit : .celsius }
}
