import Foundation

/// Has the technician moved to a different unit, and if so, is the job over?
///
/// `FieldSessionService.setEquipment` re-scopes silently when the recognised model changes: new
/// continuity scope, procedure dropped. That is right for continuity — work on one machine must
/// not carry onto another (FM) — and wrong for billing, because the job the technician has walked
/// away from is still open and still accruing. Nobody is asked whether it is finished.
///
/// One job can legitimately cover several units, so the change cannot be an automatic close either.
/// It is a question. This type decides whether there is a question to ask; the coordinator holds
/// the re-scope until it is answered.
///
/// **It only raises one on a confident identification** — the same bar `equipment_lookup` uses to
/// set the equipment at all: the text has to resolve to exactly one model the vault covers.
/// Anything less is `.unclear`, which asks nothing and changes nothing. A nameplate read that
/// split across two model numbers, a part number the vault mentions but is not a machine, a
/// half-heard model name: none of those may end a job.
enum JobChangeDetector {

    enum Outcome: Equatable {
        /// Same unit, or nothing said about equipment at all. Proceed as today.
        case same
        /// A different unit, confidently identified. Ask before re-scoping.
        case additionalUnit(candidate: EquipmentIdentity)
        /// Something was said about equipment, but not clearly enough to act on.
        case unclear(reason: UnclearReason)
    }

    enum UnclearReason: String, Equatable {
        /// The text matched more than one of the vault's models.
        case severalModels
        /// A model-like token the vault mentions, but not as a machine — an accessory, a board, a
        /// kit part number.
        case notAModel
    }

    /// What resolving a piece of text against the vault's model index produced.
    enum Candidate: Equatable {
        case none
        case unclear(reason: UnclearReason)
        case model(EquipmentIdentity)
    }

    // MARK: - Resolving text to a candidate

    /// Turn spoken words or a nameplate read into a candidate machine.
    ///
    /// Exactly one match is an identification; anything else is not. That asymmetry is the whole
    /// safety property: `equipment_lookup` already refuses to set equipment on an ambiguous read,
    /// and a question that could close a job must not be easier to trigger than the thing it
    /// guards.
    static func candidate(in text: String, index: VaultModelIndex,
                          source: EquipmentIdentity.Source,
                          nameplateText: String? = nil,
                          recognisedAt: Date = Date()) -> Candidate {
        guard !index.isEmpty else { return .none }
        let matches = index.match(text: text)
        if matches.count == 1 {
            let model = matches[0]
            return .model(EquipmentIdentity(model: model, token: model.name, source: source,
                                            recognisedAt: recognisedAt,
                                            nameplateText: nameplateText))
        }
        if matches.count > 1 { return .unclear(reason: .severalModels) }
        // No model section matched. If the text still names something the vault writes about, it
        // is an accessory or a part, not another machine — and must not raise the question.
        let tokens = VaultModelIndex.modelLikeTokens(in: text).map { $0.uppercased() }
        if tokens.contains(where: { index.vaultTokens.contains($0) }) {
            return .unclear(reason: .notAModel)
        }
        return .none
    }

    // MARK: - Comparing

    /// Compare a candidate against the unit the session is on.
    ///
    /// - Parameters:
    ///   - current: the session's equipment. **Nil is never a change** — the first machine of a
    ///     job is the job's machine, and asking "is the job finished?" before it has started would
    ///     be absurd.
    ///   - currentSerial: the serial recorded for the current unit, when one was read. Two
    ///     identical units on one site are the same model and different machines, and the serial
    ///     is the only thing that tells them apart.
    static func compare(current: EquipmentIdentity?,
                        currentSerial: String? = nil,
                        candidate: Candidate,
                        candidateSerial: String? = nil) -> Outcome {
        switch candidate {
        case .none:
            return .same
        case .unclear(let reason):
            // Nothing is unclear until there is something to change *from*.
            return current == nil ? .same : .unclear(reason: reason)
        case .model(let identity):
            guard let current else { return .same }
            guard current.heading == identity.heading else { return .additionalUnit(candidate: identity) }
            guard let a = normalisedSerial(currentSerial), let b = normalisedSerial(candidateSerial),
                  a != b else { return .same }
            return .additionalUnit(candidate: identity)
        }
    }

