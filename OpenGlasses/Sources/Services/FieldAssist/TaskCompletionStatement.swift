import Foundation

/// Whether the technician's own words say a piece of work is finished.
///
/// A tester said "measured the igniter and it shows me an open circuit"; in the same turn the
/// model proposed a replacement, accepted it and closed it as done with the note "Replaced
/// hot-surface ignitor". A reading is a finding, not a repair — and a closed task is what the
/// report, the next turn and the office all believe. So closing a task needs the technician to
/// have said the work is done: the task's own verb in the past tense ("replaced", "checked"), a
/// close synonym ("swapped", "put in a new one"), or a plain "done" / "finished". A check — the
/// retest a fix waits on — closes on the technician saying it passed ("works", "fine").
///
/// Pure and deliberately literal: it reads words, not intent. It is a floor under the model's
/// judgement, not a replacement for it, so it errs towards letting a stated completion through.
enum TaskCompletionStatement {

    /// Whether `utterance` says the work named by `taskTitle` is finished.
    static func states(_ utterance: String, completing taskTitle: String) -> Bool {
        let words = tokens(utterance)
        guard !words.isEmpty else { return false }
        var accepted = genericCompletion
        if let verb = tokens(taskTitle).first(where: { !titleLeadIns.contains($0) }) {
            accepted.formUnion(pastForms(of: verb))
        }
        if words.indices.contains(where: { accepted.contains(words[$0]) && !isNegated(words, at: $0) }) {
            return true
        }
        return containsPhrase(words, replacementPhrases)
    }

    /// Whether `utterance` says the check passed — the retest, the test run, the heat cycle.
    static func statesPassedCheck(_ utterance: String) -> Bool {
        let words = tokens(utterance)
        return words.indices.contains { passedCheck.contains(words[$0]) && !isNegated(words, at: $0) }
    }

    /// Whether `utterance` is about a test or the machine running at all — the subject a "fine"
    /// has to have before it counts as a passed check.
    static func mentionsCheck(_ utterance: String) -> Bool {
        tokens(utterance).contains(where: checkSubjects.contains)
    }

    // MARK: - Vocabulary

    private static let checkSubjects: Set<String> = [
        "test", "tested", "testing", "retest", "retested", "run", "ran", "cycle", "check", "checked",
        "working", "works", "worked", "lit", "lights", "fired", "fires", "firing", "ignites",
        "ignited", "running", "runs", "heating", "cooling"
    ]

    /// Said of any task: "that's done", "finished", "fixed".
    private static let genericCompletion: Set<String> = [
        "done", "finished", "completed", "complete", "fixed", "sorted"
    ]

    /// Said of a check: "it passed", "works fine now", "the furnace is working".
    private static let passedCheck: Set<String> = [
        "passed", "passes", "pass", "works", "working", "worked", "fine", "good", "normal",
        "normally", "successful", "successfully", "success"
    ]

    /// Words a title may open with before its verb ("Verify: run a heat cycle").
    private static let titleLeadIns: Set<String> = ["verify", "then", "now", "please"]

    /// Verbs that mean the same finished work as each other: replacing a part is installing its
    /// replacement, swapping it, changing it, fitting a new one.
    private static let replacementVerbs: Set<String> = ["replace", "swap", "change", "install", "fit"]
    private static let replacementPast: Set<String> = [
        "replaced", "swapped", "changed", "installed", "fitted", "fit"
    ]
    private static let replacementPhrases: [[String]] = [["put", "in"], ["put", "a", "new"], ["new", "one", "in"]]

    /// Past forms the regular rules get wrong.
    private static let irregular: [String: Set<String>] = [
        "put": ["put"], "set": ["set"], "reset": ["reset"], "run": ["ran", "run"],
        "cut": ["cut"], "fit": ["fitted", "fit"], "rerun": ["reran", "rerun"],
        "make": ["made"], "take": ["took", "taken"], "redo": ["redid", "redone"]
    ]

    private static let negators: Set<String> = [
        "not", "never", "no", "haven't", "hasn't", "hadn't", "didn't", "isn't", "wasn't",
        "aren't", "weren't", "doesn't", "don't", "won't", "can't", "couldn't", "havent",
        "hasnt", "didnt", "isnt", "wasnt", "doesnt", "dont", "wont", "cant", "yet", "without"
    ]

    // MARK: - Mechanics

