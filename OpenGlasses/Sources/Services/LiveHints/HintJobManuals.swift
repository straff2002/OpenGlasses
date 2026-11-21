import Foundation

// Live hints from the job's manuals (Plan MO §5a, P2b). While a Field Assist job is open on a vault
// with manuals, a hint is searched in those manuals through Field Assist's own manual search, not
// in the wearer's personal documents, and the model call for it follows the rules a Field Assist
// answer follows. Everything that decides is here, pure; the adapters are in
// `LiveHintsAdapters.swift`, and the search itself is `FieldSessionService.hintPassages`.

/// The open job's manuals, as the hints session sees them: which vault, its name for the sheet,
/// and the vault's two rules that change what the model may say.
struct HintJobManuals: Equatable, Sendable {
    let vaultId: String
    /// The vault's display name ("Garden pumps"), the sheet's name for the job's manuals.
    let vaultName: String
    /// The job is sealed to the vault's own content (`VaultOnlyPolicy`): no answer from outside it.
    let vaultOnly: Bool
    /// The vault requires every answer to cite its source (`sourceAttributionRequired`).
    let citationsRequired: Bool
}

/// What a hint's search of the job's manuals came to (`FieldSessionService.hintPassages`).
enum ManualHintSearch: Equatable, Sendable {
    /// Passages that cleared Field Assist's evidence gate as the manual's own, best first.
    case passages([HintPassage])
    /// No card: why, for the log.
    case nothing(NothingReason)

    enum NothingReason: String, Equatable, Sendable {
        case emptyQuestion
        /// No job open with manuals to search (or the vault is locked).
        case noJobManuals
        /// The question is about a machine this vault is not for (the equipment scope check).
        case otherEquipment
        /// The question names another model the vault knows than the unit the job is on.
        case otherModel
        /// Nothing in the manuals answers closely enough to rely on.
        case insufficient
        /// Only team learnings answered, which a turn discloses and a glance card cannot.
        case teamLearningOnly
    }

    var passages: [HintPassage] {
        if case .passages(let found) = self { return found }
        return []
    }
}

/// Which documents a session searches while a job is open (decision 11): the job's manuals by
/// default, or the wearer's own documents chosen on the sheet. Read at every search, so a job
/// opened or closed mid-session takes effect at the next question.
enum HintSourcePreference: String, CaseIterable, Equatable, Sendable {
    /// The job's manuals whenever a job with manuals is open; the wearer's documents otherwise.
    case jobManualsWhenOpen
    /// The wearer's own documents (the active project, or those picked), even during a job.
    case myDocuments
}

/// The documents one search goes to: the job's manuals or the wearer's own, never both.
enum HintSearchScope: Equatable, Sendable {
    case jobManuals(HintJobManuals)
    case personal(HintDocumentScope)

    /// The job's manuals when the session prefers them, a job with manuals is open, and no
    /// personal document was picked; the personal scope (`HintDocumentScope.resolve`) otherwise.
    static func resolve(preference: HintSourcePreference, openJob: HintJobManuals?, chosen: [String]?,
                        activeProject: String?) -> HintSearchScope {
        if preference == .jobManualsWhenOpen, (chosen ?? []).isEmpty, let openJob {
            return .jobManuals(openJob)
        }
        return .personal(HintDocumentScope.resolve(chosen: chosen, activeProject: activeProject))
    }

    /// Names the documents searched, so the session's cache never answers a question in one scope
    /// with a card from the other.
    var key: String {
        switch self {
        case .jobManuals(let job): return "vault:" + job.vaultId
        case .personal(let scope):
            if let ids = scope.documentIds { return "docs:" + ids.sorted().joined(separator: ",") }
            return "ns:" + (scope.namespace ?? "global")
        }
    }
}

/// What the session may do with a search's passages beyond the passage card.
enum HintModelUse: Equatable, Sendable {
    /// One model call; `allowGeneral` false keeps the answer to the passages.
    case ask(allowGeneral: Bool)
    /// The passage card only, with no model call: the rules forbid sending these passages.
    case passageOnly(reason: String)
}

/// One search, with what the session may do with it.
struct HintSearchResult: Equatable, Sendable {
    var passages: [HintPassage]
    var modelUse: HintModelUse
    /// `HintSearchScope.key`: the session caches answers per scope.
    var scopeKey: String

    init(passages: [HintPassage], modelUse: HintModelUse = .ask(allowGeneral: true), scopeKey: String = "") {
        self.passages = passages
        self.modelUse = modelUse
        self.scopeKey = scopeKey
    }
}

/// Whether a hint built from the job's manuals may go to the model (§5a), and how. The same rules
/// a Field Assist answer follows:
///
/// - **The model is the job's.** A hint asks `Config.activeModel` through `completeStateless`,
///   which is the model a job's turns use (the vault's linked model while the job is open, the
///   organisation's model on a phone its profile set up) and resolves it through the medical
///   routing rule exactly as a Direct turn does. `resolvedProvider` is that resolution: nil when no
///   model is set up or the routing rule refuses every model, and then there is no call.
/// - **Medical Local Only.** With it on, a manual passage goes only to a model on the phone. The
///   routing rule already swaps a cloud model for a downloaded one; a cloud resolution is refused
///   here all the same rather than trusted.
/// - **Vault-only and required citations.** A sealed job answers from the vault alone, and a vault
///   that requires citations answers nothing it can't cite: the call is made, with general
///   knowledge off, so the model returns an empty hint rather than an answer from outside.
///
/// When the rules forbid the call the passage card stands alone. The passages are never sent
/// anyway. Pure.
enum HintManualModelRule {

    enum Refusal: String, Equatable, Sendable {
        /// No model is set up, or the medical routing rule refused every model.
        case noPermittedModel
        /// Medical Local Only is on and the model is not on the phone.
        case medicalLocalOnly
    }

    static func decide(job: HintJobManuals, resolvedProvider: LLMProvider?, medicalLocalOnly: Bool,
                       sessionAllowsGeneral: Bool = true) -> HintModelUse {
        guard let provider = resolvedProvider else { return .passageOnly(reason: Refusal.noPermittedModel.rawValue) }
        if medicalLocalOnly, !runsOnPhone(provider) {
            return .passageOnly(reason: Refusal.medicalLocalOnly.rawValue)
        }
        return .ask(allowGeneral: sessionAllowsGeneral && !job.vaultOnly && !job.citationsRequired)
    }

    /// The providers whose model runs on the phone.
    static func runsOnPhone(_ provider: LLMProvider) -> Bool {
        provider == .local || provider == .appleOnDevice
    }
}

/// The page a manual hint's press opens (§5a): the passage's citation read back exactly as Field
/// Assist reads a `Source:` line into a chip (`CitationLineParser`), so the press opens the page
/// the chip would. Nil for a passage from the wearer's own documents, which opens in the passage
/// sheet as before. Pure.
enum HintManualCitation {
    static func citation(for passage: PassageHint) -> Citation? {
        guard let line = passage.citation?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
        else { return nil }
        if let parsed = CitationLineParser.citations(inBody: line).first(where: { $0.kind == .manual }) {
            return parsed
        }
        return Citation(kind: .manual, title: passage.documentName, page: passage.page)
    }
}
