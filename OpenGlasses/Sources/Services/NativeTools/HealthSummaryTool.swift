import CoreMotion
import Foundation

/// `health_summary` — heart rate, last night's sleep and today's steps from Apple Health, one
/// spoken sentence each (Plan GI).
///
/// Read-only. The numbers reach a model only when `HealthSummaryDeliveryPolicy` allows it; the rest
/// of the time the tool speaks the sentence itself, on-device voices only, and the model receives a
/// receipt with no numbers in it. While the phone is locked Health cannot be read, so the answer
/// comes from `HealthSummaryCache` and says how old it is.
@MainActor
final class HealthSummaryTool: NativeTool {

    let name = "health_summary"
    let description = "Read-only summary from Apple Health, spoken as one or two short sentences. metric: 'heart_rate' (the latest reading and today's resting rate), 'sleep' (last night's time asleep, deep and REM sleep, and how often the wearer woke), 'steps' (today's count compared with the wearer's usual by this time of day) or 'overview'. Use it for questions like \"how did I sleep?\", \"what's my heart rate?\" or \"am I behind on steps?\". It reports numbers and never interprets them. When the wearer has not allowed Health data to be shared with the AI, the tool speaks the answer to the wearer itself and returns only a receipt without the numbers."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "metric": [
                "type": "string",
                "description": "Which summary: heart_rate, sleep, steps, or overview (at most two sentences covering all three).",
                "enum": Metric.allCases.map(\.rawValue),
            ],
        ],
        "required": ["metric"],
    ]

    enum Metric: String, CaseIterable {
        case heartRate = "heart_rate"
        case sleep
        case steps
        case overview
    }

    typealias Speaker = @MainActor (String) async -> SpeechDeliveryOutcome

    private let reader: HealthSampleReading
    let cache: HealthSummaryCache
    private let clock: () -> Date
    private let calendar: Calendar
    private let phraser: HealthSummaryPhraser
    private let deliveryInputs: @MainActor () -> HealthSummaryDeliveryPolicy.Inputs
    private let speaker: Speaker
    private let motionSteps: () async -> Double?

    init(reader: HealthSampleReading? = nil,
         cache: HealthSummaryCache = HealthSummaryCache(),
         clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         locale: Locale = .current,
         deliveryInputs: @escaping @MainActor () -> HealthSummaryDeliveryPolicy.Inputs = HealthSummaryTool.liveDeliveryInputs,
         speaker: Speaker? = nil,
         motionSteps: (() async -> Double?)? = nil) {
        self.reader = reader ?? HealthKitSampleReader()
        self.cache = cache
        self.clock = clock
        self.calendar = calendar
        self.phraser = HealthSummaryPhraser(locale: locale, calendar: calendar)
        self.deliveryInputs = deliveryInputs
        self.speaker = speaker ?? { text in
            // On-device voices only: the point of speaking directly is that the numbers do not
            // leave the phone, and a cloud voice is a third party too.
            guard let speech = AppStateProvider.shared?.speechService else {
                return .failed(reason: "no speech service")
            }
            return await speech.speakReporting(text, onDeviceOnly: true)
        }
        let clockForMotion = clock
        self.motionSteps = motionSteps ?? { await MotionStepCounter.todaySteps(now: clockForMotion()) }
    }

    // MARK: - Execute

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.healthSummaries) else {
            return AIFeatureGate.disabledMessage(.healthSummaries)
        }
        let metric = (args["metric"] as? String).flatMap(Metric.init(rawValue:)) ?? .overview
        let sentence = await summary(for: metric)

        switch HealthSummaryDeliveryPolicy.decide(deliveryInputs()) {
        case .returnToModel:
            return sentence
        case .speakDirect:
            switch await speaker(sentence) {
            case .completed, .interrupted:
                return HealthSummaryDeliveryPolicy.receipt
            case .suppressed, .failed:
                return HealthSummaryDeliveryPolicy.notSpokenReceipt
            }
        }
    }

    /// The sentence for `metric`, whoever ends up hearing it.
    func summary(for metric: Metric) async -> String {
        let now = clock()
        switch await reader.authorizationState() {
        case .unavailable:
            return await motionFallback(metric, now: now) ?? HealthSummaryPhraser.healthUnavailable
        case .notDetermined:
            guard await reader.requestAuthorization() else {
                return await motionFallback(metric, now: now) ?? HealthSummaryPhraser.needsPermission
            }
        case .requested:
            break
        }

        do {
            let snapshot = try await read(metric, now: now)
            try? cache.store(snapshot, now: now)
            return phrase(metric, snapshot, now: now)
        } catch HealthReadError.protectedDataUnavailable {
            return await lockedAnswer(metric, now: now)
        } catch {
            return HealthSummaryPhraser.readFailed
        }
    }

    /// Refresh the locked-phone cache. Called when the app comes forward or the phone unlocks; never
    /// asks for permission and never speaks.
    func refreshCache() async {
        guard AIFeatureGate.isEnabled(.healthSummaries), !Config.disabledTools.contains(name),
              await reader.authorizationState() == .requested else { return }
        let now = clock()
        guard let snapshot = try? await read(.overview, now: now) else { return }
        try? cache.store(snapshot, now: now)
    }

    // MARK: - Reading

    private func read(_ metric: Metric, now: Date) async throws -> HealthSummarySnapshot {
        var snapshot = HealthSummarySnapshot()
        if metric == .heartRate || metric == .overview {
            let latest = try await reader.latestHeartRate(since: now.addingTimeInterval(-HeartRateSummary.recentWindow))
            let resting = try await reader.restingHeartRates(
                from: HeartRateSummary.restingSearchStart(now: now, calendar: calendar), to: now)
            snapshot.heartRate = HeartRateSummary.summarize(latest: latest, resting: resting,
                                                            now: now, calendar: calendar)
        }
        if metric == .sleep || metric == .overview {
            let window = SleepNightAggregator.window(endingOn: now, calendar: calendar)
            let samples = try await reader.sleepSamples(from: window.start, to: window.end)
            snapshot.sleep = SleepNightAggregator.aggregate(samples, now: now, calendar: calendar)
        }
        if metric == .steps || metric == .overview {
            snapshot.steps = try await readSteps(now: now)
        }
        return snapshot
    }

    private func readSteps(now: Date) async throws -> StepComparison? {
        let today = try await reader.cumulativeSteps(from: calendar.startOfDay(for: now), to: now)
        var history: [DayStepSample] = []
        for range in StepBaseline.historyRanges(now: now, calendar: calendar) {
            let byNow = try await reader.cumulativeSteps(from: range.dayStart, to: range.sameTime)
            let total = try await reader.cumulativeSteps(from: range.dayStart, to: range.dayEnd)
            history.append(DayStepSample(byNow: byNow, dayTotal: total))
        }
        // Nothing at all, today or in two weeks, is what a denied read looks like — HealthKit
        // cannot say which. The phone's motion sensor is the honest fallback for today's count.
        if today == 0, history.allSatisfy({ $0.dayTotal == 0 }) {
            return await motionSteps().map {
                StepComparison(today: $0, usualByNow: nil, usableDays: 0, asOf: now)
            }
        }
        return StepBaseline.compare(today: today, history: history, asOf: now)
    }

    private func phrase(_ metric: Metric, _ snapshot: HealthSummarySnapshot, now: Date) -> String {
        switch metric {
        case .heartRate: return phraser.heartRate(snapshot.heartRate, now: now)
        case .sleep: return phraser.sleep(snapshot.sleep, now: now)
        case .steps: return phraser.steps(snapshot.steps, now: now)
        case .overview:
            return phraser.overview(heartRate: snapshot.heartRate, sleep: snapshot.sleep,
                                    steps: snapshot.steps, now: now)
        }
    }

    // MARK: - Locked phone and fallbacks

    /// Answer from the cache. An absence here is not a fact about the wearer — it is only that the
    /// cache does not hold it — so every "I don't have…" becomes "once your phone is unlocked".
    private func lockedAnswer(_ metric: Metric, now: Date) async -> String {
        let absences: Set<String> = [HealthSummaryPhraser.noHeartRate, HealthSummaryPhraser.noSleep,
                                     HealthSummaryPhraser.noSteps, HealthSummaryPhraser.noData]
        if let cached = cache.load(now: now) {
            let text = phrase(metric, cached, now: now)
            if !absences.contains(text) { return text }
        }
        return await motionFallback(metric, now: now) ?? HealthSummaryPhraser.lockedNoCache
    }

    /// Today's steps from the phone's motion sensor, for a steps question Health cannot answer.
    private func motionFallback(_ metric: Metric, now: Date) async -> String? {
        guard metric == .steps, let steps = await motionSteps() else { return nil }
        return phraser.steps(StepComparison(today: steps, usualByNow: nil, usableDays: 0, asOf: now),
                             now: now)
    }

    // MARK: - Live delivery inputs

    /// "Local" means every model the result could reach runs on this phone: the direct pipeline,
    /// an on-device active model, and no cloud model saved that routing, the cascade or a later
    /// switch could hand this turn's history to. Anything less counts as cloud.
    static func liveDeliveryInputs() -> HealthSummaryDeliveryPolicy.Inputs {
        func onDevice(_ model: ModelConfig) -> Bool {
            switch model.llmProvider {
            case .local, .appleOnDevice: return true
            default: return false
            }
        }
        let models = Config.savedModels
        let everyModelLocal = !models.isEmpty && models.allSatisfy(onDevice)
        let activeLocal = Config.activeModel.map(onDevice) ?? false
        return HealthSummaryDeliveryPolicy.Inputs(
            activeModelIsLocal: Config.appMode == .direct && activeLocal && everyModelLocal,
            shareHealthWithAI: Config.shareHealthDataWithAI,
            hipaaMode: Config.hipaaMode,
            medicalLocalOnly: Config.hipaaLocalOnly)
    }
}

/// Today's step count from CoreMotion — the fallback when Health cannot answer.
enum MotionStepCounter {
    static func todaySteps(now: Date = Date(), calendar: Calendar = .current) async -> Double? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        let pedometer = CMPedometer()
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: calendar.startOfDay(for: now), to: now) { [pedometer] data, error in
                _ = pedometer   // held until the answer arrives
                continuation.resume(returning: error == nil ? data?.numberOfSteps.doubleValue : nil)
            }
        }
    }
}
