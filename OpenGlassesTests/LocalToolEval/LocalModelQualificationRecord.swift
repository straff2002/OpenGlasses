import CryptoKit
import Foundation
#if canImport(OpenGlasses)
@testable import OpenGlasses
#endif

/// What a device qualification run writes to `Documents/results.json` (Plan MQ P3), and what a
/// reviewed copy of becomes in `reports/` (decision 8).
///
/// **Counts and hashes only**, as `RetrievalEvalCore` writes: no question, passage, tool argument
/// or answer text, and no case id either (each run is keyed by a hash of its case id and repeat).
/// It holds the device, OS build, app commit, runtime revision, model revision and quantisation,
/// the sampling set the run used, the gate's decisions, the memory readings and the timings.
///
/// Written after every run, so a run that is stopped, killed or loses the screen never loses the
/// cases it finished; a relaunch with the same model, corpus, sampling and selection carries on
/// from where it stopped (`resumable(with:)`), and `summary` is recomputed from `runs` each time.
struct LocalModelQualificationRecord: Codable, Equatable {

    /// 2 (2026-11-22): the runtime fits a tool turn's definitions to the budget, and a native tool
    /// turn may run on a larger window, so a /1 record measured something else and is not resumed.
    static let schemaName = "local-model-qualification/2"

    var schema = LocalModelQualificationRecord.schemaName
    var startedAt: String
    var updatedAt: String
    /// Every selected case ran every repeat.
    var finished = false
    /// Why the run ended early: a gate stop (its reasons), the app leaving the foreground, a failure
    /// to load. A token, never free text.
    var stopReason: String?

    var device: Device
    var app: App
    var runtime: Runtime
    var model: Model
    var sampling: Sampling?
    var corpus: Corpus
    var gate: Gate
    var memory: Memory
    /// The context window native tool turns were budgeted with (Plan MQ P3).
    var window: Window
    var timing = Timing()
    var thermalTrace: [ThermalSample] = []
    var runs: [RunEntry] = []
    var summary = Summary()

    struct Device: Codable, Equatable {
        /// `hw.machine`, e.g. `iPhone17,3`.
        var model: String
        var osVersion: String
        var osBuild: String
        var marketingRAMGB: Double
        var physicalMemoryBytes: Int64
    }

    struct App: Codable, Equatable {
        /// The commit stamped at generation (`AvenkinSourceCommit`), or nil when the build has none.
        var commit: String?
        var version: String?
        var build: String?
    }

    struct Runtime: Codable, Equatable {
        /// `mlx-swift-lm` or `FoundationModels`.
        var name: String
        /// The pinned revision the app was built against.
        var revision: String
    }

    struct Model: Codable, Equatable {
        var id: String
        /// The hub revision the catalog recorded, or nil (Apple's model has none to name).
        var revision: String?
        var quantization: String?
        /// `copied` (MLX), `mapped` (GGUF) or `system` (Apple's on-device model).
        var backing: String
        /// The revision the download actually holds (the MLX path fetches the hub's `main`), read
        /// after it is on the phone; it can differ from `revision`.
        var downloadedRevision: String? = nil

        /// What a resumed run must share: everything but the download's revision, which is only
        /// known once the model is on the phone.
        var identity: [String?] { [id, revision, quantization, backing] }
    }

    struct Sampling: Codable, Equatable {
        /// The catalog's source note, or nil for the global set.
        var source: String?
        var general: LocalSamplingConfiguration
        var toolTurn: LocalSamplingConfiguration
    }

    struct Corpus: Codable, Equatable {
        var version: Int
        /// The corpus header's `body-sha256`: which cases these are.
        var bodySha256: String
        var groups: [String]
        var alsoCategories: [String]
        var limit: Int?
        var repeats: Int
        var selectedCases: Int
        /// Near-miss twins a live run skips (`LocalToolEval.Case.isCheckOnly`).
        var checkOnlySkipped: Int
        /// A targeted rerun's categories (`--categories`); nil for the whole selection. Such a run's
        /// floors read only the cases it took, so it is never the record a model qualifies on.
        var onlyCategories: [String]? = nil
    }

    struct Window: Codable, Equatable {
        /// The model's ordinary window (`LocalModelBudget.contextWindow(for:)`).
        var ordinaryTokens: Int
        /// The window chosen for the run's tool turns at load (`LocalModelBudget.toolTurnContextWindow`).
        var toolTurnTokens: Int
        /// `LocalModelBudget.ToolTurnWindowReason`: ordinary, smallPhone, memory or raised.
        var reason: String
        /// The prompt budget on that window.
        var toolTurnPromptBudget: Int
    }

