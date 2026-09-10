import Foundation

/// The things a retention run can sweep. A closed vocabulary, so a receipt can name the target it
/// worked on without ever naming a record.
enum RetentionTargetID: String, CaseIterable, Codable, Sendable {
    case clinicalTranscripts
    case temporaryRecordings
    case salvageBackups
    case retiredMigrations
    case abandonedStagingSessions
    case exportLeases
    case conversationThreads
    case personalMemories
    case expiredMemories
    case erasureLedger
}

/// Why a sweep could not do its work. None of these is a success, and none of them is a reason to
/// abandon the rest of the run except the last.
enum RetentionFault: Error, Equatable {
    /// The data is there but locked. The right answer is to skip and say so — deleting what you
    /// cannot read is not available, and pretending the target was clean would be worse.
    case protectedDataUnavailable
    /// The store this target needs was not wired in.
    case sourceUnavailable
    /// The run stopped part-way. The progress record stays so the next run continues it.
    case interrupted
}

/// The file operations a sweep needs, behind a seam so the boundary, the locked-data case and an
/// interruption can be exercised without a device.
protocol RetentionFileSystem {
    /// Children of `directory` with their creation dates. Throws `.sourceUnavailable` when the
    /// directory is not there and `.protectedDataUnavailable` when it cannot be read.
    func children(of directory: URL) throws -> [(url: URL, created: Date)]
    func remove(at url: URL) throws
}

struct DefaultRetentionFileSystem: RetentionFileSystem {
    private let fileManager: FileManager
    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func children(of directory: URL) throws -> [(url: URL, created: Date)] {
        guard fileManager.fileExists(atPath: directory.path) else { throw RetentionFault.sourceUnavailable }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        } catch {
            throw RetentionFault.protectedDataUnavailable
        }
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let created = values.creationDate else { return nil }
            return (url, created)
        }
    }

    func remove(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

/// One thing the scheduler sweeps: an id, the class whose policy governs it, and the work.
struct RetentionTarget {
    let id: RetentionTargetID
    let dataClass: SensitiveStore.DataClass
    /// Remove everything that expired at `cutoff`; return how many went.
    let purge: (Date) throws -> Int
    /// True when this target removes rows in a store rather than files on disk. Only the receipt
    /// cares, and only so that "3 rows" is not reported as "3 files".
    var removesRows = false
    /// Set where the target does not answer to its class's policy — a record that was written with
    /// its own expiry was given a lifetime by whoever wrote it, and a class-wide "keep everything"
    /// setting is not a licence to break that promise.
    var policyOverride: RetentionPolicy?

    /// A directory whose children expire by age, optionally filtered by name.
    static func directory(_ id: RetentionTargetID,
                          dataClass: SensitiveStore.DataClass,
                          at url: @escaping () -> URL,
                          namePrefix: String? = nil,
                          nameSuffix: String? = nil,
                          fileSystem: RetentionFileSystem) -> RetentionTarget {
        RetentionTarget(id: id, dataClass: dataClass, purge: { cutoff in
            let children = try fileSystem.children(of: url())
            let candidates = children.compactMap { child -> (RetentionCandidate, URL)? in
                let name = child.url.lastPathComponent
                if let namePrefix, !name.hasPrefix(namePrefix) { return nil }
                if let nameSuffix, !name.hasSuffix(nameSuffix) { return nil }
                return (RetentionCandidate(id: name, created: child.created), child.url)
            }
            // The cutoff is already resolved, so the comparison lives in one place: `RetentionPlan`
            // owns "strictly older expires" and this reuses it rather than restating it.
            let policy = RetentionPolicy(dataClass: dataClass, trigger: .maxAge(0), source: "resolved")
            let doomed = RetentionPlan.expired(candidates.map(\.0), policy: policy, now: cutoff)
            let doomedIDs = Set(doomed.map(\.id))
            var removed = 0
            for (candidate, fileURL) in candidates where doomedIDs.contains(candidate.id) {
                try fileSystem.remove(at: fileURL)
                removed += 1
            }
            return removed
        })
    }

    /// Rows in a store, purged by the store's own API.
    static func rows(_ id: RetentionTargetID,
                     dataClass: SensitiveStore.DataClass,
                     policyOverride: RetentionPolicy? = nil,
                     purge: @escaping (Date) throws -> Int) -> RetentionTarget {
        RetentionTarget(id: id, dataClass: dataClass, purge: purge, removesRows: true,
                        policyOverride: policyOverride)
    }
}

/// The progress of a run that has not finished. Persisted so an interrupted cleanup resumes where
/// it stopped instead of starting again and counting the same removals twice.
struct RetentionRunRecord: Codable, Equatable {
    var startedAt: Date
    var completed: [RetentionTargetID]
    var filesRemoved: Int
    var rowsRemoved: Int
    var failures: Int
}

protocol RetentionRunStore: AnyObject {
    var lastCompletedAt: Date? { get set }
    func loadInProgress() -> RetentionRunRecord?
    func saveInProgress(_ record: RetentionRunRecord)
    func clearInProgress()
}

/// The production store: preferences. Target ids and counts only — there is nothing in this record
/// that names anything that was removed, which is why it is not a registered sensitive store.
final class UserDefaultsRetentionRunStore: RetentionRunStore {
    private let defaults: UserDefaults
    private let inProgressKey = "retentionRunInProgress"
    private let lastCompletedKey = "retentionRunLastCompletedAt"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastCompletedAt: Date? {
        get { defaults.object(forKey: lastCompletedKey) as? Date }
        set { defaults.set(newValue, forKey: lastCompletedKey) }
    }

    func loadInProgress() -> RetentionRunRecord? {
        guard let data = defaults.data(forKey: inProgressKey) else { return nil }
        return try? JSONDecoder().decode(RetentionRunRecord.self, from: data)
    }

    func saveInProgress(_ record: RetentionRunRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: inProgressKey)
    }

    func clearInProgress() { defaults.removeObject(forKey: inProgressKey) }
}

