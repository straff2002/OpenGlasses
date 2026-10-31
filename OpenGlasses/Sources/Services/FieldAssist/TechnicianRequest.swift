import Foundation

/// What the technician's own words this turn asked for, for the gates that stop a tool call doing
/// something nobody asked for (Plan KD P0).
///
/// The partner's retest on 581 had a job end because the technician named it, a rule chain start
/// on a question it happened to answer, and a page open before the answer. Each was the model
/// acting on an invitation in its instructions or a tool result. Writing "don't" into those
/// instructions is not a guarantee, so the tools check the words instead: `field_session end`,
/// `rule_chain start` and `show_source` each go ahead only when the turn asked for it.
///
/// The words are English command words, as the app's other command words are. Matched whole-word
/// on lowercased words with apostrophes dropped, so "wrap it up" and "let's" read alike however
/// they were typed. Pure.
enum TechnicianRequest {

    // MARK: - Ending the job

    /// Whether the words ask to end the job: end, close, finish, cancel or wrap up, in any of
    /// their usual forms. Deliberately not "done" — "I'm done with the capacitor" is about the
    /// work, not the job.
    static func asksToEndJob(_ said: String) -> Bool {
        let words = self.words(said)
        if words.contains(where: endWords.contains) { return true }
        return containsPhrase(words, among: wrapUpPhrases)
    }

    /// "Yes" to the assistant's question about ending the job: a short affirmative, after a reply
    /// that itself asked about ending, closing or finishing it.
    static func confirmsEndingJob(_ said: String, previousReply: String?) -> Bool {
        guard isShortAffirmative(said), let previousReply else { return false }
        return asksToEndJob(previousReply)
    }

    private static let endWords: Set<String> = [
        "end", "ending", "close", "closing", "finish", "finishing", "finished",
        "cancel", "cancelling", "canceling", "cancelled", "canceled",
    ]

    private static let wrapUpPhrases: [[String]] = [
        ["wrap", "up"], ["wrap", "it", "up"], ["wrap", "this", "up"], ["wrap", "the", "job", "up"],
        ["wrapping", "up"], ["wrapup"],
    ]

    // MARK: - Asking for a person

    /// Whether the words ask for a person (Plan KE P1): "escalate", or someone to reach with a word
    /// that reaches them ("get me an expert", "can I talk to someone"), or the expert named on its
    /// own in a few words ("expert please"). "I don't need an expert" and "the manual is no help"
    /// ask for nobody. Errs towards a request: wrongly passing shows the approval card, wrongly
    /// refusing would stand between a technician and a person.
    static func asksForExpert(_ said: String) -> Bool {
        let words = self.words(said)
        guard let person = words.firstIndex(where: { personWords.contains($0) || escalateWords.contains($0) }) else {
            return false
        }
        if words[..<person].contains(where: refusingWords.contains) { return false }
        if words.contains(where: escalateWords.contains) { return true }
        if words.contains(where: reachWords.contains) { return true }
        return words.count <= 3 && words.contains(where: namedPersonWords.contains)
    }

    /// "Yes" to the assistant's offer of a person: a short affirmative, after a reply that mentioned
    /// one, the way `confirmsEndingJob` reads a reply about ending the job.
    static func confirmsExpertOffer(_ said: String, previousReply: String?) -> Bool {
        guard isShortAffirmative(said), let previousReply else { return false }
        return words(previousReply).contains { personWords.contains($0) || escalateWords.contains($0) }
    }

    /// Who a technician means. `someone` is here for "can someone look at this"; the words that
    /// follow it decide whether it asks.
    private static let personWords: Set<String> = namedPersonWords.union([
        "someone", "somebody", "person", "people", "support", "helpdesk",
    ])

    private static let namedPersonWords: Set<String> = [
        "expert", "experts", "human", "supervisor", "specialist", "engineer", "manager",
    ]

    private static let escalateWords: Set<String> = ["escalate", "escalating", "escalation"]

    private static let reachWords: Set<String> = [
        "get", "call", "ring", "page", "need", "want", "talk", "speak", "connect", "bring", "contact",
        "reach", "send", "fetch",
    ]

    private static let refusingWords: Set<String> = ["dont", "not", "never", "without", "wont", "doesnt"]

    // MARK: - Running a rule chain

    /// Whether the words ask to run a chain without naming one: "chain" with a verb that runs it
    /// ("run the chain", "use a chain for that", "start that chain").
    /// "What chains can I use?" asks about the chains, not to run one.
    static func asksToRunChain(_ said: String) -> Bool {
        let words = self.words(said)
        guard let first = words.first, !chainQuestionOpeners.contains(first),
              words.contains(where: { $0 == "chain" || $0 == "chains" }) else { return false }
        return words.contains(where: runVerbs.contains)
    }

