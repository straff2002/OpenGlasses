import Foundation

/// What the `ring` tool needs from the ring service. `RingService` conforms; tests use a fake.
@MainActor
protocol RingToolBackend: AnyObject {
    var isPaired: Bool { get }
    var isConnected: Bool { get }
    var battery: Int? { get }
    var lastSync: Date? { get }
    /// The live heart rate while a workout holds a session, nil when not fresh.
    var freshHeartRate: Int? { get }
    func measure(_ measurement: RingMeasurement) async -> RingService.MeasurementOutcome
    func findRing() async -> Bool
    func syncNow()
}

extension RingService: RingToolBackend {
    var freshHeartRate: Int? { liveReadings.freshBeatsPerMinute }
}

/// `ring` — the wearer's smart ring (Plan MZ §6): measure heart rate or blood oxygen now, the
/// ring's battery, find it, and its sync to Apple Health.
///
/// A measurement is health data: it reaches a model only when `HealthSummaryDeliveryPolicy` allows
/// it, and otherwise the tool speaks the sentence itself on an on-device voice and hands the model
/// the policy's receipt, with no number in it. Battery and the last sync are not health data and are
/// returned. Offered only while the ring support is on (`Config.ringSupportEnabled`).
@MainActor
final class RingTool: NativeTool, ConditionallyOfferedTool {

    nonisolated static let toolName = "ring"

