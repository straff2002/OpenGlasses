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

    /// "Yes" to the assistant's offer of a person: a short affirmative, after a reply that made one.
    /// Stricter than `confirmsEndingJob`, because a reply can name a person without offering one
    /// (Plan KJ P2): after "escalate rather than treating it as a pass", "okay I will check it" had
    /// opened the expert card.
    static func confirmsExpertOffer(_ said: String, previousReply: String?) -> Bool {
        guard isShortAffirmative(said), let previousReply else { return false }
        return offersExpert(previousReply)
    }

    /// Whether a reply offers a person: one of its sentences names a person or escalating and either
    /// asks, by ending in a question mark, or offers, by `offeringPhrases`. Each sentence is read on
    /// its own, so a "Source: …" line after the question does not hide it. Reading an offer wrongly
    /// costs one turn: the refusal tells the model to make the offer.
    private static func offersExpert(_ reply: String) -> Bool {
        sentences(reply).contains { sentence in
            let words = self.words(sentence.text)
            guard words.contains(where: { personWords.contains($0) || escalateWords.contains($0) }) else {
                return false
            }
            return sentence.asks || containsPhrase(words, among: offeringPhrases)
        }
    }

    /// How an offer sounds without a question mark ("I can get an expert if you want"), in spoken
    /// replies. Apostrophes are dropped, so "I can't" is not "I can".
    private static let offeringPhrases: [[String]] = [
        ["i", "can"], ["i", "could"], ["happy", "to"], ["let", "me", "know"], ["if", "you", "want"],
        ["if", "youd", "like"], ["say", "the", "word"],
    ]

    /// A reply's sentences, each with whether it ended in a question mark. A full stop ends a
    /// sentence only before a space or the end of the text, so "0.28" stays in one piece, and a line
    /// break always ends one.
    private static func sentences(_ text: String) -> [(text: String, asks: Bool)] {
        var sentences: [(text: String, asks: Bool)] = []
        var current = ""
        func closeSentence(asks: Bool) {
            sentences.append((current, asks))
            current = ""
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                closeSentence(asks: false)
                continue
            }
            current.append(character)
            if character == "?" {
                closeSentence(asks: true)
            } else if character == "!" {
                closeSentence(asks: false)
            } else if character == ".", index + 1 == characters.count || characters[index + 1].isWhitespace {
                closeSentence(asks: false)
            }
        }
        closeSentence(asks: false)
        return sentences
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

    // MARK: - Calling a named expert (Plan KM P0)

    /// Whether the words call `name` ("call Sam", "FaceTime Sam", "try Priya"): a calling word and
    /// any word of the name, with no refusal before the calling word. By name always works.
    static func asksToCall(name: String, _ said: String) -> Bool {
        let words = self.words(said)
        let nameWords = self.words(name)
        guard !nameWords.isEmpty, nameWords.contains(where: words.contains),
              let verb = words.firstIndex(where: callWords.contains) else { return false }
        return !words[..<verb].contains(where: refusingWords.contains)
    }

    /// "Yes" to a question that named the expert: a short affirmative after a reply one of whose
    /// questions names them ("… Sam is on call. Call Sam?", "Sam didn't answer. Try Priya?").
    static func confirmsCallOffer(name: String, _ said: String, previousReply: String?) -> Bool {
        guard isShortAffirmative(said), let previousReply else { return false }
        let nameWords = self.words(name)
        guard !nameWords.isEmpty else { return false }
        return sentences(previousReply).contains { sentence in
            sentence.asks && nameWords.contains(where: self.words(sentence.text).contains)
        }
    }

    /// Whether the words send the job to `name` ("send Sam the job", "send Sam the latest",
    /// "give Priya the job"): a sending word and any word of the name, with no refusal before the
    /// sending word (Plan KM P1).
    static func asksToSend(name: String, _ said: String) -> Bool {
        let words = self.words(said)
        let nameWords = self.words(name)
        guard !nameWords.isEmpty, nameWords.contains(where: words.contains),
              let verb = words.firstIndex(where: sendWords.contains) else { return false }
        return !words[..<verb].contains(where: refusingWords.contains)
    }

    private static let sendWords: Set<String> = ["send", "share", "give", "forward", "update"]

    private static let callWords: Set<String> = [
        "call", "ring", "phone", "facetime", "dial", "try", "get", "contact", "reach",
    ]

    // MARK: - Running a rule chain

    /// Whether the words ask to run a chain without naming one: "chain" with a verb that runs it
    /// ("run the chain", "use a chain for that", "start that chain").
    /// "What chains can I use?" asks about the chains, not to run one.
    ///
    /// Given the chain the model chose (`chain`), a request to be walked through the work asks for
    /// it too (Plan KR P4): "walk me through it", "step by step", "let's work it out", when the
    /// turn carries the chain name's task words and, where the name has one, its material. The
    /// retest's sizing request ended "walk me through it", and the refusal made the technician
    /// repeat a set phrase. "How many can I fit?" stays a question.
    static func asksToRunChain(_ said: String, chain name: String? = nil) -> Bool {
        let words = self.words(said)
        if let name, asksToBeWalkedThrough(chain: name, words: words) { return true }
        guard let first = words.first, !chainQuestionOpeners.contains(first),
              words.contains(where: { $0 == "chain" || $0 == "chains" }) else { return false }
        return words.contains(where: runVerbs.contains)
    }

    /// A walk-through request whose task words, and material, are the chain's (Plan KR P4).
    private static func asksToBeWalkedThrough(chain name: String, words: [String]) -> Bool {
        guard containsPhrase(words, among: guidedWalkPhrases) else { return false }
        let named = self.words(name).filter { !chainFiller.contains($0) }
        let materials = Set(named.compactMap(material))
        guard materials.isSubset(of: Set(words.compactMap(material))) else { return false }
        let tasks = taskKeys(named)
        guard !tasks.isEmpty else {
            // A name with no task word the app knows: every other word of it, as said.
            let rest = named.filter { material($0) == nil && !walkNameFiller.contains($0) }.map(stem)
            return !rest.isEmpty && Set(rest).isSubset(of: Set(words.map(stem)))
        }
        let said = taskKeys(words, anyOrder: true)
        // "Check" alone is any work's word: it counts only for a chain whose one task it is.
        let weighed = tasks.count > 1 ? tasks.subtracting(["check"]) : tasks
        return !weighed.isDisjoint(with: said)
    }

    /// How a technician asks to be taken through the work.
    private static let guidedWalkPhrases: [[String]] = [
        ["walk", "me", "through"], ["walk", "us", "through"], ["talk", "me", "through"], ["take", "me", "through"],
        ["step", "me", "through"], ["guide", "me"], ["step", "by", "step"], ["lets", "work", "it", "out"],
    ]

    /// The task a word names, as one key: "sizing" and "size" are one task, "fit" and "fill"
    /// another. "Voltage drop" is a task only as both words — in a name as a phrase, in a turn in
    /// any order ("the drop in voltage").
    private static func taskKeys(_ words: [String], anyOrder: Bool = false) -> Set<String> {
        var keys = Set(words.compactMap { taskWords[$0] })
        let joined = anyOrder ? (words.contains("voltage") && words.contains("drop"))
            : containsPhrase(words, among: [["voltage", "drop"]])
        if joined { keys.insert("voltage drop") }
        return keys
    }

    private static let taskWords: [String: String] = [
        "size": "size", "sizes": "size", "sized": "size", "sizing": "size",
        "check": "check", "checks": "check", "checking": "check",
        "breaker": "breaker", "breakers": "breaker",
        "fit": "fill", "fits": "fill", "fitting": "fill", "fill": "fill", "fills": "fill", "filling": "fill",
        "derate": "derate", "derating": "derate", "derated": "derate",
    ]

    /// A conductor material, as one key.
    private static func material(_ word: String) -> String? {
        switch word {
        case "copper", "cu": return "copper"
        case "aluminum", "aluminium", "al": return "aluminum"
        default: return nil
        }
    }

    /// Words a chain's name carries that say nothing about its task.
    private static let walkNameFiller: Set<String> = ["a", "an", "for", "of", "on", "in", "to", "and", "with", "my", "your"]

    /// A word with a common ending taken off, so "installed" meets "install".
    private static func stem(_ word: String) -> String {
        var out = word
        for suffix in ["ing", "ed", "es", "s"] where out.count > suffix.count + 2 && out.hasSuffix(suffix) {
            out = String(out.dropLast(suffix.count))
            break
        }
        if out.count > 3, let last = out.last, let before = out.dropLast().last, last == before, !"aeiou".contains(last) {
            out = String(out.dropLast())
        }
        if out.count > 3, out.hasSuffix("e") { out = String(out.dropLast()) }
        return out
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
