import Foundation

/// The read-only pass over facts saved before the write gate existed (Plan LN §6, decision 3).
/// Pure.
///
/// A fact is flagged when the gate would not keep it as it stands — an ID number, someone else's
/// health or politics, an inferred guess about the wearer's own, a memory telling the assistant to
/// check less. A health fact the wearer asked to keep about themselves is what the rule keeps, so
/// it is not flagged. Nothing here deletes or moves anything; the Memory screen shows the count
/// and a filtered list, and the wearer decides.
enum MemorySensitivityReview {

    static func flagged(_ facts: [MemoryFact]) -> [MemoryFact] {
        facts.filter(looksSensitive)
    }

    static func looksSensitive(_ fact: MemoryFact) -> Bool {
        let (key, value) = parts(of: fact)
        let destination: MemoryWritePolicy.Destination
        switch fact.id.store {
        case .brainEdge, .brainNeed: destination = .brain
        default: destination = .memory
        }
        let decision = MemoryWritePolicy.decide(
            categories: MemorySensitivity.classify(key: key, value: value),
            subject: MemorySensitivity.subject(key: key, value: value),
            origin: fact.origin, destination: destination)
        return !decision.isKept || MemoryInstructionCheck.weakensSafeguards(fact.text)
    }

    /// A semantic fact reads "key: value"; its value is what a correction replaces. Every other
    /// kind is one sentence.
    private static func parts(of fact: MemoryFact) -> (key: String, value: String) {
        guard fact.id.store == .semantic else { return ("", fact.text) }
        let value = fact.correctableValue
        let suffix = ": " + value
        let key = fact.text.hasSuffix(suffix) ? String(fact.text.dropLast(suffix.count)) : ""
        return (key, value)
    }
}
