import Foundation

/// The single owner of clinical export leases. Every path that creates a share file goes through
/// here, so there is exactly one place that decides when clinical bytes stop existing.
@MainActor
final class MedicalExportLeaseCoordinator {
    /// How a share ended. All three outcomes release — a cancelled share leaves clinical data on
    /// disk just as surely as a completed one.
    enum ShareOutcome: String {
        case completed
        case cancelled
        case failed
    }

    /// Content-free record of a lifecycle step: what happened, in what format, to how many
    /// sessions. No path, no filename, no clinical value.
    struct AuditEvent: Equatable {
        let action: String
        let format: ExportFormat?
        let count: Int

        var detail: String {
            var parts = ["count=\(count)"]
            if let format { parts.append("format=\(format.auditToken)") }
            return parts.joined(separator: " ")
        }
    }

    /// Where audit events go. Wired to the compliance audit log in the app; nil in tests until a
    /// test wants to inspect what was recorded.
    var auditSink: ((AuditEvent) -> Void)?

    private let store: MedicalExportFileStore
    private let clock: () -> Date
    private let ttl: TimeInterval
    /// Leases still outstanding, by id.
    private var leases: [UUID: MedicalExportLease] = [:]
    /// Leases handed to an onscreen share controller. Backgrounding spares these and only these.
    private var sharing: Set<UUID> = []

    init(store: MedicalExportFileStore = MedicalExportFileStore(),
         clock: @escaping () -> Date = Date.init,
         ttl: TimeInterval = MedicalExportFileStore.completedSessionTTL) {
        self.store = store
        self.clock = clock
        self.ttl = ttl
    }

    var activeLeaseCount: Int { leases.count }

    // MARK: - Creation

    func makeLease(format: ExportFormat,
                   displayName: String,
                   write: (URL) throws -> Void) throws -> MedicalExportLease {
        let lease = try store.createLease(format: format, displayName: displayName,
                                          now: clock(), write: write)
        leases[lease.id] = lease
        emit("EXPORT_LEASE_CREATED", format: format, count: 1)
        return lease
    }

    func makeLease(data: Data, format: ExportFormat, displayName: String) throws -> MedicalExportLease {
        try makeLease(format: format, displayName: displayName) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Share lifecycle

    /// Mark a lease as owned by an onscreen share controller.
    func beginShare(_ lease: MedicalExportLease) {
        guard leases[lease.id] != nil else { return }
        sharing.insert(lease.id)
        emit("EXPORT_SHARE_STARTED", format: lease.format, count: 1)
    }

    /// Release after the share provider finishes, however it finished.
    func finishShare(_ lease: MedicalExportLease, outcome: ShareOutcome) {
        guard leases[lease.id] != nil else { return }  // already released — nothing to record twice
        emit("EXPORT_SHARE_\(outcome.rawValue.uppercased())", format: lease.format, count: 1)
        release(lease)
    }

    /// Remove a lease and its files. Idempotent, so concurrent completion paths are harmless.
    func release(_ lease: MedicalExportLease) {
        sharing.remove(lease.id)
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        store.release(lease)
    }

    // MARK: - Cleanup

    /// Launch and protected-data-available sweep of abandoned sessions.
    func scavenge() {
        let removed = store.scavenge(now: clock(), ttl: ttl)
        if removed > 0 { emit("EXPORT_SCAVENGED", format: nil, count: removed) }
    }

    /// On backgrounding, drop everything not held by an onscreen share.
    func handleBackground() {
        let abandoned = leases.values.filter { !sharing.contains($0.id) }
        guard !abandoned.isEmpty else { return }
        abandoned.forEach { release($0) }
        emit("EXPORT_BACKGROUND_RELEASE", format: nil, count: abandoned.count)
    }

    /// Revoke everything at once — medical data reset, or compliance mode being switched on.
    func revokeAll() {
        let held = leases.count
        leases.removeAll()
        sharing.removeAll()
        let removed = store.revokeAll()
        if held > 0 || removed > 0 { emit("EXPORT_REVOKED", format: nil, count: max(held, removed)) }
    }

    private func emit(_ action: String, format: ExportFormat?, count: Int) {
        auditSink?(AuditEvent(action: action, format: format, count: count))
    }
}
