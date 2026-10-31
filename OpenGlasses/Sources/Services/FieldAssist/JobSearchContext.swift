import Foundation

/// What a follow-up is about, when its own words do not say (Plan KE P1).
///
/// "The tech sheet is missing, what next?" holds neither the model nor the symptom, so the search
/// finds nothing, the evidence gate refuses it, and the model has no pages to work from on the very
/// turn the technician most needs one. `manualPassagesContext` searched the turn's words alone. This
/// reads what the job is about from the active unit and the last two turns that asked or described
/// something, and one more search carries that beside the turn.
///
/// It can only add passages, they still clear the evidence gate, and a search that fails again
/// leaves the refusal as it was. Pure.
enum JobSearchContext {

    /// How many earlier turns go into a context.
    static let turnsUsed = 2
    /// How many are held: a turn dropped at the last moment for naming another model leaves others.
    static let turnsHeld = 4
    /// How many passages the second search may add to a turn that found something of its own.
    static let maximumAdded = 2

    /// Whether a turn says what the job is about: a question or a description, not a reading, a
    /// correction, a page request or the job's bookkeeping, with a content word in it, so "yes" and
    /// "ok thanks" are no subject.
    static func describesTheJob(_ turn: String) -> Bool {
        switch ManualTurnClassifier.classify(turn) {
        case .question, .statement: break
        case .jobBookkeeping, .correction, .showMe, .reading: return false
        }
        return !TechnicianRequest.isShortAffirmative(turn) && !LexicalSupport.QueryTerms(turn).isEmpty
    }

    /// `earlier` with `turn` kept, when it is worth keeping: job numbers out, the newest last. The
    /// same words again are one turn, as they are when a prompt is rebuilt after a tool round.
    static func keeping(_ turn: String, after earlier: [String]) -> [String] {
        let cleaned = ManualTurnScope.removingJobReferences(from: turn)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, describesTheJob(cleaned) else { return earlier }
        return Array((earlier.filter { $0 != cleaned } + [cleaned]).suffix(turnsHeld))
    }

    /// The context for `current`: the unit as stated, then the last two earlier turns, oldest first.
    /// A turn naming another of the vault's models is about that machine and stays out, and so does
    /// the turn in flight, which the search has already. Nil with nothing to add.
    static func context(unit: String?, earlierTurns: [String], current: String,
                        otherModels: Set<String>) -> String? {
        let asked = ManualTurnScope.removingJobReferences(from: current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let turns = earlierTurns.filter { turn in
            turn != asked && !VaultModelIndex.modelLikeTokens(in: turn).contains { otherModels.contains($0.uppercased()) }
        }
        let parts = [unit].compactMap { $0 } + turns.suffix(turnsUsed)
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    /// Whether the turn's own search needs the second: it was refused, or the unit has documents
    /// assigned and it found nothing in any of them.
    static func searchesAgain(after outcome: RetrievalOutcome, assigned: Set<String>) -> Bool {
        guard outcome.answers else { return true }
        return !assigned.isEmpty && !outcome.passages.contains { assigned.contains($0.documentId) }
    }

    /// What goes to the model. Never less than the turn found. A refused turn takes whatever the
    /// second search cleared. A turn that found only other documents keeps them, first, and gains at
    /// most `maximumAdded` from assigned documents, which a learning-only turn turns into a manual
    /// answer with its learning still beside it. A second search that fails changes nothing.
    static func merged(own: RetrievalOutcome, context: RetrievalOutcome, assigned: Set<String>) -> RetrievalOutcome {
        guard context.answers else { return own }
        guard own.answers else { return context }
        let found = Set(own.passages.map(key))
        let added = context.passages.filter { !found.contains(key($0)) && assigned.contains($0.documentId) }
            .prefix(maximumAdded)
        guard !added.isEmpty else { return own }
        return own.isSufficient ? .sufficient(own.passages + added) : .sufficient(added + own.passages)
    }

    private static func key(_ passage: VaultRetriever.Passage) -> String {
        "\(passage.documentId)#\(passage.chunkIndex)"
    }
}
