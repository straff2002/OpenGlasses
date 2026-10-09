import Foundation

/// Reviews and publishes team learnings on a reviewer's device (Plan FP P2) — the layer that reads
/// `LearningReview`'s inputs off the phone and writes its results: the candidate's new status, the
/// approved entry, and the entry's documents in the `learning:` namespaces.
///
/// **The gate is here, as P1's is in `LearningCandidateService`.** Approving, editing, merging and
/// turning down ask the `.teamLearnings` capability and are refused outright under HIPAA mode.
/// Superseding and retracting are not gated: taking an answer out of service is always allowed,
/// and a replacement's own approval is where the gate sits. Retrieval asks nothing — published
/// learnings stay readable on a lapsed licence (FP §5).
///
/// No screen calls this yet; the review queue and the corpus browser are P4.
@MainActor
final class LearningReviewService {

    static let shared = LearningReviewService()

    let candidates: LearningCandidateStore
    let entries: LearningEntryStore
    /// Where the corpus documents go. Nil in a context with no document index: the entry is still
    /// approved and kept, and `republish()` puts it in place once there is one.
    var documentStore: DocumentStore?

    /// The licence's answer for team learnings. A test states its own.
    var capability: () -> FieldAssistCapabilityCheck = { FieldAssistEntitlement.shared.check(.teamLearnings) }
    /// `Config.teamLearningReviewerDevice`, injectable.
    var isReviewerDevice: () -> Bool = { Config.teamLearningReviewerDevice }
    /// `Config.hipaaMode`, injectable.
    var hipaaMode: () -> Bool = { Config.hipaaMode }
    /// The vaults installed on this phone, each with the model index an entry's token is checked
    /// against.
    var vaults: () -> [LearningCorpus.VaultTarget] = { LearningReviewService.installedVaults() }
    /// A vault's core files, for the safety check.
    var coreFiles: (String) -> [(filename: String, contents: String)] = { id in
        VaultRegistry.shared.store(forId: id)?.readAll() ?? []
    }
    var clock: () -> Date = Date.init

    init(candidates: LearningCandidateStore? = nil, entries: LearningEntryStore? = nil,
         documentStore: DocumentStore? = nil) {
        self.candidates = candidates ?? .shared
        self.entries = entries ?? .shared
        self.documentStore = documentStore
    }

    /// What an approval did: the entry, the candidate's state, the safety finding, and where the
    /// entry was published — and held back, for a model a vault does not know.
    struct Outcome: Equatable {
        let entry: LearningEntry
        let state: LearningReview.State
        let safety: LearningSafetyCheck.Finding
        let placement: LearningCorpus.Placement
    }

    // MARK: - Context

    /// The device and licence, as `LearningReview` needs them.
    func context() -> LearningReview.Context {
        let refusal: String?
        switch capability() {
        case .granted: refusal = nil
        case .notIncluded: refusal = FieldAssistPaywallCopy.teamLearningsReviewNotIncluded
        case .denied(.expired(_)): refusal = FieldAssistPaywallCopy.teamLearningsReviewLapsed
        case .denied(.unverifiableLicense): refusal = FieldAssistPaywallCopy.unverifiable
        case .denied(.noEvidence): refusal = FieldAssistPaywallCopy.teamLearningsReviewLocked
        }
        return LearningReview.Context(isReviewerDevice: isReviewerDevice(), entitlementRefusal: refusal,
                                      hipaa: hipaaMode())
    }

    // MARK: - Previews for the review surface

    /// What the safety check finds in a candidate's text (or the reviewer's edit of it), against
    /// the safety files of every vault it would be published to.
    func safetyCheck(candidateID: String, edits: LearningReview.Edits? = nil,
                     vaultIDs: [String]? = nil) -> LearningSafetyCheck.Finding? {
        guard let candidate = candidates.candidate(id: candidateID) else { return nil }
        return LearningSafetyCheck.check(finding: edits?.finding ?? candidate.finding,
                                         symptom: edits?.symptom ?? candidate.symptom,
                                         fix: edits?.fix ?? candidate.fix,
                                         coreFiles: safetyCore(for: vaultIDs ?? [candidate.vaultId]))
    }

    /// Entries a candidate probably repeats — the merge suggestions the review surface shows.
    func mergeSuggestions(candidateID: String) -> [String] {
        guard let candidate = candidates.candidate(id: candidateID) else { return [] }
        return LearningReview.mergeSuggestions(for: candidate, among: entries.entries)
    }

    /// Where a candidate would be published, and which vaults would be held back because their
    /// model index does not know its model — the flag the reviewer sees before approving.
    func placementPreview(candidateID: String, subject: LearningEntry.Subject? = nil,
                          vaultIDs: [String]? = nil) -> LearningCorpus.Placement? {
        guard let candidate = candidates.candidate(id: candidateID),
              let resolved = subject.flatMap(LearningReview.cleanSubject) ?? LearningReview.defaultSubject(of: candidate)
        else { return nil }
        let probe = LearningEntry(subject: resolved, vaultIDs: vaultIDs ?? [candidate.vaultId],
                                  finding: candidate.finding, approvedAt: clock(), approvedByRole: "-",
                                  approvedByName: "-")
        return LearningCorpus.placement(of: probe, among: vaults())
    }

    // MARK: - Decisions

