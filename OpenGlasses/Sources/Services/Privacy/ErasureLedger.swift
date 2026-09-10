import Foundation

/// One completed erasure, kept so it can be honoured again if what it removed comes back.
struct ErasureLedgerEntry: Codable, Equatable, Identifiable {

    /// What was erased.
    enum Scope: Codable, Equatable {
        /// A whole class, by destroying its key and removing its files.
        case dataClass(ErasableClass)
        /// One subject, across every store the walk could reach.
        ///
        /// The token is the subject's own identifier, in the clear. That is a deliberate exception
        /// and the same one the offline queue's tombstone makes: replaying an erasure means
        /// searching the stores for the subject again, and a digest cannot be searched for. The
        /// ledger is therefore protected, excluded from backup, capped, and swept by retention —
        /// it is the second and last place a forgotten name may remain, and it exists only so the
        /// name does not come back everywhere else.
        case subject(kind: String, token: String)
    }

    /// Monotonic, never reused. A restored ledger whose highest id is below what this device has
    /// already seen is a ledger that was rolled back.
    let id: Int
    let at: Date
    let scope: Scope
    /// `ErasureCoverage.rendered` at the time — cryptographic or logical, and why.
    let coverage: String
    let storesCompleted: Int
    let storesWalked: Int
    /// When a replay last re-applied this entry, if one ever has.
    var lastReplayedAt: Date?
}

/// W03.5 — the durable record of completed erasures, and the replay that honours one when a store
/// it touched comes back.
///
/// ## What this closes, and what it does not
///
/// It closes the case where a *store* reappears while the ledger survives: a container preserved
/// across a reinstall, a file put back from a Files-app copy, a folder that resurfaced from a sync,
/// a partial restore. The next launch finds the entry, runs the erasure again, and the subject is
/// gone a second time.
///
/// It does **not** close a full-device restore from a backup taken before the erasure. That restore
/// replaces the container wholesale, ledger included, so the ledger that comes back is the one from
/// before the erasure and contains no record of it. Nothing kept inside the container can survive
/// its own replacement, and saying otherwise would be the kind of claim W03.5 exists to stop. What
/// covers that case instead is the other two halves of this work: the stores an erasure can reach
/// are excluded from backup, so they are not in the snapshot to be restored, and where a scoped key
/// was destroyed the restored bytes are ciphertext. A real encrypted restore drill on a device is
/// owed, and until it has been run this paragraph is the claim.
@MainActor
final class ErasureLedger {

    /// Entries beyond this are dropped oldest-first. The ledger is a safety net for the weeks
    /// after an erasure, not an archive of who has been forgotten.
    static let maxEntries = 200

    private(set) var entries: [ErasureLedgerEntry] = []

    private let storageURL: URL
    private let fileManager: FileManager

    /// `directory` is injectable so a test can round-trip a ledger without touching the wearer's.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first!
            .appendingPathComponent("Erasure", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                         attributes: [.protectionKey: Self.fileProtection])
        storageURL = root.appendingPathComponent("erasure-ledger.json")
        load()
        protectStorage()
    }

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    var lastID: Int { entries.map(\.id).max() ?? 0 }

    // MARK: - Recording

    @discardableResult
    func record(_ scope: ErasureLedgerEntry.Scope,
                coverage: ErasureCoverage,
                storesCompleted: Int = 0,
                storesWalked: Int = 0,
                now: Date = Date()) -> ErasureLedgerEntry {
        let entry = ErasureLedgerEntry(id: lastID + 1, at: now, scope: scope,
                                       coverage: coverage.rendered,
                                       storesCompleted: storesCompleted,
                                       storesWalked: storesWalked,
                                       lastReplayedAt: nil)
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        save()
        PrivacyLog.store(.erasureLedger, .recordWritten, count: entries.count,
                         detail: PrivacyToken(coverage.isCryptographic ? "cryptographic" : "logical"))
        return entry
    }

    func noteReplayed(_ id: Int, at date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastReplayedAt = date
        save()
    }

    /// Remove entries older than `cutoff`. Wired into the retention sweep: the record of an
    /// erasure has its own retention rule, as PIM-02 asks.
    @discardableResult
    func purge(olderThan cutoff: Date) -> Int {
        let before = entries.count
        entries.removeAll { $0.at < cutoff }
        guard entries.count != before else { return 0 }
        save()
        return before - entries.count
    }

    /// Everything an erasure can leave behind is in this file, so clearing it is a real delete.
    @discardableResult
    func clear() -> Int {
        let removed = entries.count
        entries.removeAll()
        save()
        return removed
    }

    // MARK: - Persistence

    private func load() {
        switch JSONStore.loadArray(ErasureLedgerEntry.self, at: storageURL, name: "erasure_ledger") {
        case .loaded(let loaded), .recovered(let loaded, _):
            entries = loaded.sorted { $0.id < $1.id }
        case .corrupt, .absent:
            entries = []
        case .unreadable:
            // Protected data locked. The file on disk may be perfectly good; never write over it.
            entries = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: [.atomic])
            protectStorage()
        } catch {
            PrivacyLog.store(.erasureLedger, .saveFailed, error: SafeErrorSummary(error))
        }
    }

    /// Protected and excluded from backup: this file names people who asked to be forgotten, and a
    /// backup is precisely where such a name must not travel.
    private func protectStorage() {
        StoreProtection.apply(Self.fileProtection, backupExcluded: true, to: storageURL,
                              fileManager: fileManager)
    }
}

