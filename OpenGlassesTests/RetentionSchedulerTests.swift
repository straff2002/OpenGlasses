import XCTest
@testable import OpenGlasses

/// W03.3 — the purge has to be right about time, honest about what it could not reach, and safe to
/// interrupt. Each of those is a way to lose somebody's records or to claim a clean sweep that was
/// not one, so each has a test with the clock in its hand.
@MainActor
final class RetentionSchedulerTests: XCTestCase {

    // MARK: - Doubles

    /// A file system that answers from a table, so a boundary can be posed to the second and a
    /// locked store can be posed at all.
    private final class FakeFileSystem: RetentionFileSystem {
        var contents: [URL: [(url: URL, created: Date)]] = [:]
        /// Directories that exist but cannot be read — protected data while the device is locked.
        var locked: Set<URL> = []
        /// Directories that are not there at all.
        var missing: Set<URL> = []
        /// Throw an interruption when this URL is swept, standing in for the process going away.
        var interruptAt: URL?
        private(set) var removed: [URL] = []
        private(set) var listed: [URL] = []

        func children(of directory: URL) throws -> [(url: URL, created: Date)] {
            listed.append(directory)
            if missing.contains(directory) { throw RetentionFault.sourceUnavailable }
            if locked.contains(directory) { throw RetentionFault.protectedDataUnavailable }
            if interruptAt == directory { throw RetentionFault.interrupted }
            return contents[directory] ?? []
        }

        func remove(at url: URL) throws {
            removed.append(url)
        }
    }

    private final class MemoryRunStore: RetentionRunStore {
        var lastCompletedAt: Date?
        var inProgress: RetentionRunRecord?
        private(set) var saves = 0

        func loadInProgress() -> RetentionRunRecord? { inProgress }
        func saveInProgress(_ record: RetentionRunRecord) { inProgress = record; saves += 1 }
        func clearInProgress() { inProgress = nil }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL { URL(fileURLWithPath: "/fake/Documents", isDirectory: true) }

    private func settings(clinical: Int = 30, history: Int = 0) -> RetentionSettings {
        RetentionSettings(clinicalDays: clinical, wearerHistoryDays: history)
    }

    // MARK: - The pure boundary

    func testARecordExactlyAtTheCutoffIsInsideThePeriodAndStays() {
        let policy = RetentionPolicy(dataClass: .clinical, trigger: .maxAge(30 * 86_400),
                                     source: "test")
        let cutoff = try! XCTUnwrap(policy.cutoff(from: now))
        let atTheCutoff = RetentionCandidate(id: "a", created: cutoff)
        let aSecondPast = RetentionCandidate(id: "b", created: cutoff.addingTimeInterval(-1))
        let aSecondInside = RetentionCandidate(id: "c", created: cutoff.addingTimeInterval(1))

        let expired = RetentionPlan.expired([atTheCutoff, aSecondPast, aSecondInside],
                                            policy: policy, now: now)
        XCTAssertEqual(expired.map(\.id), ["b"],
                       "a period of N days must keep N days: only strictly older expires")
    }

