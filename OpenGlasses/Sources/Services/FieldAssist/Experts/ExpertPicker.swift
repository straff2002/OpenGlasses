import Foundation

/// Chooses among the experts on the list for "get me a furnace expert" (Plan KM §2). Pure.
///
/// **Fixed rules over human-set fields, in a fixed order**, each narrowing only when something is
/// left:
///
/// 1. Specialty: the tags the request's words name, then the tags the job's equipment names.
/// 2. On call now, in each expert's own time zone. Nobody on call is still an answer — the list
///    is offered, and the sentence says nobody is on call.
/// 3. Rota order, rotating per phone from the expert called last.
///
/// No expert or technician is ranked by outcomes, ratings or call history (Annex III 4(b), Plan JX
/// §10): `Input` has nowhere to put one, and a test pins its fields.
enum ExpertPicker {

    /// The job, as far as the picker needs it: words that name the trade and the unit.
    struct Job: Equatable, Sendable {
        /// The trades the job's vault declares ("refrigeration_hvac"), or nil.
        let trades: [String]
        /// Words naming the unit: its kind, brand, model and the vault it was matched in.
        let equipment: [String]

        init(trades: [String] = [], equipment: [String] = []) {
            self.trades = trades
            self.equipment = equipment
        }

        static let none = Job()

        /// From a session and its vault: the vault's trades and name, and the unit the session
        /// recorded (its model heading and what the technician said it was).
        static func from(session: FieldSession?, vault: VaultManifest?) -> Job {
            let identity = session?.equipment
            let equipment = [identity?.heading, identity?.stated, vault?.name].compactMap { $0 }
            return Job(trades: vault?.trades ?? [], equipment: equipment)
        }
    }

    /// Everything the choice is made from. **Nothing else exists to choose by.**
    struct Input: Equatable, Sendable {
        /// What the technician said, or the specialty the model passed ("furnace").
        let request: String
        let job: Job
        /// The merged list, in list order.
        let experts: [EscalationContact]
        let now: Date
        /// The rota position: the expert this phone called last, if any.
        let lastCalledExpertId: String?
    }

    struct Candidate: Equatable, Sendable {
        let contact: EscalationContact
        let isOnCall: Bool
    }

    enum Match: Equatable, Sendable {
        /// The request named these tags.
        case words([String])
        /// The job's equipment named these tags.
        case equipment([String])
        /// Neither did: every expert on the list.
        case none
    }

    struct Pick: Equatable, Sendable {
        /// On call first, then not, each in rota order. The first is the one offered.
        let ordered: [Candidate]
        let match: Match
        /// One sentence for the voice reply, offering the call ("… Call Sam?").
        let sentence: String

        var offered: EscalationContact? { ordered.first?.contact }
    }

    static func pick(_ input: Input) -> Pick {
        var pool = rotaOrder(input.experts, after: input.lastCalledExpertId)
        var match = Match.none

        // 1a. The request's words.
        let requested = namedTags(in: input.request, among: pool)
        if !requested.isEmpty {
            pool = narrowed(pool, to: requested)
            match = .words(requested)
        }
        // 1b. The job's equipment, within what the words left.
        let jobText = (input.job.trades.map { $0.replacingOccurrences(of: "_", with: " ") } + input.job.equipment)
            .joined(separator: " ")
        let fromJob = namedTags(in: jobText, among: pool)
        if !fromJob.isEmpty {
            let narrower = narrowed(pool, to: fromJob)
            if !narrower.isEmpty {
                pool = narrower
                if case .none = match { match = .equipment(fromJob) }
            }
        }

        // 2 and 3: on call first, each half still in rota order.
        let candidates = pool.map { Candidate(contact: $0, isOnCall: isOnCall($0, at: input.now)) }
        let ordered = candidates.filter(\.isOnCall) + candidates.filter { !$0.isOnCall }
        return Pick(ordered: ordered, match: match, sentence: sentence(ordered: ordered, match: match))
    }

    // MARK: - On call

    /// Whether the expert is on call at `date`: no windows means any time.
    static func isOnCall(_ contact: EscalationContact, at date: Date) -> Bool {
        contact.onCall.isEmpty || contact.onCall.contains { $0.contains(date, in: contact.timeZone) }
    }

    // MARK: - Rota

    /// The list rotated to start after the expert called last. An id no longer on the list starts
    /// at the top, as a phone that never called anyone does.
    static func rotaOrder(_ experts: [EscalationContact], after lastId: String?) -> [EscalationContact] {
        guard let lastId, let index = experts.firstIndex(where: { $0.id == lastId }) else { return experts }
        let next = experts.index(after: index)
        return Array(experts[next...] + experts[..<next])
    }

    // MARK: - Specialty

    /// The list's tags that `text` names, in the order the text names them, in the list's own
    /// spelling. A tag of several words ("heat pump") must appear as that run of words; plurals
    /// match ("furnaces").
    static func namedTags(in text: String, among experts: [EscalationContact]) -> [String] {
        let words = normalised(TechnicianRequest.words(text))
        guard !words.isEmpty else { return [] }
        var found: [(position: Int, tag: String)] = []
        var seen = Set<[String]>()
        for tag in experts.flatMap(\.specialties) {
            let phrase = normalised(TechnicianRequest.words(tag))
            guard !phrase.isEmpty, seen.insert(phrase).inserted,
                  let position = position(of: phrase, in: words) else { continue }
            found.append((position, tag))
        }
        return found.sorted { $0.position < $1.position }.map(\.tag)
    }

