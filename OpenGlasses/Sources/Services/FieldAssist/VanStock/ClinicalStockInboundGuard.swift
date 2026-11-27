import Foundation

/// Refuses a sheet or a feed for a clinical list that carries a column about a patient (Plan NJ
/// §1). Pure, over column names only.
///
/// Fail closed: a heading that reads like a patient's name, date of birth, health number, chart,
/// appointment or contact details refuses the whole import with a plain sentence; it is never
/// stripped quietly, because a clinic that exports patients into a stock sheet should find out.
/// A heading the stock reader itself reads ("Name" as the line's description, "Brand name" as
/// its other names) is the stock's own column, not a patient's. A van's list is not checked.
///
/// The EMR's immunisation list (Plan MY §8) never comes through here: `ImmunisationListReader`
/// reads it in memory, keeps the date, vaccine and lot columns, and drops the rest as it reads.
enum ClinicalStockInboundGuard {

    /// Each pattern is a run of whole words, compared lower-cased.
    static let patientPatterns: [[String]] = [
        ["name"], ["names"], ["surname"], ["firstname"], ["lastname"], ["fullname"],
        ["patient"], ["patients"],
        ["date", "of", "birth"], ["dob"], ["birth", "date"], ["birthdate"], ["birthday"],
        ["health", "number"], ["health", "no"], ["health", "card"], ["healthcard"], ["phn"], ["hcn"],
        ["mrn"], ["chart"], ["charts"], ["appointment"], ["appointments"],
        ["address"], ["addresses"], ["phone"], ["phones"], ["telephone"],
        ["email"], ["emails"], ["e", "mail"],
    ]

    /// A heading's words: lower case, split at anything that is not a letter or a digit.
    static func words(_ heading: String) -> [String] {
        heading.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Words that make a following "name" a product's: "Vaccine name", "Brand names".
    static let productQualifiers: Set<String> = [
        "vaccine", "product", "brand", "trade", "item", "drug", "generic", "short", "line", "stock",
        "manufacturer", "supplier", "common", "proper", "other",
    ]

    /// Whether `heading` reads like a column about a patient.
    static func isPatientHeading(_ heading: String) -> Bool {
        let said = words(heading)
        guard !said.isEmpty else { return false }
        return patientPatterns.contains { pattern in
            guard pattern.count <= said.count else { return false }
            return (0...(said.count - pattern.count)).contains { start in
                guard Array(said[start..<(start + pattern.count)]) == pattern else { return false }
                // "Vaccine name" is the product's, unless something else in the heading is a patient's.
                if pattern == ["name"] || pattern == ["names"], start > 0, productQualifiers.contains(said[start - 1]) {
                    return false
                }
                return true
            }
        }
    }

    /// The headings that refuse the import, in sheet order: each patient-like heading that is not
    /// one of the columns the stock reader reads (`used`, by position). Empty when none does.
    static func patientHeadings(_ headings: [String], used: Set<Int> = []) -> [String] {
        headings.enumerated().compactMap { index, raw in
            let heading = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !used.contains(index) && isPatientHeading(heading) ? heading : nil
        }
    }

    /// The headings of a workbook's stock sheet that refuse it for a clinical list.
    static func patientHeadings(in sheets: [XLSXReader.Sheet]) -> [String] {
        guard let header = VanStockSheet.headerCells(in: sheets) else { return [] }
        return patientHeadings(header.headings, used: header.used)
    }

    /// The field names of a feed's row (a connector's own keys) that refuse it for a clinical
    /// list. A feed has no stock-column mapping, so every patient-like name refuses.
    static func patientFields(_ names: [String]) -> [String] {
        patientHeadings(names)
    }

    /// The plain sentence a refusal says. It names the columns, never a value under them.
    static func refusal(_ headings: [String]) -> String {
        let named = headings.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        return String(localized: "This sheet wasn't read, because it has a column that may hold patient details (\(named)). A clinic's stock list takes vaccines, lots and quantities only. Remove that column and open the sheet again.",
                      comment: "Refusal when a clinic's stock sheet has a column named like a patient's details.")
    }
}
