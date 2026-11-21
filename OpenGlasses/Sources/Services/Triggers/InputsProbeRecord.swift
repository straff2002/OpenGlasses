import Combine
import Foundation

// Plan JV P2, the Inputs probe: what the glasses' own touch inputs send while the app listens for
// them, measured before anything is mapped. Compiled and tested in every build; only a flagged
// (TestFlight-only) build has the probe that fills it, so in any other build the record stays
// empty and the support report carries no line of it.

/// Where an input came from: the SDK's input source, in the app's own words.
enum GlassesInputOrigin: String, CaseIterable, Equatable, Hashable {
    case captouch, neuralBand, captureButton, actionButton, neuralBandDrag, unknown
}

/// One input from the glasses, as the probe records it. A drag keeps its phase here; how far a
/// sample moved rides beside it (`GlassesInput.delta`), never where the finger was.
enum GlassesInputKind: Equatable, Hashable {
    enum Direction: String, Equatable, Hashable { case up, down, left, right }
    enum Press: String, Equatable, Hashable { case shortPress, hold, doublePress }
    enum DragPhase: String, Equatable, Hashable { case down, move, up }

    case nav(Direction)
    case select
    case back
    /// The action button (the SDK's only button type).
    case actionButton
    case capture(Press)
    case drag(DragPhase)
    /// An input of a kind this build does not know.
    case unknown

    /// The case name, with its direction or press type.
    var reportToken: String {
        switch self {
        case .nav(let direction): return "nav-\(direction.rawValue)"
        case .select: return "select"
        case .back: return "back"
        case .actionButton: return "button-action"
        case .capture(let press): return "capture-\(press.rawValue)"
        case .drag(let phase): return "drag-\(phase.rawValue)"
        case .unknown: return "unknown"
        }
    }
}

/// How far a drag sample moved since the sample before it, in the glasses' own input units. Meta
/// promises no origin, range or axis direction for that space, so only sizes and signs relative
/// to each other mean anything. Never a position: the SDK's `x` and `y` are not read.
struct GlassesDragDelta: Equatable, Hashable {
    var dx: Double
    var dy: Double
}

struct GlassesInput: Equatable {
    var kind: GlassesInputKind
    var origin: GlassesInputOrigin
    /// A drag sample's change since the previous one; nil for every other kind.
    var delta: GlassesDragDelta? = nil
}

/// How far a run of drag moves went: the distance along each axis (the sum of |dx| and of |dy|)
/// and the net change (the sum of dx and of dy). A drag that moves the lens has distance; a
/// pinch's twitch has little; a back-and-forth has distance with little net.
struct GlassesDragTravel: Equatable {
    var distanceX = 0.0
    var distanceY = 0.0
    var netX = 0.0
    var netY = 0.0

    init() {}
    init(_ delta: GlassesDragDelta) { add(delta) }

    mutating func add(_ delta: GlassesDragDelta) {
        distanceX += abs(delta.dx)
        distanceY += abs(delta.dy)
        netX += delta.dx
        netY += delta.dy
    }

    /// "travel x 12.5 y 3.0, net x +12.5 y -1.0".
    var reportText: String {
        let posix = Locale(identifier: "en_US_POSIX")
        return String(format: "travel x %.1f y %.1f, net x %+.1f y %+.1f", locale: posix,
                      distanceX, distanceY, netX, netY)
    }
}

/// The Inputs capability's state, in the app's own words.
enum InputsProbeState: String, Equatable {
    case inactive, activating, active, deactivating, unknown
}

/// Why the probe could not add Inputs, or what the capability reported while it ran.
enum InputsProbeFailure: String, Error, Equatable, CaseIterable {
    // The capability's own errors.
    case permissionDenied, connectionClosed, activationTimeout, activationFailed, capabilityUnavailable
    case deviceDisconnected, communicationError
    /// The shared session could not be created (or the SDK is not configured).
    case sessionUnavailable
    /// The session did not reach `started` in time.
    case sessionNotStarted
    /// The session threw adding the capability.
    case addFailed
    /// The session added nothing (the glasses offer no Inputs).
    case capabilityNotAdded
    /// Something this build does not know.
    case unknown
}

