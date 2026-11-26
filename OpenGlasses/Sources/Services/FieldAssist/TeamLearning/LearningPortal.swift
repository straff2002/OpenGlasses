import Foundation
import CryptoKit

// Plan NG P1 — a team learning filed on the job reaches the company's administrator in the portal,
// and the administrator's decision comes back to the author's job. The contract is
// `Contracts/team-learning.md` §12; the wire shapes, checks and route rule are the shared core's
// (`SeatLearning.swift`, compiled into the app), so the phone sends exactly what the portal holds it to.
//
// The route out is the seat channel (`DeviceSeatService.learningExchange`): signed by the phone's own
// seat key, to the origin of the licence's signed `profile` claim. Nothing here picks a host.

/// Which route this phone's company takes for team learnings (team-learning §12.4).
enum TeamLearningRoute {
    /// Office binding first, then the portal (company vaults, switch not off), then a reviewer's
    /// phone. A revoked enrolment binds nothing.
    nonisolated static func choose(record: OrgEnrolmentRecord?, profile: ConfigProfile?,
                                   portalSwitchedOn: Bool) -> SeatLearningRoute {
        let enrolled = record != nil && record?.revoked != true
        return SeatLearningRoute.choose(officeBinding: enrolled && record?.source == .office,
                                        portalCompanyVaults: enrolled && profile?.companyVaults != nil,
                                        portalSwitchedOn: portalSwitchedOn)
    }

    @MainActor static func current() -> SeatLearningRoute {
        choose(record: OrgProfileManager.shared.record, profile: OrgProfileManager.shared.profile,
               portalSwitchedOn: Config.organizationTeamLearningsInPortal)
    }
}

/// How the author hears where a candidate stands — the job's status line. On any route but the
/// portal it is the status's own words, exactly as before.
enum TeamLearningStatusLine {
    static func spoken(_ candidate: LearningCandidate, route: SeatLearningRoute) -> String {
        guard route == .portal, candidate.isLocal else { return candidate.status.spoken }
        let refusal = candidate.portalRefusal.flatMap(SeatLearningRefusal.init(rawValue:))
        switch candidate.status {
        case .filed:
            if let refusal { return "not sent yet: " + words(refusal) }
            return "filed, waiting to go to your company's administrator"
        case .sent, .received:
            let line = "sent to your company's administrator, awaiting review"
            return refusal.map { line + "; your latest change isn't sent yet: " + words($0) } ?? line
        case .approved: return "approved by your company's administrator"
        case .merged: return "approved as the same as one your company already has"
        case .notTakenUp:
            let reason = (candidate.reviewReason ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            return reason.isEmpty ? "not taken up" : "not taken up: \(reason)"
        case .withdrawn: return candidate.status.spoken
        }
    }

    /// What a refusal means to the technician. It stays queued and goes when it can.
    static func words(_ refusal: SeatLearningRefusal) -> String {
        switch refusal {
        case .badNonce: return "the licence service asked for it again; it will be sent again"
        case .badRequest, .tooLarge: return "the licence service couldn't read it; it will be sent again with the next update"
        case .freed: return "this phone's seat on your company's licence was freed; ask your administrator"
        case .licenceLapsed: return "your company's licence has run out"
        case .unknownProfile, .notSeatChecked: return "the licence service doesn't know this phone's company"
        case .routeOff: return "your company doesn't review team learnings in the portal"
        case .notIncluded: return "your company's licence doesn't include team learnings"
        }
    }
}

/// Queues candidates for the portal, sends them, and applies the administrator's decisions.
///
/// - **Owed.** A candidate this phone filed is owed to the portal while its revision is above the
///   highest the portal answered `received` for. A withdrawal is owed only once the portal has an
///   earlier revision: a finding taken back before it ever left goes nowhere.
/// - **Queued by id.** The queue holds the candidate's id and revision, never its words; the send
///   reads the candidate as it then stands, so a newer revision supersedes an older one queued.
/// - **`sent` on `received`.** Nothing else moves a candidate to `sent`.
/// - **Never counted as failing.** No signal, no seat, a lapsed licence or a refusal keep it queued
///   (`SyncOutcome.waiting`) for as long as it takes; a refusal is named on the job.
/// - **Gates.** HIPAA mode, a route other than the portal, and a licence without team learnings
///   (or lapsed) send nothing and fetch nothing. What was published stays: that is the set's
///   (`CompanyExperienceStore`), which nothing here touches.
@MainActor
final class LearningPortalOutbox {

    static let shared = LearningPortalOutbox()

    let candidates: LearningCandidateStore