/// W03.3 — the durable purge, driven by the store inventory's data classes.
///
/// Three things this deliberately does *not* do. It does not hide rows: every target removes files
/// or deletes rows, because a record that is filtered out of a query is still a record on the disk
/// and still in the next backup. It does not run per missed interval: a device that was off for six
/// months gets one pass with a cutoff computed from now, not a hundred and eighty catch-up passes.
/// And it does not delete what it could not read: a target whose data is locked is skipped and
/// reported, so a clean-looking receipt always means a clean sweep.
///
/// The receipt carries counts and target ids and nothing else. Which transcript went is exactly the
/// fact retention exists to stop keeping.
@MainActor
final class RetentionScheduler {

    struct Skip: Equatable {
        enum Reason: String { case policyOff, capEnforcedOnWrite, protectedDataUnavailable, sourceUnavailable }
        let target: RetentionTargetID
        let reason: Reason
    }

    struct Outcome: Equatable {
        var filesRemoved = 0
        var rowsRemoved = 0
        var failures = 0
        var skips: [Skip] = []
        var completed: [RetentionTargetID] = []
        /// False when the run stopped part-way; the progress record was kept and the next run
        /// continues it. A partial run emits no completion event.
        var finished = true

        var removed: Int { filesRemoved + rowsRemoved }
    }

    private let targets: [RetentionTarget]
    private let settings: () -> RetentionSettings
    private let runStore: RetentionRunStore
    private let clock: () -> Date
    private let interval: TimeInterval
    private weak var audit: HIPAAComplianceService?

    init(targets: [RetentionTarget],
         settings: @escaping () -> RetentionSettings = { .current },
         runStore: RetentionRunStore = UserDefaultsRetentionRunStore(),
         clock: @escaping () -> Date = Date.init,
         interval: TimeInterval = RetentionDefaults.interval,
         audit: HIPAAComplianceService? = nil) {
        self.targets = targets
        self.settings = settings
        self.runStore = runStore
        self.clock = clock
        self.interval = interval
        self.audit = audit
    }

    // MARK: - Scheduling

    /// When the next run is allowed. Nil means "now" — nothing has run yet.
    var nextDue: Date? {
        runStore.lastCompletedAt.map { $0.addingTimeInterval(interval) }
    }

