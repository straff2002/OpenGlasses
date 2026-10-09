import Foundation
import UIKit

/// Files, amends, withdraws and lists team-learning candidates (Plan FP P1) — the layer the
/// `team_learning` tool speaks through, and where the entitlement gate sits.
///
/// What it binds a candidate to is read off the active job at filing time and copied, not linked:
/// the session and its job number, the equipment identity in force (or the model the technician
/// named when none had been resolved), the task running — and that task's evidence, or the job's
/// when no task is running — as names and counts. Then the text rules run (`LearningCandidateText`:
/// normalise, redact, measure), the candidate is stored, and the job records that it exists.
///
/// **The gate is the capability, here and not in the tool.** `team_learning` checks that Field
/// Assist is on, the way its siblings do; whether this licence includes team learnings is asked
/// where `SessionExporter` and `VaultImporter` ask theirs, so no other caller can file around it.
/// Filing and amending are gated. Reading your own back and withdrawing are not: neither adds
/// anything, and a technician on a lapsed licence can still take back what they said.
@MainActor
final class LearningCandidateService {

    static let shared = LearningCandidateService()

    let store: LearningCandidateStore
    private let injectedSessions: FieldSessionService?
    private var sessions: FieldSessionService { injectedSessions ?? .shared }

    /// The licence's answer for team learnings. A test states its own.
    var capability: () -> FieldAssistCapabilityCheck = { FieldAssistEntitlement.shared.check(.teamLearnings) }

    /// The name a candidate is filed under. Nothing in the app holds a technician's display name
    /// yet — no setting, no licence field, no office binding carries one — so this is the device's
    /// name, which on iOS 16 and later is the generic model name ("iPhone") unless the app holds the
    /// user-assigned-device-name entitlement. A later phase takes it from a setting or the
    /// organisation's enrolment; the contract only needs 1–120 plain characters.
    var authorName: () -> String = { UIDevice.current.name }

    /// Called after a candidate is filed, amended or withdrawn — the hook that queues it for the
    /// organisation's endpoint, where one is configured (Plan FP P3). A withdrawal travels too.
    var onChange: ((LearningCandidate) -> Void)?

    var clock: () -> Date = Date.init

    /// Now, to the whole second: the contract carries Unix seconds, and the store's ISO-8601 dates
    /// would otherwise round-trip to a different value than the one filed.
    private func now() -> Date {
        Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
    }

    init(store: LearningCandidateStore? = nil, sessions: FieldSessionService? = nil) {
        self.store = store ?? .shared
        self.injectedSessions = sessions
    }

    /// Why a call did nothing, in the words the technician hears.
    enum Refusal: Error, Equatable {
        case noActiveJob
        case notEntitled(String)
        case text(LearningCandidateText.Refusal)
        case notFound(String)
        case alreadyWithdrawn
        case nothingToAmend

        var spoken: String {
            switch self {
            case .noActiveJob:
                return "Nothing was filed: there's no job open. Start the job first — a team learning is "
                    + "filed against the job and the machine it was worked out on."
            case .notEntitled(let reason): return reason
            case .text(let refusal): return refusal.spoken
            case .notFound(let handle):
                return handle.isEmpty
                    ? "There's no team learning on this phone to change."
                    : "I can't find one team learning matching \"\(handle)\". Say \"list my team learnings\" "
                        + "to hear their ids."
            case .alreadyWithdrawn: return "That team learning was already withdrawn."
            case .nothingToAmend:
                return "Nothing was changed: say the new finding, symptom or fix for that team learning."
            }
        }
    }

    // MARK: - The gate

    /// The capability's refusal, or nil when filing is allowed.
    func entitlementRefusal() -> Refusal? {
        switch capability() {
        case .granted: return nil
        case .notIncluded: return .notEntitled(FieldAssistPaywallCopy.teamLearningsNotIncluded)
        case .denied(.expired(_)): return .notEntitled(FieldAssistPaywallCopy.teamLearningsLapsed)
        case .denied(.unverifiableLicense): return .notEntitled(FieldAssistPaywallCopy.unverifiable)
        case .denied(.noEvidence): return .notEntitled(FieldAssistPaywallCopy.teamLearningsLocked)
        }
    }

    // MARK: - Note

