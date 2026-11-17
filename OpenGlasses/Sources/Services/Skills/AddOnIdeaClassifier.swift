import Foundation

/// Whether a failure batch is mostly "no tool could get X" — the kind of gap an add-on could fill —
/// and reading the analyser's `addon-idea: <goal>` answer. Pure.
///
/// An add-on idea is only a suggestion in the inbox: nothing is searched, fetched or drafted until
/// the wearer taps Build it, which starts an ordinary building session with all of its gates.
enum AddOnIdeaClassifier {

    /// At least this share of the batch must be a "couldn't get it" answer.
    static let dominanceShare = 0.6
    static let minimumSamples = 3
    static let maxGoalLength = 120
    static let prefix = "addon-idea:"

    /// The assistant saying it had no way to fetch something, as opposed to getting it wrong.
    static let missingCapabilityPhrases: [String] = [
        "i don't have a tool", "i do not have a tool", "no tool", "i don't have access to live",
        "i don't have access to real-time", "i can't look that up", "i cannot look that up",
        "i can't access", "i cannot access", "i don't have a way to", "i have no way to",
        "i'm unable to look up", "i am unable to look up", "i'm not able to look up",
        "i can't check", "i can't get live", "i don't have real-time", "i don't have live",
    ]

    static func isMissingCapability(_ sample: FailureSample) -> Bool {
        let text = (sample.response + " " + (sample.userCorrection ?? ""))
            .lowercased().replacingOccurrences(of: "’", with: "'")
        return missingCapabilityPhrases.contains { text.contains($0) }
    }

    /// Whether the batch is dominated by missing capabilities.
    static func isDominatedByMissingCapability(_ samples: [FailureSample]) -> Bool {
        guard samples.count >= minimumSamples else { return false }
        let missing = samples.filter(isMissingCapability).count
        return Double(missing) / Double(samples.count) >= dominanceShare
    }

    /// The goal in an `addon-idea: <goal>` answer, cleaned to one short line; nil for anything else.
    static func idea(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let goal = trimmed.dropFirst(prefix.count)
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`")))
            ?? ""
        let clean = String(goal.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard clean.count >= 3 else { return nil }
        return String(clean.prefix(maxGoalLength))
    }

    /// The store's name for an idea: unique per goal, so the same idea is never suggested twice.
    static func name(for goal: String) -> String {
        "addon-" + String(SelfBuiltIdentity.slug(from: goal).prefix(34))
    }
}
