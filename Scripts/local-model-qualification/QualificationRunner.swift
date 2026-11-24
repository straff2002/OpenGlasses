import CryptoKit
import Foundation
import UIKit

/// One qualification run: the launch arguments, the model, the gate, the corpus and the record.
///
/// Launch arguments (all optional):
///
///     --model <id>         an MLX catalog model id (default Gemma 4 E2B)
///     --apple              Apple's on-device model instead, as the baseline
///     --gguf <id>          a GGUF catalog model instead, on the GGUF runtime (Plan MQ P2), its
///                          weights file already in Documents/gguf/ (see README.md)
///     --gguf-batch <n>     a GGUF run's prefill batch, logical and physical (n_batch and n_ubatch),
///                          for this run only (default the app's: 512 logical, the engine's 512
///                          physical); the record names it
///     --repeats <n>        runs per case (default 3)
///     --groups <a,b>       case groups (default fieldAssist, with the restraint and
///                          not-in-the-manual categories beside it); `all` for every case
///     --limit <n>          the first n selected cases only (a smoke run)
///     --categories <a,b>   only cases of these categories (a targeted rerun, e.g. toolChoice,multiTurn)
///     --settle <seconds>   how long the phone must stay below critical before the first case and after a critical spell (default 120)
///     --cap <seconds>      the longest one wait lasts (default 1200)
///     --allow-battery      measure off the charger (an attended run; Low Power Mode still waits)
///     --cancel-probes <n>  cancel-latency probes after the cases (default 6; 0 for none)
///     --fresh              start a new record instead of carrying on the one in Documents
///
/// Counts and hashes only reach the record and the screen.
@MainActor
final class QualificationRunner: ObservableObject {

    struct Options: Equatable {
        var modelID = "mlx-community/gemma-4-e2b-it-4bit"
        var apple = false
        /// Plan MQ P2: a GGUF catalog id, run on `LlamaCppLocalInferenceBackend`.
        var ggufModelID: String?
        /// Plan MQ: a GGUF run's prefill batch (`n_batch` and `n_ubatch`), to compare on a phone.
        var ggufBatch: Int?
        var repeats = 3
        var selection = LocalToolEval.Selection.qualification
        var policy = QualificationRunGate.Policy.unattended
        var cancelProbes = 6
        var fresh = false
        /// Debug only: write each tool-turn generation's raw text and calls to
        /// Documents/debug-transcripts.jsonl. Never part of the record and never committed.
        var transcripts = false
        /// An experiment: the temperature every tool turn samples at, over the catalog's set
        /// (`LocalModelSampling.qualificationToolTurnOverride`). The record names it.
        var toolTemperature: Float?
        /// An experiment: P1's tool guide instead of today's (`LLMService.qualificationUsesOriginalToolGuide`).
        var originalToolGuide = false

        static func parse(_ arguments: [String]) -> Options {
            var options = Options()
            var index = arguments.startIndex
            func value() -> String? {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex else { return nil }
                index = next
                return arguments[next]
            }
            while index < arguments.endIndex {
                switch arguments[index] {
                case "--model": if let v = value() { options.modelID = v }
                case "--apple": options.apple = true
                case "--gguf": if let v = value() { options.ggufModelID = v }
                case "--gguf-batch": if let v = value().flatMap(Int.init), v > 0 { options.ggufBatch = v }
                case "--repeats": if let v = value().flatMap(Int.init), v > 0 { options.repeats = v }
                case "--limit": if let v = value().flatMap(Int.init), v >= 0 { options.selection.limit = v }
                case "--settle": if let v = value().flatMap(Double.init), v >= 0 { options.policy.settleSeconds = v }
                case "--cap": if let v = value().flatMap(Double.init), v >= 0 { options.policy.capSeconds = v }
                case "--allow-battery": options.policy.requiresCharger = false
                case "--cancel-probes": if let v = value().flatMap(Int.init), v >= 0 { options.cancelProbes = v }
                case "--fresh": options.fresh = true
                case "--transcripts": options.transcripts = true
                case "--original-tool-guide": options.originalToolGuide = true
                case "--tool-temperature": if let v = value().flatMap(Float.init), v >= 0 { options.toolTemperature = v }
                case "--categories":
                    if let v = value() {
                        let only = Set(v.split(separator: ",").compactMap { LocalToolEval.Category(rawValue: String($0)) })
                        if !only.isEmpty { options.selection.onlyCategories = only }
                    }
                case "--groups":
                    if let v = value() {
                        if v == "all" {
                            options.selection = .everything
                        } else {
                            let groups = Set(v.split(separator: ",").compactMap { LocalToolEval.Group(rawValue: String($0)) })
                            if !groups.isEmpty { options.selection.groups = groups; options.selection.alsoCategories = [] }
                        }
                    }
                default: break
                }
                index = arguments.index(after: index)
            }
            return options
        }
    }