    var route: () -> SeatLearningRoute = { TeamLearningRoute.current() }
    var hipaaMode: () -> Bool = { Config.hipaaMode }
    var capability: () -> FieldAssistCapabilityCheck = { FieldAssistEntitlement.shared.check(.teamLearnings) }
    /// One seat action. The request closure gets the lease, seat id and profile in force.
    var exchange: @MainActor (SeatLearningWire.Action, (String, String, String) -> Data?) async -> DeviceSeatService.LearningExchange = {
        action, request in await DeviceSeatService.shared.learningExchange(action, request: request)
    }
    /// Writes a candidate's new status onto the job it was filed on.
    var recordStatus: (LearningCandidate) -> Void = { candidate in
        let inUse = candidate.entryID.map { CompanyExperienceStore.shared.entry(id: $0) != nil } ?? false
        FieldSessionService.shared.recordTeamLearning(.teamLearningStatus, reference: candidate.reference(inUse: inUse),
                                                      sessionId: candidate.sessionId)
    }

    init(candidates: LearningCandidateStore? = nil) {
        self.candidates = candidates ?? .shared
    }

    // MARK: - Gates

    static let hipaaReason = "Team learnings are unavailable while HIPAA mode is on: nothing was sent."
    static let noSeatReason = "waiting for this phone's seat on the company's licence"
    static let unreachableReason = "the licence service is out of reach"

    /// Why nothing may go to the portal now, or nil when it may.
    func sendingRefusal() -> String? {
        if hipaaMode() { return Self.hipaaReason }
        guard route() == .portal else { return "this company doesn't review team learnings in the portal" }
        switch capability() {
        case .granted: return nil
        case .notIncluded: return FieldAssistPaywallCopy.teamLearningsNotIncluded
        case .denied(.expired(_)): return FieldAssistPaywallCopy.teamLearningsLapsed
        case .denied(.unverifiableLicense): return FieldAssistPaywallCopy.unverifiable
        case .denied(.seatUnavailable(let hold)): return hold.message
        case .denied(.noEvidence): return FieldAssistPaywallCopy.teamLearningsLocked
        }
    }

    nonisolated static func isOwed(_ candidate: LearningCandidate) -> Bool {
        guard candidate.isLocal, candidate.origin == .spoken else { return false }
        let received = candidate.portalReceivedRevision ?? 0
        guard candidate.revision > received else { return false }
        return !candidate.withdrawn || candidate.portalReceivedRevision != nil
    }

    // MARK: - Queueing

    /// Queue `candidate` for the portal, replacing any op for it still pending. Nothing under HIPAA
    /// mode, off the portal route, or when nothing is owed. True when an op was queued.
    @discardableResult
    func enqueue(_ candidate: LearningCandidate, in queue: OfflineQueue) -> Bool {
        guard !hipaaMode(), route() == .portal, Self.isOwed(candidate) else { return false }
        for waiting in queue.all(limit: 500)
        where waiting.kind == .teamLearningPortal && waiting.state == .pending
            && waiting.payloadJSON["candidateID"] as? String == candidate.id {
            queue.delete(id: waiting.id)
        }
        queue.enqueue(.make(portalCandidate: candidate))
        return true
    }

    /// Queue every candidate still owed that has no op pending: what was filed before the company
    /// was on the portal, or before this build. Called after a foreground. Returns how many.
    @discardableResult
    func enqueueOwed(in queue: OfflineQueue) -> Int {
        guard !hipaaMode(), route() == .portal else { return 0 }
        let pending = Set(queue.all(limit: 500).filter { $0.kind == .teamLearningPortal && $0.state == .pending }
            .compactMap { $0.payloadJSON["candidateID"] as? String })
        var queued = 0
        for candidate in candidates.candidates where Self.isOwed(candidate) && !pending.contains(candidate.id) {
            queue.enqueue(.make(portalCandidate: candidate))
            queued += 1
        }
        return queued
    }

    // MARK: - Sending

    /// Deliver one queued candidate. `.done` once the portal has it (or it is no longer owed);
    /// `.waiting` for everything that may yet change; `.permanent` only when the route changed or
    /// the candidate cannot be put in the contract's form at all.
    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard let id = op.payloadJSON["candidateID"] as? String else {
            return .permanent(reason: "not a team-learning candidate")
        }
        guard let candidate = candidates.candidate(id: id), Self.isOwed(candidate) else { return .done }
        if hipaaMode() { return .waiting(reason: Self.hipaaReason) }
        guard route() == .portal else {
            return .permanent(reason: "this company no longer reviews team learnings in the portal; the team learning stays on this phone")
        }
        if let refusal = sendingRefusal() { return .waiting(reason: refusal) }

