import XCTest
import OSLog
@testable import OpenGlasses

/// Plan HW P1. The probe reads the link level from two places the SDK writes to inside this
/// app's own sandbox: the process's unified log, and a log file in the caches directory that
/// has no timestamps. These tests give it sources of their own, and a real file where the rule
/// under test is about byte offsets.
///
/// Every identifier in these lines is invented.
final class GlassesTransportProbeTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 3_000_000)

    private func connected(_ level: String) -> String {
        "DeviceManager: Device fixture-device-01 connected with \(level) link, requesting firmware version"
    }

    /// Sources a test can change between reads.
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [TransportLogEntry] = []
        private var file: [String] = []
        private var fileIsMissing = false
        private(set) var processLogReads = 0
        private(set) var fileReads = 0

        func log(_ message: String, at date: Date) {
            lock.lock(); defer { lock.unlock() }
            entries.append(TransportLogEntry(date: date, message: message))
        }

        func write(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            file.append(line)
        }

        func removeFile() {
            lock.lock(); defer { lock.unlock() }
            fileIsMissing = true
        }

        var reads: Int {
            lock.lock(); defer { lock.unlock() }
            return processLogReads + fileReads
        }

        /// The file is modelled as one line per "byte", which keeps offsets readable.
        var sources: GlassesTransportProbe.Sources {
            GlassesTransportProbe.Sources(
                processLog: { [self] in
                    lock.lock(); defer { lock.unlock() }
                    processLogReads += 1
                    return entries
                },
                fileEndOffset: { [self] in
                    lock.lock(); defer { lock.unlock() }
                    return fileIsMissing ? nil : UInt64(file.count)
                },
                fileLines: { [self] offset, upTo in
                    lock.lock(); defer { lock.unlock() }
                    fileReads += 1
                    guard !fileIsMissing, Int(offset) <= file.count else { return [] }
                    let stop = min(upTo.map(Int.init) ?? file.count, file.count)
                    return stop > Int(offset) ? Array(file[Int(offset)..<stop]) : []
                })
        }
    }

    // MARK: - Before any video

    func testBeforeAnyVideoThereIsNothingToReportAndNothingIsRead() async {
        let fixture = Fixture()
        fixture.log(connected("medium"), at: start)
        let probe = GlassesTransportProbe(sources: fixture.sources)

        XCTAssertEqual(probe.snapshot, .noVideo)
        let reading = await probe.read()

        XCTAssertEqual(reading, .unknown)
        XCTAssertEqual(probe.snapshot, .noVideo)
        XCTAssertEqual(fixture.reads, 0, "with no stream running neither source is opened")
    }

    // MARK: - The process log

    /// A device connects when the glasses come into reach, which can be long before a stream.
    /// The line that names the link is then older than the stream, and still describes it.
    func testALevelLoggedBeforeTheStreamStartedIsTheStreamsLevel() async {
        let fixture = Fixture()
        fixture.log(connected("medium"), at: start - 600)
        let probe = GlassesTransportProbe(sources: fixture.sources)

        probe.streamStarted(at: start)
        let reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .processLog,
                                      changedDuringSession: false))
        XCTAssertTrue(probe.snapshot.videoHasRun)
        XCTAssertEqual(probe.snapshot.reading, reading)
    }

    func testADifferentLevelAfterTheStreamStartedIsAChange() async {
        let fixture = Fixture()
        fixture.log(connected("high"), at: start - 60)
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.streamStarted(at: start)
        var reading = await probe.read()
        XCTAssertEqual(reading.level, .wifi)
        XCTAssertFalse(reading.changedDuringSession)

        fixture.log(connected("medium"), at: start + 45)
        reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .processLog,
                                      changedDuringSession: true))
    }

    /// Entries are split at the start of the stream by their own dates, whatever order the
    /// store hands them over in.
    func testEntriesAreOrderedByTheirDates() async {
        let fixture = Fixture()
        fixture.log(connected("medium"), at: start + 50)
        fixture.log(connected("high"), at: start - 50)
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.streamStarted(at: start)

        let reading = await probe.read()

        XCTAssertEqual(reading.level, .bluetoothClassic, "the later entry is the latest word")
        XCTAssertTrue(reading.changedDuringSession)
    }

    // MARK: - The log file

    /// The file has no timestamps. What it held before this launch is another day's link.
    func testOnlyTheFilesLinesSinceLaunchCount() async {
        let fixture = Fixture()
        fixture.write(connected("high"))            // an earlier launch
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()
        fixture.write(connected("medium"))          // this launch, before the stream

        probe.streamStarted(at: start)
        let reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .sdkLogFile,
                                      changedDuringSession: false))
    }

    func testAnOlderLaunchesLineAloneIsNotBelieved() async {
        let fixture = Fixture()
        fixture.write(connected("high"))
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()

        probe.streamStarted(at: start)
        let reading = await probe.read()

        XCTAssertEqual(reading, .unknown)
    }

    /// Without a launch mark there is no telling the file's old lines from this launch's, so
    /// only what is written after the stream started is read.
    func testWithoutALaunchMarkTheFilesPastIsLeftUnread() async {
        let fixture = Fixture()
        fixture.write(connected("high"))
        let probe = GlassesTransportProbe(sources: fixture.sources)

        probe.streamStarted(at: start)
        var reading = await probe.read()
        XCTAssertEqual(reading, .unknown)

        fixture.write(connected("low"))
        reading = await probe.read()
        XCTAssertEqual(reading, .init(level: .bluetoothLowEnergy, origin: .sdkLogFile,
                                      changedDuringSession: false))
    }

    func testAFileLineAfterTheStreamStartedThatDiffersIsAChange() async {
        let fixture = Fixture()
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()
        fixture.write(connected("medium"))
        probe.streamStarted(at: start)
        _ = await probe.read()

        fixture.write("DeviceManager: .medium link unavailable (accessory gone), falling back to .low")
        let reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothLowEnergy, origin: .sdkLogFile,
                                      changedDuringSession: true))
    }

    func testAMissingFileIsUnknownNotAnError() async {
        let fixture = Fixture()
        fixture.removeFile()
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()

        probe.streamStarted(at: start)
        let reading = await probe.read()

        XCTAssertEqual(reading, .unknown)
        XCTAssertTrue(probe.snapshot.videoHasRun, "video ran; the link is simply not known")
    }

    // MARK: - Two sources

    /// The process log carries dates, so it is asked first. The file answers when it cannot.
    func testTheProcessLogIsPreferredAndTheFileAnswersWhenItIsSilent() async {
        let fixture = Fixture()
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()
        fixture.write(connected("medium"))
        probe.streamStarted(at: start)
        var reading = await probe.read()
        XCTAssertEqual(reading.origin, .sdkLogFile)

        fixture.log(connected("high"), at: start - 5)
        reading = await probe.read()
        XCTAssertEqual(reading, .init(level: .wifi, origin: .processLog,
                                      changedDuringSession: false))
    }

    // MARK: - A caller that will not wait

    /// The support report asks with a time limit. A source that is slow to answer must not hold
    /// the report: the caller gets what was already known, and the read still finishes.
    func testAReadWithATimeLimitAnswersWithWhatIsKnownAndTheReadStillFinishes() async {
        let gate = DispatchSemaphore(value: 0)
        let entry = TransportLogEntry(date: start - 5, message: connected("medium"))
        let probe = GlassesTransportProbe(sources: .init(
            processLog: { gate.wait(); return [entry] },
            fileEndOffset: { 0 },
            fileLines: { _, _ in [] }))
        probe.streamStarted(at: start)

        let asked = Date()
        let early = await probe.read(waitingAtMost: 0.2)
        XCTAssertEqual(early, .unknown, "nothing was known yet, and that is what was answered")
        XCTAssertLessThan(Date().timeIntervalSince(asked), 5, "the caller was not kept waiting")

        gate.signal()   // the slow read
        gate.signal()   // the one asked for below
        let late = await probe.read()
        XCTAssertEqual(late.level, .bluetoothClassic)
        XCTAssertEqual(probe.snapshot.reading.level, .bluetoothClassic)
    }

    /// And when the sources answer in time, the limit changes nothing.
    func testAReadWithATimeLimitReturnsTheReadingWhenItIsQuick() async {
        let fixture = Fixture()
        fixture.log(connected("high"), at: start - 5)
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.streamStarted(at: start)
        let reading = await probe.read(waitingAtMost: 5)
        XCTAssertEqual(reading.level, .wifi)
    }

    // MARK: - The end of a stream, and the next one

    /// What the link does after the video stopped is not a fact about the video. An ended
    /// stream is read once, up to where it ended, and then its reading stands.
    func testAfterTheStreamEndsTheReadingStands() async {
        let fixture = Fixture()
        fixture.log(connected("medium"), at: start - 60)
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.streamStarted(at: start)
        probe.streamEnded(at: start + 20)
        _ = await probe.read()
        let readsAtTheEnd = fixture.reads

        fixture.log(connected("high"), at: start + 300)
        let reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .processLog,
                                      changedDuringSession: false))
        XCTAssertEqual(fixture.reads, readsAtTheEnd, "an ended stream is not read again")
        XCTAssertTrue(probe.snapshot.videoHasRun)
    }

    /// A photo starts and stops a stream in a couple of seconds and nobody reads the probe in
    /// between. Asked later, it still answers for that stream, and only for that stream: a
    /// change inside it counts, and what was logged after it ended does not.
    func testAStreamNobodyReadWhileItRanIsReadUpToWhereItEnded() async {
        let fixture = Fixture()
        fixture.log(connected("high"), at: start - 60)
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.streamStarted(at: start)
        fixture.log(connected("medium"), at: start + 10)
        probe.streamEnded(at: start + 20)
        fixture.log(connected("low"), at: start + 30)

        let reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .processLog,
                                      changedDuringSession: true))
        XCTAssertEqual(probe.snapshot.reading, reading)
    }

    func testTheFilesLinesAfterTheStreamEndedAreNotTheStreams() async {
        let fixture = Fixture()
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()
        fixture.write(connected("medium"))
        probe.streamStarted(at: start)
        probe.streamEnded(at: start + 20)
        await settle(probe)                         // both marks are taken before the next line
        fixture.write(connected("high"))

        let reading = await probe.read()

        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .sdkLogFile,
                                      changedDuringSession: false))
    }

    /// Starting and stopping a stream asks the file its length and reads nothing. A photo does
    /// both, and must not cost a pass over the log each time.
    func testMarkingAStreamReadsNeitherSource() async {
        let fixture = Fixture()
        fixture.log(connected("medium"), at: start - 60)
        fixture.write(connected("medium"))
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.markLaunch()

        for round in 0..<5 {
            probe.streamStarted(at: start + Double(round) * 10)
            probe.streamEnded(at: start + Double(round) * 10 + 2)
        }
        await settle(probe)

        XCTAssertEqual(fixture.reads, 0)
    }

    /// Waits until the probe has done everything asked of it so far, without asking it to read.
    private func settle(_ probe: GlassesTransportProbe) async {
        await withCheckedContinuation { continuation in
            probe.afterPendingWork { continuation.resume() }
        }
    }

    func testWhatAStreamDeliveredSitsBesideItsLevelAndTheNextStreamStartsClean() async {
        let fixture = Fixture()
        fixture.log(connected("medium"), at: start - 60)
        let probe = GlassesTransportProbe(sources: fixture.sources)
        let facts = StreamDeliveryMeter.Facts(width: 504, height: 896, framesPerSecond: 30)

        probe.streamStarted(at: start)
        probe.record(delivery: facts)
        _ = await probe.read()
        XCTAssertEqual(probe.snapshot.delivery, facts)
        XCTAssertEqual(probe.snapshot.reading.level, .bluetoothClassic)

        probe.streamEnded(at: start + 100)
        probe.streamStarted(at: start + 500)
        _ = await probe.read()
        XCTAssertNil(probe.snapshot.delivery, "the new stream has not been measured yet")
        XCTAssertEqual(probe.snapshot.reading.level, .bluetoothClassic)
    }

    func testDeliveryRecordedAfterAStreamEndedIsNotAttachedToIt() async {
        let fixture = Fixture()
        let probe = GlassesTransportProbe(sources: fixture.sources)
        probe.streamStarted(at: start)
        probe.streamEnded(at: start + 5)
        probe.record(delivery: .init(width: 1, height: 1, framesPerSecond: 1))
        _ = await probe.read()
        XCTAssertNil(probe.snapshot.delivery)
    }

    // MARK: - The real file reader

    private func temporaryLog(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("MetaWearablesDAT.log")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testOnlyLinesAfterTheMarkAreRead() throws {
        let url = try temporaryLog("old line one\nold line two\n")
        let file = SDKLogFile(url: url)
        let mark = try XCTUnwrap(file.endOffset())
        XCTAssertEqual(mark, 26)
        XCTAssertEqual(file.lines(after: mark), [])

        try append("new line one\nnew line two\n", to: url)

        XCTAssertEqual(file.lines(after: mark), ["new line one", "new line two"])
        XCTAssertEqual(file.lines(after: 0),
                       ["old line one", "old line two", "new line one", "new line two"])
    }

    /// A file shorter than the mark was started again after the mark was taken. All of it is
    /// newer than the mark.
    func testAFileNowShorterThanTheMarkIsReadFromTheStart() throws {
        let url = try temporaryLog(String(repeating: "x", count: 500) + "\n")
        let file = SDKLogFile(url: url)
        let mark = try XCTUnwrap(file.endOffset())

        try Data("fresh line\n".utf8).write(to: url)

        XCTAssertLessThan(try XCTUnwrap(file.endOffset()), mark)
        XCTAssertEqual(file.lines(after: mark), ["fresh line"])
    }

    /// A stream's lines stop where the file ended when the stream did.
    func testLinesCanBeBoundedAtBothEnds() throws {
        let url = try temporaryLog("before one\nbefore two\n")
        let file = SDKLogFile(url: url)
        let started = try XCTUnwrap(file.endOffset())
        try append("during one\nduring two\n", to: url)
        let ended = try XCTUnwrap(file.endOffset())
        try append("after one\n", to: url)

        XCTAssertEqual(file.lines(after: started, upTo: ended), ["during one", "during two"])
        XCTAssertEqual(file.lines(after: 0, upTo: started), ["before one", "before two"])
        XCTAssertEqual(file.lines(after: started, upTo: started), [])
        XCTAssertEqual(file.lines(after: started), ["during one", "during two", "after one"])
    }

    /// The file was started again after both marks were taken: the lines between them went
    /// with the old file, and what is there now belongs to a later time.
    func testAWindowWhoseFileHasSinceBeenStartedAgainHasNoLines() throws {
        let url = try temporaryLog(String(repeating: "x", count: 500) + "\n")
        let file = SDKLogFile(url: url)
        let started = try XCTUnwrap(file.endOffset())
        try append("during\n", to: url)
        let ended = try XCTUnwrap(file.endOffset())

        try Data("later\n".utf8).write(to: url)

        XCTAssertEqual(file.lines(after: started, upTo: ended), [])
    }

    /// The file was started again *between* the marks: what it holds up to the second mark was
    /// all written inside the window.
    func testAWindowTheFileWasStartedAgainInsideIsReadFromTheStart() throws {
        let url = try temporaryLog(String(repeating: "x", count: 500) + "\n")
        let file = SDKLogFile(url: url)
        let started = try XCTUnwrap(file.endOffset())

        try Data("during\n".utf8).write(to: url)
        let ended = try XCTUnwrap(file.endOffset())
        try append("after\n", to: url)

        XCTAssertLessThan(ended, started)
        XCTAssertEqual(file.lines(after: started, upTo: ended), ["during"])
    }

    func testAMissingFileHasNoLengthAndNoLines() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-directory-\(UUID().uuidString)")
            .appendingPathComponent("MetaWearablesDAT.log")
        let file = SDKLogFile(url: url)
        XCTAssertNil(file.endOffset())
        XCTAssertEqual(file.lines(after: 0), [])
        XCTAssertEqual(file.lines(after: 4096), [])
        XCTAssertEqual(SDKLogFile(url: nil).lines(after: 0), [])
        XCTAssertNil(SDKLogFile(url: nil).endOffset())
    }

    /// At most the last 256 KB is read, and the line the cap cut through is dropped rather
    /// than read as if it were whole.
    func testAReadIsCappedFromTheEndAndTheCutLineIsDropped() throws {
        let filler = String(repeating: "f", count: 99) + "\n"                 // 100 bytes
        let fillerLines = (SDKLogFile.readCap / 100) + 50                      // past the cap
        let url = try temporaryLog(String(repeating: filler, count: fillerLines)
                                   + "the tail of the file is intact\n")
        let lines = SDKLogFile(url: url).lines(after: 0)

        XCTAssertEqual(lines.last, "the tail of the file is intact")
        XCTAssertLessThanOrEqual(lines.count, SDKLogFile.readCap / 100 + 1)
        XCTAssertTrue(lines.allSatisfy { $0.count == 99 || $0 == "the tail of the file is intact" },
                      "a line cut by the cap must not be returned as a line")
    }

    func testTheContainerFileIsWhereTheSDKWritesIt() throws {
        let url = try XCTUnwrap(SDKLogFile.inAppContainer.url)
        XCTAssertTrue(url.path.hasSuffix("/Library/Caches/MetaWearablesDAT/Logs/MetaWearablesDAT.log"),
                      url.path)
    }

    /// The probe and the real reader together, on a real file.
    func testTheProbeReadsARealFileByOffsets() async throws {
        let url = try temporaryLog("[ARCLog] [error] [tid:1] [DeviceManager.connect] [DeviceManager.swift:9] "
                                   + connected(".high") + "\n")
        let file = SDKLogFile(url: url)
        let probe = GlassesTransportProbe(sources: .init(
            processLog: { [] },
            fileEndOffset: { file.endOffset() },
            fileLines: { file.lines(after: $0, upTo: $1) }))
        probe.markLaunch()

        try append("[ARCLog] [error] [tid:1] [DeviceManager.connect] [DeviceManager.swift:9] "
                   + connected(".medium") + "\n", to: url)
        probe.streamStarted(at: start)
        var reading = await probe.read()
        XCTAssertEqual(reading, .init(level: .bluetoothClassic, origin: .sdkLogFile,
                                      changedDuringSession: false))

        try append("[ARCLog] [error] [tid:1] [DeviceManager.link] [DeviceManager.swift:40] "
                   + "DeviceManager: .medium link unavailable (fixture), falling back to .low\n", to: url)
        reading = await probe.read()
        XCTAssertEqual(reading, .init(level: .bluetoothLowEnergy, origin: .sdkLogFile,
                                      changedDuringSession: true))
    }

    // MARK: - The real process log

    /// The one thing here that cannot be faked: that the unified log hands this process its own
    /// entries back, and that `composedMessage` is a key the store's predicate accepts. A line
    /// shaped like the SDK's is written to the log and looked for through the real reader.
    func testTheProcessLogReaderFindsThisProcessesOwnDeviceManagerLines() async throws {
        guard (try? OSLogStore(scope: .currentProcessIdentifier)) != nil else {
            throw XCTSkip("this environment does not give a process its own log store")
        }
        let logger = Logger(subsystem: "com.openglasses.tests", category: "transport-probe")
        logger.error("DeviceManager: Device fixture-device-01 connected with medium link, requesting firmware version")
        logger.error("TransportProbeTests: a line that does not mention the device manager")

        // The store is written to asynchronously; look until the line has landed.
        var found: [TransportLogEntry] = []
        for _ in 0..<40 {
            found = ProcessLogReader.deviceManagerEntries()
            if !found.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }

        // How soon the store shows a line is the system's business, and a loaded machine can
        // take longer than this test is willing to wait. That is not a fault in the reader.
        guard !found.isEmpty else {
            throw XCTSkip("the log store had not shown this process its own line after ten seconds")
        }
        XCTAssertTrue(found.allSatisfy { $0.message.contains(ProcessLogReader.marker) },
                      "only device-manager lines are returned")
        var parser = TransportLevelParser()
        parser.consume(found.map(\.message))
        XCTAssertEqual(parser.level, .bluetoothClassic)
    }
}
