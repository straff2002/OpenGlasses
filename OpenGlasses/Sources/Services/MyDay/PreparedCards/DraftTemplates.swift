import Foundation

// Plan KT §4.1 — every kind with a draft has a deterministic template, localised in the catalogue
// and filled from the card's facts. A template is always the fallback: when no model is allowed,
// when a model fails, or when its output fails validation.
//
// A draft is written in the *draft's* language — the wearer's, or the contact's when known — which
// need not be the language the app is showing. So a template is looked up in that language's
// bundle, not with the app's current localisation, and its values are formatted in that locale.
// Placeholders are named (`{arrival}`), so a translation can put them in any order; anything left
// unfilled is caught by `DraftValidator` as a placeholder left in.

/// The templates, one per sentence a draft is made of.
enum DraftTemplateID: String, CaseIterable, Sendable {
    /// Leave by: "On my way — there about {arrival}."
    case onMyWay
    /// Running late: "Running about {minutes} minutes late, sorry — there about {arrival}."
    case runningLate
    /// Short night: "Could we move {meeting} to {slot}? It would suit me better today."
    case askToMove
    /// Meeting follow-up, before the list: "Thanks for today. Here's what we agreed:"
    case recapIntro
    /// Meeting follow-up email subject: "Recap: {meeting}"
    case recapSubject
    /// Job on my way, with the wearer's name and company.
    case jobOnMyWayFromCompany
    /// Job on my way, with the wearer's name only.
    case jobOnMyWayFromWearer
    /// Job on my way, with neither.
    case jobOnMyWay
    /// Job running late.
    case jobRunningLate
    /// An email's greeting to one person: "Hi {name},"
    case greetingOne
    /// An email's greeting to several: "Hi all,"
    case greetingAll
}

/// Where template text comes from. Production reads the string catalogue; tests inject tables.
protocol DraftTemplateSource {
    func template(_ id: DraftTemplateID, language: String) -> String
}

/// The string catalogue, in the draft's language.
struct CatalogDraftTemplates: DraftTemplateSource {
    var bundle: Bundle = .main

    func template(_ id: DraftTemplateID, language: String) -> String {
        let bundle = Self.bundle(for: language, in: self.bundle)
        let locale = Locale(identifier: language)
        switch id {
        case .onMyWay:
            return String(localized: "On my way — there about {arrival}.", bundle: bundle, locale: locale,
                          comment: "A drafted text to someone the wearer is meeting. Keep {arrival} (a time) as is.")
        case .runningLate:
            return String(localized: "Running about {minutes} minutes late, sorry — there about {arrival}.",
                          bundle: bundle, locale: locale,
                          comment: "A drafted text. Keep {minutes} (a number) and {arrival} (a time) as they are.")
        case .askToMove:
            return String(localized: "Could we move {meeting} to {slot}? It would suit me better today.",
                          bundle: bundle, locale: locale,
                          comment: "A drafted email to a meeting's organiser. Keep {meeting} (its title) and {slot} (a time). Never mention sleep.")
        case .recapIntro:
            return String(localized: "Thanks for today. Here's what we agreed:", bundle: bundle, locale: locale,
                          comment: "A drafted meeting recap email; a list of agreed actions follows.")
        case .recapSubject:
            return String(localized: "Recap: {meeting}", bundle: bundle, locale: locale,
                          comment: "Subject of a drafted meeting recap email. Keep {meeting} (its title) as is.")
        case .jobOnMyWayFromCompany:
            return String(localized: "Hi {name}, it's {wearer} from {company}. On my way, there about {arrival}.",
                          bundle: bundle, locale: locale,
                          comment: "A drafted text from a technician to a customer. Keep {name}, {wearer}, {company} and {arrival} (a time).")
        case .jobOnMyWayFromWearer:
            return String(localized: "Hi {name}, it's {wearer}. On my way, there about {arrival}.",
                          bundle: bundle, locale: locale,
                          comment: "A drafted text from a technician to a customer. Keep {name}, {wearer} and {arrival} (a time).")
        case .jobOnMyWay:
            return String(localized: "Hi {name}, on my way, there about {arrival}.",
                          bundle: bundle, locale: locale,
                          comment: "A drafted text from a technician to a customer. Keep {name} and {arrival} (a time).")
        case .jobRunningLate:
            return String(localized: "Hi {name}, running about {minutes} minutes behind — there about {arrival}. Sorry for the wait.",
                          bundle: bundle, locale: locale,
                          comment: "A drafted text from a technician to a customer. Keep {name}, {minutes} (a number) and {arrival} (a time).")
        case .greetingOne:
            return String(localized: "Hi {name},", bundle: bundle, locale: locale,
                          comment: "The first line of a drafted email to one person. Keep {name}.")
        case .greetingAll:
            return String(localized: "Hi all,", bundle: bundle, locale: locale,
                          comment: "The first line of a drafted email to several people.")
        }
    }

    /// The `.lproj` for `language` ("pt-BR", then "pt"), else the base bundle.
    static func bundle(for language: String, in base: Bundle) -> Bundle {
        var candidates = [language]
        if let dash = language.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            candidates.append(String(language[..<dash]))
        }
        for candidate in candidates {
            if let path = base.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return base
    }
}

enum DraftTemplates {

    /// Replaces every `{key}` in `template` with its value. Keys without a value are left as they
    /// are, so the validator can refuse the result.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    /// One template, filled.
    static func text(_ id: DraftTemplateID, _ values: [String: String] = [:], language: String,
                     source: DraftTemplateSource) -> String {
        fill(source.template(id, language: language), values)
    }

    /// An email: a greeting, the body, and the wearer's name to sign off when there is one.
    /// `greetingName` nil greets everyone.
    static func email(greetingName: String?, body: String, signOff: String?, language: String,
                      source: DraftTemplateSource) -> String {
        let greeting = greetingName.map { text(.greetingOne, ["name": $0], language: language, source: source) }
            ?? text(.greetingAll, language: language, source: source)
        return ([greeting, body] + [signOff].compactMap { $0 }).joined(separator: "\n\n")
    }

    /// The action items as a list: "• item", one a line. A bullet character, not Markdown.
    static func bulletList(_ items: [String]) -> String {
        items.map { "• \($0)" }.joined(separator: "\n")
    }

    /// A time of day in the draft's language: "18:15", "6:15 PM".
    static func time(_ date: Date, language: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A whole number in the draft's language.
    static func number(_ value: Int, language: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
