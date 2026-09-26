import Foundation

/// One finished turn, as support needs to see it: what went to the model with the words, which
/// model answered, how long it took, and how it ended (support ask, 2026-09-26).
///
/// **No words.** What the technician said and what the assistant replied are in the conversation
/// thread; a trace carries what went *with* them — the prompt's blocks by name and size, the manual
/// pages by citation, the tools by name and result class, the error by `SafeErrorSummary` category —
/// and the thread and job it belongs to, so an export can line the two up. That is why keeping it
/// on the device for a fortnight needs no consent of its own: it holds nothing the conversation
/// store does not already hold more of, and it leaves the phone only in a file the wearer reads and
/// shares.
struct TurnTrace: Codable, Equatable, Identifiable {

    enum Outcome: String, Codable {
        case answered
        /// The wearer talked over the reply.
        case interrupted
        /// Cancelled or superseded before it delivered.
        case cancelled
        case failed
    }

    let id: UUID
    /// When the turn was handed to the model, or failing that the earliest mark it has.
    let at: Date
    var threadId: String?
    var fieldSessionId: String?
    var backend: String?
    var model: String?
    var transcriber: String?
    var speechEngine: String?
    var micRoute: String?
    var endOfTurn: String?
    var imageSent: Bool
    var promptBlocks: [TurnTimeline.PromptBlock]
    var manualPassages: [String]
    var manualRefused: Bool
    var toolCalls: [TurnTimeline.ToolNote]
    var outcome: Outcome
    var failure: String?
    /// Speech end to the first audio the wearer heard.
    var perceivedLatency: TimeInterval?
    /// Hand-off to the model to its first output.
    var timeToFirstToken: TimeInterval?
    /// Hand-off to the model to its finished reply, tools included.
    var backendSeconds: TimeInterval?
    var toolSeconds: TimeInterval?

    init(_ timeline: TurnTimeline, sealedAt: Date) {
        id = timeline.id
        at = timeline.commitAt ?? timeline.speechEndAt ?? timeline.heldAt ?? sealedAt
        threadId = timeline.threadId
        fieldSessionId = timeline.fieldSessionId
        backend = timeline.backend?.label
        model = timeline.model.map(Self.modelName)
        transcriber = timeline.transcriber?.rawValue
        speechEngine = timeline.ttsEngine?.rawValue
        micRoute = timeline.micRoute?.rawValue
        endOfTurn = timeline.endOfTurnReason?.rawValue
        imageSent = timeline.imageSent
        promptBlocks = timeline.promptBlocks
        manualPassages = timeline.manualPassages
        manualRefused = timeline.manualRefused
        toolCalls = timeline.toolCalls
        failure = timeline.failure?.description
        if timeline.failure != nil {
            outcome = .failed
        } else if timeline.interrupted {
            outcome = .interrupted
        } else if timeline.abandoned {
            outcome = .cancelled
        } else {
            outcome = .answered
        }
        perceivedLatency = timeline.perceivedLatency
        timeToFirstToken = timeline.timeToFirstToken
        backendSeconds = timeline.backendSeconds
        toolSeconds = timeline.toolIterations > 0 ? timeline.toolSeconds : nil
    }

    /// A local model is tagged with its file path; the file name is what identifies it, and the
    /// rest of the path is the phone's own layout.
    static func modelName(_ raw: String) -> String {
        raw.contains("/") ? URL(fileURLWithPath: raw).lastPathComponent : raw
    }

    var promptCharacters: Int { promptBlocks.reduce(0) { $0 + $1.characters } }
}

/// The last two weeks of turn traces, kept on the device for a support export.
///
/// One JSON file under Application Support, protected until first unlock (a turn can finish while
/// the phone is locked in a pocket) and excluded from backup. Bounded twice — by age and by count —
/// and pruned on every write, so it cannot grow however long the app runs. Written off the main
/// thread; a trace that is lost to an abrupt exit is a missing line in a report, never a crash.
@MainActor
final class TurnTraceStore {

    nonisolated static let retention: TimeInterval = 14 * 24 * 60 * 60
    nonisolated static let capacity = 2_000

    static let shared = TurnTraceStore(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics/turn-traces.json"))

    private let url: URL?
    private let clock: () -> Date
    private var cache: [TurnTrace]?
    private let queue = DispatchQueue(label: "com.openglasses.turn-traces", qos: .utility)

    init(url: URL?, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    /// Everything kept, oldest first.
    var all: [TurnTrace] {
        let now = clock()
        return Self.retained(load(), now: now, capacity: Self.capacity)
    }

    /// The traces whose turn fell in `[start, end)`, oldest first.
    func traces(from start: Date, to end: Date) -> [TurnTrace] {
        all.filter { $0.at >= start && $0.at < end }
    }

    /// Keep a sealed turn.
    func record(_ timeline: TurnTimeline) {
        append(TurnTrace(timeline, sealedAt: clock()))
    }

    func append(_ trace: TurnTrace) {
        var traces = load()
        traces.append(trace)
        traces = Self.retained(traces, now: clock(), capacity: Self.capacity)
        cache = traces
        save(traces)
    }

    /// Delete every trace. Named in the data-store registry as this store's erase.
    func removeAll() {
        cache = []
        save([])
    }

    /// For tests and background callers only. Never block the main thread on diagnostics.
    func waitForPendingWrites() {
        queue.sync {}
    }

    /// Newest `capacity` traces younger than `retention`, oldest first. Pure.
    nonisolated static func retained(_ traces: [TurnTrace], now: Date, capacity: Int) -> [TurnTrace] {
        let fresh = traces.filter { now.timeIntervalSince($0.at) <= retention && $0.at <= now.addingTimeInterval(60) }
            .sorted { $0.at < $1.at }
        return Array(fresh.suffix(max(0, capacity)))
    }

    private func load() -> [TurnTrace] {
        if let cache { return cache }
        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
              let data = try? Data(contentsOf: url) else {
            cache = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([TurnTrace].self, from: data)) ?? []
        cache = decoded
        return decoded
    }

    private func save(_ traces: [TurnTrace]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(traces) else { return }
        queue.async {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: url, options: .atomic)
                #endif
                StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: url)
            } catch {
                // Diagnostics must never crash the app or log their own I/O failure.
            }
        }
    }
}
