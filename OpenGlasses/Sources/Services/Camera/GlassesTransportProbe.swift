import Foundation
import OSLog

/// One line the SDK wrote, with when it wrote it. The message is read by `TransportLevelParser`
/// and goes nowhere else: these lines name devices.
struct TransportLogEntry: Equatable, Sendable {
    let date: Date
    let message: String
}

/// Plan HW P1 — which link the glasses video is on, read from the SDK's own words.
///
/// Three documents of ours say the video rides Wi-Fi and field reports say it is Bluetooth
/// Classic. The SDK has no API that settles it, but it does say which link level a device
/// connected with, in two places this process can read without leaving its own sandbox:
///
/// - **its own unified log**, through `OSLogStore(scope: .currentProcessIdentifier)`. The SDK
///   runs inside this process, so whatever it sends to the system log is ours to read back.
///   Whether the device manager's lines get that far is unknown until a device shows it.
/// - **the SDK's log file in our container**, `Library/Caches/MetaWearablesDAT/Logs/
///   MetaWearablesDAT.log`. On the one phone looked at it holds error-level lines only, with no
///   timestamps, so "this launch" is everything after the length the file had at launch and
///   "this stream" everything after the length it had when the stream started.
///
/// Both go through `TransportLevelParser`, each on its own, and the answer says which one it
/// came from. A level is the latest readable statement; everything said before the stream
/// started is where the session begins, and a different level after that is a change.
///
/// The level a device connected with is logged when it connects, which may be long before any
/// stream, so both sources are read back to the launch and not just to the start of the stream.
///
/// Marking the start and the end of a stream costs one question each (how long is the file),
/// because a photo starts and stops a stream too. The sources are only read when somebody asks:
/// once, thirty seconds into a stream that is still running, and when a support report is built.
///
/// Reading is local: nothing is sent anywhere, no other process's log is opened, and no line
/// is kept or copied. A source that cannot be read is an `unknown`, never an error.
final class GlassesTransportProbe: @unchecked Sendable {

    /// The one the camera writes to and the support report reads.
    static let shared = GlassesTransportProbe(sources: .live)

    /// Where the lines come from. A seam, so the tests can supply their own.
    struct Sources: Sendable {
        /// This process's lines from the SDK's device manager since launch, oldest first.
        var processLog: @Sendable () -> [TransportLogEntry]
        /// How long the SDK's log file is now, or nil when it cannot be opened.
        var fileEndOffset: @Sendable () -> UInt64?
        /// The file's lines after that many bytes, and before `upTo` when there is one.
        var fileLines: @Sendable (_ afterOffset: UInt64, _ upTo: UInt64?) -> [String]

        static let live: Sources = {
            let file = SDKLogFile.inAppContainer
            return Sources(processLog: { ProcessLogReader.deviceManagerEntries() },
                           fileEndOffset: { file.endOffset() },
                           fileLines: { file.lines(after: $0, upTo: $1) })
        }()
    }

    struct Reading: Equatable, Sendable {
        enum Origin: String, Sendable {
            case processLog, sdkLogFile, none
        }

        var level: GlassesTransportLevel
        var origin: Origin
        /// More than one level was in force while the stream ran.
        var changedDuringSession: Bool

        static let unknown = Reading(level: .unknown, origin: .none, changedDuringSession: false)

        /// The process log is asked first: its entries carry dates, so "since the stream
        /// started" is exact there and only as good as a byte offset in the file. Each source's
        /// answer is its own; they are never merged into one sequence, because nothing says how
        /// a dated entry and an undated line are ordered.
        static func choose(processLog: TransportLevelParser,
                           file: TransportLevelParser) -> Reading {
            if processLog.level != .unknown {
                return Reading(level: processLog.level, origin: .processLog,
                               changedDuringSession: processLog.changedDuringSession)
            }
            if file.level != .unknown {
                return Reading(level: file.level, origin: .sdkLogFile,
                               changedDuringSession: file.changedDuringSession)
            }
            return Reading(level: .unknown, origin: .none,
                           changedDuringSession: processLog.changedDuringSession
                               || file.changedDuringSession)
        }
    }

    private struct Session {
        let startedAt: Date
        /// The file's length when the stream started.
        let fileOffset: UInt64
        /// When the stream ended and the file's length then. Nil while it is running.
        var ended: (at: Date, fileOffset: UInt64)?
        /// An ended stream has been read once. Its reading stands from then on: what the link
        /// does after the video has stopped is not a fact about the video.
        var isSettled = false

        var isLive: Bool { ended == nil }
    }

    private let sources: Sources
    /// Every read and every change of session happens here, in the order it was asked for.
    private let queue = DispatchQueue(label: "com.openglasses.glasses-transport-probe",
                                      qos: .utility)
    private let lock = NSLock()
    private var launchFileOffset: UInt64?
    private var session: Session?
    private var latest = GlassesVideoLinkSnapshot.noVideo

