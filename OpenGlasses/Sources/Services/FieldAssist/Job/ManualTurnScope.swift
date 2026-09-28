import Foundation

/// What a Field Assist turn asks of the manuals, once the job's own bookkeeping is taken out of it.
///
/// Every turn in a session is searched against the vault's manuals, and a turn whose evidence
/// points at a drawing or a table opens that page on the phone (Plan EK P2). Two things a technician
/// says to *run the job* are not questions about the machine, and both could open a page:
///
/// - **A job number is not a code.** "Open a new job 108, equipment Lennox SLP99UH070" handed `108`
///   to the exact-token search, which ranks a verbatim hit above everything else — and a
///   vent-length table has 108 in one of its cells. Table 8 opened over a job nobody had asked a
///   question about yet (field report, build 420).
/// - **Opening, closing or switching a job is not a question.** Even with its number gone, such a
///   turn names the machine, and a page found off a model name is a page nobody asked to see.
///
/// Neither rule stops the model reading the manuals. The passages still go with a job turn that
/// also asks something, and `manual_figure` still opens a page on request. The cost of the second
/// rule is deliberate and small: "start a job, what does 24VAXC connect to" gets its answer and its
/// citation but not the automatic page. Missing that page costs one "show me the drawing". A page
/// that opens for no reason costs the technician's trust in every page that opens after it.
enum ManualTurnScope {

    /// The turn with every job reference removed. A reference is the reference-shaped token after
    /// a job, work-order or ticket word, such as "job 108", "work order #4411" or
    /// "job number 1005-B". The words themselves stay; only the number goes.
    ///
    /// A bare number is left alone: "what does the 120 VAC output feed" is a reading off a drawing,
    /// and taking it out would lose the one token that finds the drawing.
    static func removingJobReferences(from turn: String) -> String {
        let words = turn.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < words.count {
            kept.append(words[index])
            guard let reference = referenceIndex(after: index, in: words) else {
                index += 1
                continue
            }
            // Keep the qualifiers ("number", "no.") in between, drop the reference itself.
            kept.append(contentsOf: words[(index + 1)..<reference])
            index = reference + 1
        }
        return kept.joined(separator: " ")
    }

    /// Whether the turn is running the job (opening, starting, closing, finishing or switching one)
    /// rather than asking about the equipment.
    static func isJobManagement(_ turn: String) -> Bool {
        let words = JobReferenceClassifier.normalise(turn).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        var namesAJob = false
        for (index, word) in words.enumerated() {
            let isNoun = jobNouns.contains(word)
                || (word == "order" && index > 0 && words[index - 1] == "work")
            guard isNoun else { continue }
            namesAJob = true
            // "new job", "next job": the adjective alone is the action, but only right before the
            // noun. "What's the next step on this job" is a question.
            if index > 0, jobAdjectives.contains(words[index - 1]) { return true }
        }
        return namesAJob && words.contains { jobActions.contains($0) }
    }

    // MARK: - Vocabulary

    /// The index of the reference that the job word at `index` introduces, or nil when that word
    /// is not a job word or nothing reference-shaped follows it.
    private static func referenceIndex(after index: Int, in words: [String]) -> Int? {
        let word = bare(words[index])
        let introducesReference = referenceNouns.contains(word)
            || (word == "order" && index > 0 && bare(words[index - 1]) == "work")
        guard introducesReference else { return nil }
        var next = index + 1
        while next < words.count, bare(words[next]).isEmpty || qualifiers.contains(bare(words[next])) {
            next += 1
        }
        guard next < words.count, looksLikeReference(words[next]) else { return nil }
        return next
    }

    /// A job number as spoken or typed: a digit in it, and nothing but the characters work-order
    /// numbers use. Surrounding punctuation ("108,", "#108") is the recogniser's, not the number's.
    private static func looksLikeReference(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: edgePunctuation)
        guard !trimmed.isEmpty, trimmed.count <= maximumReferenceLength,
              trimmed.contains(where: \.isNumber) else { return false }
        return trimmed.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || referencePunctuation.contains($0)
        }
    }

    /// Lowercased with its edge punctuation stripped, so "Job," and "#" compare as words.
    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: edgePunctuation)
    }

    private static let maximumReferenceLength = 16
    private static let referencePunctuation = CharacterSet(charactersIn: "-/._")
    private static let edgePunctuation = CharacterSet.punctuationCharacters
        .union(.symbols).union(.whitespaces)

    /// Words a job number follows. "work order" is matched as its second word.
    private static let referenceNouns: Set<String> = ["job", "workorder", "wo", "ticket"]

    /// Words that may sit between the job word and its number: "job number 108", "ticket no. 12".
    private static let qualifiers: Set<String> = [
        "number", "no", "num", "nr", "ref", "reference", "id", "is"
    ]

    /// In the normalised, apostrophe-free form `JobReferenceClassifier.normalise` produces.
    private static let jobNouns: Set<String> = ["job", "jobs", "workorder", "ticket"]

    /// Adjectives that make a turn about a job when they come right before its noun.
    private static let jobAdjectives: Set<String> = ["new", "next", "another", "different"]

    /// Verbs and states that make a turn naming a job a turn about running it.
    private static let jobActions: Set<String> = [
        "open", "opening", "reopen", "start", "starting", "begin", "create", "close", "closing",
        "end", "ending", "finish", "finishing", "finished", "done", "complete", "completed",
        "switch", "resume", "wrap"
    ]
}
