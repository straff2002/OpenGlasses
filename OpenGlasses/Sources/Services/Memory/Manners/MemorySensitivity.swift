import Foundation

/// What a remembered fact is about (Plan LN §1). Pure: plain strings in, categories out — no
/// configuration, no store, no clock.
///
/// The classifier errs towards matching. A false match costs one unsaved fact, which the wearer
/// can say again more plainly; a miss keeps something that should never have been kept. Every
/// list entry is a whole word or phrase (matched on word boundaries) chosen so the everyday
/// neighbour of the word does not trip it — a bank's *name*, rent, "gym routine", "works at the
/// hospital", "Union Station" — and each risky neighbour has a near-miss test.
///
/// English word lists only for now (Plan LN decision 2). The identifier shapes — a Luhn-valid
/// 13–19 digit run and an IBAN — carry no language and apply whatever the wearer speaks.
enum MemorySensitivity {

    /// Why a write is not kept as it stands. The first six are what `classify` can return; the
    /// last two are reasons the write gate gives that are not about the fact's subject matter.
    enum Category: String, CaseIterable, Sendable {
        /// Card, bank-account, passport, licence, tax or national ID numbers.
        case identifier
        /// The wearer saying they are under 18 or at school.
        case minor
        /// Arrests, convictions, being a victim, abuse, self-harm.
        case legalOrHarm
        /// Conditions, diagnoses, medication, therapy, pregnancy, allergies, recovery.
        case health
        /// Religion, ethnicity, orientation, gender identity, disability, union membership, politics.
        case protectedAttribute
        /// Salary, debts, balances, credit score.
        case finances
        /// A value that would make the assistant less careful, less honest, or skip a confirmation
        /// (`MemoryInstructionCheck`). Never returned by `classify`.
        case assistantInstruction
        /// An inferred fact in a turn that read untrusted output (`MemoryInstructionCheck`). Never
        /// returned by `classify`.
        case untrustedSource

        /// The categories `classify` reads off a fact, most serious first — the order a decision
        /// names one when a fact falls in several.
        static let subjectMatter: [Category] = [.identifier, .minor, .legalOrHarm, .health,
                                                .protectedAttribute, .finances]
    }

    /// Who a fact is about.
    enum Subject: Equatable, Sendable {
        case wearer
        /// Someone else — the cue that said so ("sister", "Sam"), for tests and nothing else; it
        /// never reaches a log.
        case otherPerson(String)
    }

    // MARK: - Classification

    /// Every subject-matter category the key and value fall in, read together.
    static func classify(key: String, value: String) -> Set<Category> {
        let original = key.isEmpty ? value : "\(key) \(value)"
        let words = normalisedWords(original)
        var found = Set<Category>()
        if hasIdentifierShape(original) || matches(words, identifierLabels) { found.insert(.identifier) }
        if isMinorStatement(key: key, value: value) { found.insert(.minor) }
        if matches(words, legalOrHarmTerms) { found.insert(.legalOrHarm) }
        if matches(words, healthTerms) { found.insert(.health) }
        if matches(words, protectedAttributeTerms) { found.insert(.protectedAttribute) }
        if matches(words, financeTerms) { found.insert(.finances) }
        return found
    }

    /// The most serious of `categories`, in `Category.subjectMatter` order.
    static func mostSerious(_ categories: Set<Category>) -> Category? {
        Category.subjectMatter.first(where: categories.contains)
    }

    // MARK: - Word lists (English, Plan LN decision 2)
    //
    // Entries are matched against the text lower-cased, apostrophes dropped ("driver's" →
    // "drivers", "I'm" → "im") and every other non-letter, non-digit turned into a space. An entry
    // ending in `*` matches any word that starts with it ("diagnos*" → diagnosed, diagnosis).

    static let identifierLabels: [String] = [
        "card number*", "card no", "card details", "cvv", "cvc", "pin number", "pin code", "bank pin",
        "card pin", "account number*", "acct number", "routing number", "sort code", "iban", "bsb",
        "passport number", "passport no", "drivers licence number", "drivers license number",
        "driving licence number", "licence number", "license number", "social security", "ssn",
        "national insurance number", "tax file number", "tfn", "tax id", "tax number",
        "ird number", "national id", "id number", "medicare number", "nhs number",
    ]