    struct Gate: Codable, Equatable {
        var settleSeconds: Double
        var capSeconds: Double
        var requiresCharger: Bool
        var waits = 0
        var waitedSeconds = 0.0
        /// Runs measured after the wait ran out on heat. A flagged run can't grant a badge.
        var flaggedRuns = 0
        /// Each reason's count over every wait.
        var reasons: [String: Int] = [:]
    }

    struct Memory: Codable, Equatable {
        /// `os_proc_available_memory()` + footprint, measured once at launch.
        var killLimitBytes: Int64?
        var recommendedWorkingSetBytes: Int64
        var reserveBytes: Int64
        var footprintBeforeLoadBytes: Int64
        var fitJudgedAgainst: String
        var fitNeededBytes: Int64
        var fitLimitBytes: Int64
        var fits: Bool
        var footprintAfterLoadBytes: Int64 = 0
        var peakFootprintBytes: Int64 = 0
        /// Kill limit minus the peak; negative means the peak crossed it.
        var headroomAtPeakBytes: Int64?
    }

    struct Timing: Codable, Equatable {
        var loadSeconds: Double?
        /// Seconds to read the prompt, per generation (time to first token).
        var firstTokenSeconds: Distribution?
        var decodeTokensPerSecond: Distribution?
        /// Seconds from a cancel to the generation stopping, per probe.
        var cancelLatencySeconds: Distribution?
        var cancelProbes = 0
        /// Probes that did not stop within `cancelBoundSeconds`.
        var cancelOverBound = 0
        var cancelBoundSeconds = 1.0
        /// Seconds the run spent measuring, waits excluded.
        var measuringSeconds = 0.0
        /// Runs that started `serious` or hotter: their answers count, their timing doesn't
        /// (`QualificationRunGate.countsForTiming`).
        var hotRunsExcludedFromTiming: Int?
        /// The excluded runs' decode rate, to show what heat cost.
        var hotDecodeTokensPerSecond: Distribution?
    }

