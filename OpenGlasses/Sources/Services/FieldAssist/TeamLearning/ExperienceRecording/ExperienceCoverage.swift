import Foundation

/// "What's missing" (Plan IM P4): the active vault's models that no crew experience is about yet,
/// so a reviewer can ask the technicians to record what they know about them at onboarding. Pure.
///
/// **What counts as crew experience** is every approved entry on the phone, whatever its origin —
/// a recollection, a sheet row from the company's crew experience set, or a learning confirmed on a
/// job (`TeamLearningSources.entries(reviewed:experience:)`) — that is live and would be published
/// to this vault (`LearningCorpus.placement`: in scope, a model this vault knows, a listed type).
///
/// **A model is covered by identity, the way retrieval scopes a learning** (team-learning §7.2):
/// an entry with a model subject covers the index's model one of whose spellings its token is,
/// trimmed and case-folded (`VaultRetriever.ModelScope.identity` against `Model.tokens`, exactly
/// what `retrievalModelScope` and `penalty(forSubjectToken:)` compare). Its prose is never read.
///
/// **A symptom entry covers no model.** Retrieval admits it for a unit only within the unit's
/// equipment type, and the unit's type comes from its own approved model entries
/// (`FieldSessionService.equipmentTypeScope`), which already cover that model; with no type
/// resolved it is unscoped, answering for every unit and so about none of them. Either way it never
/// makes a model covered that was not already. A practice entry is scoped by topic, not machine.
///
/// Nothing is assigned and nothing nags: this is a count and a list, shown on the reviewer's own
/// device. Sending the list to technicians is Plan IM P3's channel (`ExperienceCoverageRequest`
/// is the value it will carry).
struct ExperienceCoverage: Equatable {

    let vaultId: String
    let vaultName: String
    /// Every model the vault's index names, in its order.
    let models: [VaultModelIndex.Model]
    /// The models no crew experience is about, in the index's order.
    let missing: [VaultModelIndex.Model]

    var totalCount: Int { models.count }
    var missingCount: Int { missing.count }
    var coveredCount: Int { models.count - missing.count }
    /// The missing models as the vault names them.
    var missingNames: [String] { missing.map(\.name) }

    static func of(_ vault: LearningCorpus.VaultTarget, entries: [LearningEntry]) -> ExperienceCoverage {
        let identities = Set(entries.compactMap { entry -> String? in
            guard case .model(let token, _, _) = entry.subject,
                  LearningCorpus.placement(of: entry, among: [vault]).published.contains(vault.id) else { return nil }
            return VaultRetriever.ModelScope.identity(token)
        })
        let models = vault.modelIndex.models
        let missing = models.filter { model in !model.tokens.contains(where: identities.contains) }
        return ExperienceCoverage(vaultId: vault.id, vaultName: vault.modelIndex.vaultName, models: models,
                                  missing: missing)
    }

    /// The list a reviewer would send to technicians, or nil when nothing is missing.
    func request(askedAt: Date) -> ExperienceCoverageRequest? {
        guard !missing.isEmpty else { return nil }
        return ExperienceCoverageRequest(vaultId: vaultId, vaultName: vaultName, models: missingNames, askedAt: askedAt)
    }

    /// Whether the count is shown: on a reviewer's device (`Config.teamLearningReviewerDevice`),
    /// wherever the recorder itself is offered — so never under Medical Compliance, never with
    /// Field Assist off, never on a licence without team learnings.
    static func isShown(reviewerDevice: Bool, recorder verdict: ExperienceRecordingAvailability.Verdict) -> Bool {
        reviewerDevice && verdict.isOffered
    }

    /// The coverage of the vault in force, from the approved entries on this phone; nil where it
    /// is not shown or the vault is not installed.
    @MainActor
    static func current() -> ExperienceCoverage? {
        guard isShown(reviewerDevice: Config.teamLearningReviewerDevice,
                      recorder: ExperienceRecordingAvailability.current()) else { return nil }
        let id = Config.fieldAssistDefaultVaultId
        guard let manifest = VaultRegistry.shared.allManifests.first(where: { $0.id == id }) else { return nil }
        let target = LearningCorpus.VaultTarget(id: manifest.id,
                                                modelIndex: VaultModelIndex(store: VaultRegistry.shared.store(for: manifest)),
                                                equipmentTypes: manifest.equipmentTypes)
        return of(target, entries: TeamLearningSources.entries(reviewed: .shared, experience: .shared))
    }
}

/// The list of models a reviewer asks the technicians to record what they know about (Plan IM P4):
/// the models' names, the vault and when it was asked. Nobody is named and nothing is assigned; a
/// technician sees it on the recorder's card. It travels by Plan IM P3's channel, which is not built.
struct ExperienceCoverageRequest: Codable, Equatable, Sendable {
    let vaultId: String
    let vaultName: String
    /// The models, as the vault names them, in its order.
    let models: [String]
    /// Whole seconds, as every team-learning date is.
    let askedAt: Date

    init(vaultId: String, vaultName: String, models: [String], askedAt: Date) {
        self.vaultId = vaultId
        self.vaultName = vaultName
        self.models = models
        self.askedAt = Date(timeIntervalSince1970: askedAt.timeIntervalSince1970.rounded(.down))
    }

    enum CodingKeys: String, CodingKey {
        case vaultId = "vault_id"
        case vaultName = "vault_name"
        case models
        case askedAt = "asked_at"
    }
}

/// What the coverage count and the list say (Plan IM P4), in one place so the reviewer's screen,
/// the technician's card and the tests read the same words.
enum ExperienceCoverageCopy {

    /// "14 models in your vault have no crew experience yet"; nil for a vault that names no models,
    /// which has nothing to count.
    static func summary(missing: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        switch missing {
        case 0:
            return String(localized: "Every model in your vault has crew experience.",
                          comment: "The reviewer's crew experience coverage: no model in the vault is missing crew experience")
        case 1:
            return String(localized: "1 model in your vault has no crew experience yet.",
                          comment: "The reviewer's crew experience coverage: one model in the vault has none")
        default:
            return String(localized: "\(missing) models in your vault have no crew experience yet.",
                          comment: "The reviewer's crew experience coverage: how many models in the vault have none")
        }
    }

    static func summary(_ coverage: ExperienceCoverage) -> String? {
        summary(missing: coverage.missingCount, total: coverage.totalCount)
    }

    /// The reviewer's section header and the heading over the missing models.
    static var sectionTitle: String {
        String(localized: "Crew experience coverage",
               comment: "Header of the reviewer's section counting the vault's models with no crew experience")
    }
    static var missingListTitle: String {
        String(localized: "Models with no crew experience yet",
               comment: "Heading over the list of the vault's models no crew experience is about")
    }

    /// The technician's line on the recorder's card, over the list.
    static var requestLine: String {
        String(localized: "Could you record what you know about these?",
               comment: "On the technician's recorder card, above the models the reviewer would like crew experience for")
    }

    /// Which vault the list is for, and the day it was asked.
    static func requestHeader(_ request: ExperienceCoverageRequest, locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String {
        let day = request.askedAt.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated))
        return String(localized: "\(request.vaultName) · asked \(day)",
                      comment: "On the technician's recorder card: the vault the list of models is for, and the day the reviewer asked")
    }
}