    func testNothingExpiresUnderAPolicyThatIsOff() {
        let policy = RetentionPolicy(dataClass: .personalMemory, trigger: .off("wearer has not asked"),
                                     source: "test")
        XCTAssertNil(policy.cutoff(from: now))
        let ancient = RetentionCandidate(id: "a", created: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(RetentionPlan.expired([ancient], policy: policy, now: now).isEmpty)
    }

    // MARK: - The register

    func testTheHistoryPolicyIsOffUntilTheWearerAsksForIt() {
        for dataClass in [SensitiveStore.DataClass.conversationContent, .personalMemory] {
            let off = RetentionPolicyBook.policy(for: dataClass, settings: settings(history: 0))
            XCTAssertNil(off.cutoff(from: now), "\(dataClass.rawValue) expires by default")
            if case .off(let reason) = off.trigger {
                XCTAssertFalse(reason.isEmpty, "a policy that is off has to say why")
            } else {
                XCTFail("\(dataClass.rawValue) should be off at zero days")
            }
            let on = RetentionPolicyBook.policy(for: dataClass, settings: settings(history: 30))
            XCTAssertEqual(on.cutoff(from: now), now.addingTimeInterval(-30 * 86_400))
        }
    }

    func testClinicalRetentionIsDisabledAtZeroAndOtherwiseHonoured() {
        let off = RetentionPolicyBook.policy(for: .clinical, settings: settings(clinical: 0))
        XCTAssertNil(off.cutoff(from: now))
        let on = RetentionPolicyBook.policy(for: .clinical, settings: settings(clinical: 90))
        XCTAssertEqual(on.cutoff(from: now), now.addingTimeInterval(-90 * 86_400))
    }

    func testEveryDataClassHasAPolicyAndEveryDisabledOneGivesAReason() {
        let register = RetentionPolicyBook.all(settings: settings())
        XCTAssertEqual(register.count, 15)
        for policy in register {
            XCTAssertFalse(policy.source.isEmpty, "\(policy.dataClass.rawValue) has no attribution")
            if case .off(let reason) = policy.trigger {
                XCTAssertGreaterThan(reason.count, 20,
                                     "\(policy.dataClass.rawValue) is off without saying why")
            }
        }
    }

    // MARK: - Sweeps

    private func directoryTarget(_ id: RetentionTargetID = .clinicalTranscripts,
                                 dataClass: SensitiveStore.DataClass = .clinical,
                                 at url: URL,
                                 nameSuffix: String? = nil,
                                 fileSystem: RetentionFileSystem) -> RetentionTarget {
        .directory(id, dataClass: dataClass, at: { url }, nameSuffix: nameSuffix,
                   fileSystem: fileSystem)
    }

    func testASweepRemovesOnlyWhatIsPastTheCutoff() {
        let fs = FakeFileSystem()
        let old = root.appendingPathComponent("old.txt")
        let fresh = root.appendingPathComponent("fresh.txt")
        fs.contents[root] = [
            (old, now.addingTimeInterval(-40 * 86_400)),
            (fresh, now.addingTimeInterval(-2 * 86_400)),
        ]
        let store = MemoryRunStore()
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: store, clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(fs.removed, [old])
        XCTAssertEqual(outcome.filesRemoved, 1)
        XCTAssertEqual(outcome.failures, 0)
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(store.lastCompletedAt, now)
        XCTAssertNil(store.inProgress, "a finished run leaves no progress record behind")
    }

    /// The `.migrated` case the inventory called out by name: a legacy blob renamed aside during a
    /// migration, which used to sit in Documents forever holding a full copy of the memories.
    func testStaleMigrationLeftoversAreSweptAndFreshOnesAreNot() {
        let fs = FakeFileSystem()
        let stale = root.appendingPathComponent("user_memories.json.migrated")
        let recent = root.appendingPathComponent("other.json.migrated")
        let unrelated = root.appendingPathComponent("conversations.json")
        fs.contents[root] = [
            (stale, now.addingTimeInterval(-RetentionDefaults.leftoverMaxAge - 60)),
            (recent, now.addingTimeInterval(-60)),
            (unrelated, Date(timeIntervalSince1970: 0)),
        ]
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(.retiredMigrations, dataClass: .derivedIndex, at: root,
                                      nameSuffix: ".migrated", fileSystem: fs)],
            settings: { self.settings() }, runStore: MemoryRunStore(), clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(fs.removed, [stale])
        XCTAssertEqual(outcome.filesRemoved, 1)
        XCTAssertFalse(fs.removed.contains(unrelated),
                       "the live store sitting beside the leftover must not be touched")
    }

    func testAPurgeNeverTouchesAStoreWhosePolicyIsOff() {
        let fs = FakeFileSystem()
        let ancient = root.appendingPathComponent("ancient.json")
        fs.contents[root] = [(ancient, Date(timeIntervalSince1970: 0))]
        let store = MemoryRunStore()
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(.conversationThreads, dataClass: .conversationContent,
                                      at: root, fileSystem: fs)],
            settings: { self.settings(history: 0) }, runStore: store, clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertTrue(fs.removed.isEmpty)
        XCTAssertTrue(fs.listed.isEmpty, "a target whose policy is off must not even be read")
        XCTAssertEqual(outcome.skips, [.init(target: .conversationThreads, reason: .policyOff)])
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertFalse(outcome.completed.contains(.conversationThreads),
                       "a skipped target must not be ticked off; turning the policy on later has "
                           + "to find it waiting")
    }

