import Foundation

/// "What do you know about me?", "What do you know about Maria?", "Forget that my sister lives in
/// Wellington", "Actually, she lives in Nelson." (Plan GG P3)
///
/// The glasses only speak: a short summary, a handful of matches, or the outcome of one forget or
/// correction. Anything that needs choosing between facts goes to the phone. Forget and correct
/// must resolve **exactly one** fact — two or more candidates are handed to the phone rather than
/// guessed between — and a forget is confirmed with the resolved fact's own words before it runs.
///
/// What the model reads through this tool is no wider than what it could already recall: another
/// persona's facts and the assistant's own notes (outside agent mode) are left out, exactly as
/// `memory_search` and prompt assembly leave them out.
struct MyMemoryTool: NativeTool {
    let name = "my_memory"
    let description = """
    What you remember about the user, and changing it on their say-so. Actions: 'list' — when they \
    ask what you know about them, gives a short spoken summary; 'about' with 'subject' — what you \
    know about a person, place or topic ('Maria', 'my sister', 'coffee'); 'forget' with 'fact' — \
    remove one fact they name ('my sister lives in Wellington'); 'correct' with 'fact' and \
    'new_value' — replace a wrong value ('fact': 'sister lives in Wellington', 'new_value': \
    'Nelson'). Forget asks the user to confirm. If more than one fact matches, the choices go to \
    their phone — say so and stop. Speak the result as given.
    """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["list", "about", "forget", "correct"],
                "description": "list, about, forget or correct",
            ],
            "subject": [
                "type": "string",
                "description": "For 'about': who or what — a name, relation, place or topic.",
            ],
            "fact": [
                "type": "string",
                "description": "For 'forget' and 'correct': the fact in the user's words.",
            ],
            "new_value": [
                "type": "string",
                "description": "For 'correct': the right value, e.g. the new city or name.",
            ],
        ],
        "required": ["action"],
    ]

    /// Every fact this tool may read, already scoped (see `MyMemoryToolScope`).
    var facts: @MainActor () -> [MemoryFact] = { [] }
    var forgetter: MemoryFactForgetter?
    var corrector: MemoryFactCorrector?
    /// Ask the wearer to approve a forget, in words naming the resolved fact. Absent → fail closed.
    var confirm: (@MainActor (String) async -> Bool)?
    /// Put several candidates on the phone, filtered by the phrase the wearer used.
    var handOff: (@MainActor (String) -> Void)?

    static let maxSpokenFacts = 5

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? "list"
        let all = facts()
        switch action {
        case "list":
            return MemorySpokenSummary.summary(all)
        case "about":
            return about(subject: (args["subject"] as? String) ?? "", in: all)
        case "forget":
            return await forget(phrase: (args["fact"] as? String) ?? "", in: all)
        case "correct":
            return await correct(phrase: (args["fact"] as? String) ?? "",
                                 newValue: (args["new_value"] as? String) ?? "", in: all)
        default:
            return "Unknown action. Use list, about, forget or correct."
        }
    }

    // MARK: - About

    static let selfWords: Set<String> = ["me", "myself", "i", "user", "the user", "you", "everything", ""]

    static func asksAboutHealth(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["health", "medical", "medication", "doctor", "condition", "allerg", "symptom"]
            .contains(where: lowered.contains)
    }

    func about(subject: String, in all: [MemoryFact]) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.selfWords.contains(trimmed.lowercased()) { return MemorySpokenSummary.summary(all) }
        // Health is read aloud only when the question is about health.
        let pool = Self.asksAboutHealth(trimmed) ? all : all.filter { $0.group != .health }
        let matches = MemoryFactMatcher.candidates(for: trimmed, in: pool)
        guard !matches.isEmpty else {
            return "I don't have anything saved about \(trimmed)."
        }
        let spoken = matches.prefix(Self.maxSpokenFacts).map(\.text)
        var text = "About \(trimmed): \(spoken.joined(separator: "; "))."
        if matches.count > Self.maxSpokenFacts {
            text += " There are \(matches.count - Self.maxSpokenFacts) more in Memory on your phone."
        }
        return text
    }

    // MARK: - Forget

    func forget(phrase: String, in all: [MemoryFact]) async -> String {
        let candidates = MemoryFactMatcher.candidates(for: phrase, in: all,
                                                    minimumShare: MemoryFactMatcher.changeShare)
            .filter { $0.capabilities.contains(.forget) }
        switch await resolve(candidates, phrase: phrase) {
        case .none(let reply), .several(let reply):
            return reply
        case .one(let fact):
            guard let forgetter else { return "I can't change memory right now." }
            guard let confirm else {
                return "Forgetting needs your confirmation, which isn't available right now. Try again with the app open, or use Memory on your phone."
            }
            guard await confirm(Self.confirmationSummary(fact)) else {
                return "Okay, I've kept it."
            }
            let plan = forgetter.plan(for: fact)
            // By voice the assistant's notes are left alone: the matching lines are prose the
            // wearer has not seen, and the phone is where they are shown before removal.
            let result = await forgetter.forget(plan, removeNoteLines: false)
            var reply = result.summary
            if result.verified, !plan.noteLines.isEmpty {
                reply += " My notes also mention it; you can remove that in Memory on your phone."
            }
            return reply
        }
    }

    static func confirmationSummary(_ fact: MemoryFact) -> String {
        "Forget \u{201C}\(fact.text)\u{201D}?"
    }

    // MARK: - Correct

    func correct(phrase: String, newValue: String, in all: [MemoryFact]) async -> String {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "What should it say instead?" }
        let candidates = MemoryFactMatcher.candidates(for: phrase, in: all,
                                                    minimumShare: MemoryFactMatcher.changeShare)
            .filter { $0.capabilities.contains(.correct) }
        switch await resolve(candidates, phrase: phrase) {
        case .none(let reply), .several(let reply):
            return reply
        case .one(let fact):
            guard let corrector else { return "I can't change memory right now." }
            let result = corrector.correct(fact, to: value)
            return result.verified
                ? "Updated. I had \u{201C}\(fact.correctableValue)\u{201D}; it's now \u{201C}\(value)\u{201D}."
                : "I couldn't update that. You can change it in Memory on your phone."
        }
    }

    // MARK: - Resolution

    enum Resolution {
        case none(String)
        case one(MemoryFact)
        case several(String)
    }

    func resolve(_ candidates: [MemoryFact], phrase: String) async -> Resolution {
        switch candidates.count {
        case 0:
            return .none("I couldn't find that in what I remember.")
        case 1:
            return .one(candidates[0])
        default:
            if let handOff { handOff(phrase) }
            let count = candidates.count == 2 ? "two" : "\(candidates.count)"
            return .several("I found \(count) that could match; I've put them on your phone so you can choose.")
        }
    }
}

/// Which facts the voice tool may read: never wider than what the model could already recall.
enum MyMemoryToolScope {

    /// - Parameters:
    ///   - activePersona: the persona whose own facts the model may read alongside shared ones.
    ///   - agentModeEnabled: the assistant's notes reach a prompt only in agent mode.
    static func visible(_ facts: [MemoryFact], activePersona: String?,
                        agentModeEnabled: Bool) -> [MemoryFact] {
        facts.filter { fact in
            if let persona = fact.persona, persona != activePersona { return false }
            if fact.id.store == .agentNote, !agentModeEnabled { return false }
            return true
        }
    }
}
