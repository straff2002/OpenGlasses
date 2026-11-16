import Foundation

/// How a chart's value, or a chart's page, is said (Plan LX §5): one place, so *about* and the page
/// are never dropped from any wording in any language.
///
/// The sentences are held here per language rather than in the string catalog, deliberately: the
/// guarantee is that every wording carries the word for *about* and the page, and a translation in
/// a catalog can drop either without any check noticing. Each language's wording is a template
/// whose slots are filled by code, and `ChartCitationTests` proves the word and the page are in
/// every one. A language without a template is said in English. Pure.
enum ChartCitation {

    /// One language's sentences.
    struct Wording: Equatable {
        /// "About" at the start of a sentence, the word the tests look for.
        let about: String
        /// "{about} {value}, read off the chart on page {page}{figure}. That's approximate: check it on the chart."
        let value: String
        /// "That's outside the chart on page {page}{figure}, so the manual doesn't give one."
        let outside: String
        /// "The manual gives this as a chart on page {page}{figure}. Its values haven't been read: check the chart."
        let pageOnly: String
        /// The decimal separator a value is written with.
        let decimal: String
    }

    static let wordings: [String: Wording] = [
        "en": Wording(about: "About",
                      value: "{about} {value}, read off the chart on page {page}{figure}. That's approximate: check it on the chart.",
                      outside: "That's outside the chart on page {page}{figure}, so the manual doesn't give one.",
                      pageOnly: "The manual gives this as a chart on page {page}{figure}. Its values haven't been read: check the chart.",
                      decimal: "."),
        "de": Wording(about: "Etwa",
                      value: "{about} {value}, abgelesen aus dem Diagramm auf Seite {page}{figure}. Das ist ein ungefährer Wert: Prüfen Sie ihn im Diagramm.",
                      outside: "Das liegt außerhalb des Diagramms auf Seite {page}{figure}, daher nennt das Handbuch keinen Wert.",
                      pageOnly: "Das Handbuch gibt dies als Diagramm auf Seite {page}{figure} an. Die Werte wurden nicht abgelesen: Prüfen Sie das Diagramm.",
                      decimal: ","),
        "fr": Wording(about: "Environ",
                      value: "{about} {value}, lu sur le graphique de la page {page}{figure}. C'est approximatif : vérifiez-le sur le graphique.",
                      outside: "C'est en dehors du graphique de la page {page}{figure}, le manuel n'en donne donc pas.",
                      pageOnly: "Le manuel donne ceci sous forme de graphique à la page {page}{figure}. Ses valeurs n'ont pas été lues : vérifiez le graphique.",
                      decimal: ","),
        "es": Wording(about: "Aproximadamente",
                      value: "{about} {value}, leído en el gráfico de la página {page}{figure}. Es aproximado: compruébelo en el gráfico.",
                      outside: "Eso está fuera del gráfico de la página {page}{figure}, así que el manual no da ninguno.",
                      pageOnly: "El manual lo da como un gráfico en la página {page}{figure}. Sus valores no se han leído: compruebe el gráfico.",
                      decimal: ","),
    ]

    /// The wording for a language code ("de", "de-DE", "pt_BR"), English when none is held.
    static func wording(for language: String) -> Wording {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return wordings[code] ?? wordings["en"]!
    }

    /// "About 15 °F, read off the chart on page 41 (Figure 99). That's approximate: check it on the chart."
    static func valueSentence(_ value: ChartValue, page: String, figure: String?, language: String = "en") -> String {
        let wording = wording(for: language)
        return fill(wording.value, wording: wording, page: page, figure: figure)
            .replacingOccurrences(of: "{value}", with: formatted(value, decimal: wording.decimal))
    }

    /// "That's outside the chart on page 41 (Figure 99), so the manual doesn't give one."
    static func outsideSentence(page: String, figure: String?, language: String = "en") -> String {
        let wording = wording(for: language)
        return fill(wording.outside, wording: wording, page: page, figure: figure)
    }

    /// What a chart whose values have not been read says: the page, and to look there.
    static func pageOnlySentence(page: String, figure: String?, language: String = "en") -> String {
        let wording = wording(for: language)
        return fill(wording.pageOnly, wording: wording, page: page, figure: figure)
    }

    /// The page-and-figure label for a chart's page, from `PageEvidencePolicy.label`, so a chart's
    /// page is keyed like every other page the technician is shown.
    static func label(title: String, page: Int, figure: String?) -> String {
        PageEvidencePolicy.label(title: title, page: page, figure: figure)
    }

    /// "15 °F", "0.35 in. w.c.", "20%": the value written to its step's precision, then its unit.
    static func formatted(_ value: ChartValue, decimal: String = ".") -> String {
        let digits = decimals(of: value.step)
        var number = String(format: "%.\(digits)f", value.about)
        if number.hasPrefix("-"), Double(number) == 0 { number.removeFirst() }
        if decimal != "." { number = number.replacingOccurrences(of: ".", with: decimal) }
        guard let unit = value.unit?.trimmingCharacters(in: .whitespaces), !unit.isEmpty else { return number }
        return unit == "%" ? number + unit : number + " " + unit
    }

    /// The decimals a step needs: 0 for 1 or 5, 1 for 0.5, 2 for 0.05.
    static func decimals(of step: Double) -> Int {
        guard step > 0 else { return 0 }
        for digits in 0...4 {
            let scaled = step * pow(10, Double(digits))
            if abs(scaled - scaled.rounded()) < 1e-6 { return digits }
        }
        return 4
    }

    private static func fill(_ template: String, wording: Wording, page: String, figure: String?) -> String {
        let figurePart = figure.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        return template.replacingOccurrences(of: "{about}", with: wording.about)
            .replacingOccurrences(of: "{page}", with: page)
            .replacingOccurrences(of: "{figure}", with: figurePart)
    }
}