    let name = "ring"
    let description = "The wearer's smart ring, paired in Settings under Devices & Privacy, Smart Ring. action: 'heart_rate' (measure the heart rate now, up to a minute), 'oxygen' (measure blood oxygen now; the wearer keeps the hand still for about 40 seconds), 'battery' (the ring's charge), 'find' (lights the ring up so it can be found), 'last_sync' (when it last synced to Apple Health) or 'sync' (sync it now). The ring's sleep, steps and heart rate are already in Apple Health, so for last night's sleep or today's steps use health_summary instead. Readings are estimates from a consumer ring, not medical measurements: report the number and never say whether it is healthy or safe. When the wearer has not allowed Health data to be shared with the AI, the tool speaks a measurement to the wearer itself and returns only a receipt without the number."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "What to do: heart_rate, oxygen, battery, find, last_sync or sync.",
                "enum": Action.allCases.map(\.rawValue),
            ],
        ],
        "required": ["action"],
    ]

    enum Action: String, CaseIterable {
        case heartRate = "heart_rate"
        case oxygen
        case battery
        case find
        case lastSync = "last_sync"
        case sync
    }

    typealias Speaker = @MainActor (String) async -> SpeechDeliveryOutcome

    private let backend: @MainActor () -> RingToolBackend?
    private let enabled: @MainActor () -> Bool
    private let deliveryInputs: @MainActor () -> HealthSummaryDeliveryPolicy.Inputs
    private let speaker: Speaker
    private let clock: () -> Date
    private let locale: Locale
    /// How long a measurement may take before the tool answers without it.
    private let measurementWait: TimeInterval

    init(backend: (@MainActor () -> RingToolBackend?)? = nil,
         enabled: @escaping @MainActor () -> Bool = { Config.ringSupportEnabled },
         deliveryInputs: @escaping @MainActor () -> HealthSummaryDeliveryPolicy.Inputs = HealthSummaryTool.liveDeliveryInputs,
         speaker: Speaker? = nil,
         clock: @escaping () -> Date = Date.init,
         locale: Locale = .current,
         measurementWait: TimeInterval = 55) {
        self.backend = backend ?? {
            #if AVENKIN_PHONE_ONLY
            return nil
            #else
            return AppStateProvider.shared?.ringService
            #endif
        }
        self.enabled = enabled
        self.deliveryInputs = deliveryInputs
        self.speaker = speaker ?? { text in
            // On-device voices only, as `health_summary` does: a cloud voice is a third party too.
            guard let speech = AppStateProvider.shared?.speechService else {
                return .failed(reason: "no speech service")
            }
            return await speech.speakReporting(text, source: .reply, onDeviceOnly: true)
        }
        self.clock = clock
        self.locale = locale
        self.measurementWait = measurementWait
    }

    var isOfferedNow: Bool { enabled() }

    // MARK: - Lines

    nonisolated static let notOn = "The smart ring isn't turned on in this version of Avenkin."
    nonisolated static let notPaired = "No smart ring is paired. The wearer can pair one in Settings under Devices & Privacy, Smart Ring."
    nonisolated static let notConnected = "The smart ring isn't connected right now. It may be out of range or need charging; it reconnects by itself when it's back."
    nonisolated static let busy = "The ring is already taking another measurement. Try again in a minute."
    nonisolated static let interrupted = "The ring disconnected before the measurement finished. Try again when it's back in range."
    nonisolated static let holdStill = "Keep your hand still for about 40 seconds."
    nonisolated static let estimate = "It's an estimate from a consumer ring, not a medical measurement."

    // MARK: - Execute

    func execute(args: [String: Any]) async throws -> String {
        guard enabled() else { return Self.notOn }
        guard let action = (args["action"] as? String).flatMap(Action.init(rawValue:)) else {
            return "Unknown action. Use one of: \(Action.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        guard let ring = backend(), ring.isPaired else { return Self.notPaired }

        switch action {
        case .battery:
            guard let battery = ring.battery else {
                return ring.isConnected ? "The ring hasn't reported its battery yet." : Self.notConnected
            }
            return ring.isConnected
                ? "The ring's battery is at \(battery) percent."
                : "The ring isn't connected; its battery was at \(battery) percent when it was last seen."

        case .lastSync:
            guard let last = ring.lastSync else { return "The ring hasn't synced to Apple Health yet." }
            return "The ring last synced to Apple Health \(Self.relative(last, now: clock(), locale: locale))."

        case .sync:
            guard ring.isConnected else { return Self.notConnected }
            ring.syncNow()
            return "Syncing the ring now. Its readings reach Apple Health within a minute or so."

        case .find:
            guard ring.isConnected else { return Self.notConnected }
            return await ring.findRing()
                ? "The ring is lit up for a few seconds."
                : "The ring didn't answer. It may be out of range."

        case .heartRate:
            guard ring.isConnected else { return Self.notConnected }
            if let live = ring.freshHeartRate {
                return await deliver(Self.heartRateSentence(live))
            }
            return await deliver(measurement: await measured(.spotHeartRate, on: ring))

        case .oxygen:
            guard ring.isConnected else { return Self.notConnected }
            // The run starts first, so the instruction does not add to the wait.
            let run = Task { @MainActor in await self.measured(.oxygen, on: ring) }
            _ = await speaker(Self.holdStill)
            return await deliver(measurement: await run.value)
        }
    }

    // MARK: - Measuring

    /// The measurement, or no reading once `measurementWait` passes, so the tool always answers
    /// inside its own 60 s budget whatever the ring does. A run still going on the ring finishes
    /// there and its reading still reaches Health.
    private func measured(_ measurement: RingMeasurement, on ring: RingToolBackend) async -> RingService.MeasurementOutcome {
        let wait = measurementWait
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await ring.measure(measurement)) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                once.resume(.noReading)
            }
        }
    }

    @MainActor
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<RingService.MeasurementOutcome, Never>?
        init(_ continuation: CheckedContinuation<RingService.MeasurementOutcome, Never>) {
            self.continuation = continuation
        }
        func resume(_ outcome: RingService.MeasurementOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    // MARK: - Delivery

    private func deliver(measurement outcome: RingService.MeasurementOutcome) async -> String {
        switch outcome {
        case .heartRate(let bpm): return await deliver(Self.heartRateSentence(bpm))
        case .oxygen(let percent): return await deliver(Self.oxygenSentence(percent))
        case .noReading: return "The ring finished without a reading. Keep the ring snug and the hand still, then try again."
        case .notPaired: return Self.notPaired
        case .notConnected: return Self.notConnected
        case .busy: return Self.busy
        case .interrupted: return Self.interrupted
        }
    }

    /// A sentence with a health number: to the model only when the policy allows it, otherwise
    /// spoken here and replaced by the policy's receipt.
    private func deliver(_ sentence: String) async -> String {
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

    nonisolated static func heartRateSentence(_ bpm: Int) -> String {
        "Your heart rate is \(bpm) beats per minute, from your ring just now. \(estimate)"
    }

    nonisolated static func oxygenSentence(_ percent: Int) -> String {
        "Your blood oxygen is \(percent) percent, from your ring just now. \(estimate)"
    }

    nonisolated static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