    /// File a candidate against the active job.
    func note(finding: String?, symptom: String? = nil, fix: String? = nil,
              spokenModel: String? = nil) -> Result<LearningCandidate, Refusal> {
        if let refusal = entitlementRefusal() { return .failure(refusal) }
        guard let session = sessions.activeSession else { return .failure(.noActiveJob) }
        let cleaned: LearningCandidateText.Cleaned
        switch LearningCandidateText.clean(finding: finding, symptom: symptom, fix: fix) {
        case .failure(let refusal): return .failure(.text(refusal))
        case .success(let value): cleaned = value
        }

        let task = session.activeTask
        let equipment = session.equipment.map(LearningCandidate.Equipment.init)
        // The model as the technician said it, only when nothing was resolved — and through the
        // same rules as the text, because it is text they said.
        var spoken: String?
        if equipment == nil, let raw = spokenModel,
           case .success(let value) = LearningCandidateText.normalise(raw, field: .symptom),
           !value.isEmpty {
            spoken = String(String.UnicodeScalarView(value.unicodeScalars.prefix(LearningCandidateText.fieldLimit)))
        }
        let filedAt = now()
        let candidate = LearningCandidate(
            sessionId: session.id, jobReference: session.jobReference, taskId: task?.id,
            vaultId: session.vaultId, equipment: equipment, spokenModel: spoken,
            finding: cleaned.finding, symptom: cleaned.symptom, fix: cleaned.fix,
            evidence: LearningCandidate.Evidence(task?.evidence ?? session.jobEvidence),
            author: LearningCandidateText.author(authorName()),
            createdAt: filedAt, redactions: cleaned.redactions)
        store.add(candidate)
        sessions.recordTeamLearning(.teamLearningFiled, reference: candidate.reference,
                                    sessionId: candidate.sessionId, now: filedAt)
        onChange?(candidate)
        return .success(candidate)
    }

    // MARK: - Amend

    /// Change what a candidate says. Each field given replaces the one stored; a field left out
    /// is kept. The revision goes up and the redaction runs again over what is now stored.
    func amend(handle: String?, finding: String?, symptom: String?, fix: String?) -> Result<LearningCandidate, Refusal> {
        if let refusal = entitlementRefusal() { return .failure(refusal) }
        let candidate: LearningCandidate
        switch resolve(handle) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): candidate = found
        }
        guard !candidate.withdrawn else { return .failure(.alreadyWithdrawn) }
        let given = [finding, symptom, fix].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard given.contains(where: { !$0.isEmpty }) else { return .failure(.nothingToAmend) }

        func pick(_ new: String?, _ old: String?) -> String? {
            guard let new, !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return old }
            return new
        }
        let cleaned: LearningCandidateText.Cleaned
        switch LearningCandidateText.clean(finding: pick(finding, candidate.finding),
                                           symptom: pick(symptom, candidate.symptom),
                                           fix: pick(fix, candidate.fix)) {
        case .failure(let refusal): return .failure(.text(refusal))
        case .success(let value): cleaned = value
        }
        var updated = candidate
        updated.finding = cleaned.finding
        updated.symptom = cleaned.symptom
        updated.fix = cleaned.fix
        updated.redactions = cleaned.redactions
        updated.revision += 1
        updated.updatedAt = now()
        store.update(updated)
        sessions.recordTeamLearning(.teamLearningAmended, reference: updated.reference,
                                    sessionId: updated.sessionId, now: updated.updatedAt)
        onChange?(updated)
        return .success(updated)
    }

    // MARK: - Withdraw

    /// Take a candidate back. The record stays, with `withdrawn` set and its text emptied, exactly
    /// as the contract carries a withdrawal — so the job still shows that something was filed and
    /// that its author took it back.
    func withdraw(handle: String?) -> Result<LearningCandidate, Refusal> {
        let candidate: LearningCandidate
        switch resolve(handle) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): candidate = found
        }
        guard !candidate.withdrawn else { return .failure(.alreadyWithdrawn) }
        var updated = candidate
        updated.status = .withdrawn
        updated.finding = ""
        updated.symptom = nil
        updated.fix = nil
        updated.redactions = []
        updated.revision += 1
        updated.updatedAt = now()
        store.update(updated)
        sessions.recordTeamLearning(.teamLearningWithdrawn, reference: updated.reference,
                                    sessionId: updated.sessionId, now: updated.updatedAt)
        onChange?(updated)
        return .success(updated)
    }

    // MARK: - List

    /// The author's own candidates, newest first. Every candidate on this phone was filed on it,
    /// so this is the store — read back to the person who said them, and to nobody else's answer.
    func list(limit: Int = 10) -> [LearningCandidate] {
        Array(store.newestFirst.prefix(max(1, limit)))
    }

    // MARK: - Handles

    /// "the last one", an empty handle or nothing at all: the newest candidate not withdrawn.
    /// Anything else is an id or an unambiguous prefix of one.
    private func resolve(_ handle: String?) -> Result<LearningCandidate, Refusal> {
        let raw = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || Self.lastPhrases.contains(raw.lowercased()) {
            guard let last = store.newestFirst.first(where: { !$0.withdrawn }) else { return .failure(.notFound("")) }
            return .success(last)
        }
        guard let found = store.resolve(handle: raw) else { return .failure(.notFound(raw)) }
        return .success(found)
    }

    static let lastPhrases: Set<String> = ["last", "the last one", "last one", "latest", "the latest",
                                           "the last", "that one", "the one i just filed"]
}