    func testACapEnforcedOnWriteIsRecordedRatherThanSwept() {
        let fs = FakeFileSystem()
        fs.contents[root] = [(root.appendingPathComponent("a"), Date(timeIntervalSince1970: 0))]
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(.exportLeases, dataClass: .operationalAudit, at: root,
                                      fileSystem: fs)],
            settings: { self.settings() }, runStore: MemoryRunStore(), clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(outcome.skips.map(\.reason), [.capEnforcedOnWrite])
        XCTAssertTrue(fs.removed.isEmpty)
    }

    // MARK: - Locked and missing data

    func testLockedProtectedDataIsSkippedAndReportedRatherThanCountedClean() {
        let fs = FakeFileSystem()
        fs.locked = [root]
        let other = URL(fileURLWithPath: "/fake/tmp", isDirectory: true)
        let doomed = other.appendingPathComponent("OpenGlasses_old.m4a")
        fs.contents[other] = [(doomed, now.addingTimeInterval(-90 * 86_400))]

        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs),
                      directoryTarget(.temporaryRecordings, at: other, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: MemoryRunStore(),
            clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(outcome.skips,
                       [.init(target: .clinicalTranscripts, reason: .protectedDataUnavailable)])
        XCTAssertEqual(outcome.filesRemoved, 1, "the rest of the run still happens")
        XCTAssertEqual(fs.removed, [doomed])
        XCTAssertFalse(outcome.completed.contains(.clinicalTranscripts),
                       "what could not be read must not be recorded as swept")
    }

    func testAnAbsentSourceIsReportedAsUnavailableNotAsAFailure() {
        let fs = FakeFileSystem()
        fs.missing = [root]
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: MemoryRunStore(),
            clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(outcome.skips, [.init(target: .clinicalTranscripts, reason: .sourceUnavailable)])
        XCTAssertEqual(outcome.failures, 0)
    }

    // MARK: - Interruption

    func testAnInterruptedRunResumesWithoutCountingItsRemovalsTwice() {
        let fs = FakeFileSystem()
        let first = root.appendingPathComponent("first.txt")
        let second = URL(fileURLWithPath: "/fake/second", isDirectory: true)
        let third = URL(fileURLWithPath: "/fake/third", isDirectory: true)
        let thirdVictim = third.appendingPathComponent("third.txt")
        fs.contents[root] = [(first, Date(timeIntervalSince1970: 0))]
        fs.contents[second] = []
        fs.contents[third] = [(thirdVictim, Date(timeIntervalSince1970: 0))]
        fs.interruptAt = second

        let store = MemoryRunStore()
        let targets = [
            directoryTarget(.clinicalTranscripts, at: root, fileSystem: fs),
            directoryTarget(.temporaryRecordings, at: second, fileSystem: fs),
            directoryTarget(.salvageBackups, dataClass: .derivedIndex, at: third, fileSystem: fs),
        ]
        let scheduler = RetentionScheduler(targets: targets, settings: { self.settings(clinical: 30) },
                                           runStore: store, clock: { self.now })

        let partial = scheduler.run()
        XCTAssertFalse(partial.finished)
        XCTAssertEqual(partial.filesRemoved, 1)
        XCTAssertEqual(fs.removed, [first])
        let record = try! XCTUnwrap(store.inProgress)
        XCTAssertEqual(record.completed, [.clinicalTranscripts])
        XCTAssertEqual(record.filesRemoved, 1)

        // The process came back. The interruption is over, and the run continues.
        fs.interruptAt = nil
        let resumed = RetentionScheduler(targets: targets, settings: { self.settings(clinical: 30) },
                                         runStore: store, clock: { self.now.addingTimeInterval(60) })
        let outcome = resumed.run()

        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.filesRemoved, 2, "one from before the interruption and one after")
        XCTAssertEqual(fs.removed, [first, thirdVictim],
                       "the target that already completed must not be swept a second time")
        XCTAssertNil(store.inProgress)
    }

    func testAStaleProgressRecordIsDroppedRatherThanReportedUnderTodaysReceipt() {
        let fs = FakeFileSystem()
        fs.contents[root] = []
        let store = MemoryRunStore()
        store.inProgress = RetentionRunRecord(startedAt: now.addingTimeInterval(-40 * 3600),
                                              completed: [.clinicalTranscripts],
                                              filesRemoved: 99, rowsRemoved: 0, failures: 0)
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: store, clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(outcome.filesRemoved, 0, "yesterday's count must not land on today's receipt")
        XCTAssertEqual(outcome.completed, [.clinicalTranscripts])
    }

    // MARK: - Scheduling

    func testTheDueCheckIsCheapAndDoesNotRunTwiceInAnInterval() {
        let fs = FakeFileSystem()
        fs.contents[root] = []
        let store = MemoryRunStore()
        let clock = ClockBox(now)
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: store,
            clock: { clock.value }, interval: 6 * 3600)

        XCTAssertTrue(scheduler.isDue, "nothing has run yet")
        XCTAssertNotNil(scheduler.runIfDue())
        XCTAssertEqual(scheduler.nextDue, now.addingTimeInterval(6 * 3600))

        clock.value = now.addingTimeInterval(3600)
        XCTAssertFalse(scheduler.isDue)
        XCTAssertNil(scheduler.runIfDue(), "a foreground inside the interval does no work")

        clock.value = now.addingTimeInterval(7 * 3600)
        XCTAssertTrue(scheduler.isDue)
        XCTAssertNotNil(scheduler.runIfDue())
    }

    /// A phone that was off for half a year gets one pass with the cutoff computed from now — not
    /// one pass per missed interval, and not a window that starts where the last run left off.
    func testALongOfflineGapProducesOnePassWithACutoffTakenFromNow() {
        let fs = FakeFileSystem()
        let recent = root.appendingPathComponent("recent.txt")
        let ancient = root.appendingPathComponent("ancient.txt")
        let returned = now.addingTimeInterval(180 * 86_400)
        fs.contents[root] = [
            (recent, returned.addingTimeInterval(-10 * 86_400)),
            (ancient, returned.addingTimeInterval(-100 * 86_400)),
        ]
        let store = MemoryRunStore()
        store.lastCompletedAt = now

        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: store, clock: { returned })

        XCTAssertTrue(scheduler.isDue)
        let outcome = scheduler.run()

        XCTAssertEqual(fs.removed, [ancient])
        XCTAssertEqual(fs.listed.count, 1, "one pass, not one per missed interval")
        XCTAssertEqual(outcome.filesRemoved, 1)
        XCTAssertEqual(store.lastCompletedAt, returned)
    }

    func testAnInterruptedRunIsDueImmediatelyEvenInsideTheInterval() {
        let fs = FakeFileSystem()
        fs.contents[root] = []
        let store = MemoryRunStore()
        store.lastCompletedAt = now
        store.inProgress = RetentionRunRecord(startedAt: now, completed: [],
                                              filesRemoved: 0, rowsRemoved: 0, failures: 0)
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: store,
            clock: { self.now.addingTimeInterval(60) })

        XCTAssertTrue(scheduler.isDue)
    }

    // MARK: - Rows

    func testRowTargetsCountAsRowsAndReportAnAbsentStore() {
        var purged: [Date] = []
        let store = MemoryRunStore()
        let scheduler = RetentionScheduler(
            targets: [
                .rows(.conversationThreads, dataClass: .conversationContent) { cutoff in
                    purged.append(cutoff)
                    return 3
                },
                .rows(.personalMemories, dataClass: .personalMemory) { _ in
                    throw RetentionFault.sourceUnavailable
                },
            ],
            settings: { self.settings(history: 30) }, runStore: store, clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertEqual(purged, [now.addingTimeInterval(-30 * 86_400)])
        XCTAssertEqual(outcome.rowsRemoved, 3)
        XCTAssertEqual(outcome.filesRemoved, 0)
        XCTAssertEqual(outcome.skips, [.init(target: .personalMemories, reason: .sourceUnavailable)])
    }

    /// A memory written with its own expiry was given a lifetime by whoever wrote it. A class-wide
    /// "keep everything" is not permission to break that.
    func testAPerRecordExpiryIsHonouredEvenWhileTheClassPolicyIsOff() {
        var ran = false
        let scheduler = RetentionScheduler(
            targets: [.rows(.expiredMemories, dataClass: .personalMemory,
                            policyOverride: RetentionPolicy(dataClass: .personalMemory,
                                                            trigger: .maxAge(0),
                                                            source: "each record's own expires_at")) { _ in
                ran = true
                return 2
            }],
            settings: { self.settings(history: 0) }, runStore: MemoryRunStore(), clock: { self.now })

        let outcome = scheduler.run()

        XCTAssertTrue(ran)
        XCTAssertEqual(outcome.rowsRemoved, 2)
        XCTAssertTrue(outcome.skips.isEmpty)
    }

    // MARK: - The receipt

    func testTheReceiptCarriesCountsAndTargetNamesAndNothingElse() {
        let fs = FakeFileSystem()
        let victim = root.appendingPathComponent("2019-03-01 biopsy.txt")
        fs.contents[root] = [(victim, Date(timeIntervalSince1970: 0))]
        let scheduler = RetentionScheduler(
            targets: [directoryTarget(at: root, fileSystem: fs)],
            settings: { self.settings(clinical: 30) }, runStore: MemoryRunStore(),
            clock: { self.now })

        var lines: [String] = []
        let token = PrivacyLog.addTap { _, line in lines.append(line) }
        defer { PrivacyLog.removeTap(token) }

        _ = scheduler.run()

        let retention = lines.filter { $0.contains("store=retention") }
        XCTAssertFalse(retention.isEmpty, "the run emitted no receipt")
        for line in retention {
            XCTAssertFalse(line.contains("biopsy"), "a purged filename reached the log: \(line)")
            XCTAssertFalse(line.contains("/fake/"), "a path reached the log: \(line)")
        }
        XCTAssertTrue(retention.contains { $0.contains("event=cleared") && $0.contains("count=1") })
    }
}

/// A clock a test can move.
private final class ClockBox {
    var value: Date
    init(_ value: Date) { self.value = value }
}