/// Why a run ended.
enum InputsProbeStopReason: String, Equatable {
    /// Five minutes passed.
    case timeLimit
    /// The glasses' link left `.connected`.
    case linkDown
    /// The wearer pressed Stop.
    case wearerStopped
    /// The shared session stopped underneath the probe.
    case sessionEnded
    /// Inputs could not be added.
    case failed
    /// The capability reported an error. A failed capability stays attached until it is removed
    /// (Meta's Inputs guide), so the run removes it rather than holding it for the time limit.
    case capabilityFailed
    /// The capability's event stream finished without an error: the glasses were taken off, or the
    /// SDK ended it. No more inputs can arrive on it.
    case inputsEnded
    /// The app shut the probe down.
    case shutdown
}

/// Why a press of Start did nothing.
enum InputsProbeRefusal: String, Equatable {
    /// The binary has no experimental features.
    case notInThisBuild
    /// A flagged binary on the App Store channel.
    case heldOnThisChannel
    /// This copy offers no glasses.
    case glassesNotSupported
    /// No glasses' link is connected.
    case notConnected
    /// A run is already going.
    case alreadyRunning
}

/// The probe's rules, without the SDK (Plan JV P2).
enum InputsProbePolicy {
    /// How long a run lasts at most.
    static let timeLimit: Duration = .seconds(300)

    /// What the probe asks the glasses for: the touchpad and the Neural Band, its presses and
    /// swipes (`neuralBand`) and its continuous drag (`neuralBandDrag`), so one device run answers
    /// both which touches reach the app and what a band drag sends. Never the capture button
    /// (Meta's camera) or the action button. The SDK-side configuration is built from the same two
    /// answers, and `DATExperimentalGuardTests` pins both.
    static let origins: Set<GlassesInputOrigin> = [.captouch, .neuralBand, .neuralBandDrag]
    /// Back stays with Meta: the probe never consumes it. (A Back is reported to end a Display
    /// session, which is one more reason the app must not take it.)
    static let consumesBack = false

    /// Whether Start may begin a run, first refusal wins. The probe has no switch of its own: the
    /// wearer's press is the switch, so the experimental verdict is asked with it on. The camera or
    /// the lens being on is no refusal: all three share the pair's one session.
    static func refusal(verdict: DATExperimentalPolicy.Verdict, connected: Bool,
                        running: Bool) -> InputsProbeRefusal? {
        switch verdict {
        case .runs, .switchedOff: break
        case .notInThisBuild: return .notInThisBuild
        case .heldOnThisChannel: return .heldOnThisChannel
        case .glassesNotSupported: return .glassesNotSupported
        }
        if running { return .alreadyRunning }
        if !connected { return .notConnected }
        return nil
    }
}

/// What each probe run saw, kept for the support report (Plan JV P2). Case names and numbers: an
/// input's kind, direction or press type and source, its time since the run started, and whether
/// the wearer's own audio was playing when it came; state changes and errors; how the run ended
/// and the glasses' battery at each end, so a standby cost per hour can be estimated. The device
/// is never named.
@MainActor
final class InputsProbeLedger: ObservableObject {
    static let shared = InputsProbeLedger()

    enum Entry: Equatable {
        case input(GlassesInput, milliseconds: Int, userAudioPlaying: Bool)
        /// Drag moves in a row from one source, kept as one entry: a band drag streams moves, and
        /// one at a time they would fill the run's cap in seconds and crowd out every press after
        /// it. The count and the first and last times give the rate, and `travel` how far the
        /// moves went (nil when none carried a delta); no position is kept.
        case moves(GlassesInputOrigin, count: Int, firstMilliseconds: Int, lastMilliseconds: Int,
                   userAudioPlaying: Bool, travel: GlassesDragTravel?)
        case state(InputsProbeState, milliseconds: Int)
        case error(InputsProbeFailure, milliseconds: Int)
    }

    struct Stop: Equatable {
        var reason: InputsProbeStopReason
        var milliseconds: Int
        var battery: Int?
    }

    struct Run: Equatable {
        let startedAt: Date
        let batteryAtStart: Int?
        /// The inputs kept, then states and errors, in arrival order.
        var entries: [Entry] = []
        /// Every input that arrived, kept or not.
        var inputCount = 0
        /// States and errors that arrived after their cap.
        var droppedOther = 0
        var stop: Stop?