    /// The experts holding any of `tags`; those holding every one of them, when some do.
    private static func narrowed(_ experts: [EscalationContact], to tags: [String]) -> [EscalationContact] {
        let wanted = Set(tags.map { normalised(TechnicianRequest.words($0)) })
        func held(_ contact: EscalationContact) -> Set<[String]> {
            Set(contact.specialties.map { normalised(TechnicianRequest.words($0)) }).intersection(wanted)
        }
        let any = experts.filter { !held($0).isEmpty }
        let all = any.filter { held($0) == wanted }
        return all.isEmpty ? any : all
    }

    private static func position(of phrase: [String], in words: [String]) -> Int? {
        guard words.count >= phrase.count else { return nil }
        return (0...(words.count - phrase.count)).first { Array(words[$0..<($0 + phrase.count)]) == phrase }
    }

    /// Singular, so "furnaces" is "furnace" and "heat pumps" is "heat pump". Deliberately simple:
    /// a trailing s goes from a word longer than three letters that does not end in "ss".
    static func normalised(_ words: [String]) -> [String] {
        words.map { word in
            guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
            return String(word.dropLast())
        }
    }

    // MARK: - The sentence

    /// "Three furnace experts. Sam is on call. Call Sam?" — the expert by name, never a pronoun.
    static func sentence(ordered: [Candidate], match: Match) -> String {
        guard let first = ordered.first else { return "There are no experts on your list." }
        let name = spokenName(first.contact, among: ordered.map(\.contact))
        let label: String
        switch match {
        case .words(let tags), .equipment(let tags): label = tags.joined(separator: " ") + " "
        case .none: label = ""
        }
        let count = ordered.count
        let noun = count == 1 ? "\(label)expert" : "\(label)experts"
        let opening = "\(countWord(count).capitalizedFirst) \(noun)."
        if first.isOnCall {
            return "\(opening) \(name) is on call. Call \(name)?"
        }
        let nobody = count == 1 ? "\(name) isn't on call now." : "None is on call now."
        return "\(opening) \(nobody) Call \(name) anyway?"
    }

    /// The expert's first name, or the whole name when another candidate shares the first.
    static func spokenName(_ contact: EscalationContact, among others: [EscalationContact]) -> String {
        guard let first = contact.name.split(separator: " ").first.map(String.init) else { return contact.name }
        let clash = others.contains { $0.id != contact.id && $0.name.split(separator: " ").first.map(String.init)?.lowercased() == first.lowercased() }
        return clash ? contact.name : first
    }

    private static let countWords = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                     "nine", "ten", "eleven", "twelve"]

    static func countWord(_ count: Int) -> String {
        countWords.indices.contains(count) ? countWords[count] : String(count)
    }
}

/// "Call Sam": an expert named on the list (Plan JI §6 — by name always works, and skips the
/// picker). Pure.
enum ExpertNameMatch: Equatable {
    case one(EscalationContact)
    case several([EscalationContact])
    case none

    /// Words a request carries around the name.
    private static let filler: Set<String> = [
        "call", "ring", "phone", "facetime", "audio", "video", "get", "me", "my", "the", "a", "an", "please",
        "expert", "to", "try", "with", "dial",
    ]

    /// The whole name first, then experts whose name holds every word said, then a first name.
    static func resolve(_ spoken: String, in experts: [EscalationContact]) -> ExpertNameMatch {
        let said = TechnicianRequest.words(spoken).filter { !filler.contains($0) }
        guard !said.isEmpty else { return .none }
        let exact = experts.filter { TechnicianRequest.words($0.name) == said }
        if exact.count == 1 { return .one(exact[0]) }
        let holding = experts.filter { Set(said).isSubset(of: Set(TechnicianRequest.words($0.name))) }
        switch holding.count {
        case 0: return .none
        case 1: return .one(holding[0])
        default: return .several(holding)
        }
    }
}

/// "Sam didn't answer. Try Priya?" (Plan KM §2). Offered once, when a call this phone placed
/// ended without connecting. Pure.
enum NoAnswerOffer {
    /// The next expert to offer after `missed`, from the order the last pick gave, or nil.
    static func next(after missed: EscalationContact, in order: [EscalationContact]) -> EscalationContact? {
        guard let index = order.firstIndex(where: { $0.id == missed.id }) else {
            return order.first { $0.id != missed.id }
        }
        return order[order.index(after: index)...].first
    }

    static func sentence(missed: EscalationContact, next: EscalationContact?) -> String {
        let missedName = ExpertPicker.spokenName(missed, among: [missed] + (next.map { [$0] } ?? []))
        guard let next else { return "\(missedName) didn't answer." }
        let nextName = ExpertPicker.spokenName(next, among: [missed, next])
        return "\(missedName) didn't answer. Try \(nextName)?"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