    @Published private(set) var status = "Starting"
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var passed = 0
    @Published private(set) var isRunning = false

    let options: Options
    private let service = LocalLLMService()
    /// The GGUF runtime (Plan MQ P2), with its weights read from `ggufDirectory` and GGUF switched
    /// on: this app stands in for the flag-on build.
    private lazy var gguf = LlamaCppLocalInferenceBackend(
        directoryForInstallation: { _ in QualificationRunner.ggufDirectory },
        isRuntimeEnabled: { true },
        recordDiagnostics: { _ in })
    private var runTask: Task<Void, Never>?
    private var record: LocalModelQualificationRecord?
    private let started = Date()
    private var sampler: Task<Void, Never>?
    private var lastThermal: Int?
    /// Set once the model is resident in this process, so a run resumed after the app comes back
    /// to the foreground neither reloads it nor re-measures the fit with its weights already counted.
    private var modelLoaded = false
    /// One per process: a run resumed in the same process appends to it rather than starting it over.
    private lazy var transcript: DebugTranscript? = options.transcripts ? DebugTranscript() : nil

    init(options: Options = .parse(CommandLine.arguments)) {
        self.options = options
        // The kill limit is fixed per process: measure it now, before any model is resident.
        _ = LocalMemoryReadings.processKillLimit
    }

