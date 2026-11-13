import Foundation

/// The same blocker coming round again during one remote job (Plan LP §4). Pure.
///
/// A job that goes back to running after a question and then asks it again gets a fresh question
/// identity each time (it is a new ask, and a reply must answer that one), so the identity alone
/// never noticed it had heard this before and announced every round. This counts by what the
/// wearer would recognise as "the same thing again" — the question's words, or the failure's —
/// for the life of the job.
struct RecurringBlocker: Equatable {
    enum Kind: String, Equatable { case question, error }

    enum Verdict: Equatable {
        /// The first time: said as it always was.
        case announce
        /// Heard it before: kept, not said.
        case quiet
        /// The third time: ask whether to stop the job. Once per blocker.
        case askToStop
    }

    /// How many times before the wearer is asked whether to stop.
    static let askAt = 3

    private var counts: [String: Int] = [:]

    /// Note one occurrence and say what to do with it.
    mutating func note(_ kind: Kind, text: String) -> Verdict {
        let key = "\(kind.rawValue)\u{1}\(Self.normalise(text))"
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        switch count {
        case 1: return .announce
        case Self.askAt: return .askToStop
        default: return .quiet
        }
    }

    /// How many times `text` has come round as `kind`.
    func count(_ kind: Kind, text: String) -> Int {
        counts["\(kind.rawValue)\u{1}\(Self.normalise(text))"] ?? 0
    }

    /// Case, punctuation, digits and spacing ignored: "Which branch?" and "which branch" are one
    /// question, and "exit code 1 at 10:42" and "exit code 1 at 10:43" one failure.
    static func normalise(_ text: String) -> String {
        let lowered = text.lowercased().precomposedStringWithCanonicalMapping
        let words = lowered.unicodeScalars.split { scalar in
            !CharacterSet.letters.contains(scalar)
        }.map { String($0) }
        return words.joined(separator: " ")
    }

    /// "It keeps asking: “which branch should I use?”. Do you want me to stop it?"
    static func stopPrompt(_ kind: Kind, text: String) -> String {
        let quoted = AgentSummarizer.cap(text.trimmingCharacters(in: .whitespacesAndNewlines))
        switch kind {
        case .question: return "It keeps asking: “\(quoted)” Do you want me to stop it?"
        case .error: return "It keeps hitting the same problem: “\(quoted)” Do you want me to stop it?"
        }
    }

    /// The card's line.
    static func stopSummary(_ kind: Kind) -> String {
        switch kind {
        case .question: return "stop the job — it keeps asking the same question"
        case .error: return "stop the job — it keeps hitting the same problem"
        }
    }
}
