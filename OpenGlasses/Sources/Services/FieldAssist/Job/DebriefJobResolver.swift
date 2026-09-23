import Foundation

/// Which job a spoken debrief is about (Plan FO §6, P3b).
///
/// A drive covers the whole day's work, so "next job", "debrief job 1006" and "the one before
/// that" all have to land on a particular visit — and landing on the wrong one puts a
/// technician's account of one customer's plant room onto another customer's record. So this is
/// pure, exhaustive about what it will not do, and **asks rather than guesses**: two jobs with the
/// same number get a question about the date, and a reference nothing matches gets a question too.
///
/// It never invents a job and never falls back to "the most recent one" when a reference was
/// given: a misheard number resolving to whatever happens to be newest is precisely the failure
/// that would go unnoticed until the wrong customer read the wrong report.
enum DebriefJobResolver {

    /// One job the resolver may choose between — the small projection of a session it needs, so
    /// the whole table is testable without a store.
    struct Candidate: Equatable {
        let sessionId: String
        /// The number exactly as it was recorded, or nil for a visit that has none.
        let jobReference: String?
        let startedAt: Date
        /// "Resolved", "Escalated" — what the picker reads out beside the date.
        let outcomeLabel: String
        /// True for the job that is still open. It is a candidate like any other: a debrief on the
        /// open job is legitimate, and it does not close or re-scope it.
        let isActive: Bool

        init(sessionId: String, jobReference: String?, startedAt: Date,
             outcomeLabel: String, isActive: Bool = false) {
            self.sessionId = sessionId
            self.jobReference = jobReference
            self.startedAt = startedAt
            self.outcomeLabel = outcomeLabel
            self.isActive = isActive
        }

        /// "Job 1006, 21 September, Resolved" — what the app says on every switch, so the
        /// technician hears which job they are now talking about before they say anything about it.
        var spoken: String {
            let number = jobReference.map { "Job \($0)" } ?? JobTabModel.noJobNumber
            return "\(number), \(Self.dayFormatter.string(from: startedAt)), \(outcomeLabel)"
        }

