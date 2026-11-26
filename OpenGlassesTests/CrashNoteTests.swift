import XCTest
#if canImport(MetricKit)
import MetricKit
#endif
@testable import OpenGlasses

/// Plan MB P0: what the phone keeps of a crash, from the system's own JSON.
final class CrashNoteTests: XCTestCase {

    static let utc = TimeZone(identifier: "UTC")!

    /// A SIGABRT raised by UIKit's list-update assertion — the shape build 688 crashed with.
    static let sigabrtPayload = """
    {
      "timeStampBegin": "2026-11-16 21:45:00",
      "timeStampEnd": "2026-11-16 21:45:00",
      "crashDiagnostics": [{
        "version": "1.0.0",
        "callStackTree": {
          "callStackPerThread": true,
          "callStacks": [
            { "threadAttributed": false, "callStackRootFrames": [
              { "binaryName": "libsystem_kernel.dylib", "binaryUUID": "11111111-2222-3333-4444-555555555555",
                "offsetIntoBinaryTextSegment": 4096, "address": 7000, "sampleCount": 1, "subFrames": [] } ] },
            { "threadAttributed": true, "callStackRootFrames": [
              { "binaryName": "libsystem_kernel.dylib", "binaryUUID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "offsetIntoBinaryTextSegment": 38756, "address": 1, "sampleCount": 1, "subFrames": [
                { "binaryName": "UIKitCore", "binaryUUID": "0b4c6a0e-1111-2222-3333-444455556666",
                  "offsetIntoBinaryTextSegment": 1234567, "address": 2, "sampleCount": 1, "subFrames": [
                  { "binaryName": "OpenGlasses", "binaryUUID": "9f8e7d6c-5b4a-3928-1716-151413121110",
                    "offsetIntoBinaryTextSegment": 98304, "address": 3, "sampleCount": 1, "subFrames": [] } ] } ] } ] }
          ]
        },
        "diagnosticMetaData": {
          "appBuildVersion": "688",
          "appVersion": "1.4",
          "osVersion": "iPhone OS 26.1 (23B85)",
          "deviceType": "iPhone17,1",
          "exceptionType": 10,
          "exceptionCode": 0,
          "signal": 6,
          "terminationReason": "Namespace SIGNAL, Code 6",
          "objectiveCexceptionReason": {
            "composedMessage": "Invalid update: invalid number of items in section 0. The number of items after the update (3) must be equal to the number before (2). Row text: Jane Smith, 12 High St",
            "formatString": "Invalid update: invalid number of items in section %ld. The number of items after the update (%ld) must be equal to the number before (%ld). %@",
            "arguments": ["0", "3", "2", "Row text: Jane Smith, 12 High St"],
            "exceptionType": "NSInternalInconsistencyException",
            "className": "UICollectionView",
            "exceptionName": "NSInternalInconsistencyException"
          }
        }
      }]
    }
    """

    static let sigsegvPayload = """
    {
      "timeStampBegin": "2026-11-17 08:10:00",
      "timeStampEnd": "2026-11-17 08:10:00",
      "crashDiagnostics": [{
        "callStackTree": { "callStackPerThread": true, "callStacks": [
          { "threadAttributed": true, "callStackRootFrames": [
            { "binaryName": "OpenGlasses", "binaryUUID": "9f8e7d6c-5b4a-3928-1716-151413121110",
              "offsetIntoBinaryTextSegment": 4660, "sampleCount": 1, "subFrames": [] } ] } ] },
        "diagnosticMetaData": {
          "appBuildVersion": "777", "appVersion": "1.5", "osVersion": "iPhone OS 26.2 (23C55)",
          "exceptionType": 1, "exceptionCode": 0, "signal": 11,
          "terminationReason": "Namespace SIGNAL, Code 0xb",
          "virtualMemoryRegionInfo": "0 is not in any region."
        }
      }]
    }
    """

    static let watchdogPayload = """
    {
      "timeStampBegin": "2026-11-18 12:00:00",
      "timeStampEnd": "2026-11-18 12:00:00",
      "crashDiagnostics": [{
        "callStackTree": { "callStackPerThread": true, "callStacks": [] },
        "diagnosticMetaData": {
          "appBuildVersion": "777", "appVersion": "1.5", "osVersion": "iPhone OS 26.2 (23C55)",
          "exceptionType": 10, "exceptionCode": 0, "signal": 9,
          "terminationReason": "Namespace FRONTBOARD, Code 0x8badf00d"
        }
      }]
    }
    """

