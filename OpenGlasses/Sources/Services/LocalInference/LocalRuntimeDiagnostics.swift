import Foundation

/// The numbers the diagnostics card shows, captured where the runtime already measures them
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "a diagnostic card showing framework
/// revision, model revision, context, first-token latency, tokens/second, memory delta, and
/// thermal state").
///
/// ### Why this is not a second metrics path
/// The GGUF backend already measures every one of these to write its `generationCompleted` and
/// `loaded` log lines: prompt/generated token counts, first-token latency, total duration, the
/// headroom delta against the reading taken at load, the app footprint, and the thermal state.
/// A card that measured them again would be a second stopwatch disagreeing with the first. So this
/// type is a *sink at the same call site*: the backend hands the identical values to the log and to
/// this store, and the card renders what the log recorded.
///
/// Tokens per second is the one number that is derived rather than recorded, and it is derived
/// here rather than in the backend for the reason PR3 gives for leaving it out of the log line —
/// a stored ratio is one more thing that can disagree with its inputs. The card shows the inputs
/// beside it.
struct LocalRuntimeDiagnosticsSample: Equatable, Sendable {

    /// Which measurement this is. A load and a generation report different fields, and a card that
    /// pretended one was the other would show a first-token latency of zero for a model nobody has
    /// spoken to yet.
    enum Kind: Equatable, Sendable {
        /// Recorded when a model finished loading.
        case load
        /// Recorded when a generation finished normally.
        case generation
    }

    /// Thermal state, as its own case set. `ProcessInfo.ThermalState` is an imported enum; copying
    /// it keeps this value trivially `Sendable` and keeps the spoken names in one place.
    enum ThermalState: String, Equatable, Sendable {
        case nominal, fair, serious, critical, unknown

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .unknown
            }
        }

        /// Said in terms of what it means for the person holding the phone, not the enum name.
        var displayName: String {
            switch self {
            case .nominal: return "Normal"
            case .fair: return "Warm"
            case .serious: return "Hot — the phone is slowing itself down"
            case .critical: return "Very hot — on-device work will be throttled hard"
            case .unknown: return "Unknown"
            }
        }
    }

    let kind: Kind
    let modelID: LocalModelID
    let runtime: LocalModelRuntime
    /// The exact revision the installed files were pinned at, or the legacy sentinel.
    let modelRevision: String
    /// Context window the runtime actually created, after every clamp.
    let contextTokens: Int
    /// Prompt tokens submitted. Zero for a load sample.
    let promptTokens: Int
    /// Tokens produced. Zero for a load sample.
    let generatedTokens: Int
    /// Milliseconds from the start of the turn to the first produced token; nil when nothing was
    /// produced, and always nil for a load sample.
    let firstTokenMilliseconds: Int?
    /// For a generation: the whole turn, prefill included. For a load: how long the load took.
    let totalMilliseconds: Int
    /// Headroom now minus headroom at the moment the load finished. Negative means the app has
    /// taken more memory since; that is the number a jetsam investigation starts from.
    let headroomDeltaBytes: Int64
    let footprintBytes: Int64
    let thermalState: ThermalState
    let recordedAt: Date

    /// Decode rate: tokens produced per second *after* the first one arrived. Prefill is excluded
    /// deliberately — including it produces a figure that changes with prompt length and describes
    /// neither the prefill nor the decode.
    ///
    /// `nil` when there is nothing to divide: no tokens, no first-token time, or a window so short
    /// the ratio would be an artefact of the clock rather than a measurement.
    var tokensPerSecond: Double? {
        guard kind == .generation, generatedTokens > 1, let first = firstTokenMilliseconds else {
            return nil
        }
        let decodeMilliseconds = totalMilliseconds - first
        guard decodeMilliseconds >= 100 else { return nil }
        // The first token is excluded from the numerator as well as the denominator: it is the one
        // token that was produced *at* `first`, not during the window being measured.
        return Double(generatedTokens - 1) / (Double(decodeMilliseconds) / 1000)
    }
}

/// The last sample from each runtime, for the diagnostics card to read.
///
/// Deliberately not a `@Published` object: samples are recorded from a nonisolated context inside
/// the decode loop, and hopping to the main actor to publish would put a UI concern inside the one
/// path that must not wait for anything. The card reads it on a timer it already has.
///
/// It holds **one sample per runtime** and nothing else — no history, no aggregation. A ring buffer
/// of inference timings is a performance archive, and this is a card that says what the last run
/// did.
final class LocalRuntimeDiagnostics: @unchecked Sendable {

    /// The instance the app's backends record into. Tests construct their own.
    static let shared = LocalRuntimeDiagnostics()

    private let lock = NSLock()
    private var samples: [LocalModelRuntime: LocalRuntimeDiagnosticsSample] = [:]

    init() {}

    func record(_ sample: LocalRuntimeDiagnosticsSample) {
        lock.lock()
        // A generation sample never replaces itself with a load sample: loading a model that is
        // already resident is a no-op that would otherwise wipe the timings from the turn before.
        if let existing = samples[sample.runtime],
           existing.kind == .generation, sample.kind == .load,
           existing.modelID == sample.modelID {
            lock.unlock()
            return
        }
        samples[sample.runtime] = sample
        lock.unlock()
    }