    /// "replace" → replaced; "check" → checked; "swap" → swapped; "tidy" → tidied. A title verb
    /// already in the past tense ("Replaced the ignitor") stands for itself.
    static func pastForms(of verb: String) -> Set<String> {
        var forms: Set<String> = []
        if verb.hasSuffix("ed") { forms.insert(verb) }
        if let known = irregular[verb] { forms.formUnion(known) }
        if replacementVerbs.contains(verb) || replacementPast.contains(verb) {
            forms.formUnion(replacementPast)
        }
        if verb.hasSuffix("e") {
            forms.insert(verb + "d")
        } else if verb.hasSuffix("y"), let before = verb.dropLast().last, !"aeiou".contains(before) {
            forms.insert(String(verb.dropLast()) + "ied")
        } else {
            forms.insert(verb + "ed")
            if let last = verb.last, !"aeiouwxy".contains(last), verb.count >= 3,
               let before = verb.dropLast().last, "aeiou".contains(before),
               let third = verb.dropLast(2).last, !"aeiou".contains(third) {
                forms.insert(verb + String(last) + "ed")
            }
        }
        return forms
    }

    /// A completion word counts unless the few words before it deny it ("haven't replaced it",
    /// "not done yet") or make it future ("it needs to be replaced", "should be done").
    private static func isNegated(_ words: [String], at index: Int) -> Bool {
        if index > 0, words[index - 1] == "be" { return true }
        let window = words[max(0, index - 3)..<index]
        if window.contains(where: negators.contains) { return true }
        // "Not done yet", "replaced? not yet".
        let after = words[(index + 1)..<min(words.count, index + 3)]
        return after.contains("yet")
    }

    private static func containsPhrase(_ words: [String], _ phrases: [[String]]) -> Bool {
        phrases.contains { phrase in
            guard words.count >= phrase.count else { return false }
            return (0...(words.count - phrase.count)).contains { start in
                Array(words[start..<(start + phrase.count)]) == phrase
                    && !isNegated(words, at: start)
            }
        }
    }

    /// Lower-cased words, apostrophes kept ("haven't"), curly ones straightened.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}

/// Whether two task titles name the same piece of work.
///
/// The same tester's job ended with two completed tasks for one repair — "Replace the open
/// hot-surface ignitor" and "Replace hot-surface ignitor" — because the later statement added a
/// task rather than closing the one already there. Same leading verb, and nearly all the
/// remaining words shared once articles, the part's condition ("open", "faulty") and spelling
/// variants ("igniter" / "ignitor") are set aside.
enum TaskTitleMatch {

    static func isSameWork(_ a: String, _ b: String) -> Bool {
        let left = stems(a), right = stems(b)
        guard let verbA = left.first, let verbB = right.first, verbA == verbB else { return false }
        let restA = Set(left.dropFirst()), restB = Set(right.dropFirst())
        guard !restA.isEmpty, !restB.isEmpty else { return restA == restB }
        let shared = restA.intersection(restB).count
        return Double(shared) / Double(min(restA.count, restB.count)) >= 0.8
    }

    private static let ignored: Set<String> = [
        "the", "a", "an", "and", "of", "on", "to", "for", "with", "in", "at", "its", "it", "this",
        "that", "open", "new", "old", "faulty", "failed", "bad", "broken", "defective", "damaged",
        "shorted", "verify"
    ]

    /// Crude stems, applied to both sides alike: "replaced" / "replace" → "replac", "igniter" /
    /// "ignitor" → "ignit". Only ever compared with each other, never shown.
    static func stems(_ title: String) -> [String] {
        TaskCompletionStatement.tokens(title)
            .filter { !ignored.contains($0) }
            .map(stem)
    }

    private static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "es", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            w.removeLast(suffix.count)
            break
        }
        for suffix in ["er", "or", "e"] where w.hasSuffix(suffix) && w.count - suffix.count >= 4 {
            w.removeLast(suffix.count)
            break
        }
        return w
    }
}

/// What the technician said to open the turn in flight, for the gates that check a tool call
/// against their words. Nil when nobody spoke or typed one (an agent-initiated turn), and outside
/// a spoken or typed turn altogether — a live session's tool call would otherwise be read against
/// the last direct turn's words. The gates then stay out of the way rather than refuse on the
/// strength of words nobody captured.
enum TechnicianWords {
    @MainActor static func current() -> String? {
        guard let app = AppStateProvider.shared, app.isProcessing else { return nil }
        let words = app.turnUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Which turn the words in `current()` opened (Plan KD P2): a number that changes with every
    /// spoken or typed turn, the same words said again included. Nil exactly when `current()` is,
    /// so a turn with no captured words is never told apart from another.
    @MainActor static func currentTurn() -> Int? {
        guard current() != nil, let app = AppStateProvider.shared else { return nil }
        return app.turnSerial
    }

    /// What the assistant said last, before the turn in flight: what a bare "yes" answers (Plan
    /// KD P0 — "shall I close the job?", "want me to run the sizing chain?"). Nil outside a turn,
    /// as `current()` is.
    @MainActor static func previousReply() -> String? {
        guard let app = AppStateProvider.shared, app.isProcessing else { return nil }
        let reply = app.lastResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }
}
