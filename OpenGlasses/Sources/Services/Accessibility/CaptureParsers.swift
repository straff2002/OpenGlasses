import Foundation

/// Pure parsers that turn messy OCR text into structured fields for the capture→action tools.
/// Heuristic but deterministic, so they're fully unit-testable.
enum CaptureParsers {

    // MARK: - Business card

    struct BusinessCard: Equatable {
        var name: String?
        var company: String?
        var phone: String?
        var email: String?
    }

    static func parseBusinessCard(_ text: String) -> BusinessCard {
        let lines = nonEmptyLines(text)
        let email = firstMatch(text, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
        let phone = firstMatch(text, #"\+?\d[\d\-\s().]{6,}\d"#)?.trimmingCharacters(in: .whitespaces)
        let company = lines.first { line in
            ["inc", "llc", "ltd", "co.", "corp", "gmbh", "company"].contains { line.lowercased().contains($0) }
        }
        // Name: first line that's 2–4 mostly-alphabetic words, not an email/phone/company line.
        let name = lines.first { line in
            guard line != company, !line.contains("@") else { return false }
            let words = line.split(separator: " ")
            guard (2...4).contains(words.count) else { return false }
            let letters = line.filter { $0.isLetter || $0 == " " || $0 == "." || $0 == "-" }
            return Double(letters.count) / Double(max(line.count, 1)) > 0.8
        }
        return BusinessCard(name: name, company: company, phone: phone, email: email)
    }

    // MARK: - Receipt

    struct Receipt: Equatable {
        var merchant: String?
        var total: String?
        var date: String?
    }

    static func parseReceipt(_ text: String) -> Receipt {
        let lines = nonEmptyLines(text)
        let merchant = lines.first
        let date = firstMatch(text, #"\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}"#)

        // Prefer an amount on a line mentioning "total"; else the largest amount.
        let amountPattern = #"\d+\.\d{2}"#
        var total: String?
        for line in lines {
            let lower = line.lowercased()
            guard lower.contains("total"), !lower.contains("subtotal") else { continue }
            if let amt = firstMatch(line, amountPattern) { total = amt; break }
        }
        if total == nil {
            let amounts = allMatches(text, amountPattern).compactMap { Double($0) }
            if let maxAmt = amounts.max() { total = String(format: "%.2f", maxAmt) }
        }
        return Receipt(merchant: merchant, total: total, date: date)
    }

    // MARK: - Event flyer

    struct EventInfo: Equatable {
        var title: String?
        var date: String?
        var location: String?
    }

    static func parseEvent(_ text: String) -> EventInfo {
        let lines = nonEmptyLines(text)
        let title = lines.first
        // Date: a numeric date, OR a month name followed by a day.
        let date = firstMatch(text, #"\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}"#)
            ?? firstMatch(text, #"(?i)(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}"#)
        // Location: a line with "at " or one that looks like a street address.
        let location = lines.first { line in
            line.lowercased().contains(" at ") || line.range(of: #"\d{1,5}\s+\w+\s+(st|street|ave|avenue|rd|road|blvd|lane|ln)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return EventInfo(title: title, date: date, location: location)
    }

    // MARK: - Helpers

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }

    static func allMatches(_ text: String, _ pattern: String) -> [String] {
        var results: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchStart..<text.endIndex) {
            results.append(String(text[range]))
            searchStart = range.upperBound
        }
        return results
    }
}
