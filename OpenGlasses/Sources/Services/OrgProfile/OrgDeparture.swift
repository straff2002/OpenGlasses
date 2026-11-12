import Foundation

/// Losing the report route must not turn "stored locally" into "sent".
/// Real endpoint/Office sinks run first; their local fallback holds handover records.
@MainActor
final class UndeliveredHandoverSink: SyncSink {
    private let fallback: SyncSink
    private let ownedIDs: @MainActor () -> Set<String>

    init(fallback: SyncSink,
         ownedIDs: @escaping @MainActor () -> Set<String> = {
             Set(OrgDepartureService.loadStored()?.sessionIds ?? []).union(FieldSessionService.shared.lockedManagedRecordIDs)
         }) {
        self.fallback = fallback
        self.ownedIDs = ownedIDs
    }

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard !ownedIDs().contains(op.sessionId), op.payloadJSON["access_closure"] == nil else {
            return .waiting(reason: "waiting for an authorised report destination to accept the handover record")
        }
        return await fallback.deliver(op)
    }
}

/// Plan CT PR 4 — what a phone that has left the firm still owes it.
///
/// Kept apart from the enrolment record (`OrgProfileManager`'s), because a profile removed by the
/// device owner takes that record with it while the firm's records are still owed. Registered with
/// it as `SensitiveStore.orgEnrolment`.
struct OrgDeparture: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// A signed revocation, or this enrolment's id in the profile's revoked list.
        case revoked
        /// The device owner removed the profile — treated exactly as revocation.
        case removed
        /// The lease lapsed for the organisation's `eraseAfterLapseDays` without a renewal. The
        /// profile stays; a later renewal ends this departure (`cancelLapse`).
        case lapsed
    }

    let organizationName: String
    let enrolmentId: String
    var reason: Reason
    let startedAt: Date
    /// After this the firm's records are erased whether or not they reached it.
    let eraseBy: Date
    /// The session logs, from the managed period, that are the firm's.
    var sessionIds: [String]
    /// When the firm's records were erased. Nil while they are still owed.
    var settledAt: Date?
    /// Whether they reached the firm before they were erased: accepted by its endpoint. False means
    /// the window ran out first, and the erasure says so.
    var deliveredToFirm: Bool?
    /// Kept until cleanup succeeds, including across a crash during departure.
    var packId: String?
    /// Plan LR: the company vaults the enrolment installed, kept with the pack id until cleanup
    /// succeeds. Absent on every departure recorded before company vaults.
    var companyVaultIds: [String]?
    var contentErasedAt: Date?

    var isPending: Bool { settledAt == nil }
}

/// Plan CT PR 4 — leaving the firm: the organisation's content goes at once, and its records go to
/// the firm first, then are erased.
///
/// - **At once** (`eraseContent`): the vault the profile's pack installed, the jobs ahead, and the
///   staged exports. Nothing is owed to the firm for these; they are its own documents and work
///   orders.
/// - **Delivered, then erased** (`eraseRecords`): the session logs of the managed period and the
///   reports still waiting to be sent. Only the firm's endpoint delivers unattended, so they count as
///   delivered only once it has *accepted* every work record — an empty queue is not proof, because
///   with no endpoint the local sink marks records done without anything leaving the phone.
/// - **The window.** Undelivered records stay locked and are retried at launch and on every
///   foreground, and are erased regardless once `eraseBy` passes (`undeliveredEraseDays`, 30 by
///   default), with that recorded here.
/// - **Withdrawal closes the job.** Revocation/removal closes the firm's open job for
///   handover before delivery; an unrelated personal job does not hold its records hostage.
///
/// Every seam defaults to doing nothing: erasure is too consequential to be a default a test
/// inherits. `AppState` wires the production seams at launch.
@MainActor
final class OrgDepartureService: ObservableObject {

    struct Seams {
        var now: @MainActor () -> Date = { Date() }
        var load: @MainActor () -> OrgDeparture? = { nil }
        var save: @MainActor (OrgDeparture?) -> Void = { _ in }
        /// Session log ids from the managed period.
        var sessionIds: @MainActor (_ since: Date) -> [String] = { _ in [] }
        var activeJobId: @MainActor () -> String? = { nil }
        var closeJobs: @MainActor (_ ids: [String], _ reason: OrgDeparture.Reason) throws -> Void = { _, _ in }
        /// The firm's vault (by the profile's pack id), jobs ahead and staged exports.
        var eraseContent: @MainActor (_ packId: String?) async -> Void = { _ in }
        /// Plan LR: the company's own vaults, by id, with every manual in them.
        var eraseCompanyVaults: @MainActor (_ vaultIds: [String]) async -> Void = { _ in }
        var hasEndpoint: @MainActor () -> Bool = { false }
        var flushEndpoint: @MainActor () async -> Void = {}
        /// Work records for these sessions the endpoint has not yet accepted.
        var outstanding: @MainActor (_ sessionIds: [String]) -> Int = { _ in 0 }
        /// The session logs, the report queue and the delivery settings.
        var eraseRecords: @MainActor (_ sessionIds: [String]) -> Void = { _ in }
    }