// MARK: - Replay

/// Re-applies completed erasures when what they removed comes back.
@MainActor
enum ErasureReplay {

    /// How far back a replay looks. An erasure from last year is not what a restore brings back;
    /// keeping the window short is what keeps a launch cheap.
    static let window: TimeInterval = 90 * 24 * 3600
    /// And at most this many, newest first, so a long ledger cannot make a launch slow.
    static let maxEntries = 20

    struct Outcome: Equatable {
        let entryID: Int
        /// How many records the replay removed. Zero is the ordinary case and the good one: it
        /// means nothing came back.
        let removed: Int
        /// True when the replay found something to remove — a store had reappeared.
        var resurrected: Bool { removed > 0 }
    }

    /// What a replay needs. Both halves optional: a caller wires what it has, and what it does not
    /// wire is not replayed rather than being reported as replayed.
    struct Sources {
        var subjects: SubjectErasureCoordinator?
        var classFiles: ((ErasableClass) -> [URL])?
        var keyring: ScopedKeyring?

        init() {}
    }

    /// Replay the ledger. Only ever deletes: there is no path here that writes a record back, and
    /// `ErasureLedgerTests` pins that a replay against a store holding unrelated data leaves it
    /// alone.
    @discardableResult
    static func replay(ledger: ErasureLedger, sources: Sources, now: Date = Date()) async -> [Outcome] {
        let candidates = ledger.entries
            .filter { now.timeIntervalSince($0.at) <= window }
            .sorted { $0.id > $1.id }
            .prefix(maxEntries)
        guard !candidates.isEmpty else { return [] }

        var outcomes: [Outcome] = []
        for entry in candidates {
            let removed: Int
            switch entry.scope {
            case .subject(let kind, let token):
                guard let coordinator = sources.subjects,
                      let subject = Self.subject(kind: kind, token: token) else { continue }
                let receipts = await coordinator.erase(subject, now: now, recordInLedger: false)
                removed = receipts.reduce(0) { $0 + $1.removed }
            case .dataClass(let erasable):
                guard let keyring = sources.keyring, let files = sources.classFiles else { continue }
                // The key is already gone; this removes the files if they came back with it.
                removed = keyring.eraseClass(erasable, files: files(erasable)).filesRemoved
            }
            if removed > 0 { ledger.noteReplayed(entry.id, at: now) }
            outcomes.append(Outcome(entryID: entry.id, removed: removed))
        }

        let resurrected = outcomes.filter(\.resurrected).count
        PrivacyLog.store(.erasureLedger, .cleared, count: resurrected, total: outcomes.count)
        return outcomes
    }

    private static func subject(kind: String, token: String) -> ErasureSubject? {
        switch kind {
        case "person": return .person(token)
        case "thread": return .conversationThread(id: token)
        case "document": return .document(id: token)
        default: return nil
        }
    }
}
