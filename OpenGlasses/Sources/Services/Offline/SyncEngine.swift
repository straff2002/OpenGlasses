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
    /// Ops fetched per drain page. A backlog larger than this is drained across loop iterations.
    var batchSize = 500
    /// Disk cap for delivered photo evidence; pruned after every flush and on launch so the queue
    /// can't grow without bound. `nil` disables photo pruning.
    var photoEvidenceCapBytes: Int? = 256 * 1024 * 1024   // 256 MB

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
    /// calls are coalesced (a flush already running wins). Loops in `batchSize` pages until the
    /// whole backlog is drained — a >`batchSize` queue no longer needs multiple reconnects — while
    /// tracking handled ids so a transient op re-queued this flush isn't reprocessed in a spin.
    @discardableResult
    func flush() async -> Int {
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var delivered = 0
        var conflicts = 0
        // Transient failures are re-armed to `pending` only *after* the drain completes. During the
        // loop they stay `inFlight` (out of the pending set) so `pending()` strictly shrinks each
        // page and the loop can't spin on a retained op — the whole backlog drains in one flush.
        var retry: [(id: String, attempts: Int)] = []
        while true {
            let batch = queue.pending(limit: batchSize)
            if batch.isEmpty { break }
            for op in batch {
                queue.mark(op.id, state: .inFlight)
                switch await sink.deliver(op) {
                case .done:
                    queue.mark(op.id, state: .done)
                    delivered += 1
                case .conflict(let reason):
                    queue.mark(op.id, state: .conflict)
                    conflicts += 1
                    onConflict?(op, reason)
                case .transient:
                    let attempts = op.attempts + 1
                    if attempts >= maxAttempts {
                        queue.mark(op.id, state: .failed, attempts: attempts)
                        // `reason` is composed by whichever sink refused the operation and can
                        // quote the payload back; the op's kind and its retry tier are what a
                        // stuck queue is diagnosed from.
                        PrivacyLog.transfer(.offlineSync, .attemptsExhausted,
                                            item: PrivateIdentifier(op.id),
                                            operation: PrivacyToken(op.kind.rawValue),
                                            attempt: attempts)
                    } else {
                        retry.append((op.id, attempts))   // re-armed below, once the drain is done
                    }
                case .permanent:
                    queue.mark(op.id, state: .failed)
                    PrivacyLog.transfer(.offlineSync, .permanentlyFailed,
                                        item: PrivateIdentifier(op.id),
                                        operation: PrivacyToken(op.kind.rawValue))
                }
            }
        }
        for r in retry { queue.mark(r.id, state: .pending, attempts: r.attempts) }

        lastSyncedCount = delivered
        lastConflictCount = conflicts
        runMaintenance()
        return delivered
    }

    /// Reclaim queue space: drop delivered non-photo tombstones and evict oldest delivered photo
    /// evidence past `photoEvidenceCapBytes`. Runs at the tail of every flush and can be called
    /// standalone on launch so space is reclaimed even when there's nothing to send.
    func runMaintenance() {
        if let cap = photoEvidenceCapBytes { queue.prunePhotoEvidence(maxBytes: cap) }
        queue.purgeDone()
    }
}