    static let hangOnlyPayload = """
    {
      "timeStampBegin": "2026-11-18 12:00:00",
      "timeStampEnd": "2026-11-19 12:00:00",
      "hangDiagnostics": [{ "diagnosticMetaData": { "hangDuration": "3 sec" } }]
    }
    """

    static func note(_ json: String) -> CrashNote? {
        CrashNote.notes(fromPayloadJSON: Data(json.utf8), timeZone: utc).first
    }

    // MARK: - From the payload

    func testASigabrtWithAnObjCExceptionKeepsTheFormatAndNumbersOnly() throws {
        let note = try XCTUnwrap(Self.note(Self.sigabrtPayload))
        XCTAssertEqual(note.build, "688")
        XCTAssertEqual(note.signal, 6)
        XCTAssertEqual(note.exception?.name, "NSInternalInconsistencyException")
        XCTAssertEqual(note.exception?.className, "UICollectionView")
        XCTAssertEqual(note.exception?.message,
                       "Invalid update: invalid number of items in section 0. The number of items after the update (3) must be equal to the number before (2). %@")
        XCTAssertTrue(note.summary.hasPrefix(
            "SIGABRT (EXC_CRASH), NSInternalInconsistencyException (UICollectionView): Invalid update: invalid number of items in section 0."))
        // Never the composed message, nor the object description argument.
        let encoded = String(data: try JSONEncoder().encode(note), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("Jane Smith"))
        XCTAssertFalse(note.summary.contains("Jane Smith"))
    }

    func testTheCrashedThreadsFramesAreKeptNewestFirstAsBinaryUUIDAndOffset() throws {
        let note = try XCTUnwrap(Self.note(Self.sigabrtPayload))
        XCTAssertEqual(note.frames.map(\.binary), ["libsystem_kernel.dylib", "UIKitCore", "OpenGlasses"])
        XCTAssertEqual(note.frames.last?.uuid, "9F8E7D6C-5B4A-3928-1716-151413121110")
        XCTAssertEqual(note.frames.last?.offset, 98304)
    }

    func testASigsegvReadsAsABadAccessWithTheSystemsReason() throws {
        let note = try XCTUnwrap(Self.note(Self.sigsegvPayload))
        XCTAssertNil(note.exception)
        XCTAssertEqual(note.summary, "SIGSEGV (EXC_BAD_ACCESS), Namespace SIGNAL, Code 0xb")
        XCTAssertEqual(note.frames.count, 1)
    }

    func testAWatchdogTerminationSaysSo() throws {
        let note = try XCTUnwrap(Self.note(Self.watchdogPayload))
        XCTAssertTrue(note.isWatchdog)
        XCTAssertTrue(note.summary.contains("watchdog"))
        XCTAssertTrue(note.frames.isEmpty)
    }

    func testAPayloadWithNoCrashGivesNoNoteAndGarbageGivesNone() {
        XCTAssertTrue(CrashNote.notes(fromPayloadJSON: Data(Self.hangOnlyPayload.utf8)).isEmpty)
        XCTAssertTrue(CrashNote.notes(fromPayloadJSON: Data("not json".utf8)).isEmpty)
    }