    struct Distribution: Codable, Equatable {
        var count: Int
        var median: Double
        var p90: Double
        var max: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
            count = sorted.count
            median = at(0.5)
            p90 = at(0.9)
            max = sorted.last ?? 0
        }
    }

    struct ThermalSample: Codable, Equatable {
        /// Seconds since the run started.
        var t: Double
        /// `QualificationRunGate.Thermal.rawValue`: 0 nominal, 1 fair, 2 serious, 3 critical.
        var state: Int
    }

    /// One run of one case: its key, what it measured and how it graded.
    struct RunEntry: Codable, Equatable {
        /// `LocalModelQualificationRecord.key(caseID:repeat:)`.
        var key: String
        /// A hash of the case id, the same for every repeat.
        var caseHash: String
        var repeatIndex: Int
        var category: String
        var group: String
        var grades: [String: Bool]
        var passed: Bool
        var flagged: Bool
        var generations: Int
        var zeroTokenGenerations: Int
        var cutGenerations: Int
        var readerUnparsed: Int
        /// The error's type and case name when the run failed on one (`LocalToolEval.errorKind`).
        var errorKind: String?
        var generatedTokens: Int
        var promptSeconds: [Double]
        /// Tokens prefilled, per generation.
        var promptTokens: [Int]
        var decodeTokensPerSecond: [Double]
        /// What the runtime's fit sent of the tools (Plan MQ P3; counts only): offered and kept on
        /// the first generation that offered tools, generations that dropped one or went compact,
        /// whether an expected tool was dropped, and the window used.
        var toolsOffered: Int?
        var toolsKept: Int?
        var fitDroppedGenerations: Int
        var compactGenerations: Int
        var expectedToolDropped: Bool
        var contextWindow: Int?
        /// Calls `LocalTurnRouter` made before the model (Plan MQ P3); nil in older records.
        var routedCalls: Int?
        /// Arguments the loop dropped from the model's calls because nobody said their number
        /// (Plan MQ P3; a count only); nil in older records.
        var argumentsDropped: Int?
        /// `QualificationRunGate.Thermal`'s raw value when the case started; nil in older records.
        var thermalAtStart: Int?
        var seconds: Double
    }

    struct Tally: Codable, Equatable {
        var passed: Int
        var runs: Int
        /// The pass rate's 95% bootstrap interval over cases (each case's share of its repeats).
        var mean: Double?
        var lower: Double?
        var upper: Double?
    }

    struct GroupSummary: Codable, Equatable {
        var overall: Tally
        var byCategory: [String: Tally]
        var byGrader: [String: Tally]
        var cutRuns: Int
        var templateFaultRuns: Int
        var readerUnparsedRuns: Int
        /// Runs where the fit dropped a tool the case expected: "the fit dropped it", told apart
        /// from "the model missed it" (Plan MQ P3).
        var expectedToolDroppedRuns: Int
        /// Runs where the fit dropped any tool, and runs that sent compact definitions.
        var fitDroppedRuns: Int
        var compactRuns: Int
        /// Runs whose call the router made before the model (Plan MQ P3); nil in older records.
        var routedRuns: Int?
        /// Runs where the loop dropped a number nobody said from a call (Plan MQ P3); nil in older records.
        var argumentsDroppedRuns: Int?
    }

    struct FloorResult: Codable, Equatable {
        var name: String
        var minimum: Double
        var passed: Int
        var runs: Int
        var met: Bool
    }

    struct Summary: Codable, Equatable {
        var groups: [String: GroupSummary] = [:]
        var floors: [FloorResult] = []
        /// Floors no run measured: not qualified on them.
        var unjudgedFloors: [String] = []
        var flaggedRuns = 0
        /// Every floor judged and met, the run finished, and nothing flagged. What a badge needs
        /// before anyone reviews the record; not a badge by itself.
        var clearsFloorsUnflagged = false
    }

    // MARK: - Keys

    /// A short hash of a case id: enough to match a run to its case on a relaunch, without the id.
    static func caseHash(_ caseID: String) -> String {
        SHA256.hash(data: Data(caseID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func key(caseID: String, repeat index: Int) -> String {
        "\(caseHash(caseID))#\(index)"
    }

    /// Keys already measured.
    var completedKeys: Set<String> { Set(runs.map(\.key)) }

    /// Whether a record found on disk may be carried on by a run with `fresh`'s settings: same
    /// schema, model, runtime, corpus, selection, repeats and sampling, and not finished.
    func resumable(with fresh: LocalModelQualificationRecord) -> Bool {
        schema == fresh.schema && !finished && model.identity == fresh.model.identity && runtime == fresh.runtime
            && corpus == fresh.corpus && sampling == fresh.sampling && window == fresh.window
    }

    // MARK: - Adding runs

    mutating func add(_ run: LocalToolEval.Run, repeat index: Int, flagged: Bool, seconds: Double,
                      thermalAtStart: QualificationRunGate.Thermal? = nil) {
        let m = run.measurements
        let entry = RunEntry(
            key: Self.key(caseID: run.caseID, repeat: index), caseHash: Self.caseHash(run.caseID), repeatIndex: index,
            category: run.category.rawValue, group: run.group.rawValue,
            grades: Dictionary(uniqueKeysWithValues: run.grades.map { ($0.key.rawValue, $0.value) }),
            passed: run.passed, flagged: flagged, generations: m.generations,
            zeroTokenGenerations: m.zeroTokenGenerations, cutGenerations: m.cutGenerations,
            readerUnparsed: m.readerUnparsed, errorKind: m.errorKind, generatedTokens: m.generatedTokens,
            promptSeconds: m.promptSeconds, promptTokens: m.promptTokens, decodeTokensPerSecond: m.decodeTokensPerSecond,
            toolsOffered: m.toolsOffered, toolsKept: m.toolsKept, fitDroppedGenerations: m.fitDroppedGenerations,
            compactGenerations: m.compactGenerations, expectedToolDropped: m.expectedToolDropped,
            contextWindow: m.contextWindow, routedCalls: m.routedCalls, argumentsDropped: m.argumentsDropped,
            thermalAtStart: thermalAtStart?.rawValue, seconds: seconds)
        runs.removeAll { $0.key == entry.key }
        runs.append(entry)
        recompute()
    }

    /// The runs back as the eval's own type, for its report and floors.
    var evalRuns: [LocalToolEval.Run] {
        runs.compactMap { entry in
            guard let category = LocalToolEval.Category(rawValue: entry.category),
                  let group = LocalToolEval.Group(rawValue: entry.group) else { return nil }
            var grades: [LocalToolEval.Grader: Bool] = [:]
            for (name, passed) in entry.grades { if let grader = LocalToolEval.Grader(rawValue: name) { grades[grader] = passed } }
            var measurements = LocalToolEval.Measurements()
            measurements.generations = entry.generations
            measurements.zeroTokenGenerations = entry.zeroTokenGenerations
            measurements.cutGenerations = entry.cutGenerations
            measurements.readerUnparsed = entry.readerUnparsed
            measurements.errorKind = entry.errorKind
            measurements.generatedTokens = entry.generatedTokens
            measurements.promptSeconds = entry.promptSeconds
            measurements.promptTokens = entry.promptTokens
            measurements.decodeTokensPerSecond = entry.decodeTokensPerSecond
            measurements.toolsOffered = entry.toolsOffered
            measurements.toolsKept = entry.toolsKept
            measurements.fitDroppedGenerations = entry.fitDroppedGenerations
            measurements.compactGenerations = entry.compactGenerations
            measurements.expectedToolDropped = entry.expectedToolDropped
            measurements.contextWindow = entry.contextWindow
            measurements.routedCalls = entry.routedCalls ?? 0
            measurements.argumentsDropped = entry.argumentsDropped ?? 0
            // The id is not kept; the hash stands in for it, which is all the report groups by.
            return LocalToolEval.Run(caseID: entry.caseHash, category: category, group: group, grades: grades,
                                     measurements: measurements)
        }
    }

    /// Recompute `summary` and the timing distributions from `runs`.
    mutating func recompute() {
        var report = LocalToolEval.Report()
        let evalRuns = self.evalRuns
        for run in evalRuns { report.add(run) }

        func interval(_ entries: [RunEntry]) -> (Double, Double, Double)? {
            // Over cases, not runs: a case's repeats are not independent.
            let byCase = Dictionary(grouping: entries, by: \.caseHash)
            let shares = byCase.values.map { runs in Double(runs.filter(\.passed).count) / Double(runs.count) }
            return EvalIntervals.bootstrapInterval(values: shares).map { ($0.mean, $0.lower, $0.upper) }
        }
        func tally(_ entries: [RunEntry]) -> Tally {
            let i = interval(entries)
            return Tally(passed: entries.filter(\.passed).count, runs: entries.count, mean: i?.0, lower: i?.1, upper: i?.2)
        }

        var groups: [String: GroupSummary] = [:]
        for group in LocalToolEval.Group.allCases {
            let entries = runs.filter { $0.group == group.rawValue }
            guard !entries.isEmpty, let counted = report.groups[group] else { continue }
            var byCategory: [String: Tally] = [:]
            for category in LocalToolEval.Category.allCases {
                let inCategory = entries.filter { $0.category == category.rawValue }
                if !inCategory.isEmpty { byCategory[category.rawValue] = tally(inCategory) }
            }
            var byGrader: [String: Tally] = [:]
            for (grader, t) in counted.byGrader {
                byGrader[grader.rawValue] = Tally(passed: t.passed, runs: t.runs, mean: nil, lower: nil, upper: nil)
            }
            groups[group.rawValue] = GroupSummary(overall: tally(entries), byCategory: byCategory, byGrader: byGrader,
                                                  cutRuns: counted.cutRuns, templateFaultRuns: counted.templateFaultRuns,
                                                  readerUnparsedRuns: counted.readerUnparsedRuns,
                                                  expectedToolDroppedRuns: counted.expectedToolDroppedRuns,
                                                  fitDroppedRuns: counted.fitDroppedRuns, compactRuns: counted.compactRuns,
                                                  routedRuns: counted.routedRuns,
                                                  argumentsDroppedRuns: counted.argumentsDroppedRuns)
        }
        let shortfalls = Set(report.floorShortfalls().map(\.name))
        let floors = LocalToolEval.Floors.all.compactMap { floor -> FloorResult? in
            guard let t = report.tally(for: floor) else { return nil }
            return FloorResult(name: floor.name, minimum: floor.minimum, passed: t.passed, runs: t.runs,
                               met: !shortfalls.contains(floor.name))
        }
        let flagged = runs.filter(\.flagged).count
        summary = Summary(groups: groups, floors: floors, unjudgedFloors: report.unjudgedFloors().map(\.name),
                          flaggedRuns: flagged,
                          clearsFloorsUnflagged: finished && report.clearsFloors && flagged == 0)
        gate.flaggedRuns = flagged
        // Heat changes the speed, not the answers: every run counts above, only cool ones here.
        func cool(_ entry: RunEntry) -> Bool {
            entry.thermalAtStart.flatMap(QualificationRunGate.Thermal.init(rawValue:))
                .map(QualificationRunGate.countsForTiming) ?? true
        }
        let coolRuns = runs.filter(cool)
        let hotRuns = runs.filter { !cool($0) }
        timing.firstTokenSeconds = Distribution(coolRuns.flatMap(\.promptSeconds))
        timing.decodeTokensPerSecond = Distribution(coolRuns.flatMap(\.decodeTokensPerSecond))
        timing.hotRunsExcludedFromTiming = hotRuns.count
        timing.hotDecodeTokensPerSecond = Distribution(hotRuns.flatMap(\.decodeTokensPerSecond))
    }

    // MARK: - Writing

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> LocalModelQualificationRecord? {
        try? JSONDecoder().decode(LocalModelQualificationRecord.self, from: data)
    }
}
