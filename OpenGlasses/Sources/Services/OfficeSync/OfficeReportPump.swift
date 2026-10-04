import Foundation

/// Runs the reports' side of the office connection on each poll while it is up: reads the
/// office's receipts, lets the queue try again when one changed a report's standing or records
/// are waiting, and lets go of documents the office now has.
///
/// The queue flushes on its own when the network comes back; nothing tells it the *office* has.
/// This does, without flushing on every poll.
@MainActor
final class OfficeReportPump {

    struct Seams {
        /// One pass over the office's receipts. True when a report's standing changed.
        var sweep: @MainActor () async -> Bool
        /// Whether any record is queued and waiting.
        var recordsWaiting: @MainActor () -> Bool
        var flush: @MainActor () async -> Void
        /// Operations whose documents are no longer owed to the office.
        var settled: @MainActor () -> Set<String>
        var forget: @MainActor (Set<String>) -> Void
        var clock: () -> Date = Date.init
    }

    /// How often waiting records are offered again while nothing has changed.
    static let retryInterval: TimeInterval = 60

    private let seams: Seams
    private var lastFlush: Date?
    private var forgotten: Set<String> = []

    init(seams: Seams) { self.seams = seams }

    func tick() async {
        let changed = await seams.sweep()
        let now = seams.clock()
        let due = lastFlush.map { now.timeIntervalSince($0) >= Self.retryInterval } ?? true
        if changed || (due && seams.recordsWaiting()) {
            lastFlush = now
            await seams.flush()
        }
        let settled = seams.settled().subtracting(forgotten)
        if !settled.isEmpty {
            seams.forget(settled)
            forgotten.formUnion(settled)
        }
    }
}
