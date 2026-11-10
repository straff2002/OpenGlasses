import Foundation

/// One finished turn, as support needs to see it: what went to the model with the words, which
/// model answered, how long it took, and how it ended (support ask, 2026-09-26).
///
/// Conversation words remain in the conversation thread. A trace carries what went *with* them:
/// prompt sizes, manual citations, tool outcomes and errors. Web searches additionally carry a
/// bounded, credential-redacted query and returned text, which may contain personal information.
/// Traces stay on the device for up to a fortnight and leave only in a support report the wearer
/// previews and shares. Ordinary event-log diagnostics contain none of this search content.
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
    /// `at` is the hand-off to the model rather than a fallback mark (the end of speech, which
    /// comes *before* the question is saved). Optional: traces written before it decode as nil,
    /// and the export infers it from what the turn recorded.
    var atHandOff: Bool?
    var threadId: String?
    var fieldSessionId: String?
    var backend: String?
    var model: String?
    var transcriber: String?
    var speechEngine: String?
    var micRoute: String?
    var endOfTurn: String?
    var imageSent: Bool
    /// The words sent were the app's own prompt — a photo from a button or quick action — not the
    /// wearer's. Optional: traces written before it decode as nil; nil and false read the same.
    var appPrompt: Bool?
    /// The effective reasoning token (Plan GB P0). Optional: traces written before it decode as nil.
    var reasoning: String?
    /// The OpenAI endpoint token (Plan GC). Optional: traces written before it decode as nil.
    var route: String?
    /// Plan LA: the quiet-ending verdict token. Optional: traces written before it decode as nil.
    var quietVerdict: String?
    var promptBlocks: [TurnTimeline.PromptBlock]
    var manualPassages: [String]
    var manualRefused: Bool
    var toolCalls: [TurnTimeline.ToolNote]
    var outcome: Outcome
    var failure: String?
    // What a refused request adds to the failure (Plan IE P0). All optional: traces written
    // before them decode as nil, and a turn that was not refused has none.
    /// `ProviderRejection.Reason`, by raw value.
    var rejectionReason: String?
    /// The provider's id for the refused request.
    var requestId: String?
    /// A refusal over the per-minute allowance (Plan KL P1): the account's tokens a minute, and
    /// what the provider counted the request as. Numbers only, read out of the provider's message.
    var allowanceLimit: Int?
    var allowanceRequested: Int?
    /// `AnthropicAuth.CredentialKind`, by raw value — the kind of credential, never the value.
    var credential: String?
    /// How many tool definitions the request carried, and how many came from MCP servers.
    var toolsSent: Int?
    var toolsFromMCP: Int?
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
        atHandOff = timeline.commitAt != nil
        threadId = timeline.threadId
        fieldSessionId = timeline.fieldSessionId
        backend = timeline.backend?.label
        model = timeline.model.map(Self.modelName)
        transcriber = timeline.transcriber?.rawValue
        speechEngine = timeline.ttsEngine?.rawValue
        micRoute = timeline.micRoute?.rawValue
        endOfTurn = timeline.endOfTurnReason?.rawValue
        imageSent = timeline.imageSent
        appPrompt = timeline.appPrompt ? true : nil
        reasoning = timeline.reasoning
        route = timeline.route
        quietVerdict = timeline.quietVerdict
        promptBlocks = timeline.promptBlocks
        manualPassages = timeline.manualPassages
        manualRefused = timeline.manualRefused
        toolCalls = timeline.toolCalls
        failure = timeline.failure?.description
        rejectionReason = timeline.rejection?.reason.rawValue
        requestId = timeline.rejection?.requestID
        allowanceLimit = timeline.rejection?.limit ?? timeline.overAllowanceLimit
        allowanceRequested = timeline.rejection?.requested
        credential = timeline.credential?.rawValue
        toolsSent = timeline.toolsSent?.count
        toolsFromMCP = timeline.toolsSent?.fromMCP
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
    /// rest of the path is the phone's own layout. A service's model id keeps its slash: Groq and
    /// OpenRouter name models `vendor/model`, and a report that showed `qwen3.8-27b` for Groq's
    /// `qwen/qwen3.8-27b` read as a model Groq does not serve (support report, 2026-10-29).
    static func modelName(_ raw: String) -> String {
        let isPath = raw.hasPrefix("/") || raw.hasPrefix("~") || raw.lowercased().hasPrefix("file:")
        guard isPath else { return raw }
        let path = raw.lowercased().hasPrefix("file:") ? (URL(string: raw)?.path ?? raw) : raw
        return URL(fileURLWithPath: path).lastPathComponent
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
    nonisolated static let maxStorageBytes = 8_000_000

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

    /// Newest traces within age, count and encoded-byte bounds, oldest first. The byte bound
    /// matches the reader: search content must never grow a file that the next launch refuses.
    nonisolated static func retained(_ traces: [TurnTrace], now: Date, capacity: Int,
                                    maxBytes: Int = maxStorageBytes) -> [TurnTrace] {
        let fresh = traces.filter { now.timeIntervalSince($0.at) <= retention && $0.at <= now.addingTimeInterval(60) }
            .sorted { $0.at < $1.at }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var kept: [TurnTrace] = []
        var bytes = 2 // JSON array brackets, plus a comma between adjacent records below.
        for trace in fresh.suffix(max(0, capacity)).reversed() {
            guard let size = try? encoder.encode(trace).count,
                  bytes + size + (kept.isEmpty ? 0 : 1) <= maxBytes else { break }
            bytes += size + (kept.isEmpty ? 0 : 1)
            kept.append(trace)
        }
        return kept.reversed()
    }

    private func load() -> [TurnTrace] {
        if let cache { return cache }
        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxStorageBytes,
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