    init(sources: Sources) {
        self.sources = sources
    }

    /// What is known right now, without reading anything. Safe from any thread.
    var snapshot: GlassesVideoLinkSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Call before the SDK is configured. The file has no timestamps, so its length now is the
    /// only way to tell this launch's lines from an earlier one's. Opening a file and asking its
    /// length reads none of it, and it has to have happened before the SDK can write.
    func markLaunch() {
        let offset = sources.fileEndOffset() ?? 0
        lock.lock()
        launchFileOffset = offset
        lock.unlock()
    }

    /// A stream started streaming. Everything said so far is where this session begins.
    func streamStarted(at now: Date = Date()) {
        queue.async { [self] in
            let offset = sources.fileEndOffset() ?? 0
            lock.lock()
            session = Session(startedAt: now, fileOffset: offset)
            latest = GlassesVideoLinkSnapshot(videoHasRun: true, reading: .unknown, delivery: nil)
            lock.unlock()
        }
    }

    /// The stream is over. Where the file ends now is where this session ends; nothing is read.
    func streamEnded(at now: Date = Date()) {
        queue.async { [self] in
            lock.lock()
            let isLive = session?.isLive == true
            lock.unlock()
            guard isLive else { return }
            let offset = sources.fileEndOffset() ?? 0
            lock.lock()
            session?.ended = (at: now, fileOffset: offset)
            lock.unlock()
        }
    }

    /// What the stream delivered in its first thirty seconds, to sit beside the level.
    func record(delivery: StreamDeliveryMeter.Facts?) {
        queue.async { [self] in
            lock.lock()
            if session?.isLive == true { latest.delivery = delivery }
            lock.unlock()
        }
    }

    /// Read both sources again and return what they say about the stream. Off the main thread,
    /// and never throws: a source that cannot be read contributes nothing. Before any stream
    /// neither source is touched, and a stream that has ended is read once and not again.
    @discardableResult
    func read() async -> Reading {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readOnQueue())
            }
        }
    }

    /// The same read, for a caller that must not wait on it: the support report. How long a
    /// pass over this process's log takes on a phone that has been running for hours has not
    /// been measured, and a report cannot hang on a diagnostic. After `seconds` the caller is
    /// given what was already known. The read carries on, and whoever asks next has its answer.
    @discardableResult
    func read(waitingAtMost seconds: TimeInterval) async -> Reading {
        await withCheckedContinuation { continuation in
            let answered = AnsweredOnce()
            queue.async { [self] in
                let reading = readOnQueue()
                if answered.claim() { continuation.resume(returning: reading) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
                if answered.claim() { continuation.resume(returning: snapshot.reading) }
            }
        }
    }

    /// Whichever of the read and its time limit comes first answers; the other finds it done.
    private final class AnsweredOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !answered else { return false }
            answered = true
            return true
        }
    }

    /// Runs `work` once everything asked of the probe so far has been done. For the tests,
    /// which need to look at it after a mark has landed without asking it to read.
    func afterPendingWork(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func readOnQueue() -> Reading {
        lock.lock()
        let current = session
        let standing = latest.reading
        let launchOffset = launchFileOffset
        lock.unlock()
        guard let current, !current.isSettled else { return standing }

        // Split at the start of the stream by each entry's own date, read afresh every time: an
        // entry can reach the store a moment after it was written, and a reading that kept its
        // place between calls would step over it.
        let entries = sources.processLog().sorted { $0.date < $1.date }
        var fromLog = TransportLevelParser()
        fromLog.consume(entries.lazy.filter { $0.date < current.startedAt }.map(\.message))
        fromLog.beginSession()
        fromLog.consume(entries.lazy
            .filter { $0.date >= current.startedAt }
            .filter { entry in current.ended.map { entry.date <= $0.at } ?? true }
            .map(\.message))

        var fromFile = TransportLevelParser()
        // Without a launch mark there is no telling this launch's lines from older ones, so
        // the file's past is left unread rather than believed.
        if let launchOffset {
            fromFile.consume(sources.fileLines(launchOffset, current.fileOffset))
        }
        fromFile.beginSession()
        fromFile.consume(sources.fileLines(current.fileOffset, current.ended?.fileOffset))

        let reading = Reading.choose(processLog: fromLog, file: fromFile)
        lock.lock()
        // Only if this is still the stream that was read: a new one may have started meanwhile.
        if session?.startedAt == current.startedAt {
            latest.reading = reading
            if !current.isLive { session?.isSettled = true }
        }
        lock.unlock()
        return reading
    }
}

/// What the support report says about the glasses video link, as data.
struct GlassesVideoLinkSnapshot: Equatable, Sendable {
    /// False until a stream has streamed in this launch. Then there is nothing to report, which
    /// is a different thing from having looked and not found out.
    var videoHasRun: Bool
    var reading: GlassesTransportProbe.Reading
    var delivery: StreamDeliveryMeter.Facts?

