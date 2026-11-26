import XCTest
@testable import OpenGlasses

/// Plan NH §3 — the ledger: local-midnight days in any time zone, what it keeps, and its place in
/// the data-store inventory. Every ledger here is over a temporary directory.
final class AssistantTimeLedgerTests: XCTestCase {

    private var workspace: URL!

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantTimeLedgerTests_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private static func date(_ text: String, in zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    // MARK: - Midnight

    func testTheDayResetsAtLocalMidnight() {
        let zone = "Pacific/Auckland"
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        let lateNight = Self.date("2026-11-25 23:59:30", in: zone)
        let afterMidnight = Self.date("2026-11-26 00:00:30", in: zone)
        ledger.add(600, at: lateNight)
        XCTAssertEqual(ledger.secondsUsed(on: lateNight), 600)
        XCTAssertEqual(ledger.secondsUsed(on: afterMidnight), 0, "the minutes come back at midnight")
        ledger.add(20, at: afterMidnight)
        XCTAssertEqual(ledger.secondsUsed(on: afterMidnight), 20)
        XCTAssertEqual(ledger.secondsUsed(on: lateNight), 600, "yesterday is kept, not added to")
    }

    func testMidnightIsTheZoneThePhoneIsIn() {
        // 10:30 on 25 November in Auckland is 13:30 on 24 November in Los Angeles.
        let instant = Self.date("2026-11-25 10:30:00", in: "Pacific/Auckland")
        var zone = "Pacific/Auckland"
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        XCTAssertEqual(ledger.dayKey(for: instant), "2026-11-25")
        ledger.add(300, at: instant)

        zone = "America/Los_Angeles"
        XCTAssertEqual(ledger.dayKey(for: instant), "2026-11-24")
        XCTAssertEqual(ledger.secondsUsed(on: instant), 0,
                       "after flying east to west it is a different local day")
        zone = "Pacific/Auckland"
        XCTAssertEqual(ledger.secondsUsed(on: instant), 300)
    }

    func testUTCMidnightIsNotTheBoundaryForALocalDay() {
        let zone = "America/New_York"
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        let evening = Self.date("2026-11-25 20:00:00", in: zone)   // 01:00 UTC on the 26th
        let laterEvening = Self.date("2026-11-25 23:00:00", in: zone)
        ledger.add(100, at: evening)
        ledger.add(50, at: laterEvening)
        XCTAssertEqual(ledger.secondsUsed(on: laterEvening), 150)
    }

    // MARK: - What it keeps

    func testACountSurvivesARelaunch() {
        let zone = "Europe/London"
        let day = Self.date("2026-11-25 12:00:00", in: zone)
        let first = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        first.add(42, at: day)
        let second = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        XCTAssertEqual(second.secondsUsed(on: day), 42)
    }

    func testALiveSecondIsWrittenAtMostEveryFifteenSecondsAndOnFlush() {
        let zone = "Europe/London"
        let start = Self.date("2026-11-25 12:00:00", in: zone)
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        ledger.add(1, at: start, immediately: false)       // first write: nothing written before
        for second in 1...5 { ledger.add(1, at: start.addingTimeInterval(TimeInterval(second)), immediately: false) }
        XCTAssertEqual(ledger.secondsUsed(on: start), 6, "in memory at once")
        XCTAssertEqual(AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
                        .secondsUsed(on: start), 1, "on disk only at the write interval")
        ledger.flush()
        XCTAssertEqual(AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
                        .secondsUsed(on: start), 6)
    }

    func testOnlyAWeekIsKept() {
        let zone = "Europe/London"
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        let first = Self.date("2026-11-01 12:00:00", in: zone)
        for day in 0..<10 { ledger.add(10, at: first.addingTimeInterval(TimeInterval(day) * 86_400)) }
        let data = try? Data(contentsOf: ledger.fileLocation)
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let days = json?["days"] as? [String: Int]
        XCTAssertEqual(days?.count, AssistantTimeLedger.keptDays)
        XCTAssertNil(days?["2026-11-01"])
        XCTAssertEqual(days?["2026-11-10"], 10)
    }

    func testDeleteAllClearsTheFile() {
        let zone = "Europe/London"
        let day = Self.date("2026-11-25 12:00:00", in: zone)
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { Self.calendar(zone) })
        ledger.add(30, at: day)
        ledger.deleteAll()
        XCTAssertEqual(ledger.secondsUsed(on: day), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.fileLocation.path))
        XCTAssertEqual(AssistantTimeLedger(directory: workspace).secondsUsed(on: day), 0)
    }

    // MARK: - The inventory

    func testTheLedgerIsRegisteredWithTheDataStoreRegistry() {
        let record = SensitiveStore.assistantTime.record
        XCTAssertEqual(record.owner, "AssistantTimeLedger")
        XCTAssertEqual(record.ownerPaths, ["OpenGlasses/Sources/Services/Allowance/AssistantTimeLedger.swift"])
        XCTAssertEqual(record.subjectLinkage, .wearer)
        XCTAssertEqual(record.protection, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(record.backupExcluded, "on the phone only: never in a backup")
        XCTAssertEqual(record.deleteAll, .api("AssistantTimeLedger.deleteAll()"))
        XCTAssertEqual(AssistantTimeLedger.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(SensitiveStore.registeredPaths.contains(record.ownerPaths[0]))
    }

    /// A subject erasure looks for a named person. The ledger holds day keys and seconds, so the
    /// registry says it has no subject to erase, and the walk accounts for that rather than
    /// skipping it silently: the coordinator walks every store with a subject delete, and this one
    /// declares none.
    @MainActor
    func testTheSubjectErasureWalkAccountsForTheLedger() {
        let record = SensitiveStore.assistantTime.record
        XCTAssertEqual(record.deleteSubject, .notSubjectLinked)
        XCTAssertNotEqual(record.subjectLinkage, .thirdPartySubject)
        XCTAssertFalse(record.deleteSubject.isAvailable)
        XCTAssertFalse(SubjectErasureCoordinator.order.contains(.assistantTime),
                       "nothing to erase per person; deleteAll() clears it")
    }

    func testTheFileIsOutOfBackupAndProtectedAsTheRegistrySays() throws {
        let ledger = AssistantTimeLedger(directory: workspace)
        ledger.add(5, at: Date())
        let url = ledger.fileLocation
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        XCTAssertTrue(excluded)
        if let actual = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(actual, .completeUntilFirstUserAuthentication)
        }
        XCTAssertTrue(url.path.contains("/Allowance") || url.path.contains(workspace.path))
    }

    func testTheDefaultFolderIsApplicationSupportNotICloud() {
        let folder = AssistantTimeLedger.defaultDirectory().path
        XCTAssertTrue(folder.contains("Application Support"), folder)
        XCTAssertFalse(folder.contains("Mobile Documents"), "never the iCloud container")
    }
}
