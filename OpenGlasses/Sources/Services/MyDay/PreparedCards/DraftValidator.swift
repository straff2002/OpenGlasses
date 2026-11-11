import Foundation
import NaturalLanguage

// Plan KT §4.4 — every model draft is checked before it is shown, and every template after it is
// filled. A model draft that fails falls back to the template; a template that fails gives the
// card no draft at all. Pure: no model, no network, no store.

/// What a draft is checked against.
struct DraftValidationContext: Equatable, Sendable {
    let channel: DraftChannel
    /// BCP 47 — the language the template targets.
    let language: String
    /// Text the rule set from the source rows: the card's facts, the template's values, names.
    /// A time, number, address or link in the draft must appear in here.
    let trustedText: [String]
    /// A meeting follow-up's action items — caption text the draft may quote in full.
    var actionItems: [String] = []
    /// The caption text the action items came from, for a meeting follow-up; the draft must not
    /// copy anything else out of it.
    var untrustedSource: String?
}

/// Why a draft was refused. One per row of §4.4's table (the contact row covers URLs, email
/// addresses and phone numbers; the last row is meeting follow-ups' copy check).
enum DraftValidationFailure: String, CaseIterable, Sendable {
    case empty
    case placeholderLeft
    case markdown
    case tooLong
    case url
    case emailAddress
    case phoneNumber
    case moneyAmount
    case timeOrDateNotInFacts
    case wrongLanguage
    case copiedCaptionText
}

enum DraftValidator {

    /// Characters a channel takes before a draft is too long to be a draft.
    static func budget(for channel: DraftChannel) -> Int {
        switch channel {
        case .messages: 320
        case .whatsapp: 500
        case .email: 1200
        }
    }

    /// More consecutive words than this copied from caption text (outside the action items) fail.
    static let copiedWordLimit = 12
    /// The language check only speaks up when the recogniser is this sure.
    static let languageConfidence = 0.9
    /// …and the text, action items left out, has at least this many words.
    static let languageMinimumWords = 6

    /// Nil when the draft passes every row.
    static func validate(_ text: String, context: DraftValidationContext) -> DraftValidationFailure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if matches(placeholderPattern, in: trimmed) { return .placeholderLeft }
        if matches(markdownPattern, in: trimmed) { return .markdown }
        if trimmed.count > budget(for: context.channel) { return .tooLong }

        let trusted = context.trustedText.joined(separator: "\n")
        let trustedLower = trusted.lowercased()
        let trustedCompact = trustedLower.filter { !$0.isWhitespace }
        let trustedDigits = trusted.filter(\.isNumber)

        // Each finding is cut out once checked, so one string is judged by one row: an email
        // address also holds a domain, "$10.50" also reads as a time, "18.15" as a date.
        var remaining = trimmed
        for email in all(emailPattern, in: remaining) {
            if !trustedLower.contains(email.lowercased()) { return .emailAddress }
            remaining = remaining.replacingOccurrences(of: email, with: " ")
        }
        for url in all(urlPattern, in: remaining) {
            if !trustedLower.contains(url.lowercased()) { return .url }
            remaining = remaining.replacingOccurrences(of: url, with: " ")
        }
        for amount in all(moneyPattern, in: remaining) {
            if !trustedCompact.contains(amount.lowercased().filter { !$0.isWhitespace }) { return .moneyAmount }
            remaining = remaining.replacingOccurrences(of: amount, with: " ")
        }
        for time in all(timePattern, in: remaining) {
            if !containsTime(time, in: trustedLower) { return .timeOrDateNotInFacts }
            remaining = remaining.replacingOccurrences(of: time, with: " ")
        }
        for date in all(datePattern, in: remaining) {
            if !trustedLower.contains(date.lowercased()) { return .timeOrDateNotInFacts }
            remaining = remaining.replacingOccurrences(of: date, with: " ")
        }
        for phone in all(phonePattern, in: remaining) {
            let digits = phone.filter(\.isNumber)
            if digits.count >= 7, !trustedDigits.contains(digits) { return .phoneNumber }
        }

        let ownWords = removing(context.actionItems, from: trimmed)
        if isConfidentlyAnotherLanguage(ownWords, than: context.language) { return .wrongLanguage }