        /// The inputs the kept entries stand for (a run of moves counts each move).
        var keptInputs: Int {
            entries.reduce(0) {
                switch $1 {
                case .input: return $0 + 1
                case .moves(_, let count, _, _, _, _): return $0 + count
                case .state, .error: return $0
                }
            }
        }
        /// The kept entries that hold inputs, which is what the cap counts.
        var inputEntries: Int {
            entries.reduce(0) {
                switch $1 {
                case .input, .moves: return $0 + 1
                case .state, .error: return $0
                }
            }
        }
        var isTruncated: Bool { inputCount > keptInputs || droppedOther > 0 }
    }

    /// Input entries kept per run (a run of drag moves is one); the first ones are kept, and the
    /// report says how many more inputs came.
    static let inputCapacity = 500
    /// State changes and errors kept per run.
    static let otherCapacity = 100
    /// Runs kept; the oldest go first.
    static let runCapacity = 3

    @Published private(set) var runs: [Run] = []
    @Published private(set) var lastRefusal: InputsProbeRefusal?
    private var totalRuns = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// The run going now, if one is.
    var current: Run? {
        guard let last = runs.last, last.stop == nil else { return nil }
        return last
    }

    func begin(battery: Int?) {
        if current != nil { end(.shutdown, battery: nil) }
        lastRefusal = nil
        totalRuns += 1
        runs.append(Run(startedAt: now(), batteryAtStart: battery))
        if runs.count > Self.runCapacity { runs.removeFirst(runs.count - Self.runCapacity) }
    }

    func refused(_ refusal: InputsProbeRefusal) {
        lastRefusal = refusal
    }

    func recordInput(_ input: GlassesInput, userAudioPlaying: Bool) {
        mutateCurrent { run, ms in
            run.inputCount += 1
            let isMove = input.kind == .drag(.move)
            if isMove, let last = run.entries.indices.last,
               case .moves(let origin, let count, let first, _, let audio, var travel) = run.entries[last],
               origin == input.origin {
                if let delta = input.delta {
                    if travel == nil { travel = GlassesDragTravel() }
                    travel?.add(delta)
                }
                run.entries[last] = .moves(origin, count: count + 1, firstMilliseconds: first,
                                           lastMilliseconds: ms, userAudioPlaying: audio, travel: travel)
                return
            }
            guard run.inputEntries < Self.inputCapacity else { return }
            run.entries.append(isMove
                ? .moves(input.origin, count: 1, firstMilliseconds: ms, lastMilliseconds: ms,
                         userAudioPlaying: userAudioPlaying, travel: input.delta.map(GlassesDragTravel.init))
                : .input(input, milliseconds: ms, userAudioPlaying: userAudioPlaying))
        }
    }

    func recordState(_ state: InputsProbeState) {
        mutateCurrent { run, ms in appendOther(.state(state, milliseconds: ms), to: &run) }
    }

    func recordError(_ failure: InputsProbeFailure) {
        mutateCurrent { run, ms in appendOther(.error(failure, milliseconds: ms), to: &run) }
    }

    func end(_ reason: InputsProbeStopReason, battery: Int?) {
        mutateCurrent { run, ms in run.stop = Stop(reason: reason, milliseconds: ms, battery: battery) }
    }

    func reset() {
        runs = []
        lastRefusal = nil
        totalRuns = 0
    }

    private func appendOther(_ entry: Entry, to run: inout Run) {
        let others = run.entries.count - run.inputEntries
        guard others < Self.otherCapacity else { run.droppedOther += 1; return }
        run.entries.append(entry)
    }

    private func mutateCurrent(_ change: (inout Run, Int) -> Void) {
        guard let index = runs.indices.last, runs[index].stop == nil else { return }
        var run = runs[index]
        let ms = max(0, Int((now().timeIntervalSince(run.startedAt) * 1000).rounded()))
        change(&run, ms)
        runs[index] = run
    }

    // MARK: - Report

