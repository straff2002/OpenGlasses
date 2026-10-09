import Foundation

/// Makes the team-learning bundles that leave this phone (Plan FP P3), stages them for the
/// delivery channels and the offline queue, and marks candidates `sent` once a bundle carrying
/// them has really left.
///
/// - **Candidates** (field → reviewer): every candidate this phone filed that the reviewer has not
///   yet answered — `filed`, `sent` and `withdrawn`, so a withdrawal travels too. A bundle is
///   cumulative rather than "what changed since last time": the reviewer's merge is idempotent on
///   `candidateID` + `revision`, and a bundle that is lost costs nothing once the next one goes.
/// - **Decisions** (reviewer → field): every entry this device holds (retracted ones as
///   `retracted[]`, with tombstones for entries it never held), and a status for each candidate
///   that arrived here in a bundle — `received` until it is decided, then the decision. Cumulative
///   for the same reason, which is also what makes refusing an older decisions bundle cost nothing.
/// - **A vault export's learnings**: the entries scoped to that vault, as a decisions bundle.
///
/// **Not signed, and saying so is the point.** A crew has no key; the vendor's key is off-repo and
/// the signed route is the office contract. A bundle from here is read on the other end as
/// untrusted input and accepted entry by entry.
///
/// **`sent` means it left.** Composing a bundle, staging it, or handing it to a composer that was
/// then cancelled changes nothing; a confirmed send (`DeliveryOutcome.sent`) or the endpoint
/// accepting the queued op does. Gates: HIPAA mode — no bundle out; composing asks the
/// `.teamLearnings` capability.
@MainActor
final class LearningBundleOutbox {

    static let shared = LearningBundleOutbox()

    let candidates: LearningCandidateStore
    let entries: LearningEntryStore

    var capability: () -> FieldAssistCapabilityCheck = { FieldAssistEntitlement.shared.check(.teamLearnings) }
    var hipaaMode: () -> Bool = { Config.hipaaMode }
    /// The organisation's name as the profile gives it, for a person reading the file. Not authority.
    var organisationLabel: () -> String? = {
        let name = Config.organizationDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : TechnicianName.clean(name)
    }
    /// Where a bundle's file is staged for a composer or the share sheet.
    var exports: StagedExportCoordinator = .fieldSession
    /// Writes a candidate's new status onto the job it was filed on.
    var recordStatus: (LearningCandidate) -> Void = { candidate in
        FieldSessionService.shared.recordTeamLearning(.teamLearningStatus, reference: candidate.reference,
                                                      sessionId: candidate.sessionId)
    }
    var clock: () -> Date = Date.init

    init(candidates: LearningCandidateStore? = nil, entries: LearningEntryStore? = nil) {
        self.candidates = candidates ?? .shared
        self.entries = entries ?? .shared
    }

    enum Refusal: Error, Equatable {
        case hipaa
        case notEntitled(String)
        case nothingToSend
        case writeFailed
        case tooLarge

        var message: String {
            switch self {
            case .hipaa: return "Team learnings are unavailable while HIPAA mode is on: nothing was sent."
            case .notEntitled(let reason): return reason
            case .nothingToSend: return "There are no team learnings on this phone waiting to go."
            case .writeFailed: return "The team-learning file couldn't be prepared."
            case .tooLarge:
                return "The team learnings on this phone are too many for one file. Retract or supersede old ones first."
            }
        }
    }

    // MARK: - Composing