    /// Whether the words ask what chains there are — "what chains can I use?", "list the rule
    /// chains" — rather than to run one (Plan KD P2): the list is then said as `rule_chain` wrote
    /// it. "Chain" said with a verb that runs one is a request to run it, not to hear the list, and
    /// a question about one chain ("what does the sizing chain do?") is the model's to answer.
    static func asksAboutChains(_ said: String) -> Bool {
        let words = self.words(said)
        guard words.contains("chains") || (words.contains("list") && words.contains("chain")) else { return false }
        return !asksToRunChain(said)
    }

    private static let chainQuestionOpeners: Set<String> = [
        "what", "whats", "which", "how", "is", "are", "does", "do", "list", "tell",
    ]

    /// Whether the words name the chain called `name`: its name as a run of words ("run the
    /// conductor sizing check"), or every one of its significant words together with a verb that
    /// runs it. A question that merely shares a word with a chain's name ("what size conductor?")
    /// names nothing — that is exactly the turn a chain used to start on unasked.
    static func names(chain name: String, in said: String) -> Bool {
        let wanted = words(name).filter { !chainFiller.contains($0) }
        guard !wanted.isEmpty else { return false }
        let words = self.words(said).filter { !chainFiller.contains($0) }
        if containsPhrase(words, among: [wanted]) { return true }
        // A verb the name itself carries is the name's ("voltage drop on a run"), not a request.
        let verbs = runVerbs.subtracting(wanted)
        return words.contains(where: verbs.contains) && Set(wanted).isSubset(of: Set(words))
    }

    /// The chains among `names` that `reply` mentions by name — what the assistant offered.
    static func chainsMentioned(in reply: String, among names: [String]) -> [String] {
        let words = self.words(reply).filter { !chainFiller.contains($0) }
        return names.filter { name in
            let wanted = self.words(name).filter { !chainFiller.contains($0) }
            return !wanted.isEmpty && containsPhrase(words, among: [wanted])
        }
    }

    private static let runVerbs: Set<String> = [
        "run", "running", "start", "starting", "use", "using", "begin", "try", "go", "work",
    ]

    /// Words a chain's name and a request for it may each carry or leave out.
    private static let chainFiller: Set<String> = ["the", "a", "an", "chain", "rule", "please"]

    // MARK: - Agreeing

    /// A short yes or go-ahead: "yes", "go ahead", "yeah do it", "ok, run it". At most six words,
    /// opening with the agreement, so "yes, but what's the derating?" is not a go-ahead.
    static func isShortAffirmative(_ said: String) -> Bool {
        let words = self.words(said)
        guard !words.isEmpty, words.count <= 6, !said.contains("?") else { return false }
        if affirmativeOpeners.contains(words[0]) { return true }
        return containsPhrase(Array(words.prefix(3)), among: affirmativePhrases, atStart: true)
    }

    private static let affirmativeOpeners: Set<String> = [
        "yes", "yeah", "yep", "yup", "yea", "aye", "sure", "ok", "okay", "please", "absolutely",
        "definitely", "correct", "right",
    ]

    private static let affirmativePhrases: [[String]] = [
        ["go", "ahead"], ["go", "for", "it"], ["do", "it"], ["do", "that"], ["lets", "do", "it"],
        ["run", "it"], ["start", "it"], ["sounds", "good"], ["go"],
    ]

    // MARK: - Seeing a page

    /// Whether the words ask to see a page, a table or a source: the manual-turn classifier's
    /// "show me" (Plan GB P1), "where does it say that", and a bare "open it" / "show that" said
    /// on its own. Typed or spoken alike — the words are the turn's either way.
    static func asksToSee(_ said: String) -> Bool {
        if ManualTurnClassifier.classify(said) == .showMe { return true }
        let words = self.words(said)
        if containsPhrase(words, among: seePhrases) { return true }
        // "Open it" on its own is a request to see what was just mentioned; "open it up and check
        // the capacitor" is work being described.
        return words.count <= 4 && containsPhrase(Array(words.prefix(2)), among: shortSeePhrases, atStart: true)
    }

    private static let seePhrases: [[String]] = [
        ["where", "does", "it", "say"], ["where", "is", "that", "written"], ["lets", "see"],
        ["let", "me", "look"], ["can", "i", "look"], ["show", "us"],
    ]

    private static let shortSeePhrases: [[String]] = [
        ["open", "it"], ["open", "that"], ["open", "this"], ["show", "it"], ["show", "that"], ["show", "this"],
    ]

    // MARK: - Words

    /// Lowercased words, apostrophes dropped, split on anything that is not a letter or a digit.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Whether `words` holds one of `phrases` as a contiguous run (at its start, when asked).
    private static func containsPhrase(_ words: [String], among phrases: [[String]], atStart: Bool = false) -> Bool {
        phrases.contains { phrase in
            guard !phrase.isEmpty, words.count >= phrase.count else { return false }
            let starts = atStart ? [0] : Array(0...(words.count - phrase.count))
            return starts.contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
        }
    }
}
