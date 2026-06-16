import Foundation
import Combine

/// The result of attempting to deliver one op to the sync target.
enum SyncOutcome: Equatable {
    case done                       // delivered (the receiver dedups by op.id, so retries are safe)
    case conflict(reason: String)   // server state diverged while offline — surface, don't overwrite
    case transient(reason: String)  // temporary failure — keep the op, retry later
    case permanent(reason: String)  // will never succeed — fail the op
}

/// Pluggable delivery target for queued ops (Plan T). v1 is `LocalSyncSink` (no backend — local
/// export only); a gateway / customer endpoint slots in behind the same interface later.
@MainActor
protocol SyncSink: AnyObject {
    func deliver(_ op: QueuedOp) async -> SyncOutcome
}

/// v1 sink: there is no remote backend yet, so a well-formed op is considered delivered (its
/// durable local record already exists). Records delivered ids so a real backend's idempotent
/// dedup behaviour is mirrored, and so tests can assert no double-delivery.
@MainActor
final class LocalSyncSink: SyncSink {
    private(set) var delivered: [String] = []

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        if delivered.contains(op.id) { return .done }   // idempotent
        delivered.append(op.id)
        return .done
    }
}

/// Reachability-driven store-and-forward flush (Plan T). On the rising edge of connectivity it
/// drains the durable `OfflineQueue` in strict FIFO order through a `SyncSink`. Transient errors
/// keep the op pending (attempts incremented, capped → failed); conflicts are surfaced rather than
/// silently overwritten; permanent errors fail the op. Idempotent: each op carries a stable id.
@MainActor
final class SyncEngine: ObservableObject {
    private let queue: OfflineQueue
    private let sink: SyncSink

    @Published private(set) var isFlushing = false
    @Published private(set) var lastSyncedCount = 0
    @Published private(set) var lastConflictCount = 0

    /// Surfaced when an op diverges from server state. AppState speaks / badges this.
    var onConflict: ((QueuedOp, String) -> Void)?
    /// Max delivery attempts before an op is marked `failed`.
    var maxAttempts = 6

    private var reachabilityChange: ((Bool) -> Void)?

    init(queue: OfflineQueue, sink: SyncSink) {
        self.queue = queue
        self.sink = sink
    }

    /// Flush on the rising edge of `reachability` (false → true). Chains any existing `onChange`.
    func bind(to reachability: Reachability) {
        let previous = reachability.onChange
        reachability.onChange = { [weak self] online in
            previous?(online)
            if online { Task { @MainActor in await self?.flush() } }
        }
    }

    /// Deliver all pending ops in FIFO order. Returns the number delivered this pass. Re-entrant
    /// calls are coalesced (a flush already running wins).
    @discardableResult
    func flush() async -> Int {
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var delivered = 0
        var conflicts = 0
        for op in queue.pending() {
            queue.mark(op.id, state: .inFlight)
            switch await sink.deliver(op) {
            case .done:
                queue.mark(op.id, state: .done)
                delivered += 1
            case .conflict(let reason):
                queue.mark(op.id, state: .conflict)
                conflicts += 1
                onConflict?(op, reason)
            case .transient(let reason):
                let attempts = op.attempts + 1
                if attempts >= maxAttempts {
                    queue.mark(op.id, state: .failed, attempts: attempts)
                    NSLog("[SyncEngine] op %@ failed after %d attempts: %@", op.id, attempts, reason)
                } else {
                    queue.mark(op.id, state: .pending, attempts: attempts)   // retained for a later flush
                }
            case .permanent(let reason):
                queue.mark(op.id, state: .failed)
                NSLog("[SyncEngine] op %@ permanently failed: %@", op.id, reason)
            }
        }

        lastSyncedCount = delivered
        lastConflictCount = conflicts
        return delivered
    }
}
