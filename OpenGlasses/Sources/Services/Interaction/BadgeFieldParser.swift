import Foundation
import CoreGraphics

/// One OCR'd text line with its normalized bounding box (Vision convention:
/// origin bottom-left, so larger `minY` = higher on the badge).
struct RecognizedTextLine: Equatable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(_ text: String, boundingBox: CGRect, confidence: Float = 1.0) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Parsed badge contents. Fields are nil rather than guessed — same absence-honesty
/// rule as the vision substrate.
struct BadgeFields: Equatable {
    let name: String?
    let title: String?
    let organization: String?
    /// Overall parse confidence ∈ [0, 1]; callers should reject below `acceptThreshold`.
    let confidence: Double

    static let acceptThreshold = 0.45
    var isAcceptable: Bool { name != nil && confidence >= Self.acceptThreshold }
}

/// Heuristic layout parser for conference-badge OCR (Plan CG P1). Pure geometry +
/// text rules over `RecognizedTextLine`s; no Vision import, fixture-testable.
enum BadgeFieldParser {
    /// Ribbon/role words printed on badges that are categories, not people.
    private static let ribbonWords: Set<String> = [
        "visitor", "attendee", "exhibitor", "speaker", "staff", "press", "media",
        "vip", "sponsor", "organizer", "organiser", "delegate", "volunteer", "crew"
    ]

    private static let titleKeywords = [
        "engineer", "developer", "designer", "architect", "manager", "director",
        "founder", "co-founder", "ceo", "cto", "cfo", "coo", "president",
        "vice president", "vp ", "lead", "head of", "chief", "doctor", "dr.",
        "professor", "prof.", "student", "researcher", "scientist", "analyst",
        "consultant", "nurse", "specialist", "coordinator", "administrator",
        "owner", "partner", "principal", "md", "phd"
    ]

    private static let orgSuffixes = [
        "inc", "inc.", "ltd", "ltd.", "llc", "gmbh", "corp", "corp.", "co.",
        "company", "university", "institute", "college", "hospital", "clinic",
        "labs", "laboratories", "technologies", "systems", "solutions", "group",
        "studio", "studios", "software", "media", "partners", "foundation"
    ]

    static func parse(_ lines: [RecognizedTextLine]) -> BadgeFields {
        let usable = lines
            .map { RecognizedTextLine(normalize($0.text), boundingBox: $0.boundingBox, confidence: $0.confidence) }
            .filter { isUsable($0.text) }
        guard !usable.isEmpty else {
            return BadgeFields(name: nil, title: nil, organization: nil, confidence: 0)
        }

        let medianHeight = median(usable.map { $0.boundingBox.height })

        // Name: the most prominent name-shaped line. Prominence = font size (box
        // height) with a nudge for being high on the badge.
        let nameCandidate = usable
            .filter { isNameShaped($0.text) && !isTitleLine($0.text) && !isOrgShaped($0.text) }
            .max { prominence($0, median: medianHeight) < prominence($1, median: medianHeight) }

        let title = usable.first { $0 != nameCandidate && isTitleLine($0.text) }

        // Org: prefer an explicit org-suffixed line; else the most prominent
        // remaining line that isn't the name or title.
        let remaining = usable.filter { $0 != nameCandidate && $0 != title }
        let organization = remaining.first { isOrgShaped($0.text) }
            ?? remaining
                .filter { !isNameShaped($0.text) }
                .max { prominence($0, median: medianHeight) < prominence($1, median: medianHeight) }

        var confidence = 0.0
        if let n = nameCandidate {
            confidence += 0.5 * Double(n.confidence)
            // A name that is also the tallest text is the classic badge layout.
            if n.boundingBox.height >= medianHeight * 1.2 { confidence += 0.1 }
        }
        if let t = title { confidence += 0.15 * Double(t.confidence) }
        if let o = organization {
            confidence += (isOrgShaped(o.text) ? 0.25 : 0.12) * Double(o.confidence)
        }

        return BadgeFields(
            name: nameCandidate.map { titleCased($0.text) },
            title: title?.text,
            organization: organization?.text,
            confidence: min(1, confidence)
        )
    }

    // MARK: - Line classification

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isUsable(_ text: String) -> Bool {
        guard text.count >= 2, text.count <= 60 else { return false }
        let lower = text.lowercased()
        if ribbonWords.contains(lower) { return false }
        if lower.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) { return false }
        if lower.contains("http") || lower.contains("www.") || lower.contains("@") { return false }
        return true
    }

    /// Lowercase connective particles allowed inside a name ("Ludwig van Beethoven").
    private static let nameParticles: Set<String> = ["van", "von", "de", "da", "del", "der", "di", "bin", "al", "la", "le"]

    /// 2–4 alphabetic tokens, each capitalized (ALL-CAPS badges included), no digits.
    /// Interior lowercase particles ("van", "de") are allowed; first/last must be capitalized.
    private static func isNameShaped(_ text: String) -> Bool {
        let tokens = text.split(separator: " ")
        guard tokens.count >= 2, tokens.count <= 4 else { return false }
        for (i, token) in tokens.enumerated() {
            guard token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }) else { return false }
            let isEdge = i == 0 || i == tokens.count - 1
            guard let first = token.first else { return false }
            if !first.isUppercase {
                guard !isEdge, nameParticles.contains(String(token)) else { return false }
            }
        }
        return true
    }

    private static func isTitleLine(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        return titleKeywords.contains { keyword in
            lower.contains(" \(keyword) ") || lower.contains(" \(keyword),")
                || lower.hasSuffix(" \(keyword) ")
        }
    }

    private static func isOrgShaped(_ text: String) -> Bool {
        let lower = text.lowercased()
        return orgSuffixes.contains { suffix in
            lower.hasSuffix(" \(suffix)") || lower == suffix
                || lower.hasSuffix(" \(suffix).")
        }
    }

    private static func prominence(_ line: RecognizedTextLine, median: CGFloat) -> CGFloat {
        guard median > 0 else { return line.boundingBox.height }
        // Height dominates; the top-of-badge nudge only breaks ties between
        // similar-sized lines (names sit above orgs in the common layout).
        return (line.boundingBox.height / median) + line.boundingBox.minY * 0.3
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// "JANE O'BRIEN-SMITH" → "Jane O'Brien-Smith" (leave mixed case alone).
    private static func titleCased(_ text: String) -> String {
        guard text == text.uppercased() else { return text }
        return text.lowercased().capitalizedPreservingSeparators()
    }
}

private extension String {
    /// Capitalize the first letter of every word, including after "-" and "'".
    func capitalizedPreservingSeparators() -> String {
        var result = ""
        var capitalizeNext = true
        for ch in self {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ch == " " || ch == "-" || ch == "'" { capitalizeNext = true }
        }
        return result
    }
}