    /// The cheap check the launch and foreground hooks make: two date comparisons and a preference
    /// read, so calling it on every activation costs nothing when nothing is due.
    var isDue: Bool {
        if runStore.loadInProgress() != nil { return true }   // an interrupted run always resumes
        guard let nextDue else { return true }
        return clock() >= nextDue
    }

    /// Run only if due. Returns nil when it was not.
    @discardableResult
    func runIfDue() -> Outcome? {
        guard isDue else { return nil }
        return run()
    }

    // MARK: - The run

    @discardableResult
    func run() -> Outcome {
        let now = clock()
        let current = settings()
        var outcome = Outcome()

        // Resume an interrupted run rather than starting a new one, so its removals are counted
        // once. A record older than a day is stale — the run it belonged to is long gone and its
        // counts would be reported under today's receipt — so it is dropped and the run starts.
        var record: RetentionRunRecord
        if let inProgress = runStore.loadInProgress(),
           now.timeIntervalSince(inProgress.startedAt) < 24 * 3600 {
            record = inProgress
            outcome.filesRemoved = inProgress.filesRemoved
            outcome.rowsRemoved = inProgress.rowsRemoved
            outcome.failures = inProgress.failures
            outcome.completed = inProgress.completed
        } else {
            record = RetentionRunRecord(startedAt: now, completed: [],
                                        filesRemoved: 0, rowsRemoved: 0, failures: 0)
        }
        runStore.saveInProgress(record)

        for target in targets {
            if record.completed.contains(target.id) { continue }

            let policy = target.policyOverride
                ?? RetentionPolicyBook.policy(for: target.dataClass, settings: current)
            switch policy.trigger {
            case .off:
                // Not swept, and not marked done either — a policy that is turned on tomorrow
                // must find this target waiting rather than ticked off.
                outcome.skips.append(Skip(target: target.id, reason: .policyOff))
                PrivacyLog.store(.retention, .saveSkipped, slot: PrivacyToken(target.id.rawValue),
                                 detail: PrivacyToken(Skip.Reason.policyOff.rawValue))
                continue
            case .capEnforcedOnWrite:
                outcome.skips.append(Skip(target: target.id, reason: .capEnforcedOnWrite))
                continue
            case .maxAge:
                break
            }
            guard let cutoff = policy.cutoff(from: now) else { continue }

            do {
                let removed = try target.purge(cutoff)
                if target.removesRows {
                    outcome.rowsRemoved += removed
                    record.rowsRemoved += removed
                } else {
                    outcome.filesRemoved += removed
                    record.filesRemoved += removed
                }
                record.completed.append(target.id)
                outcome.completed.append(target.id)
                if removed > 0 {
                    PrivacyLog.store(.retention, .evicted, slot: PrivacyToken(target.id.rawValue),
                                     count: removed)
                }
            } catch RetentionFault.interrupted {
                // The process is going away. Keep the record exactly as it is: the next run picks
                // up at this target, and nothing already counted is counted again.
                runStore.saveInProgress(record)
                outcome.finished = false
                PrivacyLog.store(.retention, .saveSkipped, slot: PrivacyToken(target.id.rawValue),
                                 detail: PrivacyToken("interrupted"))
                return outcome
            } catch let fault as RetentionFault {
                let reason: Skip.Reason = fault == .protectedDataUnavailable
                    ? .protectedDataUnavailable : .sourceUnavailable
                outcome.skips.append(Skip(target: target.id, reason: reason))
                PrivacyLog.store(.retention, .saveSkipped, slot: PrivacyToken(target.id.rawValue),
                                 detail: PrivacyToken(reason.rawValue))
            } catch {
                outcome.failures += 1
                record.failures += 1
                PrivacyLog.store(.retention, .deleteFailed, slot: PrivacyToken(target.id.rawValue),
                                 error: SafeErrorSummary(error))
            }
            runStore.saveInProgress(record)
        }

        runStore.clearInProgress()
        runStore.lastCompletedAt = now

        PrivacyLog.store(.retention, .cleared, count: outcome.removed,
                         total: targets.count - outcome.skips.count)
        if outcome.removed > 0 || outcome.failures > 0 {
            audit?.record(.retentionPurgeCompleted, target: .dataStore,
                          purpose: .retentionPolicy,
                          result: outcome.failures > 0 ? .failed : .succeeded,
                          count: outcome.removed)
        }
        return outcome
    }
}

