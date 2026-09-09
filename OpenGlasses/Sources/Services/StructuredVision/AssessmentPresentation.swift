import Foundation

/// The strings every surface renders for one `AssessmentCard` — card footer, HUD line, spoken
/// summary, PDF caveat (W08.2 + W08.3).
///
/// Extracted from the view so the wording is testable without SwiftUI, and so the card, the HUD and
/// the voice path cannot drift into saying three different things about the same result. The rules
/// live here once: never a percentage the model did not produce, always the limitations when there
/// are any, always the escalation line.
struct AssessmentPresentation {
    let card: AssessmentCard

    init(_ card: AssessmentCard) { self.card = card }

    /// The banded certainty, or the explicit absence of one. Never a percentage: the number the old
    /// footer printed was a hard-coded 1.0, and printing a real one would still invite reading a
    /// model's self-rating as a measurement.
    var certaintyText: String {
        guard let band = card.certainty else {
            return String(localized: "Certainty not established")
        }
        return String(localized: "Certainty: \(band.displayLabel)")
    }

    /// One line naming what limited the view, or `nil` when nothing did.
    var limitationsText: String? {
        guard !card.limitations.isEmpty else { return nil }
        return String(localized: "Limited view: \(card.limitations.joined(separator: "; ")).")
    }

    /// Always present. Who to hand this to, in the tone the first-aid coaching already uses.
    var escalationText: String { AssessmentEscalation.line(forKind: card.kind) }

    /// The one-line AI attribution shown on the card chrome.
    var attributionText: String {
        String(localized: "AI vision · \(card.tier.displayLabel)")
    }

    /// What the HUD shows and the voice path speaks. Carries the limitations and the escalation, and
    /// never a certainty percentage — only the model's own numbers reach a wearer, and this path
    /// carries none of them.
    var spokenSummary: String {
        var lines = ["\(card.title): \(card.summary)"]
        if let action = card.recommendedAction, !action.isEmpty { lines.append(action) }
        if let limits = limitationsText { lines.append(limits) }
        lines.append(certaintyText)
        lines.append(escalationText)
        return lines.joined(separator: " ")
    }

    /// The caveat block a shared document carries: what limited it, that it is one AI estimate from
    /// one camera view, and who to escalate to.
    static func caveatLines(kind: String, limitations: [String], certainty: CertaintyBand?) -> [String] {
        var lines: [String] = []
        lines.append(String(localized: "LIMITATIONS AND CERTAINTY"))
        lines.append(String(localized: "This is an AI estimate produced from a single camera view. It is not a measurement, an inspection or a certification, and anything outside that view was not assessed."))
        if let certainty {
            lines.append(String(localized: "Certainty: \(certainty.displayLabel)."))
        } else {
            lines.append(String(localized: "Certainty: not established — the model reported no confidence in this result."))
        }
        if !limitations.isEmpty {
            lines.append(String(localized: "Limited view: \(limitations.joined(separator: "; "))."))
        }
        lines.append(AssessmentEscalation.line(forKind: kind))
        return lines
    }
}