    static let healthTerms: [String] = [
        "diagnos*", "diabet*", "cancer", "tumour*", "tumor*", "chemo*", "hiv", "hepatitis",
        "asthma*", "epilep*", "seizure*", "depression", "depressed", "anxiety", "panic attack*",
        "bipolar", "schizophren*", "adhd", "ptsd", "ocd", "eating disorder", "anorexi*", "bulimi*",
        "dementia", "alzheimer*", "parkinson*", "multiple sclerosis", "had a stroke",
        "heart attack", "heart condition", "blood pressure", "cholesterol", "migraine*",
        "arthritis", "chronic", "illness", "disease", "disorder", "symptom*", "medication*", "meds",
        "prescription*", "prescribed", "insulin", "antidepressant*", "therapy", "therapist*",
        "counselling", "counseling", "counsellor*", "counselor*", "psychiatr*", "psychologist*",
        "rehab", "in recovery", "addict*", "alcoholic", "sober", "sobriety", "pregnan*",
        "miscarriage", "ivf", "fertility", "infertil*", "allerg*", "surgery", "injur*", "sti",
        "std", "covid", "mental health", "medical condition", "health condition",
    ]

    static let protectedAttributeTerms: [String] = [
        // Religion
        "religion*", "religious", "christianity", "a christian", "is christian", "christians",
        "catholic*", "protestant*", "muslim*", "islam", "islamic", "jewish", "judaism", "hindu*",
        "buddhis*", "sikh*", "atheis*", "agnostic", "mormon*", "jehovah*", "evangelical", "mosque",
        "synagogue", "goes to church", "go to church", "attends church", "ramadan",
        // Ethnicity
        "ethnicity", "ethnic*", "racial*", "mixed race", "skin colour", "skin color", "indigenous",
        // Sexual orientation
        "gay", "lesbian*", "bisexual*", "queer", "homosexual*", "heterosexual*",
        "sexual orientation", "sexuality", "came out as", "coming out as", "lgbt*", "pansexual",
        "asexual",
        // Gender identity
        "transgender", "trans woman", "trans man", "non binary", "nonbinary", "gender identity",
        "transitioning", "genderqueer", "gender fluid", "genderfluid",
        // Disability
        "disabilit*", "disabled", "wheelchair*", "blind", "visually impaired", "deaf",
        "hard of hearing", "hearing aid*", "autis*", "dyslex*", "impairment", "amputee",
        "paraplegic", "quadriplegic", "down syndrome", "cerebral palsy",
        // Union membership
        "union member*", "member of the union", "member of a union", "trade union*",
        "labour union", "labor union", "union rep", "union representative", "shop steward",
        "joined the union", "in the union",
        // Political views
        "politic*", "votes for", "voted for", "voting for", "party member", "labour party",
        "labor party", "national party", "green party", "liberal party", "conservative party",
        "tory", "tories", "republican*", "democrat*", "socialist*", "communist*", "left wing",
        "right wing", "libertarian*",
    ]

    /// Rent, bills, budgets and a bank's name are deliberately absent: they change answers every
    /// day and say nothing a stranger could use.
    static let financeTerms: [String] = [
        "salary", "salaries", "earns", "income", "wage", "wages", "debt*", "student loan*",
        "personal loan*", "car loan*", "payday loan*", "home loan*", "a loan", "mortgage*",
        "bankrupt*", "insolven*", "credit score*", "credit rating", "net worth", "bank balance",
        "account balance", "savings", "overdraft", "overdrawn", "arrears", "inheritance",
    ]

    static let legalOrHarmTerms: [String] = [
        "arrest*", "convicted", "conviction*", "criminal record", "prison*", "jail", "jailed",
        "in jail", "gaol", "in custody", "parole", "probation", "on bail", "charged with",
        "court case", "pleaded guilty", "guilty plea", "lawsuit", "sued", "being sued",
        "victim*", "assault*", "abuse*", "abusive", "domestic violence", "rape", "raped",
        "rapist", "sexual assault", "molest*", "harass*", "stalked", "stalker*", "stalking",
        "self harm*", "selfharm", "self injur*", "suicid*", "overdos*", "restraining order",
        "protection order", "deported", "deportation", "undocumented", "dui", "dwi",
        "drink driving", "drunk driving",
    ]

    // MARK: - Matching