    func latest(for runtime: LocalModelRuntime) -> LocalRuntimeDiagnosticsSample? {
        lock.lock()
        defer { lock.unlock() }
        return samples[runtime]
    }

    /// The most recent sample from any runtime. What the card shows when the user has not chosen a
    /// runtime to inspect.
    var latest: LocalRuntimeDiagnosticsSample? {
        lock.lock()
        defer { lock.unlock() }
        return samples.values.max { $0.recordedAt < $1.recordedAt }
    }

    func clear() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

// MARK: - Card copy

/// The diagnostics card's rows, as label/value pairs with spoken forms.
///
/// Every field's source is named in a comment beside it, because "where did this number come from"
/// is the first question anyone reading a diagnostics card asks, and the answer must not be
/// "somewhere in the view".
enum LocalRuntimeDiagnosticsCard {

    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let value: String
        /// Spoken form, when the drawn value is an abbreviation or a hash.
        let spokenValue: String?

        init(id: String, label: String, value: String, spokenValue: String? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.spokenValue = spokenValue
        }

        var spokenLabel: String { "\(label): \(spokenValue ?? value)" }
    }

    /// Build the card. `frameworkDescription` is the engine's own report of the revision it was
    /// built from (`LlamaRuntimeAvailability.engineDescription`), passed in so this stays pure.
    static func rows(sample: LocalRuntimeDiagnosticsSample?,
                     frameworkDescription: String) -> [Row] {
        // 1. Framework revision — from the linked binary, not a constant typed into Swift.
        var rows = [Row(id: "framework", label: "Runtime build", value: frameworkDescription,
                        spokenValue: spokenRevisionPhrase(frameworkDescription))]

        guard let sample else {
            rows.append(Row(id: "empty", label: "Last run",
                            value: "No on-device run recorded yet",
                            spokenValue: "No on-device run has been recorded yet"))
            return rows
        }

        // 2. Model revision — the descriptor's pinned revision, as installed.
        rows.append(Row(id: "modelRevision", label: "Model version",
                        value: revisionText(sample.modelRevision),
                        spokenValue: spokenRevision(sample.modelRevision)))
        // 3. Context — what the runtime actually created after every clamp, reported by the
        //    context itself at load time.
        rows.append(Row(id: "context", label: "Context",
                        value: "\(sample.contextTokens) tokens"))

        if sample.kind == .generation {
            // 4. First-token latency — the backend's `firstTokenMilliseconds`, measured from the
            //    start of the turn, prefill included.
            rows.append(Row(id: "firstToken", label: "First token",
                            value: sample.firstTokenMilliseconds.map { "\($0) ms" } ?? "—",
                            spokenValue: sample.firstTokenMilliseconds
                                .map { "\($0) milliseconds" } ?? "not measured"))
            // 5. Tokens per second — derived from the recorded counts and durations beside it.
            rows.append(Row(id: "rate", label: "Speed",
                            value: sample.tokensPerSecond
                                .map { String(format: "%.1f tokens/s", $0) } ?? "—",
                            spokenValue: sample.tokensPerSecond
                                .map { String(format: "%.1f tokens per second", $0) }
                                ?? "not measured"))
            rows.append(Row(id: "tokens", label: "Tokens",
                            value: "\(sample.promptTokens) in, \(sample.generatedTokens) out",
                            spokenValue: "\(sample.promptTokens) in, \(sample.generatedTokens) out"))
        } else {
            rows.append(Row(id: "loadTime", label: "Load time",
                            value: "\(sample.totalMilliseconds) ms",
                            spokenValue: "\(sample.totalMilliseconds) milliseconds"))
        }

        // 6. Memory delta — headroom now against the reading taken when the load finished.
        rows.append(Row(id: "memory", label: "Memory since load",
                        value: signedBytes(sample.headroomDeltaBytes),
                        spokenValue: spokenMemoryDelta(sample.headroomDeltaBytes)))
        // 7. Thermal state — `ProcessInfo.thermalState` as read at the same moment.
        rows.append(Row(id: "thermal", label: "Thermal state",
                        value: sample.thermalState.displayName))
        return rows
    }

    private static func revisionText(_ revision: String) -> String {
        guard revision != LocalModelDescriptor.floatingRevision, !revision.isEmpty else {
            return "Not pinned"
        }
        return String(revision.prefix(12))
    }

    private static func spokenRevision(_ revision: String) -> String {
        guard revision != LocalModelDescriptor.floatingRevision, !revision.isEmpty else {
            return "not pinned to an exact version"
        }
        return "version \(String(revision.prefix(12)))"
    }

    /// A build identifier read aloud verbatim is a stream of letters; say what it is first.
    private static func spokenRevisionPhrase(_ description: String) -> String {
        "engine build \(description)"
    }

    private static func signedBytes(_ delta: Int64) -> String {
        let magnitude = LocalModelPresentation.formatBytes(abs(delta))
        if delta == 0 { return "unchanged" }
        return delta > 0 ? "+\(magnitude) free" : "−\(magnitude) free"
    }

    private static func spokenMemoryDelta(_ delta: Int64) -> String {
        let magnitude = LocalModelPresentation.formatBytes(abs(delta))
        if delta == 0 { return "unchanged since the model loaded" }
        return delta > 0
            ? "\(magnitude) more free than when the model loaded"
            : "\(magnitude) less free than when the model loaded"
    }
}
