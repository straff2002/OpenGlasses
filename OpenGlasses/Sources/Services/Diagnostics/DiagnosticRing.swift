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
/// It has no persistence. The buffer lives in this process and dies with it, so a diagnostics
/// export can only ever describe the session the wearer is reporting on, and there is no file for
/// anything else to find later.
final class DiagnosticRing: @unchecked Sendable {

    /// One recorded event: when it happened, what it was, and the encoded line itself.
    struct Entry: Equatable {
        let timestamp: Date
        let category: PrivacyLog.Category
        let name: PrivacyEvent.Name
        /// Exactly what `PrivacyEventEncoder` produced, including the `[category] name` prefix.
        let line: String
    }

    /// Roughly a session's worth of events at the rate the app actually logs, and small enough
    /// that the whole buffer is readable in a preview the wearer is expected to actually read.
    static let defaultCapacity = 500

    static let shared = DiagnosticRing()

    let capacity: Int

    private let clock: () -> Date
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var tap: PrivacyLog.TapToken?

    init(capacity: Int = DiagnosticRing.defaultCapacity, clock: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.clock = clock
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
        lock.unlock()
    }

    /// Everything held, oldest first.
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
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
