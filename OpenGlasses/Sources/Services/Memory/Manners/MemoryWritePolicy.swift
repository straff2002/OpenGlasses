import Foundation

/// The rule for what a memory write may keep (Plan LN §2). Pure.
///
/// | What the fact is | told me | inferred (or any other origin) |
/// |---|---|---|
/// | an ID or card number | refuse, said aloud | refuse, silently |
/// | the wearer as a minor | drop | drop |
/// | sensitive, about someone else | refuse, said aloud | drop |
/// | sensitive, about the wearer | keep, local only | drop |
/// | anything else | keep | keep |
///
/// "Local only" is never pushed to the gateway (Plan LN decision 1). A tag is never rewritten into
/// a vaguer version of itself: "Sam: has a health condition" is refused exactly like the diagnosis.
enum MemoryWritePolicy {

    /// Where the write is going.
    enum Destination: Sendable {
        /// A saved fact (`SemanticMemoryStore`), which may also be pushed to the gateway.
        case memory
        /// Notes about a person (`SocialContextStore`). Always about someone else.
        case people
        /// The knowledge graph (`BrainStore`): people, organisations and places the wearer
        /// mentions. Never the wearer.
        case brain
        /// A "want me to remember that?" offer. Nothing is said when one is not made.
        case offer
    }

    enum Decision: Equatable, Sendable {
        case keep
        /// Kept on this phone and never sent to the gateway.
        case keepLocalOnly
        /// Not kept; `spoken` when the wearer asked for it and is owed one sentence.
        case refuse(MemorySensitivity.Category, spoken: Bool)
        /// Not kept, and nothing said.
        case drop(MemorySensitivity.Category)

        var isKept: Bool {
            switch self {
            case .keep, .keepLocalOnly: return true
            case .refuse, .drop: return false
            }
        }

        /// The category a write was declined for, when it was.
        var declinedCategory: MemorySensitivity.Category? {
            switch self {
            case .keep, .keepLocalOnly: return nil
            case .refuse(let category, _), .drop(let category): return category
            }
        }

        /// The sentence a spoken refusal appends to the reply, else nil.
        var spokenNotice: String? {
            guard case .refuse(let category, true) = self else { return nil }
            return MemoryRefusalNotice.sentence(for: category)
        }
    }

    static func decide(categories: Set<MemorySensitivity.Category>,
                       subject: MemorySensitivity.Subject,
                       origin: MemoryOrigin,
                       destination: Destination) -> Decision {
        let told = origin == .toldMe
        // An offer never speaks a refusal: it is simply not made.
        let speaks = told && destination != .offer
        if categories.contains(.identifier) { return .refuse(.identifier, spoken: speaks) }
        if categories.contains(.minor) { return .drop(.minor) }
        guard let category = MemorySensitivity.mostSerious(categories) else { return .keep }

        let aboutWearer: Bool
        switch destination {
        case .people, .brain: aboutWearer = false
        case .memory, .offer: aboutWearer = subject == .wearer
        }
        if aboutWearer { return told ? .keepLocalOnly : .drop(category) }
        return told ? .refuse(category, spoken: speaks) : .drop(category)
    }
}

/// The one gate every memory writer calls (Plan LN §4): the instruction check, then the subject
/// matter, the subject and the rule. Pure.
enum MemoryWriteGate {

    static func decide(key: String, value: String, origin: MemoryOrigin,
                       destination: MemoryWritePolicy.Destination,
                       turnReadUntrustedOutput: Bool = false,
                       utteranceSpeakerIsWearer: Bool = true) -> MemoryWritePolicy.Decision {
        if let reason = MemoryInstructionCheck.reason(key: key, value: value, origin: origin,
                                                      turnReadUntrustedOutput: turnReadUntrustedOutput) {
            let speaks = origin == .toldMe && destination != .offer && reason == .assistantInstruction
            return speaks ? .refuse(reason, spoken: true) : .drop(reason)
        }
        return MemoryWritePolicy.decide(
            categories: MemorySensitivity.classify(key: key, value: value),
            subject: MemorySensitivity.subject(key: key, value: value,
                                               utteranceSpeakerIsWearer: utteranceSpeakerIsWearer),
            origin: origin, destination: destination)
    }
}

/// The one sentence a refused told-me write adds to the reply — no explanation of the policy and
/// no list of what else is not kept.
enum MemoryRefusalNotice {

    static func sentence(for category: MemorySensitivity.Category) -> String {
        switch category {
        case .identifier:
            return String(localized: "I don't keep card or ID numbers in memory.",
                          comment: "Appended to a spoken reply when the wearer asked the assistant to remember a card, bank or ID number, which it never keeps.")
        case .assistantInstruction:
            return String(localized: "I don't keep instructions like that in memory.",
                          comment: "Appended to a spoken reply when the wearer asked the assistant to remember an instruction to skip a check, warn less or approve things on its own.")
        case .minor, .legalOrHarm, .health, .protectedAttribute, .finances, .untrustedSource:
            return String(localized: "I don't keep details like that about other people.",
                          comment: "Appended to a spoken reply when the wearer asked the assistant to remember a health, money, legal or similar private detail about someone else.")
        }
    }
}