        var problem: SeatLearningProblem?
        var sentUnder: (seatID: String, profileId: String)?
        let outcome = await exchange(.learningCandidate) { lease, seatID, profileId in
            let request = SeatLearningCandidateRequest(lease: lease,
                                                       candidate: Self.wire(candidate, profileId: profileId, seatID: seatID))
            do {
                let fitted = try Self.fitted(request)
                sentUnder = (seatID, profileId)
                return try SeatLearningWire.encoder().encode(fitted)
            } catch {
                problem = error as? SeatLearningProblem ?? SeatLearningProblem(.tooLarge, "request")
                return nil
            }
        }
        if let problem {
            return .permanent(reason: "the team learning can't be put in the portal's form (\(problem.description))")
        }
        switch outcome {
        case .noSeat: return .waiting(reason: Self.noSeatReason)
        case .unreachable: return .waiting(reason: Self.unreachableReason)
        case .reply(let data):
            guard let reply = try? SeatLearningWire.decoder().decode(SeatLearningCandidateReply.self, from: data),
                  let sentUnder else { return .waiting(reason: "the licence service's answer couldn't be read") }
            if let refusal = reply.refusal {
                if refusal != .badNonce { noteRefusal(id: id, refusal) }
                return .waiting(reason: "the licence service refused it (\(refusal.rawValue))")
            }
            guard let status = reply.status, status.candidateID == id, status.revision >= candidate.revision,
                  apply(status, profileId: sentUnder.profileId, seatID: sentUnder.seatID, receivedRevision: candidate.revision)
            else { return .waiting(reason: "the licence service's answer didn't name this team learning") }
            return .done
        }
    }