    static let noVideo = GlassesVideoLinkSnapshot(videoHasRun: false, reading: .unknown,
                                                  delivery: nil)
}

/// Plan HW P1 — the support report's one line about the glasses video link (pure).
///
/// Always present, so a report that says nothing about the link is one where nothing was
/// known rather than one from a build that did not look. The picture's size and rate are
/// printed as what they are, beside the level; they are not evidence for it.
enum GlassesVideoLinkReport {

    static func line(for snapshot: GlassesVideoLinkSnapshot) -> String {
        guard snapshot.videoHasRun else {
            return "Glasses video link: not known (no video since the app started)"
        }
        var line = "Glasses video link: " + levelPhrase(snapshot.reading)
        if snapshot.reading.changedDuringSession { line += ", changed during the session" }
        if let delivery = snapshot.delivery {
            line += "; picture \(delivery.width)×\(delivery.height) at "
                + "\(Int(delivery.framesPerSecond.rounded())) fps"
        }
        return line
    }

    private static func levelPhrase(_ reading: GlassesTransportProbe.Reading) -> String {
        let name: String
        switch reading.level {
        case .wifi: name = "Wi-Fi"
        case .bluetoothClassic: name = "Bluetooth Classic"
        case .bluetoothLowEnergy: name = "Bluetooth Low Energy"
        case .unknown: return "not known"
        }
        switch reading.origin {
        case .processLog: return name + " (from the glasses software's log)"
        case .sdkLogFile: return name + " (from the glasses software's log file)"
        case .none: return name
        }
    }
}

/// The SDK's own log file, inside this app's container.
///
/// Read with `FileHandle` and byte offsets only. The file's dates and attributes are never
/// asked for: lines carry no timestamps, so a length taken at a known moment is what marks time.
struct SDKLogFile: Sendable {

    /// The most that is ever read in one go, counted back from the end. The lines that matter
    /// are the newest, and a log that has grown past this is not worth holding in memory.
    static let readCap = 256 * 1024

    let url: URL?

    static var inAppContainer: SDKLogFile {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return SDKLogFile(url: caches?
            .appendingPathComponent("MetaWearablesDAT", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MetaWearablesDAT.log"))
    }

    /// The file's length, or nil when there is no file to open.
    func endOffset() -> UInt64? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.seekToEnd()
    }

    /// The lines after `offset`, and before `limit` when there is one (a stream's lines end
    /// where the file ended when the stream did).
    ///
    /// A file that is now shorter than the offset has been started again since the mark was
    /// taken. With no limit, all of it is newer than the mark and it is read from the beginning.
    /// With a limit taken before the file was started again, the lines asked for went with the
    /// old file and there are none. A limit *below* the offset means the file was started again
    /// between the two marks, and what it holds up to the limit is the window. A missing file
    /// has no lines.
    func lines(after offset: UInt64, upTo limit: UInt64? = nil) -> [String] {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }

        var start = offset
        var stop = min(limit ?? end, end)
        if let limit, limit < offset {
            start = 0
        } else if offset > end {
            guard limit == nil else { return [] }
            start = 0
            stop = end
        }

        var startsMidLine = false
        if stop > start, stop - start > UInt64(Self.readCap) {
            start = stop - UInt64(Self.readCap)
            startsMidLine = true
        }
        guard stop > start, (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(stop - start)) else {
            return []
        }

        var lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
        // A read that began at the cap rather than at a mark most likely began inside a line.
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

/// This process's own entries in the unified log that mention the SDK's device manager.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` cannot see any other process. The entries are
/// narrowed by what the message says, with a predicate on `composedMessage` (the property
/// `OSLogEntry` declares), and not by a subsystem: nobody has seen which subsystem the SDK logs
/// under, if it logs here at all. Should the predicate ever be refused, the same test is made
/// in code over a bounded number of entries.
enum ProcessLogReader {

    /// What both recognised lines begin with.
    static let marker = "DeviceManager:"

    /// Entries looked at before giving up, when the store would not narrow them for us.
    static let scanCap = 50_000

    /// Matching entries kept, newest last. A device connects a handful of times a day.
    static let keepCap = 500

    static func deviceManagerEntries() -> [TransportLogEntry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let predicate = NSPredicate(format: "composedMessage CONTAINS %@", marker)
        let entries: AnySequence<OSLogEntry>
        if let narrowed = try? store.getEntries(matching: predicate) {
            entries = narrowed
        } else if let everything = try? store.getEntries() {
            entries = everything
        } else {
            return []
        }

        var found: [TransportLogEntry] = []
        var scanned = 0
        for entry in entries {
            scanned += 1
            if scanned > scanCap { break }
            let message = entry.composedMessage
            guard message.contains(marker) else { continue }
            found.append(TransportLogEntry(date: entry.date, message: message))
        }
        return Array(found.suffix(keepCap))
    }
}
