import Foundation

/// Voltage drop along a run (Plan JJ P4): `domain_calc`'s electrical domain, and the arithmetic a
/// rule chain's `calc` step writes out by name.
///
/// The drop is the run's current times its one-way length times the conductor's resistance per
/// unit length, times 2 for a single-phase run (out and back) or √3 for a three-phase run (line to
/// line):
///
/// ```text
/// single-phase   2  × I × L × R
/// three-phase    √3 × I × L × R
/// ```
///
/// The resistance per unit length is either given (`R`, ohms per km, m, 1000 ft or ft) or worked
/// from a factor and the conductor's area (`R = K / A`: K in Ω·mm²/m with A in mm², or K in
/// Ω·cmil/ft with A in circular mils). The resistance, the factor and the area are inputs, given by
/// the technician or read by a chain's lookup from the organisation's own book, and a missing one is
/// refused, never assumed. Resistance only: reactance and power factor are not modelled, which the
/// answer says.
///
/// **One exception, for a run said as a wire size** (Plan MQ P3): "50 feet of 14 gauge copper" is
/// how a technician says it, and a small model cannot turn it into an area or a factor. A
/// `WireGauge` gives the size's area in circular mils (the standard AWG sizes, 18 to 4/0), and a
/// `Material` the usual factor for copper (12.9 Ω·cmil/ft) or aluminium (21.2), both at 75 °C. The
/// material is never assumed, and a resistance, factor or area that is given wins over them. The
/// answer says which values came from here, so a figure from the organisation's book can replace
/// them. Every other number in this file is 2, √3 or a unit's definition.
///
/// Pure.
enum VoltageDrop {

    enum Phase: String, Equatable {
        case single, three

        /// 2 for a single-phase run, √3 for a three-phase one.
        var multiplier: Double { self == .single ? 2 : 3.0.squareRoot() }
        var multiplierText: String { self == .single ? "2" : "√3" }
        var name: String { self == .single ? "single-phase" : "three-phase" }

        /// "single", "1", "single-phase", "1-phase", "three", "3", "3ph", "three phase" …
        init?(words: String) {
            let key = words.lowercased().replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            let first = key.split(separator: " ").first.map(String.init) ?? key
            switch first {
            case "single", "1", "one", "1ph", "single phase": self = .single
            case "three", "3", "3ph", "three phase", "poly", "polyphase": self = .three
            default: return nil
            }
        }
    }

    /// A length unit, as metres per unit.
    enum LengthUnit: String, Equatable {
        case metres = "m"
        case feet = "ft"

        var metres: Double { self == .metres ? 1 : 0.3048 }
    }

    /// A resistance per unit length, as ohms per metre per unit.
    enum ResistanceUnit: String, Equatable, CaseIterable {
        case ohmsPerKilometre = "Ω/km"
        case ohmsPerMetre = "Ω/m"
        case ohmsPerThousandFeet = "Ω/1000 ft"
        case ohmsPerFoot = "Ω/ft"

        var perMetre: Double {
            switch self {
            case .ohmsPerKilometre: return 1 / 1000
            case .ohmsPerMetre: return 1
            case .ohmsPerThousandFeet: return 1 / (1000 * 0.3048)
            case .ohmsPerFoot: return 1 / 0.3048
            }
        }
    }

    /// A conductor factor and the area it is divided by.
    enum FactorUnit: String, Equatable {
        /// K in Ω·mm²/m over an area in mm²: ohms per metre.
        case ohmSquareMillimetresPerMetre = "Ω·mm²/m"
        /// K in Ω·cmil/ft over an area in circular mils: ohms per foot.
        case ohmCircularMilsPerFoot = "Ω·cmil/ft"

        var areaUnit: String { self == .ohmSquareMillimetresPerMetre ? "mm²" : "cmil" }
        /// Ohms per metre for K / A = 1.
        var perMetre: Double { self == .ohmSquareMillimetresPerMetre ? 1 : 1 / 0.3048 }
    }

    /// A standard AWG size and its area. Only the sizes building wire comes in, 18 to 4/0; any
    /// other is refused rather than worked out.
    struct WireGauge: Equatable {
        /// "14", "1/0".
        let name: String
        let circularMils: Double

        static let sizes: [WireGauge] = {
            let table: [(String, Double)] = [
                ("18", 1_620), ("16", 2_580), ("14", 4_110), ("12", 6_530), ("10", 10_380), ("8", 16_510),
                ("6", 26_240), ("4", 41_740), ("3", 52_620), ("2", 66_360), ("1", 83_690),
                ("1/0", 105_600), ("2/0", 133_100), ("3/0", 167_800), ("4/0", 211_600),
            ]
            return table.map { WireGauge(name: $0.0, circularMils: $0.1) }
        }()

        /// "14", "14 AWG", "#12", "12 gauge", "1/0", "00" (2/0), "14.0".
        init?(words: String) {
            var key = words.lowercased()
                .replacingOccurrences(of: #"awg|gauge|ga\b|#|no\.|wire|size"#, with: "", options: .regularExpression)
                .filter { !$0.isWhitespace }
            if key.hasSuffix(".0") { key.removeLast(2) }
            if !key.isEmpty, key.allSatisfy({ $0 == "0" }), key.count <= 4 { key = "\(key.count)/0" }
            guard let size = Self.sizes.first(where: { $0.name == key }) else { return nil }
            self = size
        }

        private init(name: String, circularMils: Double) {
            self.name = name
            self.circularMils = circularMils
        }
    }