    /// Serials are compared case- and separator-insensitively: the same plate read twice, once by
    /// camera and once aloud, must not look like two machines.
    private static func normalisedSerial(_ value: String?) -> String? {
        guard let value else { return nil }
        let stripped = value.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
        return stripped.isEmpty ? nil : String(stripped)
    }
}

// MARK: - The question, and its answers

/// What the app asks when a different unit turns up mid-job.
struct JobUnitChangeQuestion: Equatable {
    let jobReference: String?
    let candidate: EquipmentIdentity

    var spoken: String {
        let job = jobReference.map { "job \($0)" } ?? "the job"
        return "That sounds like a different unit. Is \(job) finished, or is this another unit on the same job?"
    }
}

/// The three answers. "Not sure" is a real answer and its effect is deliberate: nothing changes.
enum JobUnitChangeAnswer: String, Equatable {
    case sameJob
    case jobFinished
    case unsure
}

/// Reading the answer out of what the technician said.
///
/// Returns nil for anything that is not an answer, which passes the turn to the model untouched —
/// the same contract the job-number intake uses, and for the same reason.
enum JobUnitChangeClassifier {

    static func classify(_ text: String) -> JobUnitChangeAnswer? {
        let normalised = normalise(text)
        guard !normalised.isEmpty else { return nil }
        if unsurePhrases.contains(where: { normalised == $0 }) { return .unsure }
        if finishedPhrases.contains(where: { normalised.contains($0) }) { return .jobFinished }
        if samePhrases.contains(where: { normalised.contains($0) }) { return .sameJob }
        return nil
    }

    /// Checked before "same job", because "the same job is finished" is a finish.
    private static let finishedPhrases: [String] = [
        "job is finished", "jobs finished", "job is done", "jobs done", "that ones finished",
        "that one is finished", "that ones done", "that one is done", "finished with that",
        "done with that", "first job is finished", "its finished", "it is finished",
        "thats finished", "that is finished", "new job", "different job", "another job",
        "started a new job", "finished", "all done"
    ]

    private static let samePhrases: [String] = [
        "same job", "same one", "same visit", "another unit", "second unit", "next unit",
        "other unit", "same work order", "still the same job", "one job", "same ticket"
    ]

    private static let unsurePhrases: [String] = [
        "not sure", "im not sure", "i am not sure", "dont know", "i dont know", "dunno",
        "no idea", "unsure", "cant say", "i cant say", "hang on", "wait"
    ]

    /// The same bare form the job-number classifier uses — including dropping apostrophes rather
    /// than splitting on them, so "that one's finished" still reads as a finish.
    private static func normalise(_ text: String) -> String {
        JobReferenceClassifier.normalise(text)
    }
}

/// A unit the job has been on. Appended, never replaced, so a multi-unit job can say what it
/// covered even though `FieldSession.equipment` only holds the current one.
struct VisitedUnit: Codable, Equatable {
    let modelToken: String
    let heading: String
    let serial: String?
    let firstSeenAt: Date
    /// The continuity scope the unit's work was recorded under (FM), so the export can partition.
    let continuityScope: String

    init(identity: EquipmentIdentity, serial: String? = nil, continuityScope: String,
         firstSeenAt: Date = Date()) {
        self.modelToken = identity.modelToken
        self.heading = identity.heading
        self.serial = serial
        self.firstSeenAt = firstSeenAt
        self.continuityScope = continuityScope
    }
}

/// A change question that has been put and not yet answered. Persisted with the session, so an
/// app restart mid-question does not quietly drop it.
struct PendingUnitChange: Codable, Equatable {
    let candidate: EquipmentIdentity
    let candidateSerial: String?
    let raisedAt: Date
    /// How many times this candidate has been asked about. Capped at one, by design.
    var asked: Int

    init(candidate: EquipmentIdentity, candidateSerial: String? = nil,
         raisedAt: Date = Date(), asked: Int = 0) {
        self.candidate = candidate
        self.candidateSerial = candidateSerial
        self.raisedAt = raisedAt
        self.asked = asked
    }

    /// Whether the same candidate may be raised again. It may not — once per candidate.
    func matches(_ identity: EquipmentIdentity) -> Bool { candidate.heading == identity.heading }
}