// MARK: - The production wiring

extension RetentionScheduler {

    /// The stores a run needs. Everything optional: an absent store is a reported skip, not a
    /// silently missing sweep.
    @MainActor
    struct Sources {
        var conversations: ConversationStore?
        var semanticMemory: SemanticMemoryStore?
        var transcriptsDirectory: () -> URL = {
            Config.transcriptFolderURL
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Transcripts")
        }
        var documentsDirectory: () -> URL = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        }
        var cachesDirectory: () -> URL = {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        }
        var temporaryDirectory: () -> URL = { FileManager.default.temporaryDirectory }
        /// Sweeps the export leases and returns how many sessions went.
        var sweepExportLeases: (() -> Int)?
        /// The record of completed erasures. It has its own retention rule because it is the one
        /// place, besides a queued tombstone, where a forgotten name is still written down.
        var erasureLedger: ErasureLedger?

        init() {}
    }

    /// The target list, in the order a run walks it. Cheap and local first, so an interruption
    /// leaves the expensive work rather than the trivial work undone.
    static func targets(sources: Sources,
                        fileSystem: RetentionFileSystem = DefaultRetentionFileSystem())
    -> [RetentionTarget] {
        var made: [RetentionTarget] = [
            .directory(.temporaryRecordings, dataClass: .clinical,
                       at: sources.temporaryDirectory, namePrefix: "OpenGlasses_",
                       fileSystem: fileSystem),
            .directory(.clinicalTranscripts, dataClass: .clinical,
                       at: sources.transcriptsDirectory, fileSystem: fileSystem),
            .directory(.salvageBackups, dataClass: .derivedIndex,
                       at: { sources.documentsDirectory().appendingPathComponent("StoreRecovery",
                                                                                 isDirectory: true) },
                       nameSuffix: ".corrupt.json", fileSystem: fileSystem),
            .directory(.retiredMigrations, dataClass: .derivedIndex,
                       at: sources.documentsDirectory, nameSuffix: ".migrated",
                       fileSystem: fileSystem),
            .directory(.abandonedStagingSessions, dataClass: .exportArtifact,
                       at: { sources.cachesDirectory().appendingPathComponent("SkillPackSideload",
                                                                             isDirectory: true) },
                       fileSystem: fileSystem),
        ]
        if let sweep = sources.sweepExportLeases {
            // Counted as files: a lease is a directory of them, not a row.
            made.append(RetentionTarget(id: .exportLeases, dataClass: .exportArtifact,
                                        purge: { _ in sweep() }))
        }
        // A memory carrying its own `expires_at` was given a lifetime when it was written, so it
        // is purged on that promise and not on the class policy. Until now that promise was kept
        // only by skipping the row on read, which left it on disk and in every backup.
        made.append(.rows(.expiredMemories, dataClass: .personalMemory,
                          policyOverride: RetentionPolicy(
                            dataClass: .personalMemory, trigger: .maxAge(0),
                            source: "each record's own expires_at")) { _ in
            guard let memory = sources.semanticMemory else { throw RetentionFault.sourceUnavailable }
            return memory.purgeExpired(now: Date())
        })
        made.append(.rows(.personalMemories, dataClass: .personalMemory) { cutoff in
            guard let memory = sources.semanticMemory else { throw RetentionFault.sourceUnavailable }
            return memory.purge(olderThan: cutoff)
        })
        if let ledger = sources.erasureLedger {
            made.append(.rows(.erasureLedger, dataClass: .derivedIndex,
                              policyOverride: RetentionPolicy(
                                dataClass: .derivedIndex,
                                trigger: .maxAge(ErasureReplay.window),
                                source: "the replay window: past it the entry can do nothing")) { cutoff in
                ledger.purge(olderThan: cutoff)
            })
        }
        made.append(.rows(.conversationThreads, dataClass: .conversationContent) { cutoff in
            guard let conversations = sources.conversations else {
                throw RetentionFault.sourceUnavailable
            }
            return conversations.deleteThreads(olderThan: cutoff)
        })
        return made
    }
}