    /// The candidate in the contract's form (§12.1), under the seat in force.
    nonisolated static func wire(_ c: LearningCandidate, profileId: String, seatID: String) -> SeatLearningCandidate {
        func short(_ value: String?) -> String? {
            guard let value else { return nil }
            let plain = String(String.UnicodeScalarView(value.unicodeScalars.map { SeatLearningCheck.isRefused($0) ? " " : $0 }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = String(String.UnicodeScalarView(plain.unicodeScalars.prefix(SeatLearningCheck.shortTextLimit)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cut.isEmpty ? nil : cut
        }
        func names(_ list: [String]) -> [String] {
            list.compactMap { name -> String? in
                let plain = String(String.UnicodeScalarView(name.unicodeScalars.map { SeatLearningCheck.isRefused($0) ? " " : $0 }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cut = String(String.UnicodeScalarView(plain.unicodeScalars.prefix(SeatLearningCheck.evidenceNameLimit)))
                return cut.isEmpty ? nil : cut
            }.prefix(SeatLearningCheck.evidenceNamesLimit).map { $0 }
        }
        return SeatLearningCandidate(
            candidateID: c.id, revision: c.revision, withdrawn: c.withdrawn, profileId: profileId, seatID: seatID,
            jobSessionID: jobSessionID(profileId: profileId, sessionId: c.sessionId),
            jobNumber: short(c.jobReference), taskID: short(c.taskId),
            createdAt: Int64(c.createdAt.timeIntervalSince1970.rounded(.down)), author: c.author, vaultID: c.vaultId,
            modelToken: short(c.modelToken), spokenModel: c.spokenModel.flatMap { $0.isEmpty ? nil : $0 },
            finding: c.withdrawn ? "" : c.finding,
            symptom: c.withdrawn ? nil : c.symptom.flatMap { $0.isEmpty ? nil : $0 },
            fix: c.withdrawn ? nil : c.fix.flatMap { $0.isEmpty ? nil : $0 },
            evidence: SeatLearningEvidence(pagesVerified: names(c.evidence.pagesVerified),
                                           citationsOpened: names(c.evidence.citationsOpened),
                                           readings: max(0, c.evidence.readings), photos: max(0, c.evidence.photos)),
            redactions: Array(c.redactions.filter(SeatLearningCheck.isSafeIdentifier).prefix(SeatLearningCheck.redactionsLimit)))
    }

    /// A request that passes §12.1: page and citation names are dropped, last first, until it fits
    /// 32 KiB (their counts are not the evidence; the names are a convenience). Anything else that
    /// fails is thrown.
    nonisolated static func fitted(_ request: SeatLearningCandidateRequest) throws -> SeatLearningCandidateRequest {
        var current = request
        while true {
            do {
                try SeatLearningCheck.check(current)
                return current
            } catch let problem as SeatLearningProblem where problem.reason == .tooLarge {
                var candidate = current.candidate
                if !candidate.evidence.citationsOpened.isEmpty { candidate.evidence.citationsOpened.removeLast() }
                else if !candidate.evidence.pagesVerified.isEmpty { candidate.evidence.pagesVerified.removeLast() }
                else { throw problem }
                current = SeatLearningCandidateRequest(lease: current.lease, candidate: candidate)
            }
        }
    }

    /// The join key the portal gets for the job, never its id (decision 3; contract §12.1).
    nonisolated static func jobSessionID(profileId: String, sessionId: String) -> String {
        let digest = SHA256.hash(data: SeatLearningWire.jobSessionHashInput(profileId: profileId, sessionId: sessionId))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    private func noteRefusal(id: String, _ refusal: SeatLearningRefusal) {
        guard var candidate = candidates.candidate(id: id), candidate.portalRefusal != refusal.rawValue else { return }
        candidate.portalRefusal = refusal.rawValue
        candidates.update(candidate)
        recordStatus(candidate)
    }

    // MARK: - Hearing back

    /// After a foreground: when a candidate this phone filed is `sent` and not yet decided, fetch the
    /// seat's statuses page by page and apply each. Returns how many changed a candidate.
    @discardableResult
    func refreshStatuses() async -> Int {
        guard sendingRefusal() == nil,
              candidates.candidates.contains(where: { $0.isLocal && $0.status == .sent }) else { return 0 }
        var after: String?
        var applied = 0
        for _ in 0..<SeatLearningWire.maximumPagesPerFetch {
            var asked: (seatID: String, profileId: String)?
            let cursor = after
            let outcome = await exchange(.learningStatus) { lease, seatID, profileId in
                asked = (seatID, profileId)
                return try? SeatLearningWire.encoder().encode(SeatLearningStatusRequest(lease: lease, after: cursor))
            }
            guard case .reply(let data) = outcome, let asked,
                  let reply = try? SeatLearningWire.decoder().decode(SeatLearningStatusReply.self, from: data),
                  reply.refusal == nil else { break }
            for status in reply.statuses ?? [] where apply(status, profileId: asked.profileId, seatID: asked.seatID) {
                applied += 1
            }
            // A page must move forward, or the fetch stops: a service that answers the same cursor
            // again cannot keep the phone asking.
            guard let next = reply.next, after.map({ next > $0 }) ?? true else { break }
            after = next
        }
        return applied
    }

    /// Apply one status, if it is this seat's, passes §12.1, and is about a candidate this phone
    /// filed and has not withdrawn. `received` moves `filed` to `sent`; a decision is final and is
    /// never replaced by a later answer. `receivedRevision` is the revision a send just carried.
    /// True when the candidate changed.
    @discardableResult
    func apply(_ status: SeatLearningStatus, profileId: String, seatID: String, receivedRevision: Int? = nil) -> Bool {
        guard (try? SeatLearningCheck.check(status)) != nil, status.profileId == profileId, status.seatID == seatID,
              var candidate = candidates.candidate(id: status.candidateID), candidate.isLocal else { return false }
        let before = candidate
        let received = max(candidate.portalReceivedRevision ?? 0, min(status.revision, candidate.revision),
                           receivedRevision ?? 0)
        candidate.portalReceivedRevision = received
        if received >= candidate.revision { candidate.portalRefusal = nil }
        let decided: Set<LearningCandidate.Status> = [.approved, .merged, .notTakenUp, .withdrawn]
        if !decided.contains(candidate.status) {
            switch status.status {
            case .received:
                if candidate.status == .filed { candidate.status = .sent }
            case .approved:
                candidate.status = .approved
                candidate.entryID = status.entryID
            case .merged:
                candidate.status = .merged
                candidate.entryID = status.entryID
            case .notTakenUp:
                candidate.status = .notTakenUp
                candidate.reviewReason = status.reason
            }
        }
        guard candidate != before else { return false }
        candidates.update(candidate)
        if candidate.status != before.status || candidate.portalRefusal != before.portalRefusal { recordStatus(candidate) }
        return true
    }
}

/// The queue's stage for portal candidates (Plan NG): everything else goes on to the sinks that were
/// there before.
@MainActor
final class LearningPortalSink: SyncSink {
    private let fallback: SyncSink
    private let outbox: @MainActor () -> LearningPortalOutbox

    init(fallback: SyncSink, outbox: @escaping @MainActor () -> LearningPortalOutbox = { LearningPortalOutbox.shared }) {
        self.fallback = fallback
        self.outbox = outbox
    }

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard op.kind == .teamLearningPortal else { return await fallback.deliver(op) }
        return await outbox().deliver(op)
    }

    func deliveryExhausted(_ op: QueuedOp) {
        guard op.kind != .teamLearningPortal else { return }
        fallback.deliveryExhausted(op)
    }
}