        static let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("d MMMM")
            return formatter
        }()
    }

    /// What the spoken reference amounted to.
    enum Resolution: Equatable {
        case resolved(sessionId: String)
        /// More than one job answers to it. The question names the dates, never a guess.
        case ambiguous(question: String, sessionIds: [String])
        /// Nothing answers to it.
        case notFound(question: String)
        /// The utterance was not a job reference at all — it belongs to the conversation.
        case notAReference
    }

    /// Resolve what was said against the day's jobs.
    ///
    /// - Parameters:
    ///   - spoken: the technician's words, as heard.
    ///   - candidates: every job that may be debriefed, **newest first**. The order is the
    ///     resolver's notion of "next" and "previous", so the caller sorts once and the relative
    ///     references cannot mean two different things on two surfaces.
    ///   - current: the job a debrief is on right now, when one is. Relative references are
    ///     relative to it; with none, "next job" means the newest.
    static func resolve(_ spoken: String, candidates: [Candidate], current: String? = nil) -> Resolution {
        let text = spoken.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !candidates.isEmpty else {
            return candidates.isEmpty ? .notFound(question: nothingToDebrief) : .notAReference
        }

        // A number wins over a relative word: "debrief job 1006" said while on 1005 means 1006,
        // whatever else is in the sentence.
        if let number = spokenNumber(in: text) {
            let matches = candidates.filter { $0.jobReference?.lowercased() == number }
            switch matches.count {
            case 1: return .resolved(sessionId: matches[0].sessionId)
            case 0:
                return .notFound(question: "I don't have a job \(number) on this device. "
                                 + "Say the number again, or pick it from the Jobs list.")
            default:
                return .ambiguous(question: ambiguityQuestion(number: number, matches: matches),
                                  sessionIds: matches.map(\.sessionId))
            }
        }

        if let byDate = dateMatches(in: text, candidates: candidates) {
            switch byDate.count {
            case 1: return .resolved(sessionId: byDate[0].sessionId)
            case 0: break
            default:
                return .ambiguous(question: "There's more than one job that day — "
                                  + byDate.map(\.spoken).joined(separator: "; ")
                                  + ". Which one?",
                                  sessionIds: byDate.map(\.sessionId))
            }
        }

        guard let relative = relativeReference(in: text) else { return .notAReference }
        return resolve(relative, candidates: candidates, current: current)
    }

    /// The sentence the app says when there is nothing to debrief at all.
    static let nothingToDebrief =
        "There are no jobs on this device to debrief yet."

    // MARK: - Relative references

    /// "next job", "the one before that", "the last one".
    enum Relative: Equatable {
        /// Older than the one in hand — the next job to talk about on a drive home.
        case next
        case previous
        /// The most recent job of all.
        case mostRecent
        /// The job in hand, said out loud ("this one").
        case current
    }

    static func relativeReference(in text: String) -> Relative? {
        let words = text.lowercased()
        // "The one before that" and "the previous job" both mean the job *before* the one in hand,
        // which — with the list newest first — is the newer neighbour.
        if words.contains("before that") || words.contains("before this")
            || words.contains("previous") || words.contains("one back") {
            return .previous
        }
        if words.contains("next job") || words.contains("the next one") || words.contains("next one") {
            return .next
        }
        if words.contains("last job") || words.contains("latest job") || words.contains("most recent")
            || words.contains("the last one") {
            return .mostRecent
        }
        if words.contains("this job") || words.contains("this one") { return .current }
        return nil
    }

    private static func resolve(_ relative: Relative, candidates: [Candidate],
                                current: String?) -> Resolution {
        let index = current.flatMap { id in candidates.firstIndex { $0.sessionId == id } }
        switch relative {
        case .mostRecent:
            return .resolved(sessionId: candidates[0].sessionId)
        case .current:
            guard let index else {
                return .notFound(question: "There's no job in hand. Say the job number, or pick it from the "
                                 + "Jobs list.")
            }
            return .resolved(sessionId: candidates[index].sessionId)
        case .next:
            // Newest first, so "next" walks backwards in time — the next job to talk over.
            guard let index else { return .resolved(sessionId: candidates[0].sessionId) }
            guard index + 1 < candidates.count else {
                return .notFound(question: "That's the oldest job on the device. Say a job number instead.")
            }
            return .resolved(sessionId: candidates[index + 1].sessionId)
        case .previous:
            guard let index, index > 0 else {
                return .notFound(question: "There's nothing more recent than that one. Say a job number "
                                 + "instead.")
            }
            return .resolved(sessionId: candidates[index - 1].sessionId)
        }
    }

    // MARK: - Numbers

    /// The job number in a sentence, or nil. Deliberately narrow: it takes what follows the word
    /// "job", or a bare token that is mostly digits, and nothing else. A sentence with no number
    /// in it is not a number said badly.
    static func spokenNumber(in text: String) -> String? {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
        if let jobIndex = tokens.firstIndex(of: "job"), jobIndex + 1 < tokens.count {
            let next = tokens[jobIndex + 1]
            if isReferenceShaped(next) { return next }
        }
        // "1006" on its own, while a debrief is being switched. Two or more characters, at least
        // one digit, so "it" and "ok" cannot be job numbers.
        let bare = tokens.filter { isReferenceShaped($0) }
        return bare.count == 1 ? bare[0] : nil
    }

    private static func isReferenceShaped(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        guard token.contains(where: \.isNumber) else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Dates

    /// Jobs whose day the sentence names, or nil when it names no day at all.
    ///
    /// Only the two forms a technician actually uses in a car: "today"/"yesterday", and a day and
    /// month ("the twenty-first", "on 21 September"). Anything cleverer would be guessing.
    static func dateMatches(in text: String, candidates: [Candidate],
                            calendar: Calendar = .current, now: Date = Date()) -> [Candidate]? {
        if text.contains("yesterday") {
            guard let day = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return candidates.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
        }
        if text.contains("today") {
            return candidates.filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
        }
        guard let day = dayOfMonth(in: text) else { return nil }
        let month = monthName(in: text)
        return candidates.filter { candidate in
            let components = calendar.dateComponents([.day, .month], from: candidate.startedAt)
            guard components.day == day else { return false }
            guard let month else { return true }
            return components.month == month
        }
    }

    private static func dayOfMonth(in text: String) -> Int? {
        // "the 21st", "on the 3rd" — a bare number that reads as a day, never a job number, which
        // is why this is only consulted after the number path has found nothing.
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (index, token) in tokens.enumerated() {
            let digits = token.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits), (1...31).contains(value) else { continue }
            let suffix = token.dropFirst(digits.count)
            if ["st", "nd", "rd", "th"].contains(String(suffix)) { return value }
            if index > 0, tokens[index - 1] == "the" { return value }
            if monthName(in: text) != nil { return value }
        }
        return nil
    }

    private static func monthName(in text: String) -> Int? {
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        for (index, name) in months.enumerated() where text.contains(name) { return index + 1 }
        return nil
    }

    // MARK: - Questions

    private static func ambiguityQuestion(number: String, matches: [Candidate]) -> String {
        let dates = matches.map { Candidate.dayFormatter.string(from: $0.startedAt) }
        return "There are \(matches.count) jobs numbered \(number) — "
            + dates.joined(separator: " and ") + ". Which one?"
    }
}