    /// Approve a candidate (as written, or edited), store the entry and publish it. A safety
    /// collision needs `confirmsSafetyDeparture`; a model a vault does not know is held back from
    /// that vault, and the outcome says which.
    func approve(candidateID: String, approver: LearningReview.Approver, edits: LearningReview.Edits? = nil,
                 subject: LearningEntry.Subject? = nil, vaultIDs: [String]? = nil,
                 supersedes: String? = nil,
                 confirmsSafetyDeparture: Bool = false) -> Result<Outcome, LearningReview.Refusal> {
        guard let candidate = candidates.candidate(id: candidateID) else {
            return .failure(.unknownCandidate(candidateID))
        }
        var replaced: LearningEntry?
        if let supersedes {
            guard let old = entries.entry(id: supersedes) else { return .failure(.unknownEntry(supersedes)) }
            guard old.isLive else { return .failure(.entryNotLive(supersedes)) }
            replaced = old
        }
        let scope = vaultIDs ?? [candidate.vaultId]
        let now = clock()
        let approval: LearningReview.Approval
        switch LearningReview.approve(candidate, approver: approver, edits: edits, subject: subject,
                                      vaultIDs: scope, supersedes: supersedes,
                                      safetyCore: safetyCore(for: scope),
                                      confirmsSafetyDeparture: confirmsSafetyDeparture,
                                      context: context(), now: now) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): approval = value
        }
        entries.upsert(approval.entry)
        var updated = candidate
        updated.status = .approved
        updated.entryID = approval.entry.id
        updated.updatedAt = LearningReview.wholeSecond(now)
        candidates.update(updated)
        if let replaced, case .success(let stamped) = LearningReview.supersede(replaced, by: approval.entry, now: now) {
            entries.upsert(stamped)
            if let documentStore { LearningCorpus.withdraw(entryID: stamped.id, store: documentStore) }
        }
        let placement = publish(approval.entry)
        return .success(Outcome(entry: approval.entry, state: approval.state, safety: approval.safety,
                                placement: placement))
    }

    /// Fold a candidate into an approved entry that already says it: one more job, no new entry.
    /// The entry's document is unchanged — the citation does not move; the lead-in's count does.
    func merge(candidateID: String, into entryID: String,
               approver: LearningReview.Approver) -> Result<LearningEntry, LearningReview.Refusal> {
        guard let candidate = candidates.candidate(id: candidateID) else {
            return .failure(.unknownCandidate(candidateID))
        }
        guard let entry = entries.entry(id: entryID) else { return .failure(.unknownEntry(entryID)) }
        switch LearningReview.merge(candidate, into: entry, approver: approver, context: context()) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let result):
            entries.upsert(result.entry)
            var updated = candidate
            updated.status = .merged
            updated.entryID = entryID
            updated.updatedAt = LearningReview.wholeSecond(clock())
            candidates.update(updated)
            return .success(result.entry)
        }
    }

    /// Not taken up, with the reviewer's reason for the author.
    func reject(candidateID: String, reason: String) -> Result<LearningCandidate, LearningReview.Refusal> {
        guard let candidate = candidates.candidate(id: candidateID) else {
            return .failure(.unknownCandidate(candidateID))
        }
        switch LearningReview.reject(candidate, reason: reason, context: context()) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let state):
            var updated = candidate
            updated.status = .notTakenUp
            if case .rejected(let words) = state { updated.reviewReason = words }
            updated.updatedAt = LearningReview.wholeSecond(clock())
            candidates.update(updated)
            return .success(updated)
        }
    }

    /// Replace one entry with another already approved: the old one is stamped and kept, and its
    /// documents leave every namespace. Replaying it changes nothing.
    func supersede(entryID: String, by replacementID: String) -> Result<LearningEntry, LearningReview.Refusal> {
        guard let old = entries.entry(id: entryID) else { return .failure(.unknownEntry(entryID)) }
        guard let replacement = entries.entry(id: replacementID) else { return .failure(.unknownEntry(replacementID)) }
        switch LearningReview.supersede(old, by: replacement, now: clock()) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let stamped):
            entries.upsert(stamped)
            if let documentStore { LearningCorpus.withdraw(entryID: stamped.id, store: documentStore) }
            return .success(stamped)
        }
    }

    /// Take an entry out of service with a reason: stamped and kept as history, its documents gone
    /// from every namespace. Replaying it changes nothing.
    func retract(entryID: String, reason: String) -> Result<LearningEntry, LearningReview.Refusal> {
        guard let entry = entries.entry(id: entryID) else { return .failure(.unknownEntry(entryID)) }
        switch LearningReview.retract(entry, reason: reason, now: clock()) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let stamped):
            entries.upsert(stamped)
            if let documentStore { LearningCorpus.withdraw(entryID: stamped.id, store: documentStore) }
            return .success(stamped)
        }
    }

    /// Make the namespaces match the entries again — after an import, a vault install or a store
    /// that arrived late. Idempotent. Refused under HIPAA mode, where nothing is published.
    func republish() {
        guard !hipaaMode(), let documentStore else { return }
        LearningCorpus.reconcile(entries: entries.entries, vaults: vaults(), store: documentStore)
    }

    // MARK: - Parts

    @discardableResult
    private func publish(_ entry: LearningEntry) -> LearningCorpus.Placement {
        guard let documentStore else { return LearningCorpus.placement(of: entry, among: vaults()) }
        return LearningCorpus.publish(entry, vaults: vaults(), store: documentStore)
    }

    /// The core files of the vaults in scope (every installed vault when the scope is empty).
    private func safetyCore(for vaultIDs: [String]) -> [(filename: String, contents: String)] {
        let ids = vaultIDs.isEmpty ? vaults().map(\.id) : vaultIDs
        return ids.flatMap { coreFiles($0) }
    }

    /// Every vault this phone can answer from, with its model index.
    static func installedVaults() -> [LearningCorpus.VaultTarget] {
        VaultRegistry.shared.allManifests.map { manifest in
            LearningCorpus.VaultTarget(id: manifest.id,
                                       modelIndex: VaultModelIndex(store: VaultRegistry.shared.store(for: manifest)))
        }
    }
}
