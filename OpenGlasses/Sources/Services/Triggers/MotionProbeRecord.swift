import Combine
import Foundation

// Plan NB §5, the Motion probe: what the Neural Band's motion sends while the wearer pinches,
// holds and turns, measured before the twist is switched on. Compiled and tested in every build;
// only a flagged (TestFlight-only) build has the probe that fills it, so in any other build the
// record stays empty and the support report carries no line of it.

/// The Motion capability's state, in the app's own words.
enum MotionChannelState: String, Equatable {
    case stopped, starting, started, stopping, unknown
}

/// Why Motion could not be added, or what the capability reported while it ran.
enum MotionChannelFailure: String, Error, Equatable, CaseIterable {
    // The capability's own errors.
    case sensorUnavailable, capabilityClosed, deviceDisconnected
    /// The shared session could not be created (or the SDK is not configured).
    case sessionUnavailable
    /// The session did not reach `started` in time.
    case sessionNotStarted
    /// The session threw adding the capability.
    case addFailed
    /// The session added nothing (the glasses offer no Motion, or the session was not started).
    case capabilityNotAdded
    /// Something this build does not know.
    case unknown
}

/// The four things the probe asks the wearer to do, in order, one window each.
enum MotionProbePrompt: String, CaseIterable, Equatable {
    case hold, twistClockwise, twistAnticlockwise, moveArmLeft

    /// What the phone shows while the prompt's window is open.
    var instruction: String {
        switch self {
        case .hold: return String(localized: "Pinch and hold for two seconds, then let go. Again, until the next step.")
        case .twistClockwise: return String(localized: "Pinch, hold and turn your wrist clockwise, then let go. Again, until the next step.")
        case .twistAnticlockwise: return String(localized: "Pinch, hold and turn your wrist anticlockwise, then let go. Again, until the next step.")
        case .moveArmLeft: return String(localized: "Pinch, hold and move your arm to the left, then let go. Again, until the next step.")
        }
    }
}

/// Why a Motion probe run ended.
enum MotionProbeStopReason: String, Equatable {
    /// The four prompts ran their course.
    case finished
    /// The glasses' link left `.connected`.
    case linkDown
    case wearerStopped
    /// The shared session stopped underneath the probe.
    case sessionEnded
    /// Motion could not be added.
    case failed
    /// The capability reported an error.
    case capabilityFailed
    case shutdown
}

/// Why a press of Start did nothing.
enum MotionProbeRefusal: String, Equatable {
    case notInThisBuild, heldOnThisChannel, glassesNotSupported, notConnected, alreadyRunning
    /// The Inputs probe is running: both want the session's one Inputs capability.
    case otherProbeRunning
}

/// The Motion probe's rules, without the SDK (Plan NB §5).
enum MotionProbePolicy {
    /// Each prompt's window; four of them make the minute.
    static let promptWindow: Duration = .seconds(15)
    static var runLength: Duration { promptWindow * MotionProbePrompt.allCases.count }

    /// Whether Start may begin a run, first refusal wins (as the Inputs probe's).
    static func refusal(verdict: DATExperimentalPolicy.Verdict, connected: Bool, running: Bool,
                        otherProbeRunning: Bool) -> MotionProbeRefusal? {
        switch verdict {
        case .runs, .switchedOff: break
        case .notInThisBuild: return .notInThisBuild
        case .heldOnThisChannel: return .heldOnThisChannel
        case .glassesNotSupported: return .glassesNotSupported
        }
        if running { return .alreadyRunning }
        if otherProbeRunning { return .otherProbeRunning }
        if !connected { return .notConnected }
        return nil
    }
}

/// What each Motion probe run saw, kept for the support report (Plan NB §5). Aggregates only, per
/// prompt: samples by source, the band's rate, how many band samples carried an orientation and a
/// gyroscope, the twist's net and peak (degrees, signed, `TwistTracker` over the window), the drag
/// bursts' and `select`s' times, other inputs counted, and whether the phone's output volume
/// changed (Meta taking the twist). Never a sample, a position or a device's name.
@MainActor
final class MotionProbeLedger: ObservableObject {
    static let shared = MotionProbeLedger()