    /// Where a GGUF run's weights file goes: the catalog entry's file name, in Documents/gguf/.
    nonisolated static var ggufDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gguf", isDirectory: true)
    }

    /// The catalog entry `--gguf` names.
    private var ggufEntry: LocalModelCatalog.GGUFEntry? {
        guard let id = options.ggufModelID else { return nil }
        return LocalModelCatalog.bundledGGUFEntries().first { $0.id.rawValue.lowercased() == id.lowercased() }
    }

    static var resultsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json")
    }

    private var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    // MARK: - Lifecycle

    func start() {
        // A finished record stays finished: coming back to the app does not run the corpus again.
        guard runTask == nil, record?.finished != true else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        runTask = Task { [weak self] in
            await self?.run()
            self?.finishRunning()
        }
    }

    /// The app is leaving the foreground: stop generating now (Metal is forbidden in the
    /// background) and keep what finished. A relaunch carries on.
    func resignActive() {
        guard let runTask else { return }
        runTask.cancel()
        if var record, !record.finished {
            record.stopReason = "resignedActive"
            self.record = record
            write()
        }
        status = "Stopped: the app left the foreground. Relaunch to carry on."
    }

    private func finishRunning() {
        sampler?.cancel()
        runTask = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - The run

    private func run() async {
        guard let corpusURL = Bundle.main.url(forResource: "local-tool-corpus.v2", withExtension: "jsonl"),
              let corpusText = try? String(contentsOf: corpusURL, encoding: .utf8) else {
            status = "The corpus is missing from the app bundle."
            return
        }
        guard let fixtureURL = Bundle.main.url(forResource: "qualification-fixture", withExtension: "json"),
              let fixtureData = try? Data(contentsOf: fixtureURL),
              let fixture = LocalModelQualificationFixture.decode(fixtureData) else {
            status = "The fixture is missing or unreadable."
            return
        }
        let bodyHash = corpusText.split(separator: "\n").first { $0.hasPrefix("// body-sha256: ") }
            .map { String($0.dropFirst("// body-sha256: ".count)) } ?? ""
        guard fixture.corpusBodySha256 == bodyHash else {
            status = "The fixture was built for another corpus: run LocalModelQualificationFixtureTests."
            return
        }
        Config.assistantName = fixture.assistantName

        // Apple's model and a GGUF model read Gemma 4 E2B's fixture prompt: the same 4,096 window
        // and the same compact job tier (a GGUF run is the same model on the other runtime).
        let promptModelID = options.apple || options.ggufModelID != nil ? "mlx-community/gemma-4-e2b-it-4bit" : options.modelID
        guard fixture.prompts[promptModelID] != nil else {
            status = "No fixture prompts for this model. Add it to the tool candidates and regenerate the fixture."
            return
        }
        let (cases, skipped) = LocalToolEval.select(LocalToolEval.loadCorpus(corpusText).cases, options.selection, live: true)

        var fresh = makeRecord(cases: cases.count, skipped: skipped, bodyHash: bodyHash)
        if let current = record, !current.finished {
            // Back in the foreground in the same process: carry on with the record in hand. `--fresh`
            // applies to the launch, not to every return, and a record rebuilt now would budget its
            // window with the model's weights already resident.
            fresh = current
            fresh.stopReason = nil
        } else if !options.fresh, let data = try? Data(contentsOf: Self.resultsURL),
           let existing = LocalModelQualificationRecord.decode(data), existing.resumable(with: fresh) {
            fresh = existing
            fresh.stopReason = nil
        }
        record = fresh
        total = cases.count * options.repeats
        refreshCounts()
        write()
        startSampler()

        // The model.
        let environment: LocalToolEval.Environment
        if options.apple {
            #if canImport(FoundationModels)
            guard LiveEnvironments.appleModelAvailable else { return stop("appleModelUnavailable") }
            environment = LiveEnvironments.apple(fixture: fixture, promptModelID: promptModelID)
            #else
            return stop("appleModelUnavailable")
            #endif
        } else if options.ggufModelID != nil {
            guard let entry = ggufEntry else { return stop("modelNotInCatalog") }
            do {
                try await prepareGGUF(entry)
            } catch {
                return stop("loadFailed-\(String(describing: type(of: error)))")
            }
            environment = LiveEnvironments.backend(gguf, fixture: fixture, modelID: entry.id.rawValue,
                                                   promptModelID: promptModelID,
                                                   cancellationBound: record?.timing.cancelBoundSeconds ?? 1.0,
                                                   transcript: transcript)
        } else {
            guard LocalModelCatalog.entry(for: LocalModelID(options.modelID)) != nil else { return stop("modelNotInCatalog") }
            do {
                try await prepareModel()
            } catch {
                return stop("loadFailed-\(String(describing: type(of: error)))")
            }
            environment = LiveEnvironments.mlx(service: service, fixture: fixture, modelID: options.modelID,
                                               contextWindow: record?.window.toolTurnTokens,
                                               cancellationBound: record?.timing.cancelBoundSeconds ?? 1.0,
                                               transcript: transcript)
        }

        // The cases, each behind the gate.
        var gate = QualificationRunGate.State()
        var done = record?.completedKeys ?? []
        for testCase in cases {
            for index in 0..<options.repeats {
                let key = LocalModelQualificationRecord.key(caseID: testCase.id, repeat: index)
                guard !done.contains(key) else { continue }
                guard !Task.isCancelled else { return }
                guard let flagged = await passGate(&gate) else { return }
                status = "Measuring \(completed + 1) of \(total)"
                let caseStarted = Date()
                let thermalAtStart = DeviceFacts.gateReading(at: elapsed).thermal
                let run = await LocalToolEval.run(testCase, environment: environment)
                // A run cut short by the app leaving the foreground is not a result.
                guard !Task.isCancelled else { return }
                let seconds = Date().timeIntervalSince(caseStarted)
                record?.add(run, repeat: index, flagged: flagged, seconds: seconds, thermalAtStart: thermalAtStart)
                record?.timing.measuringSeconds += seconds
                done.insert(key)
                refreshCounts()
                write()
            }
        }

        if !options.apple, options.ggufModelID == nil, options.cancelProbes > 0, let system = fixture.prompts[promptModelID]?.everyday {
            status = "Timing cancellation"
            var latencies: [Double] = []
            var over = 0
            let bound = record?.timing.cancelBoundSeconds ?? 1.0
            for probe in 0..<options.cancelProbes {
                guard !Task.isCancelled else { return }
                // Half land while the prompt is read, half while it answers.
                let delay = probe.isMultiple(of: 2) ? 0.3 : 2.5
                let prompt = system.replacingOccurrences(of: LocalModelQualificationFixture.dateTimePlaceholder,
                                                         with: LLMService.currentDateTimeLine())
                if let latency = await LiveEnvironments.cancelLatency(service: service, systemPrompt: prompt, after: delay) {
                    latencies.append(latency)
                    if latency > bound { over += 1 }
                }
            }
            record?.timing.cancelProbes = latencies.count
            record?.timing.cancelOverBound = over
            record?.timing.cancelLatencySeconds = .init(latencies)
        }

        record?.finished = true
        record?.recompute()
        write()
        status = "Finished: \(passed) of \(completed) runs passed. Results are in Documents/results.json."
    }

    /// Wait at the gate. Returns whether the run is flagged, or nil when the run must stop.
    private func passGate(_ state: inout QualificationRunGate.State) async -> Bool? {
        var waitStarted: Date?
        while !Task.isCancelled {
            let decision = QualificationRunGate.decide(DeviceFacts.gateReading(at: elapsed), state: &state,
                                                       policy: options.policy)
            switch decision {
            case .proceed:
                noteWait(since: waitStarted)
                return false
            case .flag(let reasons):
                noteWait(since: waitStarted)
                count(reasons)
                return true
            case .stop(let reasons):
                noteWait(since: waitStarted)
                count(reasons)
                stop("gate-" + reasons.map(\.rawValue).joined(separator: "-"))
                return nil
            case .wait(let reasons):
                if waitStarted == nil {
                    waitStarted = Date()
                    record?.gate.waits += 1
                    count(reasons)
                }
                status = "Waiting: " + reasons.map(\.rawValue).joined(separator: ", ")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        return nil
    }

    private func noteWait(since start: Date?) {
        guard let start else { return }
        record?.gate.waitedSeconds += Date().timeIntervalSince(start)
    }

    private func count(_ reasons: [QualificationRunGate.Reason]) {
        for reason in reasons { record?.gate.reasons[reason.rawValue, default: 0] += 1 }
    }

    private func stop(_ reason: String) {
        record?.stopReason = reason
        write()
        status = "Stopped: \(reason)"
    }

    // MARK: - The model

    private func prepareModel() async throws {
        guard !modelLoaded else { return }
        let id = options.modelID
        if !service.isModelDownloaded(id) {
            status = "Downloading the model"
            try await service.downloadModel(id)
        }
        record?.model.downloadedRevision = DeviceFacts.downloadedRevision(modelID: id)
        // Readings with nothing resident: the fit the plan's rule would make for this model.
        let readings = LocalMemoryReadings.againstProcessLimit()
        let weights = LocalModelCatalog.entry(for: LocalModelID(id))?.snapshot.weightsBytes ?? 0
        let fit = LocalMemoryBudget.fit(weightsBytes: weights, workingBytes: MemoryHeadroom.workingOverheadBytes,
                                        backing: .copied, readings: readings)
        record?.memory.footprintBeforeLoadBytes = readings.footprintBytes
        record?.memory.fitJudgedAgainst = fit.judgedAgainst.rawValue
        record?.memory.fitNeededBytes = fit.neededBytes
        record?.memory.fitLimitBytes = fit.limitBytes
        record?.memory.fits = fit.fits
        status = "Loading the model"
        let loadStarted = Date()
        try await service.loadModel(id)
        record?.timing.loadSeconds = Date().timeIntervalSince(loadStarted)
        record?.memory.footprintAfterLoadBytes = MemoryHeadroom.appFootprintBytes()
        modelLoaded = true
        write()
    }

    /// The GGUF model (Plan MQ P2): its file is placed by hand (README.md), checked by size as the
    /// runtime checks every load, and loaded on the GGUF backend with the entry's context policy.
    private func prepareGGUF(_ entry: LocalModelCatalog.GGUFEntry) async throws {
        guard !modelLoaded else { return }
        let installation = InstalledLocalModel(descriptor: entry.descriptor,
                                               storage: .managed(directoryName: entry.id.storageComponent),
                                               installedAt: Date(), validatedFiles: entry.descriptor.files)
        let readings = LocalMemoryReadings.againstProcessLimit()
        let fit = LocalMemoryBudget.fit(weightsBytes: entry.descriptor.estimatedWeightsBytes,
                                        workingBytes: entry.descriptor.estimatedWorkingBytes,
                                        backing: .mapped, readings: readings)
        record?.memory.footprintBeforeLoadBytes = readings.footprintBytes
        record?.memory.fitJudgedAgainst = fit.judgedAgainst.rawValue
        record?.memory.fitNeededBytes = fit.neededBytes
        record?.memory.fitLimitBytes = fit.limitBytes
        record?.memory.fits = fit.fits
        status = "Loading the model"
        let loadStarted = Date()
        // `--gguf-batch` sets both batches; without it the load is the app's own.
        let configuration = options.ggufBatch.map {
            LocalLoadConfiguration(contextLength: entry.descriptor.contextLength, batchSize: $0, physicalBatchSize: $0)
        } ?? LocalLoadConfiguration(contextLength: entry.descriptor.contextLength)
        _ = try await gguf.load(installation, configuration: configuration)
        record?.timing.loadSeconds = Date().timeIntervalSince(loadStarted)
        record?.memory.footprintAfterLoadBytes = MemoryHeadroom.appFootprintBytes()
        modelLoaded = true
        write()
    }

    // MARK: - The record

    private func makeRecord(cases: Int, skipped: Int, bodyHash: String) -> LocalModelQualificationRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        let entry = LocalModelCatalog.entry(for: LocalModelID(options.modelID))
        let gguf = ggufEntry
        let model: LocalModelQualificationRecord.Model
        let runtime: LocalModelQualificationRecord.Runtime
        if options.apple {
            model = .init(id: "apple-on-device", revision: nil, quantization: nil, backing: "system")
            runtime = .init(name: "FoundationModels", revision: DeviceFacts.osBuild)
        } else if let gguf {
            model = .init(id: gguf.id.rawValue, revision: gguf.descriptor.revision,
                          quantization: gguf.descriptor.quantization, backing: LocalMemoryBudget.Backing.mapped.rawValue)
            runtime = .init(name: "llama.cpp", revision: LlamaRuntimeAvailability.engineRevision ?? "unknown")
        } else {
            model = .init(id: options.modelID, revision: entry?.snapshot.revision, quantization: entry?.descriptor.quantization,
                          backing: LocalMemoryBudget.Backing.copied.rawValue)
            runtime = .init(name: "mlx-swift-lm", revision: DeviceFacts.mlxSwiftLMRevision)
        }
        let samplingID = gguf?.id.rawValue ?? options.modelID
        if let temperature = options.toolTemperature {
            LocalModelSampling.qualificationToolTurnOverride = .init(temperature: temperature)
        }
        LLMService.qualificationUsesOriginalToolGuide = options.originalToolGuide
        let sampling: LocalModelQualificationRecord.Sampling? = options.apple ? nil : .init(
            source: [gguf?.sampling?.source ?? entry?.sampling?.source,
                     options.toolTemperature.map { "run override: tool-turn temperature \($0)" },
                     options.originalToolGuide ? "run override: P1's original tool guide" : nil]
                .compactMap { $0 }.joined(separator: "; "),
            general: LocalModelSampling.configuration(for: samplingID, toolTurn: false),
            toolTurn: LocalModelSampling.configuration(for: samplingID, toolTurn: true))
        let readings = LocalMemoryReadings.againstProcessLimit()
        let selection = options.selection
        // The window this run's tool turns are budgeted with, chosen as `sendLocal` chooses it with the
        // flag on (this app stands in for the flag-on build), at launch, with the model not yet
        // resident: its weights are charged as not yet in the footprint. `LiveEnvironments.mlx` keeps
        // the same choice for every case.
        let window = gguf.map { LocalModelBudget.ToolTurnWindow(tokens: $0.descriptor.contextLength, reason: .ordinary) }
            ?? Self.toolTurnWindow(modelID: options.modelID, apple: options.apple, readings: readings,
                                   weightsBytes: entry?.snapshot.weightsBytes ?? 0)
        return LocalModelQualificationRecord(
            startedAt: now, updatedAt: now, device: DeviceFacts.device, app: DeviceFacts.app, runtime: runtime,
            model: model, sampling: sampling,
            corpus: .init(version: LocalToolEval.corpusVersion, bodySha256: bodyHash,
                          groups: selection.groups.map(\.rawValue).sorted(),
                          alsoCategories: selection.alsoCategories.map(\.rawValue).sorted(),
                          limit: selection.limit, repeats: options.repeats, selectedCases: cases,
                          checkOnlySkipped: skipped,
                          onlyCategories: selection.onlyCategories?.map(\.rawValue).sorted()),
            gate: .init(settleSeconds: options.policy.settleSeconds, capSeconds: options.policy.capSeconds,
                        requiresCharger: options.policy.requiresCharger),
            memory: .init(killLimitBytes: LocalMemoryReadings.processKillLimit,
                          recommendedWorkingSetBytes: readings.recommendedWorkingSetBytes,
                          reserveBytes: LocalMemoryBudget.reserveBytes(marketingRAMGB: readings.marketingRAMGB),
                          footprintBeforeLoadBytes: readings.footprintBytes, fitJudgedAgainst: "notMeasured",
                          fitNeededBytes: 0, fitLimitBytes: 0, fits: true),
            window: .init(ordinaryTokens: LocalModelBudget.contextWindow(for: options.apple ? nil : options.modelID),
                          toolTurnTokens: window.tokens, reason: window.reason.rawValue,
                          toolTurnPromptBudget: LocalModelBudget.promptBudget(for: options.modelID,
                                                                             contextWindow: window.tokens),
                          ggufBatchTokens: gguf == nil ? nil
                              : options.ggufBatch ?? LlamaCppLocalInferenceBackend.defaultBatchTokens))
    }

    /// The tool-turn window for `modelID`: `LocalModelBudget.toolTurnContextWindow` with native tool
    /// calls decided by `LocalNativeToolPolicy` with the flag on. Apple's model keeps its own 4,096.
    static func toolTurnWindow(modelID: String, apple: Bool, readings: LocalMemoryBudget.Readings,
                               weightsBytes: Int64) -> LocalModelBudget.ToolTurnWindow {
        guard !apple else { return .init(tokens: LocalModelBudget.defaultContextWindow, reason: .ordinary) }
        return LocalModelBudget.toolTurnContextWindow(
            modelId: modelID,
            nativeToolCalls: LocalNativeToolPolicy.usesNativeToolCalls(modelID: modelID, runtime: .mlx, flagOn: true),
            marketingRAMGB: readings.marketingRAMGB, readings: readings, residentWeightsBytes: weightsBytes)
    }

    /// Footprint every 2 s for the peak, thermal state on every change (and every minute).
    private func startSampler() {
        sampler = Task { [weak self] in
            var lastTrace = -Double.infinity
            while !Task.isCancelled {
                guard let self else { return }
                let footprint = MemoryHeadroom.appFootprintBytes()
                if footprint > (self.record?.memory.peakFootprintBytes ?? 0) {
                    self.record?.memory.peakFootprintBytes = footprint
                    self.record?.memory.headroomAtPeakBytes = LocalMemoryBudget.headroomAtPeak(
                        peakFootprintBytes: footprint, killLimitBytes: LocalMemoryReadings.processKillLimit)
                }
                let thermal = DeviceFacts.gateReading(at: self.elapsed).thermal.rawValue
                if thermal != self.lastThermal || self.elapsed - lastTrace >= 60 {
                    self.record?.thermalTrace.append(.init(t: (self.elapsed * 10).rounded() / 10, state: thermal))
                    self.lastThermal = thermal
                    lastTrace = self.elapsed
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refreshCounts() {
        completed = record?.runs.count ?? 0
        passed = record?.runs.filter(\.passed).count ?? 0
    }

    /// Write the record atomically: a kill mid-write leaves the previous one.
    private func write() {
        guard var record else { return }
        record.updatedAt = ISO8601DateFormatter().string(from: Date())
        self.record = record
        guard let data = try? record.encoded() else { return }
        try? data.write(to: Self.resultsURL, options: [.atomic])
    }
}
