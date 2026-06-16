import Foundation

/// What to do with an op once the server's current state is known.
enum ConflictDecision: Equatable {
    case accept(newVersion: Int)   // last-writer-wins — adopt the server version and deliver
    case conflict(reason: String)  // server advanced while we were offline — surface it
}

/// Single-writer conflict detection (Plan T), reduced from the vector-clock idea to a per-session
/// version counter. The technician's device is the only writer in v1; the only "conflict" is the
/// server having moved on (e.g. tasks reassigned, a procedure version bumped) while the device was
/// offline. Pure and deterministic — a real networked `SyncSink` consults this; v1's local sink
/// doesn't need it. Multi-writer reconciliation is explicitly out of scope.
final class ConflictResolver {
    /// The last server version this device knew about, per session.
    private var knownVersion: [String: Int] = [:]

    /// Record the server version the device last synced to for a session.
    func setKnownVersion(_ version: Int, for sessionId: String) {
        knownVersion[sessionId] = version
    }

    func knownVersion(for sessionId: String) -> Int {
        knownVersion[sessionId] ?? 0
    }

    /// Decide an op against the server's current version for its session. If the server advanced
    /// beyond what we knew, it's a conflict; otherwise accept (last-writer-wins) and adopt the
    /// server version so subsequent ops in the same flush compare against the fresh baseline.
    func resolve(op: QueuedOp, serverVersion: Int) -> ConflictDecision {
        let known = knownVersion[op.sessionId] ?? 0
        if serverVersion > known {
            let delta = serverVersion - known
            setKnownVersion(serverVersion, for: op.sessionId)
            return .conflict(reason: "\(delta) change\(delta == 1 ? "" : "s") happened on the server while you were offline")
        }
        // Server is at or behind what we knew — our write wins; keep the baseline current.
        setKnownVersion(max(known, serverVersion), for: op.sessionId)
        return .accept(newVersion: max(known, serverVersion))
    }
}
