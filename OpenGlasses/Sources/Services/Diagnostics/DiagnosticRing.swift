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
/// The shared ring checkpoints its bounded tail locally, together with what earlier runs left
/// (`previousEntries`), so a consented export can reach back across relaunches for up to
/// `defaultMaxAge`. An earlier run is not evidence that it ended in a crash. Writes are
/// asynchronous and coalesced, so an abrupt exit may lose the latest queued events.
///
/// ## What is kept
///
/// A tester's support report held exactly the newest 500 lines of a long run: the launch and the
/// first minutes had been evicted with nothing to say so, and only the immediately previous run
/// survived a relaunch. So, per run:
/// - the first `launchLimit` events are the **launch window** and are never evicted;
/// - after them, events are kept for `maxAge` and up to `capacity` in all, oldest dropped first,
///   and the first event kept after a drop carries the count (`Entry.gapBefore`) so the export
///   can say "N earlier events not kept" where the hole is;
/// - earlier runs are appended to the persisted history rather than overwritten, bounded by the
///   same age and count, and every entry carries its run's id so the export can mark where one
///   run ends and the next begins.
final class DiagnosticRing: @unchecked Sendable {

    /// One recorded event: when it happened, what it was, and the encoded line itself.
    struct Entry: Equatable, Codable {
        let timestamp: Date
        let category: PrivacyLog.Category
        let name: PrivacyEvent.Name
        /// Exactly what `PrivacyEventEncoder` produced, including the `[category] name` prefix.
        let line: String
        /// The run of the app that recorded it: a short random id minted per process, nothing
        /// about the device. Nil in files written before runs were told apart, which read as one
        /// earlier run.
        var run: String? = nil
        /// How many events immediately before this one were not kept — evicted, or unreadable
        /// after an app update. Nil when nothing is missing.
        var gapBefore: Int? = nil
    }

    /// One line of the export's event log: an event, or a note about where events are missing or
    /// where one run of the app gave way to the next.
    struct TimelineLine: Equatable {
        let at: Date
        let line: String
    }

    /// Why earlier runs' events are not in the export at all.
    enum HistoryProblem: Equatable {
        /// The file was there and could not be opened — protected data before the phone's first
        /// unlock. Retried by `protectedDataDidBecomeAvailable()`.
        case unreadable
        /// The file opened and was not a list of events at all.
        case corrupt
    }

    /// Plan JQ: measured on an iPhone Air before raising from 2,000. The doubled persisted
    /// history (28,000 synthetic 300-character events, 10.9 MB) loaded in at most 78.1 ms.
    /// See docs/plans/JQ-pilot-identity-and-daily-reports.md. Count can still evict before age.
    static let defaultCapacity = 14_000

    /// How far back the ring, and the history saved for later runs, reaches.
    static let retentionDays = 7
    static let defaultMaxAge: TimeInterval = TimeInterval(retentionDays * 24 * 60 * 60)

    /// How many of a run's first events are kept however long the run goes on: the launch, and the
    /// minutes after it, which are where "it never started listening" is answered.
    static let defaultLaunchLimit = 40

    static let shared = DiagnosticRing(persistenceURL: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics/last-session.json"),
        alsoClear: { CrashNoteStore.shared.clear(); LastScreensStore.shared.clear() })

    /// What else goes when the ring is cleared: the crash notes and last screens that describe the
    /// same runs (Plan MB). Empty for a ring made in a test.
    private let alsoClear: () -> Void

    private let persistence: DiagnosticBreadcrumbStore?

    let capacity: Int
    let maxAge: TimeInterval
    /// This process's run id, stamped on every entry it records.
    let runID: String
    /// The size of the launch window. A tenth of `capacity` at most, so a small ring still behaves
    /// as a plain newest-N buffer.
    let launchLimit: Int

    private let clock: () -> Date
    private let lock = NSLock()
    /// This run's launch window, never evicted.
    private var launch: [Entry] = []
    /// How many of `launch` are capture noise, counted against `frameReceivedBudget`.
    private var launchNoise = 0
    /// This run's events after the launch window, bounded by count and age.
    private var buffer: [Entry] = []
    /// What earlier runs left, oldest first; persisted ahead of this run's events.
    private var history: [Entry] = []
    private var historyProblem: HistoryProblem?
    /// Undecodable entries at the very end of the history: no later history entry can carry the
    /// count, so this run's first entry does.
    private var carriedGap = 0
    private var tap: PrivacyLog.TapToken?

