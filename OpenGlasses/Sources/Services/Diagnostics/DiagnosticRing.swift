import Foundation

/// A bounded, in-memory tail of the structured events the app has already logged.
///
/// This is deliberately not a second logging system. It subscribes to `PrivacyLog` at the point
/// where an event has already been encoded, and keeps the *same line* the OS log received — so
/// everything the classification table forbids is absent here for exactly the reason it is absent
/// there: no method on the facade accepts it. That is what makes an opt-out-free, on-by-default
/// tap defensible; a ring of content would need consent to *collect*, and this one needs consent
/// only to *leave the device*.
///
/// The shared ring checkpoints its bounded tail locally. The previous run is loaded separately
/// for a consented export after a crash; it is not evidence that the previous exit was a crash.
/// Writes are asynchronous, so an abrupt exit may lose the latest queued events.
final class DiagnosticRing: @unchecked Sendable {

    /// One recorded event: when it happened, what it was, and the encoded line itself.
    struct Entry: Equatable, Codable {
        let timestamp: Date
        let category: PrivacyLog.Category
        let name: PrivacyEvent.Name
        /// Exactly what `PrivacyEventEncoder` produced, including the `[category] name` prefix.
        let line: String
    }

    /// Roughly a session's worth of events at the rate the app actually logs, and small enough
    /// that the whole buffer is readable in a preview the wearer is expected to actually read.
    static let defaultCapacity = 500

    static let shared = DiagnosticRing(persistenceURL: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics/last-session.json"))

    /// Frozen at launch: current activity must not push the previous run out of the export.
    let previousEntries: [Entry]
    private let persistence: DiagnosticBreadcrumbStore?

    let capacity: Int

    private let clock: () -> Date
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var tap: PrivacyLog.TapToken?

    init(capacity: Int = DiagnosticRing.defaultCapacity, clock: @escaping () -> Date = Date.init,
         persistenceURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.clock = clock
        persistence = persistenceURL.map { DiagnosticBreadcrumbStore(url: $0) }
        previousEntries = persistence?.read(capacity: max(1, capacity), now: clock()) ?? []
        buffer.reserveCapacity(min(self.capacity, 64))
    }

    deinit {
        if let tap { PrivacyLog.removeTap(tap) }
    }

    // MARK: - Recording

    /// Record one already-encoded event. Oldest entries fall off the front once full.
    func record(_ event: PrivacyEvent, line: String, at time: Date? = nil) {
        let entry = Entry(timestamp: time ?? clock(), category: event.category,
                          name: event.name, line: line)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        // Queue while holding the ring lock so concurrent producers cannot persist an older
        // snapshot after a newer one. Disk work itself never runs under this lock or on the UI.
        persistence?.schedule(buffer)
        lock.unlock()
    }

    /// Everything held, oldest first.
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func waitForPendingWrites() { persistence?.waitForPendingWrites() }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        persistence?.schedule([])
        lock.unlock()
    }

    // MARK: - Subscription

    /// Start recording. Idempotent — a second call does not double-record.
    func attach() {
        lock.lock()
        let alreadyAttached = tap != nil
        lock.unlock()
        guard !alreadyAttached else { return }

        let token = PrivacyLog.addTap { [weak self] event, line in
            self?.record(event, line: line)
        }
        lock.lock()
        // A concurrent `attach` may have won; keep exactly one tap and drop the loser.
        if tap == nil {
            tap = token
            lock.unlock()
        } else {
            lock.unlock()
            PrivacyLog.removeTap(token)
        }
    }

    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    func detach() {
        lock.lock()
        let token = tap
        tap = nil
        lock.unlock()
        if let token { PrivacyLog.removeTap(token) }
    }
}


/// Coalesces pending snapshots so a burst of events cannot queue unbounded disk writes.
/// Only encoded, content-free events enter this store. No crash-time handler does file I/O.
final class DiagnosticBreadcrumbStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.openglasses.diagnostic-breadcrumbs", qos: .utility)
    private let lock = NSLock()
    private var pending: [DiagnosticRing.Entry]?
    private var scheduled = false

    init(url: URL) { self.url = url }

    func read(capacity: Int, now: Date) -> [DiagnosticRing.Entry] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2_000_000,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([DiagnosticRing.Entry].self, from: data)
        else { return [] }
        return Array(entries.filter {
            now.timeIntervalSince($0.timestamp) <= 48 * 60 * 60 && $0.timestamp <= now
        }.suffix(capacity))
    }

    func schedule(_ entries: [DiagnosticRing.Entry]) {
        lock.lock()
        pending = entries
        let needsWorker = !scheduled
        scheduled = true
        if needsWorker { queue.async { self.drain() } }
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let entries = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var excludedDirectory = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try excludedDirectory.setResourceValues(values)
                let data = try JSONEncoder().encode(entries)
                #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: url, options: .atomic)
                #endif
                StoreProtection.apply(.completeUntilFirstUserAuthentication,
                                      backupExcluded: true, to: url)
            } catch {
                // Diagnostics must never crash the app or recursively log their own I/O failure.
            }
        }
    }

    /// For tests/background callers only. Never block the main thread waiting for diagnostics.
    func waitForPendingWrites() {
        lock.lock()
        lock.unlock() // Any accepted worker is enqueued before the barrier is submitted.
        queue.sync {}
    }
}
