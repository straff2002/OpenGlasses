import Foundation

/// One diagnostics bundle on disk. Holding a lease is what keeps the file; releasing it is what
/// removes the session directory, so no path can hand the wearer a file without also taking on
/// the obligation to delete it.
struct DiagnosticExportLease: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let fileURL: URL
    /// Name offered to the share UI. Never becomes a filename.
    let displayName: String

    var sessionDirectory: URL { fileURL.deletingLastPathComponent() }
}

/// The single owner of diagnostics export leases.
///
/// The clinical export coordinator is the model here, and the *mechanism* is literally the same
/// object (`ProtectedExportFileStore`): protected session directory, complete file protection,
/// backup exclusion, release on any share outcome including cancellation, and a scavenge for
/// sessions a crash abandoned. What is not shared is the policy — a diagnostics bundle has one
/// format, no clinical audit trail, and no compliance revoke — so this stays a small sibling of
/// `MedicalExportLeaseCoordinator` rather than a generalisation of it.
@MainActor
final class DiagnosticExportCoordinator {

    /// How a share ended. All three release: a cancelled share leaves the file on disk just as
    /// surely as a completed one.
    enum ShareOutcome: String {
        case completed
        case cancelled
        case failed
    }

    static let shared = DiagnosticExportCoordinator()

    private static let rootDirectoryName = "DiagnosticExports"

    private let store: ProtectedExportFileStore
    private let clock: () -> Date
    private let ttl: TimeInterval
    private var leases: [UUID: DiagnosticExportLease] = [:]
    /// Leases handed to an onscreen share controller. Backgrounding spares these and only these.
    private var sharing: Set<UUID> = []

    init(store: ProtectedExportFileStore? = nil,
         clock: @escaping () -> Date = Date.init,
         ttl: TimeInterval = ProtectedExportFileStore.completedSessionTTL) {
        self.store = store ?? ProtectedExportFileStore(rootDirectoryName: Self.rootDirectoryName)
        self.clock = clock
        self.ttl = ttl
    }

    var activeLeaseCount: Int { leases.count }

    // MARK: - Creation

    /// Write a previewed document to a protected session. The document is written exactly as the
    /// wearer read it — the builder already ran the redaction pass, and nothing is appended here.
    func makeLease(document: DiagnosticExportDocument,
                   displayName: String? = nil) throws -> DiagnosticExportLease {
        let now = clock()
        let session = try store.createSession(fileExtension: "txt", now: now) { url in
            try Data(document.body.utf8).write(to: url, options: .atomic)
        }
        let lease = DiagnosticExportLease(
            id: session.id,
            createdAt: session.createdAt,
            fileURL: session.fileURL,
            displayName: ProtectedExportFileStore.sanitizedDisplayName(
                displayName ?? DiagnosticExportBuilder.displayName(now: now),
                fallback: "openglasses-diagnostics.txt")
        )
        leases[lease.id] = lease
        PrivacyLog.transfer(.diagnosticsExport, .exported, count: document.eventCount)
        return lease
    }

    // MARK: - Share lifecycle

    func beginShare(_ lease: DiagnosticExportLease) {
        guard leases[lease.id] != nil else { return }
        sharing.insert(lease.id)
        PrivacyLog.transfer(.diagnosticsExport, .shareStarted)
    }

    /// Release after the share provider finishes, however it finished.
    func finishShare(_ lease: DiagnosticExportLease, outcome: ShareOutcome) {
        guard leases[lease.id] != nil else { return }
        PrivacyLog.transfer(.diagnosticsExport, .shareEnded,
                            operation: PrivacyToken(outcome.rawValue))
        release(lease)
    }

    /// Remove a lease and its file. Idempotent, so concurrent completion paths are harmless.
    func release(_ lease: DiagnosticExportLease) {
        sharing.remove(lease.id)
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        store.release(id: lease.id, directory: lease.sessionDirectory)
        PrivacyLog.transfer(.diagnosticsExport, .released)
    }

    // MARK: - Cleanup

    /// Launch sweep of sessions a crash abandoned.
    func scavenge() {
        let removed = store.scavenge(now: clock(), ttl: ttl)
        if removed > 0 {
            PrivacyLog.transfer(.diagnosticsExport, .scavenged, count: removed)
        }
    }

    /// On backgrounding, drop everything not held by an onscreen share.
    func handleBackground() {
        let abandoned = leases.values.filter { !sharing.contains($0.id) }
        guard !abandoned.isEmpty else { return }
        abandoned.forEach { release($0) }
    }

    // There is deliberately no `revokeAll` here, unlike the clinical coordinator. That exists
    // because entering compliance mode must destroy files written under the looser regime; a
    // diagnostics bundle holds no clinical content by construction, and its whole lifecycle is
    // covered by release-on-any-share-outcome, release-on-background and the launch scavenge.
}
