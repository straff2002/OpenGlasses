import Foundation

/// The technician's name as their team sees it (Plan FP P3) — the `technicianDisplayName` setting
/// and the `author` a candidate is filed under.
enum TechnicianName {

    /// The contract's author limit (§3).
    static let limit = LearningCandidateText.authorLimit

    /// Trimmed, every control character turned into a space, at most `limit` Unicode scalars, and
    /// trimmed again. Empty means unset.
    static func clean(_ raw: String) -> String {
        let plain = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            LearningCandidateText.isRefused($0) ? " " : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars.prefix(limit) { scalars.append(scalar) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Who a candidate is filed under: the configured name, else the device's name, else
    /// "Technician" — never empty.
    static func author(configured: String, deviceName: String) -> String {
        let name = clean(configured)
        return LearningCandidateText.author(name.isEmpty ? deviceName : name)
    }
}