    struct PromptRecord: Equatable {
        let prompt: MotionProbePrompt
        let startedMilliseconds: Int
        var samples: [WristSampleOrigin: Int] = [:]
        var withOrientation = 0
        var withGyroscope = 0
        var firstNs: Int64?
        var lastNs: Int64?
        var tracker = TwistTracker()
        var twistNetDegrees = 0.0
        /// The twist furthest from the reference, signed.
        var twistPeakDegrees = 0.0
        /// Drag bursts (`drag(.down)` from `neuralBandDrag`) and selects, ms since the run started.
        var dragDowns: [Int] = []
        var selects: [Int] = []
        var otherInputs = 0
        var volumeBefore: Float?
        var volumeAfter: Float?

        var bandSamples: Int { samples[.neuralBand] ?? 0 }

        /// The band's samples a second, from the first to the last; nil under two samples.
        var bandRate: Double? {
            guard bandSamples >= 2, let firstNs, let lastNs, lastNs > firstNs else { return nil }
            return Double(bandSamples - 1) * 1e9 / Double(lastNs - firstNs)
        }

        var volumeChanged: Bool? {
            guard let volumeBefore, let volumeAfter else { return nil }
            return abs(volumeBefore - volumeAfter) > 0.001
        }
    }

    struct Run: Equatable {
        let startedAt: Date
        var prompts: [PromptRecord] = []
        var states: [(MotionChannelState, Int)] = []
        var errors: [(String, Int)] = []
        var stop: (reason: MotionProbeStopReason, milliseconds: Int)?

        static func == (a: Run, b: Run) -> Bool {
            a.startedAt == b.startedAt && a.prompts == b.prompts
                && a.states.map(\.0) == b.states.map(\.0) && a.states.map(\.1) == b.states.map(\.1)
                && a.errors.map(\.0) == b.errors.map(\.0) && a.errors.map(\.1) == b.errors.map(\.1)
                && a.stop?.reason == b.stop?.reason && a.stop?.milliseconds == b.stop?.milliseconds
        }
    }

    /// Times kept per prompt for drag bursts and selects each; the rest are counted.
    static let timeCapacity = 30
    /// States and errors kept per run.
    static let otherCapacity = 40
    static let runCapacity = 3

    @Published private(set) var runs: [Run] = []
    @Published private(set) var lastRefusal: MotionProbeRefusal?
    private var totalRuns = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    var current: Run? {
        guard let last = runs.last, last.stop == nil else { return nil }
        return last
    }

    func begin() {
        if current != nil { end(.shutdown) }
        lastRefusal = nil
        totalRuns += 1
        runs.append(Run(startedAt: now()))
        if runs.count > Self.runCapacity { runs.removeFirst(runs.count - Self.runCapacity) }
    }

    func refused(_ refusal: MotionProbeRefusal) { lastRefusal = refusal }

    func beginPrompt(_ prompt: MotionProbePrompt, volume: Float?) {
        mutateCurrent { run, ms in
            finishPrompt(in: &run, volume: volume)
            var record = PromptRecord(prompt: prompt, startedMilliseconds: ms)
            record.volumeBefore = volume
            run.prompts.append(record)
        }
    }

    /// Ends the open prompt's window, with the volume at its end.
    func endPrompt(volume: Float?) {
        mutateCurrent { run, _ in finishPrompt(in: &run, volume: volume) }
    }

    /// A sample from the band: counted, timed, and its twist followed.
    func recordBandSample(_ sample: WristSample) {
        mutatePrompt { record, _ in
            record.samples[.neuralBand, default: 0] += 1
            if sample.orientation != nil { record.withOrientation += 1 }
            if sample.gyroscope != nil { record.withGyroscope += 1 }
            if record.firstNs == nil { record.firstNs = sample.timestampNs }
            record.lastNs = sample.timestampNs
            if let angle = record.tracker.add(sample) {
                let degrees = WristTwist.degrees(angle)
                record.twistNetDegrees = degrees
                if abs(degrees) > abs(record.twistPeakDegrees) { record.twistPeakDegrees = degrees }
            }
        }
    }

    /// A sample from anywhere but the band: counted only.
    func recordOtherSample(_ origin: WristSampleOrigin) {
        mutatePrompt { record, _ in record.samples[origin, default: 0] += 1 }
    }

    func recordInput(_ input: GlassesInput) {
        mutatePrompt { record, ms in
            switch input.kind {
            case .drag(.down) where input.origin == .neuralBandDrag:
                if record.dragDowns.count < Self.timeCapacity { record.dragDowns.append(ms) } else { record.otherInputs += 1 }
            case .select:
                if record.selects.count < Self.timeCapacity { record.selects.append(ms) } else { record.otherInputs += 1 }
            default:
                record.otherInputs += 1
            }
        }
    }