    /// A conductor's metal, with the factor a wire size is worked with.
    enum Material: String, Equatable {
        case copper, aluminum

        /// Ω·cmil/ft at 75 °C: the usual figures, used only for a run given as a wire size.
        var factor: Double { self == .copper ? 12.9 : 21.2 }

        /// "copper", "Cu", "aluminium", "aluminum", "Al".
        init?(words: String) {
            let key = words.lowercased().trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("copper") || key == "cu" { self = .copper }
            else if key.hasPrefix("alumin") || key == "al" { self = .aluminum }
            else { return nil }
        }
    }

    /// Which of a factor's values came from a wire size rather than from what was given: the area
    /// from `gauge`, the factor from `material`. Said back in the answer.
    struct Sizing: Equatable {
        var gauge: WireGauge?
        var material: Material?
    }

    /// Where the conductor's resistance per unit length comes from.
    enum Conductor: Equatable {
        case resistance(Double, ResistanceUnit)
        case factor(Double, FactorUnit, area: Double)
    }

    struct Input: Equatable {
        var phase: Phase
        /// Amps.
        var current: Double
        /// One way, in `lengthUnit`.
        var length: Double
        var lengthUnit: LengthUnit
        var conductor: Conductor
        /// Volts, for the drop as a share of it; nil gives the drop in volts only.
        var supply: Double?
        /// Set when a `.factor` conductor's area or factor came from a wire size.
        var sizing: Sizing? = nil
    }

    struct Output: Equatable {
        let input: Input
        /// The conductor's resistance, in ohms per metre.
        let ohmsPerMetre: Double
        let volts: Double
        /// The drop as a percentage of the supply, when one was given.
        let percent: Double?
    }

    enum Problem: Error, Equatable {
        /// A quantity at or below zero, or not a number, by its name.
        case notPositive(String)
    }

    static func compute(_ input: Input) -> Result<Output, Problem> {
        func positive(_ value: Double, _ name: String) -> Problem? {
            value.isFinite && value > 0 ? nil : .notPositive(name)
        }
        if let problem = positive(input.current, "current") ?? positive(input.length, "length") { return .failure(problem) }
        let ohmsPerMetre: Double
        switch input.conductor {
        case .resistance(let value, let unit):
            if let problem = positive(value, "resistance") { return .failure(problem) }
            ohmsPerMetre = value * unit.perMetre
        case .factor(let k, let unit, let area):
            if let problem = positive(k, "factor") ?? positive(area, "area") { return .failure(problem) }
            ohmsPerMetre = k / area * unit.perMetre
        }
        if let supply = input.supply, let problem = positive(supply, "supply") { return .failure(problem) }
        let metres = input.length * input.lengthUnit.metres
        let volts = input.phase.multiplier * input.current * metres * ohmsPerMetre
        let percent = input.supply.map { volts / $0 * 100 }
        return .success(Output(input: input, ohmsPerMetre: ohmsPerMetre, volts: volts, percent: percent))
    }

    // MARK: - Saying it

    /// "3.84 V, 1.67 % of 230 V" and the working, with every input as given.
    static func render(_ output: Output) -> String {
        let input = output.input
        var answer = "Voltage drop ≈ \(number(output.volts)) V"
        if let percent = output.percent, let supply = input.supply {
            answer += ", \(number(percent)) % of the \(number(supply)) V supply"
        }
        answer += " (\(input.phase.name): \(input.phase.multiplierText) × current × one-way length × resistance"
        if case .factor = input.conductor { answer += ", the resistance being the factor ÷ the area" }
        answer += "). "
        answer += "Inputs as given: \(input.phase.name); current \(given(input.current)) A; one-way length "
            + "\(given(input.length)) \(input.lengthUnit.rawValue); "
        switch input.conductor {
        case .resistance(let value, let unit):
            answer += "conductor resistance \(given(value)) \(unit.rawValue)"
        case .factor(let k, let unit, let area):
            if let sizing = input.sizing, sizing.gauge != nil || sizing.material != nil {
                let size = [sizing.gauge.map { "\($0.name) AWG" }, sizing.material?.rawValue].compactMap { $0 }
                answer += "conductor " + size.joined(separator: " ") + ": "
            }
            answer += "factor \(given(k)) \(unit.rawValue), conductor area \(given(area)) \(unit.areaUnit) "
                + "(\(number(output.ohmsPerMetre * 1000)) Ω/km)"
        }
        answer += input.supply.map { "; supply \(given($0)) V. " } ?? ". Give the supply voltage for the drop as a percentage. "
        answer += "Resistance only: reactance and power factor are not included. "
        if let sizing = input.sizing, sizing.gauge != nil || sizing.material != nil {
            let area = sizing.gauge.map { "the area is the standard \($0.name) AWG size" } ?? "the area is the one given"
            let factor = sizing.material.map { "the factor the usual figure for \($0.rawValue) at 75 °C" }
                ?? "the factor the one given"
            answer += "Of the conductor, \(area) and \(factor); a figure from the organisation's own book wins over these."
        } else {
            answer += "The resistance or factor is the one given, not a value from any code or table, so cite where it came from."
        }
        return answer
    }

    /// An input as it was given, to six places at most: "0.875", "20".
    static func given(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.6f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Two places, trailing zeros dropped: "3.84", "4", "0.5".
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
