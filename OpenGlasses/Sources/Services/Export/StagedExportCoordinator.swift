import Foundation

/// One staged export on disk. Holding a lease is what keeps the file; releasing it is what removes
/// the session directory, so no path can hand the wearer a file without also taking on the
/// obligation to delete it.
struct StagedExportLease: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let fileURL: URL
    /// Name offered to the share UI. Never becomes a filename.
    let displayName: String

    var sessionDirectory: URL { fileURL.deletingLastPathComponent() }
}

/// The lease owner every non-clinical export family shares.
///
/// `MedicalExportLeaseCoordinator` and `DiagnosticExportCoordinator` each grew their own copy of
/// this lifecycle because each also carries policy the other does not — a clinical audit trail on
/// one, a single format and no compliance revoke on the other. The third, fourth and fifth export
/// families (agent archive, safety report, field session record) carry no such policy at all, so
/// they share one coordinator rather than adding three more near-identical siblings. The
/// *mechanism* under all of them is the same object either way: `ProtectedExportFileStore`.
///
/// What a lease buys, and what none of these exports had before:
/// - the session directory is protected and backup-excluded **before** the first byte is written;
/// - a write failure, an attribute failure or a cancelled share removes the whole session;
/// - a crash leaves a session the next launch's `scavenge()` collects once its TTL passes;
/// - backgrounding drops everything not held by an onscreen share.
@MainActor
final class StagedExportCoordinator {

    /// How a share ended. All three release: a cancelled share leaves the file on disk just as
    /// surely as a completed one.
    enum ShareOutcome: String {
        case completed
        case cancelled
        case failed
    }

    /// The wearer's portable archive of agent documents, memories and conversations.
    static let agentArchive = StagedExportCoordinator(
        channel: .agentExport, rootDirectoryName: "AgentExports")

    /// HECA safety-assessment PDFs.
    static let safetyReport = StagedExportCoordinator(
        channel: .safetyExport, rootDirectoryName: "SafetyExports")

    /// Field Assist audit JSON and work-order PDFs. These are *derived* artifacts: the durable
    /// record is the session's own `session.json` + `log.jsonl`, which a re-export rebuilds them
    /// from at any time, so binding the shareable copy to a lease loses nothing the wearer owns.
    static let fieldSession = StagedExportCoordinator(
        channel: .fieldSessionExport, rootDirectoryName: "FieldSessionExports")

    private let channel: PrivacyLog.TransferChannel
    private let store: ProtectedExportFileStore
    private let clock: () -> Date
    private let ttl: TimeInterval
    private var leases: [UUID: StagedExportLease] = [:]
    /// Leases handed to an onscreen share controller. Backgrounding spares these and only these.
    private var sharing: Set<UUID> = []

    init(channel: PrivacyLog.TransferChannel,
         rootDirectoryName: String,
         store: ProtectedExportFileStore? = nil,
         clock: @escaping () -> Date = Date.init,
         ttl: TimeInterval = ProtectedExportFileStore.completedSessionTTL) {
        self.channel = channel
        self.store = store ?? ProtectedExportFileStore(rootDirectoryName: rootDirectoryName)
        self.clock = clock
        self.ttl = ttl
    }

    var activeLeaseCount: Int { leases.count }

    var root: URL { store.root }

    // MARK: - Creation

    /// Create a protected session and hand its file to `write`, which must produce the content at
    /// the URL it is given. `write` may also stage intermediate files inside the session directory
    /// — `stagingDirectory(for:)` names it — because that directory is already protected and
    /// backup-excluded, and is removed whole on any failure.
    func makeLease(fileExtension: String,
                   displayName: String,
                   fallbackName: String,
                   write: (URL) throws -> Void) throws -> StagedExportLease {
        let now = clock()
        let session = try store.createSession(fileExtension: fileExtension, now: now, write: write)
        let lease = StagedExportLease(
            id: session.id,
            createdAt: session.createdAt,
            fileURL: session.fileURL,
            displayName: ProtectedExportFileStore.sanitizedDisplayName(displayName,
                                                                      fallback: fallbackName)
        )
        leases[lease.id] = lease
        // The `.exported` event itself belongs to the caller, which is the only thing that knows
        // how much of which store went in. Everything from here on is lifecycle.
        return lease
    }

    /// Convenience for the formats that produce their bytes up front. Written atomically.
    func makeLease(data: Data,
                   fileExtension: String,
                   displayName: String,
                   fallbackName: String) throws -> StagedExportLease {
        try makeLease(fileExtension: fileExtension, displayName: displayName,
                      fallbackName: fallbackName) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    /// The protected directory a multi-file export may stage into while `write` runs. It lives
    /// inside the session, so it inherits the session's protection and disappears with it.
    static func stagingDirectory(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
    }

    // MARK: - Share lifecycle

    func beginShare(_ lease: StagedExportLease) {
        guard leases[lease.id] != nil else { return }
        sharing.insert(lease.id)
        PrivacyLog.transfer(channel, .shareStarted)
    }

    /// Release after the share provider finishes, however it finished.
    func finishShare(_ lease: StagedExportLease, outcome: ShareOutcome) {
        guard leases[lease.id] != nil else { return }
        PrivacyLog.transfer(channel, .shareEnded, operation: PrivacyToken(outcome.rawValue))
        release(lease)
    }

    /// Remove a lease and its file. Idempotent, so concurrent completion paths are harmless.
    func release(_ lease: StagedExportLease) {
        sharing.remove(lease.id)
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        store.release(id: lease.id, directory: lease.sessionDirectory)
        PrivacyLog.transfer(channel, .released)
    }

    // MARK: - Cleanup

    /// Launch sweep of sessions a crash abandoned. Returns how many went, so the retention
    /// receipt can count them rather than reporting a sweep it cannot quantify.
    @discardableResult
    func scavenge() -> Int {
        let removed = store.scavenge(now: clock(), ttl: ttl)
        if removed > 0 {
            PrivacyLog.transfer(channel, .scavenged, count: removed)
        }
        return removed
    }

    /// On backgrounding, drop everything not held by an onscreen share.
    func handleBackground() {
        let abandoned = leases.values.filter { !sharing.contains($0.id) }
        guard !abandoned.isEmpty else { return }
        abandoned.forEach { release($0) }
    }

    /// Remove every session under this family's root, active leases included. Used by the
    /// coordinated subject erasure, where "when the TTL expires" is not an acceptable answer.
    @discardableResult
    func revokeAll() -> Int {
        leases.removeAll()
        sharing.removeAll()
        let removed = store.revokeAll()
        if removed > 0 {
            PrivacyLog.transfer(channel, .released, count: removed)
        }
        return removed
    }

    /// The three families, in one place so a caller that needs all of them cannot miss one.
    static var allFamilies: [StagedExportCoordinator] { [agentArchive, safetyReport, fieldSession] }

    /// Sweep every staged-export family. Called at launch and on backgrounding.
    @discardableResult
    static func scavengeAll() -> Int {
        allFamilies.reduce(0) { $0 + $1.scavenge() }
    }

    static func handleBackgroundAll() {
        for coordinator in allFamilies { coordinator.handleBackground() }
    }
}