    init(capacity: Int = DiagnosticRing.defaultCapacity,
         maxAge: TimeInterval = DiagnosticRing.defaultMaxAge,
         launchLimit: Int = DiagnosticRing.defaultLaunchLimit,
         clock: @escaping () -> Date = Date.init,
         runID: String = String(UUID().uuidString.prefix(8)).lowercased(),
         persistenceURL: URL? = nil,
         alsoClear: @escaping () -> Void = {}) {
        self.alsoClear = alsoClear
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
        self.launchLimit = max(0, min(launchLimit, self.capacity / 10))
        self.clock = clock
        self.runID = runID
        persistence = persistenceURL.map { DiagnosticBreadcrumbStore(url: $0) }
        buffer.reserveCapacity(min(self.capacity, 64))
        if let persistence {
            adopt(persistence.load(capacity: self.capacity, maxAge: maxAge, now: clock()))
        }
    }

    deinit {
        if let tap { PrivacyLog.removeTap(tap) }
    }

    /// What earlier runs left, oldest first. Read at launch (or at the first unlock after a
    /// locked launch); current activity never pushes it out of the export.
    var previousEntries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    // MARK: - Recording

    /// Plan GB P4: how many camera `frameReceived` entries the ring keeps. The field tester's
    /// export spent 222 of 500 slots on them, pushing out the model and speech events the report
    /// was needed for. Capture noise keeps its own small window; everything else keeps the rest.
    static let frameReceivedBudget = 40

    /// Whether an event is per-frame capture noise that is held to `frameReceivedBudget`.
    static func isFrameNoise(_ event: PrivacyEvent) -> Bool {
        event.name == .camera && event.fields.contains {
            $0.key == .event && $0.value == .token(PrivacyToken("frameReceived"))
        }
    }

    private static func isNoiseEntry(_ entry: Entry) -> Bool {
        entry.name == .camera && entry.line.contains("frameReceived")
    }

    /// Record one already-encoded event. The first `launchLimit` of a run are kept for good; after
    /// that the oldest fall off the front once the ring is full or past `maxAge`, and the first
    /// one kept says how many went. A `frameReceived` over its own budget replaces the oldest
    /// `frameReceived` instead.
    func record(_ event: PrivacyEvent, line: String, at time: Date? = nil) {
        var entry = Entry(timestamp: time ?? clock(), category: event.category,
                          name: event.name, line: line, run: runID)
        let noise = Self.isFrameNoise(event)
        lock.lock()
        if launch.isEmpty, buffer.isEmpty, carriedGap > 0 {
            entry.gapBefore = carriedGap
            carriedGap = 0
        }
        if launch.count < launchLimit, buffer.isEmpty {
            launch.append(entry)
            if noise { launchNoise += 1 }
        } else {
            if noise {
                let noisy = buffer.indices.filter { Self.isNoiseEntry(buffer[$0]) }
                if noisy.count + launchNoise >= Self.frameReceivedBudget, let oldest = noisy.first {
                    buffer.remove(at: oldest)
                }
            }
            buffer.append(entry)
            evictLocked(newest: entry.timestamp)
        }
        // Queue while holding the ring lock so concurrent producers cannot persist an older
        // snapshot after a newer one. Disk work itself never runs under this lock or on the UI.
        persistLocked()
        lock.unlock()
    }

    /// Drop from the front of `buffer` past the count or age bound, and hand the count of what
    /// went — including any gap those entries were already carrying — to the first one kept.
    private func evictLocked(newest: Date) {
        let bound = max(1, capacity - launch.count)
        var dropped = 0
        var cut = 0
        while buffer.count - cut > bound
            || (buffer.count - cut > 1 && newest.timeIntervalSince(buffer[cut].timestamp) > maxAge) {
            dropped += 1 + (buffer[cut].gapBefore ?? 0)
            cut += 1
        }
        guard cut > 0 else { return }
        buffer.removeFirst(cut)
        buffer[0].gapBefore = (buffer[0].gapBefore ?? 0) + dropped
    }

    /// Persist history and this run together — unless earlier runs could not be read yet, when
    /// writing would replace them with this run alone. Those writes wait for the retry.
    private func persistLocked() {
        guard historyProblem != .unreadable else { return }
        persistence?.schedule(history + launch + buffer)
    }