    /// The text as the lists read it: " word word … " with a space either side, so an entry is
    /// found only on word boundaries.
    static func normalisedWords(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
        let mapped = folded.map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : " " }
        let collapsed = String(mapped).split(separator: " ").joined(separator: " ")
        return " \(collapsed) "
    }

    static func matches(_ words: String, _ entries: [String]) -> Bool {
        entries.contains { matches(words, entry: $0) }
    }

    /// One entry against text already passed through `normalisedWords`.
    static func matches(_ words: String, entry: String) -> Bool {
        if entry.hasSuffix("*") {
            return words.contains(" " + entry.dropLast())
        }
        return words.contains(" \(entry) ")
    }

    // MARK: - Identifier shapes (every language)

    /// A Luhn-valid run of 13–19 digits (spaces and hyphens between groups allowed), or a valid
    /// IBAN.
    static func hasIdentifierShape(_ text: String) -> Bool {
        digitRuns(in: text).contains(where: containsCardNumber) || containsIBAN(text)
    }

    /// Runs of digits, joined across single spaces or hyphens ("4111 1111-1111 1111").
    static func digitRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var pendingSeparator = false
        for ch in text {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
                pendingSeparator = false
            } else if (ch == " " || ch == "-"), !current.isEmpty, !pendingSeparator {
                pendingSeparator = true
            } else {
                if !current.isEmpty { runs.append(current) }
                current = ""
                pendingSeparator = false
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// A card number at the start of a run: the whole run when it is 13–19 digits, otherwise the
    /// common card lengths read from its first digit (a card read out with an expiry after it
    /// makes one long run).
    static func containsCardNumber(_ run: String) -> Bool {
        if (13...19).contains(run.count) { return luhnValid(run) }
        guard run.count > 19 else { return false }
        return [16, 15, 19, 13, 14, 17, 18].contains { luhnValid(String(run.prefix($0))) }
    }

    static func luhnValid(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, values.count >= 2 else { return false }
        var sum = 0
        for (index, digit) in values.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private static let ibanPattern = try? NSRegularExpression(
        pattern: #"\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]){11,30}\b"#)

    /// A two-letter country code, two check digits, then 11–30 letters or digits (spaces between
    /// groups allowed), passing the ISO 13616 mod-97 check.
    static func containsIBAN(_ text: String) -> Bool {
        guard let regex = ibanPattern else { return false }
        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..., in: upper)
        return regex.matches(in: upper, range: range).contains { match in
            guard let r = Range(match.range, in: upper) else { return false }
            return ibanValid(upper[r].replacingOccurrences(of: " ", with: ""))
        }
    }

    static func ibanValid(_ candidate: String) -> Bool {
        let iban = candidate.uppercased()
        guard (15...34).contains(iban.count), iban.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return false
        }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let chunk: String
            if let digit = ch.wholeNumberValue {
                chunk = String(digit)
            } else if let ascii = ch.asciiValue {
                chunk = String(Int(ascii) - 55)   // A = 10 … Z = 35
            } else {
                return false
            }
            for d in chunk { remainder = (remainder * 10 + (d.wholeNumberValue ?? 0)) % 97 }
        }
        return remainder == 1
    }

    // MARK: - The wearer as a minor (first-person statements only)

    private static let minorPatterns: [NSRegularExpression] = [
        #"\b(i am|im) (a minor|under 18|underage|under age)\b"#,
        #"\b(i am|im) ([1-9]|1[0-7])( years? old| yo| yrs? old)?$"#,
        #"\b(i am|im) ([1-9]|1[0-7]) (years? old|yo|yrs? old)\b"#,
        // School years: grade and form 1–12; "year" only from 7, so a second year at university
        // is not read as a child.
        #"\b(i am|im) (in )?(grade|form) ([1-9]|1[0-2])\b"#,
        #"\b(i am|im) (in )?year ([7-9]|1[0-3])\b"#,
        #"\bi (go to|attend) (high|primary|middle|secondary|elementary) school\b"#,
        #"\b(i am|im) (in|at) (high|primary|middle|secondary|elementary) school\b"#,
        #"\b(i am|im) (in|at) junior high\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Keys that, on their own, say the value is the wearer's age.
    private static let ownAgeKeys: Set<String> = ["age", "my age", "user age", "users age",
                                                   "wearer age", "wearers age"]

    static func isMinorStatement(key: String, value: String) -> Bool {
        let keyWords = normalisedWords(key).trimmingCharacters(in: .whitespaces)
        let valueWords = normalisedWords(value).trimmingCharacters(in: .whitespaces)
        if ownAgeKeys.contains(keyWords),
           let age = Int(valueWords.split(separator: " ").first ?? ""), age < 18 {
            return true
        }
        let text = normalisedWords(key.isEmpty ? value : "\(key) \(value)").trimmingCharacters(in: .whitespaces)
        let range = NSRange(text.startIndex..., in: text)
        return minorPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - Who a fact is about

    /// Words that name someone other than the wearer.
    static let relationshipWords: [String] = [
        "sister*", "brother*", "mother*", "mum", "mums", "mom", "moms", "father*", "dad", "dads",
        "wife*", "husband*", "partner*", "son", "sons", "daughter*", "child", "children", "kid",
        "kids", "friend*", "colleague*", "coworker*", "co worker*", "boss*", "neighbour*",
        "neighbor*", "aunt*", "uncle*", "cousin*", "grandma*", "grandmother*", "grandfather*",
        "grandpa*", "grandparent*", "niece*", "nephew*", "girlfriend*", "boyfriend*", "fiance*",
        "flatmate*", "roommate*", "housemate*", "manager*", "client*", "customer*", "patient*",
        "stepmother*", "stepfather*", "stepson*", "stepdaughter*", "parent*", "sibling*",
        "in law*", "teammate*", "classmate*", "employee*", "tenant*", "landlord*", "someone",
        "somebody", "a man", "a woman", "a guy", "this guy", "that guy", "stranger*",
    ]

    /// Openers that put the sentence about someone else.
    private static let thirdPersonOpeners: [String] = [
        "he", "she", "they", "his", "her", "their", "hes", "shes", "theyre", "him", "them",
    ]

    /// Words that look like a possessive name but are not ("today's", "it's", "what's").
    private static let possessiveNonNames: Set<String> = [
        "it", "that", "what", "there", "here", "who", "let", "one", "today", "tomorrow",
        "yesterday", "year", "week", "month", "night", "day", "user", "wearer", "everyone",
        "nobody", "anyone", "where", "how", "when", "why", "this", "he", "she", "doctor", "dr",
        "world", "life", "car", "dog", "cat", "people", "child", "childrens", "mens", "womens",
    ]

    /// Capitalised words that start a clause without being a name.
    private static let capitalisedNonNames: Set<String> = [
        "The", "This", "That", "These", "Those", "My", "It", "There", "Here", "Today", "Tomorrow",
        "Yesterday", "He", "She", "They", "We", "You", "Your", "Our", "Their", "His", "Her", "User",
        "Wearer", "Everyone", "Nobody", "Someone", "What", "Who", "Where", "When", "Why", "How",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    /// "Sam's" anywhere; in a key, "sam's" too — keys are short labels a model often lower-cases,
    /// while a lower-case possessive in a sentence is usually a thing ("the clinic's number").
    private static let possessiveNamePattern = try? NSRegularExpression(
        pattern: #"\b([A-Z][A-Za-z]{1,19})['’]s\b"#)
    private static let possessiveKeyPattern = try? NSRegularExpression(
        pattern: #"\b([A-Za-z]{2,20})['’]s\b"#)
    private static let namedStatementPattern = try? NSRegularExpression(
        pattern: #"(?:^|[\s,;(])([A-Z][a-z]{1,20})\s+(?:has|is|was|had|takes|took|got|gets|suffers|uses|went|goes|lost|needs|struggles|attends|votes|voted|earns|owes|lives|told|said)\b"#)

    /// `.wearer` unless the key or value names someone else: a relationship word ("sister",
    /// "my boss"), a possessive name ("Sam's diagnosis"), a named statement ("Sam has …"), or a
    /// sentence that opens on he / she / they. `utteranceSpeakerIsWearer` false (a bystander's
    /// words) makes everything someone else's.
    ///
    /// Reading the subject wrongly for an inferred fact changes nothing — an inferred sensitive
    /// fact is dropped whoever it is about. It matters only for a told-me fact, which a misread
    /// keeps locally at worst.
    static func subject(key: String, value: String, utteranceSpeakerIsWearer: Bool = true) -> Subject {
        guard utteranceSpeakerIsWearer else { return .otherPerson("someone") }
        let joined = key.isEmpty ? value : "\(key) \(value)"
        let words = normalisedWords(joined)
        if let word = relationshipWords.first(where: { matches(words, entry: $0) }) {
            return .otherPerson(word.replacingOccurrences(of: "*", with: ""))
        }
        let notAThing: (String) -> Bool = { !possessiveNonNames.contains($0.lowercased()) }
        if let name = firstCapture(possessiveKeyPattern, in: key, where: notAThing)
            ?? firstCapture(possessiveNamePattern, in: joined, where: notAThing) {
            return .otherPerson(name)
        }
        if let name = firstCapture(namedStatementPattern, in: joined,
                                   where: { !capitalisedNonNames.contains($0) }) {
            return .otherPerson(name)
        }
        let valueWords = normalisedWords(value).split(separator: " ")
        if let opener = valueWords.first, thirdPersonOpeners.contains(String(opener)) {
            return .otherPerson(String(opener))
        }
        return .wearer
    }

    /// The first capture of `regex` in `text` that `accept` allows.
    private static func firstCapture(_ regex: NSRegularExpression?, in text: String,
                                     where accept: (String) -> Bool) -> String? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text), accept(String(text[r])) {
                return String(text[r])
            }
        }
        return nil
    }
}
