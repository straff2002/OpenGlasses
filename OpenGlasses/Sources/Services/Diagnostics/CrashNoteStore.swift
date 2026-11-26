import Foundation

/// The crash notes on this phone (`CrashNote`), and whether each has been offered.
///
/// At most `maxNotes`, none older than `DiagnosticRing.retentionDays`, in Application Support with
/// the first-unlock class and out of backup — the same posture as the diagnostic ring beside it,
/// and cleared with it. Declared in `DataStoreRegistry` as `.crashNotes`.
///
/// The same file directory also holds `LastScreens` (`LastScreensStore`), the few hundred bytes
/// that say which screens each recent run opened, written at once so a crash cannot lose them.
final class CrashNoteStore: @unchecked Sendable {

    /// A note, when it reached the phone, and what the banner did with it.
    struct Record: Codable, Equatable {
        var note: CrashNote
        let receivedAt: Date
        /// When the banner offered it. Once offered, never offered again, whatever was tapped.
        var offeredAt: Date?
    }

    static let maxNotes = 10
    static let maxAge: TimeInterval = DiagnosticRing.defaultMaxAge

    static let shared = CrashNoteStore(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics/crash-notes.json"))

    private let url: URL?
    private let clock: () -> Date
    private let lock = NSLock()
    private var records: [Record] = []
    private var loaded = false

    init(url: URL?, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    /// Every note kept, oldest first.
    var all: [Record] {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return records
    }

    var notes: [CrashNote] { all.map(\.note) }

    /// Keep new notes. A note already held (same fingerprint) is not added twice. Returns the
    /// notes that were new.
    @discardableResult
    func add(_ notes: [CrashNote]) -> [CrashNote] {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        var added: [CrashNote] = []
        for note in notes where !records.contains(where: { $0.note.id == note.id }) {
            records.append(Record(note: note, receivedAt: now, offeredAt: nil))
            added.append(note)
        }
        records = Self.retained(records, now: now)
        saveLocked()
        return added.filter { note in records.contains { $0.note.id == note.id } }
    }

    /// The banner offered this note: it is not offered again.
    func markOffered(_ id: String) {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        guard let index = records.firstIndex(where: { $0.note.id == id }),
              records[index].offeredAt == nil else { return }
        records[index].offeredAt = now
        saveLocked()
    }

    /// Forget every note. What the registry's "delete all" names; the diagnostic ring's own
    /// `clear()` calls it too.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        records = []
        loaded = true
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The bounds, pure: newest `maxNotes`, none older than `maxAge` or dated in the future past
    /// a day's clock change. Oldest first.
    static func retained(_ records: [Record], now: Date) -> [Record] {
        let fresh = records.filter {
            now.timeIntervalSince($0.note.at) <= maxAge && $0.note.at.timeIntervalSince(now) < 86_400
        }
        .sorted { $0.note.at < $1.note.at }
        return Array(fresh.suffix(maxNotes))
    }

    // MARK: - Disk

    private func loadLocked() {
        guard !loaded else { return }
        guard let url else { loaded = true; return }
        guard FileManager.default.fileExists(atPath: url.path) else { loaded = true; return }
        // Unreadable before the first unlock: try again next time rather than writing over it.
        guard let data = try? Data(contentsOf: url) else { return }
        loaded = true
        records = Self.retained((try? JSONDecoder().decode([Record].self, from: data)) ?? [], now: clock())
    }

    private func saveLocked() {
        guard loaded, let url else { return }
        DiagnosticsFile.write(records, to: url)
    }
}

/// The screens one run of the app opened, newest last — a crash-time record of where the person
/// was, since the ring's own write lags a second behind.
///
/// The tokens are `diagnosticScreen`'s call-site file names: fixed code vocabulary, never a title.
struct LastScreens: Codable, Equatable {
    struct Screen: Codable, Equatable {
        let token: String
        let at: Date
        /// True when the screen appeared, false when it went away.
        let appeared: Bool
    }

    static let capacity = 8

    let run: String
    let build: String
    let startedAt: Date
    private(set) var screens: [Screen] = []

    init(run: String, build: String, startedAt: Date, screens: [Screen] = []) {
        self.run = run
        self.build = build
        self.startedAt = startedAt
        self.screens = Array(screens.suffix(Self.capacity))
    }

    /// The newest moment this run is known to have been alive.
    var lastSeen: Date { screens.last?.at ?? startedAt }

    mutating func record(_ token: String, appeared: Bool, at: Date) {
        screens.append(Screen(token: token, at: at, appeared: appeared))
        if screens.count > Self.capacity { screens.removeFirst(screens.count - Self.capacity) }
    }
}

/// Writes `LastScreens` for this run and keeps the last few runs' records, so a run that crashed
/// can still be named on a later launch.
///
/// Every change is written at once, atomically, on a utility queue: no delay to gather a burst,
/// because the write that matters is the last one before a crash. A pending write that a newer
/// one has overtaken is skipped, which costs nothing.
final class LastScreensStore: @unchecked Sendable {

    /// Runs kept, newest last. A crash's note can arrive a launch or two late.
    static let maxRuns = 8

    static let shared = LastScreensStore(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics/last-screens.json"))

    private let url: URL?
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "com.openglasses.last-screens", qos: .utility)
    private let lock = NSLock()
    private var runs: [LastScreens] = []
    /// The run this process is writing, once `begin` has been called.
    private var current: String?
    /// Earlier runs could not be read yet (protected data before the first unlock); writing now
    /// would replace them with this run alone.
    private var waitingForUnlock = false
    private var generation = 0

    init(url: URL?, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    /// Start this run's record. Reads the earlier runs first.
    func begin(run: String, build: String) {
        let earlier = load()
        lock.lock()
        switch earlier {
        case .some(let previous):
            runs = previous.filter { $0.run != run }
            waitingForUnlock = false
        case .none:
            runs = []
            waitingForUnlock = true
        }
        runs.append(LastScreens(run: run, build: build, startedAt: clock()))
        runs = Array(runs.suffix(Self.maxRuns))
        current = run
        scheduleLocked()
        lock.unlock()
    }

    /// A screen appeared or went away.
    func record(_ token: String, appeared: Bool) {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        guard let current, let index = runs.lastIndex(where: { $0.run == current }) else { return }
        runs[index].record(token, appeared: appeared, at: now)
        scheduleLocked()
    }

    /// Every run's record, oldest first.
    var all: [LastScreens] {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    /// Protected data is readable again: fold in the earlier runs a locked launch could not read.
    func protectedDataDidBecomeAvailable() {
        lock.lock()
        let waiting = waitingForUnlock
        lock.unlock()
        guard waiting, let earlier = load() else { return }
        lock.lock()
        defer { lock.unlock() }
        guard waitingForUnlock else { return }
        waitingForUnlock = false
        let mine = Set(runs.map(\.run))
        runs = Array((earlier.filter { !mine.contains($0.run) } + runs).suffix(Self.maxRuns))
        scheduleLocked()
    }

    /// Forget every run but keep recording this one from an empty record.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        if let current, let mine = runs.last(where: { $0.run == current }) {
            runs = [LastScreens(run: mine.run, build: mine.build, startedAt: mine.startedAt)]
        } else {
            runs = []
        }
        waitingForUnlock = false
        scheduleLocked()
    }

    func waitForPendingWrites() { queue.sync {} }

    // MARK: - Disk

    /// The saved runs, an empty list when there is no file, or nil when the file is there and
    /// cannot be read yet.
    private func load() -> [LastScreens]? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode([LastScreens].self, from: data)) ?? []
    }

    private func scheduleLocked() {
        guard !waitingForUnlock, let url else { return }
        generation += 1
        let mine = generation
        let snapshot = runs
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = mine != self.generation
            self.lock.unlock()
            guard !stale else { return }
            DiagnosticsFile.write(snapshot, to: url)
        }
    }
}

/// The write both stores share: the folder made and kept out of backup, the file atomic with the
/// first-unlock class. Never throws and never logs — diagnostics must not crash the app or log
/// their own I/O.
enum DiagnosticsFile {
    static func write<Value: Encodable>(_ value: Value, to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(value)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: url)
        } catch {
            // Nothing to do: the next change writes again.
        }
    }
}