    /// Empty until a run has started — always, in a build without the probe.
    var reportLines: [String] {
        guard !runs.isEmpty else { return [] }
        let config = InputsProbePolicy.origins.map(\.rawValue).sorted().joined(separator: "+")
        var lines = ["Glasses inputs probe: \(totalRuns) run\(totalRuns == 1 ? "" : "s") since launch"
                     + " (sources \(config), Back \(InputsProbePolicy.consumesBack ? "consumed" : "left to Meta"))"]
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        let first = totalRuns - runs.count + 1
        for (offset, run) in runs.enumerated() {
            lines += Self.lines(for: run, number: first + offset, clock: clock)
        }
        return lines
    }

    static func lines(for run: Run, number: Int, clock: DateFormatter) -> [String] {
        let prefix = "  run \(number)"
        var lines = ["\(prefix) · \(clock.string(from: run.startedAt)) · started, battery \(percent(run.batteryAtStart))"]
        for entry in run.entries {
            lines.append("\(prefix) · \(describe(entry))")
        }
        if run.inputCount > run.keptInputs {
            lines.append("\(prefix) · truncated: \(run.inputCount) inputs, the first \(run.keptInputs) kept")
        }
        if run.droppedOther > 0 {
            lines.append("\(prefix) · truncated: \(run.droppedOther) more state changes and errors not kept")
        }
        lines.append("\(prefix) · \(tally(run))")
        if let stop = run.stop {
            var line = "\(prefix) · stopped (\(stop.reason.rawValue)) after \(stop.milliseconds / 1000) s, battery \(percent(stop.battery))"
            if let rate = batteryPerHour(from: run.batteryAtStart, to: stop.battery, milliseconds: stop.milliseconds) {
                line += " (\(rate))"
            }
            lines.append(line)
        } else {
            lines.append("\(prefix) · still running")
        }
        return lines
    }

    static func describe(_ entry: Entry) -> String {
        switch entry {
        case .input(let input, let ms, let audio):
            // A drag's down or up says how far it moved only when it did.
            let moved = input.delta.flatMap { $0.dx != 0 || $0.dy != 0 ? ", " + GlassesDragTravel($0).reportText : nil } ?? ""
            return "+\(ms) ms · \(input.kind.reportToken) (\(input.origin.rawValue))\(moved)\(audio ? ", audio playing" : "")"
        case .moves(let origin, let count, let first, let last, let audio, let travel):
            let span = count == 1 ? "" : " \(count) times over \(last - first) ms"
            return "+\(first) ms · \(GlassesInputKind.drag(.move).reportToken)\(span) (\(origin.rawValue))"
                + (travel.map { ", " + $0.reportText } ?? "")
                + (audio ? ", audio playing" : "")
        case .state(let state, let ms):
            return "+\(ms) ms · state \(state.rawValue)"
        case .error(let failure, let ms):
            return "+\(ms) ms · error \(failure.rawValue)"
        }
    }

    /// Every input by kind and source, most frequent first: "42 inputs: select (captouch) 20, …".
    static func tally(_ run: Run) -> String {
        var counts: [String: Int] = [:]
        var audio = 0
        for entry in run.entries {
            switch entry {
            case .input(let input, _, let playing):
                counts["\(input.kind.reportToken) (\(input.origin.rawValue))", default: 0] += 1
                if playing { audio += 1 }
            case .moves(let origin, let count, _, _, let playing, _):
                counts["\(GlassesInputKind.drag(.move).reportToken) (\(origin.rawValue))", default: 0] += count
                if playing { audio += count }
            case .state, .error:
                continue
            }
        }
        guard run.inputCount > 0 else { return "0 inputs" }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
        return "\(run.inputCount) input\(run.inputCount == 1 ? "" : "s"): " + parts.joined(separator: ", ")
            + " · \(audio) with audio playing"
    }

    private static func percent(_ level: Int?) -> String {
        level.map { "\($0) %" } ?? "not known"
    }

    /// The battery's fall over the run, as points per hour. Coarse: the reading moves in whole
    /// points, so a short run says little; nil without both readings or a run of under a minute.
    static func batteryPerHour(from start: Int?, to end: Int?, milliseconds: Int) -> String? {
        guard let start, let end, milliseconds >= 60_000 else { return nil }
        let perHour = Double(start - end) * 3_600_000 / Double(milliseconds)
        return String(format: "%.1f points per hour", locale: Locale(identifier: "en_US_POSIX"), perHour)
    }
}