    /// Take a load's result as the history.
    private func adopt(_ load: DiagnosticBreadcrumbStore.Load) {
        switch load {
        case .absent:
            history = []
            historyProblem = nil
        case .unreadable:
            history = []
            historyProblem = .unreadable
        case .corrupt:
            history = []
            historyProblem = .corrupt
        case .loaded(let entries, let trailingGap):
            history = entries
            historyProblem = nil
            carriedGap += trailingGap
        }
    }

    /// Everything this run holds, oldest first: the launch window, then the rest.
    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return launch + buffer
    }

    func waitForPendingWrites() { persistence?.waitForPendingWrites() }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return launch.count + buffer.count
    }

    /// Forget everything — this run, earlier runs, and the file. What the registry's "delete all"
    /// names.
    func clear() {
        lock.lock()
        launch.removeAll()
        launchNoise = 0
        buffer.removeAll(keepingCapacity: true)
        history.removeAll()
        carriedGap = 0
        // Whatever the file held is meant to go, readable or not: the next write replaces it.
        historyProblem = nil
        persistLocked()
        lock.unlock()
        alsoClear()
    }

    /// Protected data is readable again. A launch before the phone's first unlock could not read
    /// the saved history; read it now, and resume persisting once it is in hand.
    func protectedDataDidBecomeAvailable() {
        lock.lock()
        let waiting = historyProblem == .unreadable
        lock.unlock()
        guard waiting, let persistence else { return }
        let load = persistence.load(capacity: capacity, maxAge: maxAge, now: clock())
        lock.lock()
        defer { lock.unlock() }
        guard historyProblem == .unreadable else { return }
        adopt(load)
        if carriedGap > 0, !(launch.isEmpty && buffer.isEmpty) {
            if launch.isEmpty {
                buffer[0].gapBefore = (buffer[0].gapBefore ?? 0) + carriedGap
            } else {
                launch[0].gapBefore = (launch[0].gapBefore ?? 0) + carriedGap
            }
            carriedGap = 0
        }
        persistLocked()
    }

    // MARK: - Export

    /// The event log a support report carries, oldest first: earlier runs, then this one, with a
    /// line wherever events are missing and wherever one run of the app gave way to the next.
    var timeline: [TimelineLine] {
        lock.lock()
        let earlier = history
        let current = launch + buffer
        let problem = historyProblem
        lock.unlock()
        return Self.timeline(history: earlier, current: current, historyProblem: problem,
                             now: clock())
    }

    /// The pure half of `timeline`, so its markers are a unit test rather than a promise.
    static func timeline(history: [Entry], current: [Entry], historyProblem: HistoryProblem?,
                         now: Date) -> [TimelineLine] {
        var lines: [TimelineLine] = []
        if let historyProblem {
            let at = history.first?.timestamp ?? current.first?.timestamp ?? now
            switch historyProblem {
            case .unreadable:
                lines.append(.init(at: at, line: "… events from earlier runs could not be read yet "
                    + "(the phone had not been unlocked since it started) …"))
            case .corrupt:
                lines.append(.init(at: at, line: "… events from earlier runs could not be read …"))
            }
        }
        var previousRun: String?? = .none
        func emit(_ entry: Entry, boundary: String) {
            if let gap = entry.gapBefore, gap > 0 {
                lines.append(.init(at: entry.timestamp,
                                   line: "… \(gap) earlier event\(gap == 1 ? "" : "s") not kept …"))
            }
            if previousRun != .some(entry.run) {
                lines.append(.init(at: entry.timestamp, line: boundary))
                previousRun = .some(entry.run)
            }
            lines.append(.init(at: entry.timestamp, line: entry.line))
        }
        for entry in history {
            emit(entry, boundary: "── an earlier run of the app ──")
        }
        for entry in current {
            emit(entry, boundary: "── this run of the app ──")
        }
        return lines
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
///
/// The file is a JSON array of `DiagnosticRing.Entry`, the format every build has written; the
/// fields added since (`run`, `gapBefore`) are optional, so an older file still reads and an older
/// build still reads a newer one. Reading is per entry: an event an app update renamed or removed
/// costs that one line, counted, and not the whole history.
final class DiagnosticBreadcrumbStore: @unchecked Sendable {

    /// What a read found.
    enum Load: Equatable {
        /// No file: a first run, or a cleared ring.
        case absent
        /// A file that could not be opened — protected data before the first unlock.
        case unreadable
        /// A file that opened and was not a list of events (or was implausibly large).
        case corrupt
        /// The entries within the age and count bounds, oldest first. Entries skipped as
        /// undecodable, or dropped by the count bound, are counted into the `gapBefore` of the
        /// next one kept; `trailingGap` is the count after the last one kept.
        case loaded([DiagnosticRing.Entry], trailingGap: Int)
    }

    /// A file larger than this is not something this store wrote. Room for the ring and the
    /// history at their default bounds with plenty to spare.
    static let maxFileSize = 16_000_000

    private let url: URL
    private let writeDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.openglasses.diagnostic-breadcrumbs", qos: .utility)
    private let lock = NSLock()
    private var pending: [DiagnosticRing.Entry]?
    private var scheduled = false

    /// `writeDelay` gathers a burst into one write: the snapshot holds a few thousand entries, and
    /// re-encoding it for every event would cost the battery for nothing.
    init(url: URL, writeDelay: TimeInterval = 1) {
        self.url = url
        self.writeDelay = max(0, writeDelay)
    }

    /// The saved entries within `maxAge` of `now` and the newest `capacity` of them.
    func load(capacity: Int, maxAge: TimeInterval = DiagnosticRing.defaultMaxAge,
              now: Date) -> Load {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxFileSize {
            return .corrupt
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let decoded = try? JSONDecoder().decode([LossyEntry].self, from: data) else {
            return .corrupt
        }
        let (entries, trailing) = Self.retained(decoded.map(\.entry), capacity: capacity,
                                                maxAge: maxAge, now: now)
        return .loaded(entries, trailingGap: trailing)
    }

    /// Convenience for callers that only want the entries.
    func read(capacity: Int, now: Date) -> [DiagnosticRing.Entry] {
        guard case .loaded(let entries, _) = load(capacity: capacity, now: now) else { return [] }
        return entries
    }

    /// Apply the bounds to a decoded file, carrying every count of missing entries forward onto
    /// the next entry kept. Pure.
    ///
    /// - Parameter decoded: the file's entries in order, nil where one could not be decoded.
    /// - Returns: the kept entries, and the undecodable count after the last of them.
    static func retained(_ decoded: [DiagnosticRing.Entry?], capacity: Int, maxAge: TimeInterval,
                         now: Date) -> (entries: [DiagnosticRing.Entry], trailingGap: Int) {
        var kept: [DiagnosticRing.Entry] = []
        var skipped = 0
        for item in decoded {
            guard var entry = item else {
                skipped += 1
                continue
            }
            // Past the age bound (or from the future, after a clock change): gone, and not a hole
            // worth marking — it is simply outside the window the export covers.
            guard now.timeIntervalSince(entry.timestamp) <= maxAge, entry.timestamp <= now else {
                skipped = 0
                continue
            }
            if skipped > 0 {
                entry.gapBefore = (entry.gapBefore ?? 0) + skipped
                skipped = 0
            }
            kept.append(entry)
        }
        let bound = max(1, capacity)
        if kept.count > bound {
            let cut = kept.count - bound
            let dropped = kept.prefix(cut).reduce(0) { $0 + 1 + ($1.gapBefore ?? 0) }
            kept.removeFirst(cut)
            kept[0].gapBefore = (kept[0].gapBefore ?? 0) + dropped
        }
        return (kept, skipped)
    }

    /// One element of the saved array: the entry, or nil when it no longer decodes — typically an
    /// event name a later build renamed or removed.
    private struct LossyEntry: Decodable {
        let entry: DiagnosticRing.Entry?
        init(from decoder: Decoder) throws {
            entry = try? DiagnosticRing.Entry(from: decoder)
        }
    }

    func schedule(_ entries: [DiagnosticRing.Entry]) {
        lock.lock()
        pending = entries
        let needsWorker = !scheduled
        scheduled = true
        if needsWorker {
            if writeDelay > 0 {
                queue.asyncAfter(deadline: .now() + writeDelay) { self.drain() }
            } else {
                queue.async { self.drain() }
            }
        }
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
    /// Writes what is pending now rather than waiting out `writeDelay`; the delayed worker then
    /// finds nothing left to do.
    func waitForPendingWrites() {
        queue.sync { self.drain() }
    }
}