        if let source = context.untrustedSource,
           copiesRun(longerThan: copiedWordLimit, of: source, in: ownWords) {
            return .copiedCaptionText
        }
        return nil
    }

    /// The text to show: the model's when it passes, else the template's. `failure` says why the
    /// model's was refused (nil when it passed, or when there was none).
    static func choose(model: String?, template: String,
                       context: DraftValidationContext) -> (text: String, usedModel: Bool, failure: DraftValidationFailure?) {
        guard let model else { return (template, false, nil) }
        if let failure = validate(model, context: context) { return (template, false, failure) }
        return (model, true, nil)
    }

    // MARK: - The rows' patterns

    static let placeholderPattern = #"\{[A-Za-z_][A-Za-z0-9_]*\}"#
    /// Bold/italic markers, inline code, headings, list markers at a line's start, and links.
    /// The "•" the templates list items with is not Markdown.
    static let markdownPattern = #"(?m)(\*\*|__|`|^\s{0,3}#{1,6}\s|^\s*[-*+]\s|^\s*\d+\.\s|\[[^\]]+\]\([^)]*\))"#
    static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    static let urlPattern = #"(?i)\b((https?://|www\.)\S+|[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|net|org|io|co|nz|au|uk|de|fr|es|it|nl|ca|us|app|dev|ly|me|info|biz)(/\S*)?)\b"#
    static let moneyPattern = #"(?i)([$€£¥₹]\s?\d+([.,]\d+)*|\d+([.,]\d+)*\s?([$€£¥₹]|(usd|eur|gbp|nzd|aud|cad|dollars?|euros?|pounds?)\b))"#
    static let phonePattern = #"\+?\d[\d\s().-]{5,}\d"#
    /// 18:15, 18.15, 18h15, 6pm, 6:15 p.m.
    static let timePattern = #"(?i)\b([01]?\d|2[0-3])\s?[:.h]\s?[0-5]\d(\s?([ap]\.?m\.?))?|\b(1[0-2]|0?[1-9])\s?([ap]\.?m\.?)(?![a-z])"#
    /// 12/11, 12.11.2026, 2026-11-12, "12 November", "Nov 12", weekday names.
    static let datePattern = #"(?i)\b(\d{4}-\d{2}-\d{2}|\d{1,2}[/.-]\d{1,2}([/.-]\d{2,4})?|\d{1,2}(st|nd|rd|th)?\s+(of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*|(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#

    // MARK: - Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = regex(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// A time found in a draft is in the facts when the same hour and minute are written there in
    /// any of the separators a locale uses ("18:15", "18.15", "18 h 15").
    private static func containsTime(_ time: String, in trustedLower: String) -> Bool {
        let compact = time.lowercased().filter { !$0.isWhitespace }
        if trustedLower.filter({ !$0.isWhitespace }).contains(compact) { return true }
        let normalised = normaliseTime(compact)
        return all(timePattern, in: trustedLower).contains { normaliseTime($0.lowercased().filter { !$0.isWhitespace }) == normalised }
    }

    private static func normaliseTime(_ compact: String) -> String {
        var text = compact.replacingOccurrences(of: ".", with: ":").replacingOccurrences(of: "h", with: ":")
        text = text.replacingOccurrences(of: "a:m:", with: "am").replacingOccurrences(of: "p:m:", with: "pm")
            .replacingOccurrences(of: "a:m", with: "am").replacingOccurrences(of: "p:m", with: "pm")
        return text
    }

    private static func removing(_ items: [String], from text: String) -> String {
        items.reduce(text) { partial, item in
            item.isEmpty ? partial : partial.replacingOccurrences(of: item, with: " ")
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func isConfidentlyAnotherLanguage(_ text: String, than language: String) -> Bool {
        guard words(text).filter({ $0.contains(where: \.isLetter) }).count >= languageMinimumWords else {
            return false
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= languageConfidence else { return false }
        return baseLanguage(best.key.rawValue) != baseLanguage(language)
    }

    private static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    /// Whether `draft` holds more than `limit` consecutive words, in order, from `source`.
    static func copiesRun(longerThan limit: Int, of source: String, in draft: String) -> Bool {
        let window = limit + 1
        let sourceWords = words(source)
        let draftWords = words(draft)
        guard sourceWords.count >= window, draftWords.count >= window else { return false }
        var grams: Set<String> = []
        for index in 0...(sourceWords.count - window) {
            grams.insert(sourceWords[index..<(index + window)].joined(separator: " "))
        }
        for index in 0...(draftWords.count - window)
        where grams.contains(draftWords[index..<(index + window)].joined(separator: " ")) {
            return true
        }
        return false
    }
}