    static let shared = OrgDepartureService()

    @Published private(set) var departure: OrgDeparture?
    var seams: Seams
    private var isSettling = false

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    func loadAtLaunch() {
        departure = seams.load()
    }

    /// The phone has left the firm. Erases the firm's content at once and starts the delivery of its
    /// records. Beginning again for the same enrolment changes nothing.
    func begin(_ reason: OrgDeparture.Reason, organizationName: String, enrolmentId: String,
               enrolledAt: Date, packId: String?, undeliveredEraseDays: Int?,
               companyVaultIds: [String] = []) async {
        if var current = departure, current.isPending, current.enrolmentId == enrolmentId {
            // An explicit withdrawal cannot inherit a prior offline lapse's grace or renewal.
            if current.reason == .lapsed, reason != .lapsed {
                current.reason = reason
                departure = current
                seams.save(current)
                await settle()
            }
            return
        }
        let now = seams.now()
        let requested = undeliveredEraseDays ?? ConfigProfile.defaultUndeliveredEraseDays
        let days = min(max(requested, ConfigProfile.erasureDaysRange.lowerBound),
                       ConfigProfile.erasureDaysRange.upperBound)
        let started = OrgDeparture(organizationName: organizationName, enrolmentId: enrolmentId,
                                   reason: reason, startedAt: now,
                                   eraseBy: now.addingTimeInterval(TimeInterval(days) * 86_400),
                                   sessionIds: seams.sessionIds(enrolledAt), packId: packId,
                                   companyVaultIds: companyVaultIds.isEmpty ? nil : companyVaultIds)
        departure = started
        seams.save(started)
        await settle()
    }

    /// Deliver what is owed, and erase it once it has been delivered or the window has passed.
    /// Called when the departure begins, at launch and on every foreground.
    func settle() async {
        guard !isSettling else { return }
        isSettling = true
        defer { isSettling = false }
        guard let pending = departure, pending.isPending else { return }
        do { try seams.closeJobs(pending.sessionIds, pending.reason) } catch { return }
        // Never erase or report a successful close if the closure did not end the firm's job.
        if let active = seams.activeJobId(), pending.sessionIds.contains(active) { return }
        if pending.contentErasedAt == nil {
            await seams.eraseContent(pending.packId)
            await seams.eraseCompanyVaults(pending.companyVaultIds ?? [])
            guard var current = departure, current.enrolmentId == pending.enrolmentId, current.isPending else { return }
            current.contentErasedAt = seams.now()
            departure = current
            seams.save(current)
        }
        var delivered = false
        if seams.hasEndpoint() {
            await seams.flushEndpoint()
            delivered = seams.outstanding(pending.sessionIds) == 0
        }
        let now = seams.now()
        guard delivered || now >= pending.eraseBy else { return }
        // The departure may have been replaced while the flush was out.
        guard var current = departure, current.enrolmentId == pending.enrolmentId, current.isPending else { return }
        seams.eraseRecords(current.sessionIds)
        current.settledAt = now
        current.deliveredToFirm = delivered
        departure = current
        seams.save(current)
    }

    /// What erasure cannot reach, said on the managed row rather than implied away (Plan CT PR 4).
    /// The erasure deletes files; it does not re-encrypt them (sealing, 4b, is deferred), so a
    /// backup taken before it is outside it too.
    nonisolated static let erasureLimits = "Erasing covers this app only. Photos saved to the camera roll, screenshots, reports already sent, and backups of this phone made before the erasure are outside it."

    /// The session logs from the managed period: the firm's record, and what a departure owes it.
    /// One rule for the departure and for the removal prompt that offers to send them first.
    nonisolated static func managedSessionIds(_ sessions: [FieldSession], since enrolledAt: Date) -> [String] {
        sessions.filter { $0.startedAt >= enrolledAt }.map { $0.id }
    }

    /// The managed period and retained-record ledger establish ownership after access ends.
    nonisolated static func ownsManagedRecord(id: String, startedAt: Date,
                                              enrolledAt: Date?, retainedIDs: Set<String>) -> Bool {
        retainedIDs.contains(id) || enrolledAt.map { startedAt >= $0 } == true
    }

    /// A renewal was heard after a lapse erasure: the phone is the firm's again, so the records a
    /// lapse departure still owes are no longer erased. A revocation or removal is never undone.
    func cancelLapse(enrolmentId: String) {
        guard let current = departure, current.isPending, current.reason == .lapsed,
              current.enrolmentId == enrolmentId else { return }
        departure = nil
        seams.save(nil)
    }

    // MARK: - Storage

    nonisolated static let storageKey = "orgDeparture"

    nonisolated static func loadStored() -> OrgDeparture? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? ProfileVerification.decoder.decode(OrgDeparture.self, from: data)
    }

    nonisolated static func saveStored(_ departure: OrgDeparture?) {
        guard let departure, let data = try? ProfileVerification.encoder.encode(departure) else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