    /// Candidates for the reviewer.
    func composeCandidates() -> Result<LearningBundle, Refusal> {
        if let refusal = gate() { return .failure(refusal) }
        let outgoing = candidates.candidates
            .filter { $0.isLocal && [.filed, .sent, .withdrawn].contains($0.status) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard !outgoing.isEmpty else { return .failure(.nothingToSend) }
        return sized(LearningBundle(direction: .candidates, organisationLabel: organisationLabel(),
                                    issuedAt: now(), candidates: outgoing.map(LearningBundle.Candidate.init)))
    }

    /// The reviewer's decisions and every entry this device holds.
    func composeDecisions() -> Result<LearningBundle, Refusal> {
        if let refusal = gate() { return .failure(refusal) }
        let bundle = decisions(entries: entries.entries, tombstones: entries.bundleLedger.tombstones,
                               statuses: statuses())
        guard !bundle.isEmpty else { return .failure(.nothingToSend) }
        return sized(bundle)
    }

    /// A bundle the other end would refuse for its size is not made.
    private func sized(_ bundle: LearningBundle) -> Result<LearningBundle, Refusal> {
        bundle.encoded().count <= LearningBundle.maximumBytes ? .success(bundle) : .failure(.tooLarge)
    }

    /// The learnings a vault export carries: the entries scoped to it (live and retracted), as a
    /// decisions bundle. Nil when the gate refuses or there are none — the export goes without.
    func vaultExport(vaultId: String) -> LearningBundle? {
        guard gate() == nil else { return nil }
        let scoped = entries.entries.filter { $0.isScoped(to: vaultId) }
        let bundle = decisions(entries: scoped, tombstones: [], statuses: [])
        guard !bundle.isEmpty, case .success(let fits) = sized(bundle) else { return nil }
        return fits
    }

    private func decisions(entries held: [LearningEntry], tombstones: [LearningBundle.Retraction],
                           statuses: [LearningBundle.Status]) -> LearningBundle {
        let ordered = held.sorted { ($0.approvedAt, $0.id) < ($1.approvedAt, $1.id) }
        let retracted = ordered.compactMap(LearningBundle.Retraction.init) + tombstones
        return LearningBundle(direction: .decisions, organisationLabel: organisationLabel(), issuedAt: now(),
                              statuses: statuses, entries: ordered.map(LearningBundle.Entry.init),
                              retracted: retracted.sorted { $0.entryID < $1.entryID })
    }

    /// A status for every candidate that arrived here in a bundle: the decision once made,
    /// `received` until then. Candidates filed on this device are not sent back to it.
    private func statuses() -> [LearningBundle.Status] {
        candidates.candidates.filter { !$0.isLocal && !$0.withdrawn }.compactMap { candidate in
            let decision: LearningBundle.Decision
            switch candidate.status {
            case .approved: decision = .approved
            case .merged: decision = .merged
            case .notTakenUp: decision = .notTakenUp
            case .received, .filed, .sent: decision = .received
            case .withdrawn: return nil
            }
            guard decision != .approved && decision != .merged || candidate.entryID != nil else { return nil }
            return LearningBundle.Status(
                candidateID: candidate.id, revision: Int64(candidate.revision), status: decision,
                entryID: decision.isFinal && decision != .notTakenUp ? candidate.entryID : nil,
                reason: decision == .notTakenUp ? candidate.reviewReason.flatMap { $0.isEmpty ? nil : $0 } : nil,
                issuedAt: Int64(candidate.updatedAt.timeIntervalSince1970.rounded(.down)))
        }.sorted { $0.candidateID < $1.candidateID }
    }

    // MARK: - Staging for a channel

    /// The delivery request for a bundle on a channel: the one JSON file, named for the bundle,
    /// staged as a protected export that is removed when the share ends.
    func deliveryRequest(for bundle: LearningBundle, channel: DeliveryChannel,
                         recipients: [String]) -> Result<DeliveryRequest, Refusal> {
        if let refusal = gate() { return .failure(refusal) }
        guard let lease = try? exports.makeLease(data: bundle.encoded(), fileExtension: "json",
                                                 displayName: bundle.fileName, fallbackName: bundle.fileName)
        else { return .failure(.writeFailed) }
        let attachment = DeliveryRequest.Attachment(url: lease.fileURL, kind: .json, filename: bundle.fileName)
        return .success(DeliveryRequest.make(learningBundle: bundle, channel: channel, recipients: recipients,
                                             attachment: attachment))
    }

    /// The op for the offline queue, gated like everything else here.
    func queuedOp(for bundle: LearningBundle) -> Result<QueuedOp, Refusal> {
        if let refusal = gate() { return .failure(refusal) }
        return .success(QueuedOp.make(learningBundle: bundle))
    }

    // MARK: - It left

    /// A composer, share sheet or hand-off finished. Only a confirmed send moves anything.
    func completed(_ request: DeliveryRequest, outcome: DeliveryOutcome) {
        guard outcome.isSent, case .learningBundle(let bundle, _) = request.payload else { return }
        markSent(bundle)
    }

    /// The endpoint accepted a queued op. Anything that is not a candidates bundle is ignored.
    func delivered(_ op: QueuedOp) {
        guard op.kind == .teamLearning, case .success(let decoded) = LearningBundle.decode(op.payload) else { return }
        markSent(decoded.bundle)
    }

    /// Every candidate a bundle carried that is still `filed` becomes `sent`, and its job says so.
    /// A candidate already further on — or withdrawn — is left where it is.
    func markSent(_ bundle: LearningBundle) {
        guard bundle.direction == .candidates else { return }
        for wire in bundle.candidates {
            guard var candidate = candidates.candidate(id: wire.candidateID), candidate.isLocal,
                  candidate.status == .filed else { continue }
            candidate.status = .sent
            candidates.update(candidate)
            recordStatus(candidate)
        }
    }

    // MARK: - Parts

    private func gate() -> Refusal? {
        if hipaaMode() { return .hipaa }
        switch capability() {
        case .granted: return nil
        case .notIncluded: return .notEntitled(FieldAssistPaywallCopy.teamLearningsBundleNotIncluded)
        case .denied(.expired(_)): return .notEntitled(FieldAssistPaywallCopy.teamLearningsBundleLapsed)
        case .denied(.unverifiableLicense): return .notEntitled(FieldAssistPaywallCopy.unverifiable)
        case .denied(.noEvidence): return .notEntitled(FieldAssistPaywallCopy.teamLearningsBundleLocked)
        }
    }

    private func now() -> Int64 { Int64(clock().timeIntervalSince1970.rounded(.down)) }
}
