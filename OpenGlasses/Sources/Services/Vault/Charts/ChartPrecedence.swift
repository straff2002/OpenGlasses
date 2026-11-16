import Foundation

/// Which source answers when a manual gives one quantity more than one way (Plan LX §6). A value
/// printed as text beats a certain cell read from a pictured table, which beats a value the app
/// computes from bundled data, which beats a value read off a chart. A lower source answers only
/// when no higher one does. Pure.
///
/// Not wired into `table_lookup` or `domain_calc` yet (P2's rest): this is the rule they will use.
enum ChartPrecedence {

    enum Source: Int, Comparable, Equatable {
        /// A value printed as text in the manual: a text-layer table.
        case printed = 0
        /// A certain cell of a table read from a picture.
        case recognisedCell = 1
        /// A value the app computes from bundled data (a saturation temperature).
        case computed = 2
        /// A value read off a chart.
        case chart = 3

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Decision: Equatable {
        /// The source that answers, and its value.
        let source: Source
        let value: Double
        /// The chart answered too and differed from the chosen value by more than two of its
        /// steps. The caller counts it — never the values — so a misread chart shows up in support
        /// reports. The chart is not mentioned in the answer.
        let chartDisagreed: Bool

        /// Whether the answer may say the value came from a chart: only when the chart is the
        /// source that answers.
        var mentionsChart: Bool { source == .chart }
    }

    /// How many of the chart's steps apart two values must be to count as disagreeing.
    static let disagreementSteps = 2.0

    /// The answer for one quantity. `recognised` is a pictured table's cell and whether it was
    /// read certainly; an uncertain cell never answers. Nil when nothing answers.
    static func choose(printed: Double?, recognised: (value: Double, certain: Bool)?, computed: Double?,
                       chart: ChartValue?) -> Decision? {
        var higher: (source: Source, value: Double)?
        if let printed {
            higher = (.printed, printed)
        } else if let recognised, recognised.certain {
            higher = (.recognisedCell, recognised.value)
        } else if let computed {
            higher = (.computed, computed)
        }
        if let higher {
            let disagreed = chart.map { abs($0.about - higher.value) > disagreementSteps * $0.step } ?? false
            return Decision(source: higher.source, value: higher.value, chartDisagreed: disagreed)
        }
        guard let chart else { return nil }
        return Decision(source: .chart, value: chart.about, chartDisagreed: false)
    }

    /// The count a disagreement adds to the diagnostics: how many, never which values.
    struct DisagreementTally: Equatable {
        private(set) var count = 0

        mutating func note(_ decision: Decision?) {
            if decision?.chartDisagreed == true { count += 1 }
        }
    }
}

/// Charts whose value must always send the technician to the page (Plan LX §7): refrigerant charge,
/// electrical limits, fuel gas and combustion. Decided from the chart's caption, titles and units,
/// matched as content terms under the document's own `TermRule` (`LexicalSupport`), so a word is
/// compared the way the evidence gate compares it. Pure.
///
/// A critical chart's page always opens with what is said about it (`FigureAutoOpenPolicy`), a
/// value from it never feeds a chain step silently, and it is never the unit's specification in a
/// pass/fail sentence. Fan and pump curves and most performance charts are ordinary.
enum ChartSafetyClass: Equatable {
    case critical(Category)
    case ordinary

    enum Category: String, Equatable, CaseIterable {
        case refrigerantCharge = "refrigerant_charge"
        case electricalLimit = "electrical_limit"
        case fuelGas = "fuel_gas"
        case combustion
    }

    var isCritical: Bool {
        if case .critical = self { return true }
        return false
    }

    /// Each category's words and phrases (every word of a phrase must be present), in the
    /// interface languages measured first: English, German, French and Spanish.
    static let vocabulary: [Category: [String]] = [
        .refrigerantCharge: [
            "superheat", "subcooling", "subcool", "charging", "charge", "liquid line", "suction",
            "überhitzung", "unterkühlung", "füllmenge", "befüllung", "saugleitung", "flüssigkeitsleitung",
            "surchauffe", "sous-refroidissement", "sous refroidissement", "charge frigorifique", "aspiration",
            "sobrecalentamiento", "subenfriamiento", "carga de refrigerante", "aspiración", "línea de líquido",
        ],
        .electricalLimit: [
            "derating", "ampacity", "conductor", "conductors",
            "leistungsminderung", "strombelastbarkeit", "leiter",
            "déclassement", "courant admissible", "conducteur",
            "reducción de potencia", "ampacidad", "conductor eléctrico",
        ],
        .fuelGas: [
            "manifold pressure", "orifice", "input rating", "gas pressure", "gas input",
            "düsendruck", "gasdruck", "düse", "wärmebelastung",
            "pression d'alimentation gaz", "pression gaz", "injecteur", "débit calorifique",
            "presión del colector", "presión de gas", "orificio", "potencia de entrada",
        ],
        .combustion: [
            "combustion", "flue", "excess air",
            "verbrennung", "abgas", "luftüberschuss",
            "combustion", "fumées", "excès d'air",
            "combustión", "humos", "exceso de aire",
        ],
    ]

    /// Current against temperature is an electrical limit even with no other word for one.
    static let currentWords = ["current", "amps", "ampere", "amperes", "strom", "courant", "corriente"]
    static let temperatureWords = ["temperature", "ambient", "temperatur", "température", "temperatura"]

    static func classify(caption: String?, titles: [String], units: [String], rule: TermRule = .english) -> ChartSafetyClass {
        let text = ([caption ?? ""] + titles + units).joined(separator: " ")
        let terms = LexicalSupport.contentTerms(text, rule: rule)
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        // Every word of the phrase: a content word as a term, a word too short to be one ("gas",
        // "air") as itself, so "gas pressure" is never matched by "pressure" alone.
        func has(_ phrase: String) -> Bool {
            let parts = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            guard !parts.isEmpty else { return false }
            return parts.allSatisfy { part in
                let term = LexicalSupport.contentTerms(part, rule: rule)
                return term.isEmpty ? (words.contains(part) || part.count < 3) : term.isSubset(of: terms)
            }
        }
        for category in Category.allCases where vocabulary[category, default: []].contains(where: has) {
            return .critical(category)
        }
        // Current up one axis and temperature along the other.
        let unitsSayAmps = units.contains { ["a", "amps", "amp"].contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        if (currentWords.contains(where: has) || unitsSayAmps), temperatureWords.contains(where: has) {
            return .critical(.electricalLimit)
        }
        return .ordinary
    }

    /// The class of a chart found at import, from its caption, axis titles and units.
    static func classify(_ candidate: ChartCandidate, rule: TermRule = .english) -> ChartSafetyClass {
        classify(caption: candidate.caption.map { $0.label + " " + $0.title },
                 titles: candidate.axes.compactMap(\.title) + candidate.insideWords,
                 units: candidate.axes.compactMap(\.unit), rule: rule)
    }
}