    func testTheSameCrashTwiceHasOneFingerprint() throws {
        let first = try XCTUnwrap(Self.note(Self.sigabrtPayload))
        let second = try XCTUnwrap(Self.note(Self.sigabrtPayload))
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, try XCTUnwrap(Self.note(Self.sigsegvPayload)).id)
    }

    /// iOS 27's `CrashDiagnostic` carries the Objective-C reason as a nested struct; decoded from
    /// the same crash it makes the same note.
    func testTheIOS27ShapeMakesTheSameNote() throws {
        #if canImport(MetricKit) && compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("CrashDiagnostic needs iOS 27") }
        let json = """
        {"callStackTree":{"callStackPerThread":true,"binaryInfo":[
            {"uuid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"libsystem_kernel.dylib"},
            {"uuid":"0B4C6A0E-1111-2222-3333-444455556666","name":"UIKitCore"},
            {"uuid":"9F8E7D6C-5B4A-3928-1716-151413121110","name":"OpenGlasses"}],
          "callStackThreads":[
            {"threadAttributed":false,"rootFrames":[{"binaryUUID":"11111111-2222-3333-4444-555555555555","offsetIntoBinaryTextSegment":4096,"subFrames":[]}]},
            {"threadAttributed":true,"rootFrames":[
              {"binaryUUID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","offsetIntoBinaryTextSegment":38756,"address":1,"sampleCount":1,"subFrames":[
                {"binaryUUID":"0B4C6A0E-1111-2222-3333-444455556666","offsetIntoBinaryTextSegment":1234567,"address":2,"sampleCount":1,"subFrames":[
                  {"binaryUUID":"9F8E7D6C-5B4A-3928-1716-151413121110","offsetIntoBinaryTextSegment":98304,"address":3,"sampleCount":1,"subFrames":[]}]}]}]}]},
         "terminationReason":"Namespace SIGNAL, Code 6","exceptionType":10,"exceptionCode":0,"signal":6,
         "exceptionReason":{"composedMessage":"Row text: Jane Smith","formatString":"Invalid update: invalid number of items in section %ld. The number of items after the update (%ld) must be equal to the number before (%ld). %@","arguments":["0","3","2","Row text: Jane Smith, 12 High St"],"exceptionType":"NSInternalInconsistencyException","className":"UICollectionView","exceptionName":"NSInternalInconsistencyException"}}
        """
        let crash = try JSONDecoder().decode(CrashDiagnostic.self, from: Data(json.utf8))
        let legacy = try XCTUnwrap(Self.note(Self.sigabrtPayload))
        let modern = CrashNote(crash: crash, appVersion: "1.4", build: "688",
                               osVersion: "iPhone OS 26.1 (23B85)",
                               window: DateInterval(start: legacy.windowStart, end: legacy.windowEnd))
        XCTAssertEqual(modern, legacy)
        #else
        throw XCTSkip("CrashDiagnostic needs the iOS 27 SDK")
        #endif
    }

    // MARK: - The numeric-argument filter

    func testOnlyPlainNumbersAreFilledIn() {
        XCTAssertEqual(CrashNote.numericOnly(format: "row %ld of %lu, %@ said %s", arguments: ["4", "9", "Jane", "hi"]),
                       "row 4 of 9, %@ said %s")
        XCTAssertEqual(CrashNote.numericOnly(format: "%d%% done", arguments: ["50"]), "50% done")
        XCTAssertEqual(CrashNote.numericOnly(format: "value %d", arguments: ["12 High St"]), "value %d")
        XCTAssertEqual(CrashNote.numericOnly(format: "at %f, %x", arguments: ["1.5", "0x1f"]), "at 1.5, 0x1f")
        XCTAssertEqual(CrashNote.numericOnly(format: "count %ld", arguments: []), "count %ld")
    }

    func testPositionalAndStarArgumentsAreNotFilledAtAll() {
        XCTAssertEqual(CrashNote.numericOnly(format: "%2$@ then %1$ld", arguments: ["3", "Jane"]),
                       "%2$@ then %1$ld")
        XCTAssertEqual(CrashNote.numericOnly(format: "%*d items", arguments: ["4", "5"]), "%*d items")
    }
}