    func recordState(_ state: MotionChannelState) {
        mutateCurrent { run, ms in
            if run.states.count + run.errors.count < Self.otherCapacity { run.states.append((state, ms)) }
        }
    }

    /// A Motion failure, or the Inputs channel's (by case name).
    func recordError(_ token: String) {
        mutateCurrent { run, ms in
            if run.states.count + run.errors.count < Self.otherCapacity { run.errors.append((token, ms)) }
        }
    }

    func end(_ reason: MotionProbeStopReason, volume: Float? = nil) {
        mutateCurrent { run, ms in
            finishPrompt(in: &run, volume: volume)
            run.stop = (reason, ms)
        }
    }

    func reset() {
        runs = []
        lastRefusal = nil
        totalRuns = 0
    }

    private func finishPrompt(in run: inout Run, volume: Float?) {
        guard let last = run.prompts.indices.last, run.prompts[last].volumeAfter == nil else { return }
        run.prompts[last].volumeAfter = volume ?? run.prompts[last].volumeBefore
    }

    private func mutateCurrent(_ change: (inout Run, Int) -> Void) {
        guard let index = runs.indices.last, runs[index].stop == nil else { return }
        var run = runs[index]
        let ms = max(0, Int((now().timeIntervalSince(run.startedAt) * 1000).rounded()))
        change(&run, ms)
        runs[index] = run
    }

    private func mutatePrompt(_ change: (inout PromptRecord, Int) -> Void) {
        mutateCurrent { run, ms in
            guard let last = run.prompts.indices.last, run.prompts[last].volumeAfter == nil else { return }
            change(&run.prompts[last], ms)
        }
    }

    // MARK: - Report

    /// Empty until a run has started — always, in a build without the probe.
    var reportLines: [String] {
        guard !runs.isEmpty else { return [] }
        var lines = ["Glasses motion probe: \(totalRuns) run\(totalRuns == 1 ? "" : "s") since launch"
                     + " (30 Hz; band samples followed, others counted)"]
        let first = totalRuns - runs.count + 1
        for (offset, run) in runs.enumerated() {
            lines += Self.lines(for: run, number: first + offset)
        }
        return lines
    }

    static func lines(for run: Run, number: Int) -> [String] {
        let prefix = "  run \(number)"
        var lines: [String] = []
        for record in run.prompts {
            lines.append("\(prefix) · \(describe(record))")
        }
        if run.prompts.isEmpty { lines.append("\(prefix) · no prompt began") }
        for (state, ms) in run.states { lines.append("\(prefix) · +\(ms) ms · state \(state.rawValue)") }
        for (token, ms) in run.errors { lines.append("\(prefix) · +\(ms) ms · error \(token)") }
        if let stop = run.stop {
            lines.append("\(prefix) · stopped (\(stop.reason.rawValue)) after \(stop.milliseconds / 1000) s")
        } else {
            lines.append("\(prefix) · still running")
        }
        return lines
    }

    static func describe(_ record: PromptRecord) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        let bySource = WristSampleOrigin.allCases.map { "\($0.rawValue) \(record.samples[$0] ?? 0)" }
            .joined(separator: ", ")
        let rate = record.bandRate.map { String(format: "%.1f Hz", locale: posix, $0) } ?? "rate not known"
        let twist = String(format: "twist net %+.0f°, peak %+.0f°", locale: posix,
                           record.twistNetDegrees, record.twistPeakDegrees)
        let drags = record.dragDowns.isEmpty ? "none" : record.dragDowns.map { "+\($0)" }.joined(separator: ", ")
        let selects = record.selects.isEmpty ? "none" : record.selects.map { "+\($0)" }.joined(separator: ", ")
        let volume: String
        switch record.volumeChanged {
        case true?: volume = "volume changed"
        case false?: volume = "volume unchanged"
        case nil: volume = "volume not known"
        }
        return "\(record.prompt.rawValue) (+\(record.startedMilliseconds) ms) · samples \(bySource) · \(rate)"
            + " · band with orientation \(record.withOrientation), gyroscope \(record.withGyroscope)"
            + " · \(twist) · drag down at \(drags) ms · select at \(selects) ms"
            + " · other inputs \(record.otherInputs) · \(volume)"
    }
}