/// Plan MB P0: the notes on the phone, the runs they match, and the screens last opened.
final class CrashNoteStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashNoteStoreTests_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    static func note(at date: Date, build: String = "777", offset: UInt64 = 1) -> CrashNote {
        CrashNote(windowStart: date, windowEnd: date, appVersion: "1.5", build: build,
                  osVersion: "iPhone OS 26.2", exceptionType: 10, exceptionCode: 0, signal: 6,
                  terminationReason: nil, exception: nil,
                  frames: [.init(binary: "OpenGlasses", uuid: "9F8E", offset: offset)])
    }

    func testNotesAreKeptOnceBoundedAndSurviveARelaunch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = directory.appendingPathComponent("crash-notes.json")
        let store = CrashNoteStore(url: url, clock: { now })
        let notes = (0..<12).map { Self.note(at: now.addingTimeInterval(TimeInterval(-60 * $0)), offset: UInt64($0)) }
        XCTAssertEqual(store.add(notes).count, CrashNoteStore.maxNotes)
        XCTAssertTrue(store.add([notes[0]]).isEmpty, "the same crash is not kept twice")
        XCTAssertEqual(store.all.count, CrashNoteStore.maxNotes)
        XCTAssertEqual(store.all.last?.note.id, notes[0].id, "oldest first, the newest kept")

        let reopened = CrashNoteStore(url: url, clock: { now })
        XCTAssertEqual(reopened.all.count, CrashNoteStore.maxNotes)
    }

    func testANoteOlderThanSevenDaysIsNotKept() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CrashNoteStore(url: directory.appendingPathComponent("c.json"), clock: { now })
        store.add([Self.note(at: now.addingTimeInterval(-8 * 86_400)), Self.note(at: now)])
        XCTAssertEqual(store.all.count, 1)
    }

    func testClearForgetsEveryNoteAndTheFile() {
        let url = directory.appendingPathComponent("c.json")
        let store = CrashNoteStore(url: url)
        store.add([Self.note(at: Date())])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.clear()
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheRingsClearTakesItsCompanionsWithIt() {
        var cleared = false
        let ring = DiagnosticRing(alsoClear: { cleared = true })
        ring.clear()
        XCTAssertTrue(cleared)
    }

    func testTheFileIsProtectedAndOutOfBackup() throws {
        let url = directory.appendingPathComponent("crash-notes.json")
        CrashNoteStore(url: url).add([Self.note(at: Date())])
        let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, SensitiveStore.crashNotes.record.backupExcluded)
    }

    // MARK: - The banner

    func testTheBannerOffersANewNoteOnceAndNeverALateOne() {
        let crash = Date(timeIntervalSince1970: 1_800_000_000)
        var now = crash.addingTimeInterval(120)
        let store = CrashNoteStore(url: directory.appendingPathComponent("c.json"), clock: { now })
        store.add([Self.note(at: crash)])
        let offered = CrashBannerPolicy.noteToOffer(store.all)
        XCTAssertNotNil(offered)
        store.markOffered(offered!.id)
        XCTAssertNil(CrashBannerPolicy.noteToOffer(store.all), "one banner per note")

        now = crash.addingTimeInterval(25 * 3600)
        store.add([Self.note(at: crash.addingTimeInterval(60), offset: 9)])
        XCTAssertNil(CrashBannerPolicy.noteToOffer(store.all), "a note arriving a day late is kept, not offered")
        XCTAssertEqual(store.all.count, 2)
    }

    func testTheBannerWordsTheCrash() {
        let text = CrashBannerPolicy.message(for: Self.note(at: Date()))
        XCTAssertTrue(text.hasPrefix("Avenkin closed unexpectedly at "))
        XCTAssertTrue(text.hasSuffix("Send a report so we can fix it?"))
    }

    // MARK: - Last screens

    func testLastScreensKeepsTheNewestEight() {
        var screens = LastScreens(run: "r1", build: "777", startedAt: Date(timeIntervalSince1970: 0))
        for index in 0..<12 {
            screens.record("Screen\(index).swift", appeared: true, at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        XCTAssertEqual(screens.screens.count, LastScreens.capacity)
        XCTAssertEqual(screens.screens.first?.token, "Screen4.swift")
        XCTAssertEqual(screens.lastSeen, Date(timeIntervalSince1970: 11))
    }

    func testTheStoreWritesAtOnceAndKeepsEarlierRuns() {
        let url = directory.appendingPathComponent("last-screens.json")
        let first = LastScreensStore(url: url)
        first.begin(run: "r1", build: "776")
        first.record("MemoryView.swift", appeared: true)
        first.waitForPendingWrites()

        let second = LastScreensStore(url: url)
        second.begin(run: "r2", build: "777")
        second.waitForPendingWrites()
        XCTAssertEqual(second.all.map(\.run), ["r1", "r2"])
        XCTAssertEqual(second.all.first?.screens.map(\.token), ["MemoryView.swift"])
        let third = LastScreensStore(url: url)
        third.begin(run: "r3", build: "777")
        XCTAssertEqual(third.all.map(\.run), ["r1", "r2", "r3"])
    }

    // MARK: - Matching a note to its run

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ id: String, from: TimeInterval, to: TimeInterval, build: String? = "777") -> CrashRunMatcher.Run {
        .init(id: id, first: base.addingTimeInterval(from), last: base.addingTimeInterval(to), build: build)
    }

    func testANoteInsideOneRunsSpanMatchesIt() {
        let note = Self.note(at: base.addingTimeInterval(100))
        let runs = [run("a", from: 0, to: 98), run("b", from: 120, to: 600)]
        XCTAssertEqual(CrashRunMatcher.match(note, runs: runs), .run(runs[0]))
    }

    func testANoteNoRunSpansIsUnidentified() {
        let note = Self.note(at: base.addingTimeInterval(1_000))
        XCTAssertEqual(CrashRunMatcher.match(note, runs: [run("a", from: 0, to: 98)]), .unidentified)
    }

    func testTwoCandidatesAreNotGuessedBetween() {
        let note = Self.note(at: base.addingTimeInterval(100))
        let runs = [run("a", from: 0, to: 200), run("b", from: 50, to: 300)]
        XCTAssertEqual(CrashRunMatcher.match(note, runs: runs), .unidentified)
    }

    func testABuildMismatchOrAnUnknownBuildIsNotAMatch() {
        let note = Self.note(at: base.addingTimeInterval(100), build: "776")
        XCTAssertEqual(CrashRunMatcher.match(note, runs: [run("a", from: 0, to: 200)]), .unidentified)
        XCTAssertEqual(CrashRunMatcher.match(Self.note(at: base.addingTimeInterval(100)),
                                             runs: [run("a", from: 0, to: 200, build: nil)]), .unidentified)
    }

    func testRunsComeFromTheRingAndTheLastScreensAndLeaveTheCurrentRunOut() {
        let history = [
            DiagnosticRing.Entry(timestamp: base, category: .lifecycle, name: .app, line: "x", run: "a"),
            DiagnosticRing.Entry(timestamp: base.addingTimeInterval(50), category: .lifecycle, name: .app, line: "y", run: "a"),
        ]
        var screens = LastScreens(run: "a", build: "777", startedAt: base)
        screens.record("MemoryView.swift", appeared: true, at: base.addingTimeInterval(90))
        let current = LastScreens(run: "now", build: "777", startedAt: base.addingTimeInterval(200))
        let runs = CrashRunMatcher.runs(history: history, lastScreens: [screens, current], excluding: "now")
        XCTAssertEqual(runs, [run("a", from: 0, to: 90)],
                       "the last screen extends the span past the ring's last persisted event")
    }

    // MARK: - The export

    private let environment = DiagnosticExportEnvironment(appVersion: "1.5", buildNumber: "777",
                                                          systemName: "iOS", systemVersion: "26.2",
                                                          deviceModel: "iPhone17,1")

    private func entry(_ offset: TimeInterval, run: String) -> DiagnosticRing.Entry {
        .init(timestamp: base.addingTimeInterval(offset), category: .lifecycle, name: .app,
              line: "[lifecycle] app event=screenAppeared", run: run)
    }

    func testAMatchedRunEndsInACrashAndAnUnmatchedNoteStandsAlone() {
        let previous = [entry(0, run: "a"), entry(90, run: "a"), entry(300, run: "b")]
        var screens = LastScreens(run: "a", build: "777", startedAt: base)
        screens.record("MemoryView.swift", appeared: true, at: base.addingTimeInterval(92))
        let matched = Self.note(at: base.addingTimeInterval(60))
        let stray = Self.note(at: base.addingTimeInterval(5_000), offset: 7)
        let document = DiagnosticExportBuilder.build(
            entries: [], environment: environment, previousEntries: previous,
            crashNotes: [matched, stray], lastScreens: [screens], currentRun: "now",
            now: base.addingTimeInterval(6_000), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(document.body.contains("ended in a crash after its last event at "))
        XCTAssertTrue(document.body.contains("MemoryView.swift opened"))
        XCTAssertTrue(document.body.contains("OpenGlasses  9F8E  +0x1"))
        XCTAssertTrue(document.body.contains("A crash the phone recorded (run not identified)"))
        // Run b had no note: today's wording.
        XCTAssertEqual(document.body.components(separatedBy: "exit reason unknown").count - 1, 1)
    }

    func testWithNoNoteEveryEarlierRunKeepsTodaysWording() {
        let document = DiagnosticExportBuilder.build(entries: [], environment: environment,
                                                     previousEntries: [entry(0, run: "a")])
        XCTAssertTrue(document.body.contains("Previous run (may be a different app build; exit reason unknown)"))
        XCTAssertFalse(document.body.lowercased().contains("ended in a crash"))
    }
}

/// The owner's rule for where the crash report goes (2026-11-26), beside the general rule it
/// leaves alone.
final class CrashReportRouteTests: XCTestCase {

    func testAnOrganisationPhoneWithItsOwnSupportEmailSendsTheFullReportThere() {
        XCTAssertEqual(CrashReportRoute.resolve(configured: " support@acme.example ", organisationPhone: true),
                       .send(to: "support@acme.example", contents: .normal))
    }

    func testAnOrganisationPhoneWithNoSupportEmailSendsTheTechnicalLayerToTheDeveloper() {
        let route = CrashReportRoute.resolve(configured: "", organisationPhone: true)
        XCTAssertEqual(route, .send(to: DiagnosticsReportBuilder.supportEmail, contents: .technicalOnly))
        // Never the job-report office, whatever it is: the general rule would have chosen it.
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "", organisationPhone: true,
                                                      organisationRecipients: ["office@acme.example"]),
                       "office@acme.example")
        XCTAssertNotEqual(route.recipient, "office@acme.example")
        XCTAssertEqual(CrashReportRoute.resolve(configured: "not an address", organisationPhone: true).contents,
                       .technicalOnly)
    }

    func testAPersonalPhoneSendsTheNormalReportToItsAddressOrTheDeveloper() {
        XCTAssertEqual(CrashReportRoute.resolve(configured: "me@home.example", organisationPhone: false),
                       .send(to: "me@home.example", contents: .normal))
        XCTAssertEqual(CrashReportRoute.resolve(configured: "", organisationPhone: false),
                       .send(to: DiagnosticsReportBuilder.supportEmail, contents: .normal))
    }

    func testOrdinarySupportReportsStillResolveExactlyAsBefore() {
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "", organisationPhone: false),
                       DiagnosticsReportBuilder.supportEmail)
        XCTAssertNil(SupportReportRecipient.resolve(configured: "", organisationPhone: true))
        XCTAssertEqual(SupportReportRecipient.resolve(configured: "a@b.example", organisationPhone: true),
                       "a@b.example")
    }

    func testTheCrashRequestCarriesTheRouteAndTheTechnicalLayerCannotBeWidened() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let technical = SupportReportRequest.afterCrash(
            at: at, route: .send(to: DiagnosticsReportBuilder.supportEmail, contents: .technicalOnly))
        XCTAssertEqual(technical.recipients, [DiagnosticsReportBuilder.supportEmail])
        XCTAssertTrue(technical.options.technicalOnly)
        XCTAssertFalse(technical.options.otherConversations)
        XCTAssertNil(technical.widerDay)
        let full = SupportReportRequest.afterCrash(at: at, route: .send(to: "s@acme.example", contents: .normal))
        XCTAssertFalse(full.options.technicalOnly)
        XCTAssertTrue(full.options.troubleshooting)
        XCTAssertEqual(full.scope, .day(at))
    }

    /// The technical layer, rendered: the crash, the phone and the app's events — and nothing that
    /// names a job, a conversation or a person, even when the caller holds them.
    func testTheTechnicalReportCarriesTheCrashAndNoContent() {
        let crash = Date(timeIntervalSince1970: 1_800_000_000)
        let note = CrashNoteStoreTests.note(at: crash)
        let details = JobTranscriptExport.Details(
            traces: [], from: "Jane Smith, Acme Heating",
            activity: [], phone: ["App: 1.5 (777)", "System: iOS 26.2"], app: "1.5 (777)",
            appEvents: [.init(at: crash, line: "[lifecycle] app event=screenAppeared detail=MemoryView.swift")],
            debugLog: ["user said: fix the boiler at 12 High St"],
            crashNotes: [note], technicalOnly: true)
        let document = JobTranscriptExport.document(
            scope: .day(crash), jobs: [], exportedAt: crash.addingTimeInterval(600),
            timeZone: TimeZone(identifier: "UTC")!, details: details)
        XCTAssertTrue(document.title.hasPrefix("Crash report"))
        XCTAssertTrue(document.body.contains("Crashes the phone recorded (1)"))
        XCTAssertTrue(document.body.contains("screenAppeared"))
        XCTAssertTrue(document.body.contains("App: 1.5 (777)"))
        XCTAssertFalse(document.body.contains("High St"), "the debug log is not in the technical layer")
        XCTAssertFalse(document.body.contains("Jane Smith"), "no From line in the technical layer")
        XCTAssertFalse(document.body.contains("Troubleshooting details are included"))
    }
}
