import Foundation

/// A measurement the app can ask the ring for.
enum RingMeasurement: String, Equatable, Hashable, Sendable {
    /// One heart-rate reading, then stop (capped at 60 s).
    case spotHeartRate
    /// Heart rate streamed until the app stops it (a workout).
    case liveHeartRate
    /// One blood-oxygen reading (up to 45 s).
    case oxygen
}

/// A timer the machine asked for. The token makes a stale timer harmless: a fire whose token is
/// not the machine's current one for that kind is ignored.
struct RingTimer: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// No echo for the outstanding write (or no battery value) yet.
        case acknowledgement
        /// Waiting for an activity packet the startup burst did not bring.
        case activityWait
        /// No sleep packet for a while: the timeline is complete.
        case sleepQuiet
        /// No stored-measurement packet for a while: give up on the end marker.
        case storedHistoryWatchdog
        /// A spot heart-rate reading took too long.
        case heartRateCap
        /// A blood-oxygen reading took too long.
        case oxygenWait
    }

    let kind: Kind
    let token: Int
}

/// What happens to the machine.
enum RingSyncInput: Equatable, Sendable {
    /// Connected, the protocol service found and notifications subscribed.
    case linkReady
    /// The link dropped.
    case disconnected
    /// A notification, decoded by the driver.
    case event(RingEvent)
    /// The answer to `.readBattery`; nil when the read failed.
    case batteryRead(percent: Int?)
    /// A timer the machine asked for went off.
    case timerFired(RingTimer)
    /// The app wants a measurement.
    case measure(RingMeasurement)
    /// The app no longer wants a live heart-rate session.
    case stopLiveHeartRate
    /// Run the whole sync again.
    case syncNow
    /// The phone's time zone changed: the ring's clock is set again.
    case timeZoneChanged(TimeZone)
    /// Turn the ring's clench trigger mode on or off now, and at every later connect (Plan MZ §8).
    case setSelfieMode(Bool)
    /// Change the automatic heart-rate schedule; sent now when linked, and at every later connect.
    case setHeartRateSchedule(RingHeartRateSchedule)
    /// Light the ring up so it can be found.
    case findRing
}

/// What the machine wants done, in order.
enum RingSyncEffect: Equatable, Sendable {
    /// Write a command (the driver encodes it). One is outstanding at a time.
    case write(RingCommand)
    /// Read the standard battery level characteristic, answered with `.batteryRead`.
    case readBattery
    case startTimer(RingTimer, after: TimeInterval)
    case cancelTimer(RingTimer)
    /// The link is gone: drop every timer.
    case cancelAllTimers
    case report(RingSyncReport)
}

/// What the machine learned or finished, for the ring service to act on.
enum RingSyncReport: Equatable, Sendable {
    case syncStarted
    case syncFinished(at: Date)
    /// The ring's clock was set; keep this clock with the ring's cursors.
    case clockLatched(RingClock)
    case battery(percent: Int)
    /// The ring's day step counter, read at `at`.
    case activity(steps: Int, at: Date)
    /// The sleep timeline, as merged runs, decoded with the clock it was recorded under.
    case sleep([RingSleepRun])
    /// The stored-measurement stream: how many chunks came, and whether its end marker did.
    /// Nothing from it is written until the device pass confirms the format (Plan MZ risk 7).
    case storedHistory(chunks: Int, complete: Bool)
    case heartRate(bpm: Int, at: Date, during: RingMeasurement)
    case oxygen(percent: Int, at: Date)
    /// A measurement ended without a plausible value.
    case noReading(RingMeasurement)
    /// A measurement is over and the ring told to stop.
    case measurementFinished(RingMeasurement)
    /// Not linked, or another measurement is running or waiting.
    case measurementRefused(RingMeasurement)
    /// The link dropped during a measurement or before a waiting one began.
    case measurementInterrupted(RingMeasurement)
    /// A sync step got no answer after one retry and was skipped.
    case stepSkipped(RingSyncMachine.SyncStep)
    /// A one-off command (find ring, the trigger mode) was acknowledged.
    case commandFinished(RingCommandKind)
    /// A one-off command got no answer after one retry, or the link dropped before it was sent.
    case commandFailed(RingCommandKind)
    case clench
    /// A packet the driver does not read. Only its opcode is reported, so it can be counted.
    case unknownPacket(opcode: UInt8)
    case malformedPacket
}

/// The ring's sync, as a pure state machine (Plan MZ §4).
///
/// Events and timer fires go in; writes, timers and reports come out. Writes are serialised: one is
/// outstanding at a time, its echo is its acknowledgement, and no echo within 3 s is one retry and
/// then the step is skipped and the sync carries on. The connect sequence is `SyncStep.allCases`.
/// From idle the app can ask for one measurement at a time; one asked for during a sync waits for
/// the current step, runs, and the sync resumes after it. A disconnect resets everything except the
/// clocks; the next `.linkReady` starts again from the top.
struct RingSyncMachine {

    struct Configuration: Equatable, Sendable {
        var timeZone: TimeZone
        /// Sent as observed; the ring's own app sent this whatever the phone's language.
        var locale = "en-US"
        var heartRateSchedule = RingHeartRateSchedule.recommended
        /// The wearer's daily step goal; the goal step is skipped without one.
        var stepGoal: Int?
        /// The clench trigger is on: the connect sequence turns the ring's trigger mode on. Off
        /// sends nothing at connect; turning it off while linked sends the off command once.
        var selfieMode = false
        var acknowledgementTimeout: TimeInterval = 3
        var activityWait: TimeInterval = 5
        var sleepQuietWindow: TimeInterval = 2
        var storedHistoryWatchdog: TimeInterval = 10
        var spotHeartRateCap: TimeInterval = 60
        var oxygenWait: TimeInterval = 45

        init(timeZone: TimeZone, stepGoal: Int? = nil) {
            self.timeZone = timeZone
            self.stepGoal = stepGoal
        }
    }

    /// The connect sequence, in order. Connecting and subscribing are the transport's. `trigger`
    /// writes only while the clench trigger is on (`Configuration.selfieMode`).
    enum SyncStep: String, CaseIterable, Equatable, Sendable {
        case status, time, locale, schedule, goal, trigger, battery, activity, sleep, storedHistory
    }

    enum Phase: Equatable, Sendable {
        case disconnected
        case syncing(SyncStep)
        case measuring(RingMeasurement)
        /// A one-off command is outstanding.
        case sending(RingCommandKind)
        case idle
    }

    static let plausibleHeartRate = 30...220
    static let plausibleOxygen = 70...100

    private(set) var configuration: Configuration
    /// What the ring's clock was last set to.
    private(set) var latchedClock: RingClock?
    /// What the data still on the ring was stamped under: the clock before this connection's
    /// time sync, until a full sync has fetched everything recorded under it.
    private(set) var recordingClock: RingClock?

    private var linked = false
    private var syncQueue: [SyncStep] = []
    private var fullSyncRunning = false
    private var current: Activity?
    private var pendingMeasurement: RingMeasurement?
    /// One-off commands waiting their turn; they run before the next sync step.
    private var commandQueue: [RingCommand] = []
    private var outstanding: Outstanding?
    private var timers: [RingTimer.Kind: RingTimer] = [:]
    private var nextToken = 0
    private var activitySeenThisLink = false
    private var clockBeingSet: RingClock?
    private var sleepPackets: [RingSleepPacket] = []
    private var storedChunks = 0

    private enum Activity: Equatable {
        case step(SyncStep)
        case measuring(Measuring)
        case command(RingCommandKind)
    }

    private struct Measuring: Equatable {
        enum Stage: Equatable { case starting, running, stopping }
        let kind: RingMeasurement
        var stage: Stage = .starting
        var gotReading = false
        var stopWanted = false
    }

    private enum Action: Equatable {
        case write(RingCommand)
        case readBattery
    }

    private struct Outstanding: Equatable {
        let action: Action
        var attempt: Int
    }

    /// `latchedClock`: the clock the ring was last set to, kept with its cursors; nil for a ring
    /// that has never synced.
    init(configuration: Configuration, latchedClock: RingClock? = nil) {
        self.configuration = configuration
        self.latchedClock = latchedClock
        self.recordingClock = latchedClock
    }

    var phase: Phase {
        guard linked else { return .disconnected }
        switch current {
        case .step(let step): return .syncing(step)
        case .measuring(let measuring): return .measuring(measuring.kind)
        case .command(let kind): return .sending(kind)
        case nil: return .idle
        }
    }

    // MARK: - Input

    mutating func handle(_ input: RingSyncInput, at now: Date) -> [RingSyncEffect] {
        switch input {
        case .linkReady:
            var effects: [RingSyncEffect] = linked ? [.cancelAllTimers] : []
            resetLink()
            linked = true
            effects += startFullSync(now)
            return effects

        case .disconnected:
            guard linked else { return [] }
            var effects: [RingSyncEffect] = [.cancelAllTimers]
            if case .measuring(let measuring) = current {
                effects.append(.report(.measurementInterrupted(measuring.kind)))
            }
            if let pending = pendingMeasurement {
                effects.append(.report(.measurementInterrupted(pending)))
            }
            if case .command(let kind) = current {
                effects.append(.report(.commandFailed(kind)))
            }
            effects += commandQueue.map { .report(.commandFailed($0.kind)) }
            resetLink()
            return effects

        case .event(let event):
            guard linked else { return [] }
            return handle(event, now)

        case .batteryRead(let percent):
            guard linked, outstanding?.action == .readBattery else { return [] }
            var effects = clearOutstanding()
            if let percent, (0...100).contains(percent) {
                effects.append(.report(.battery(percent: percent)))
            } else {
                effects.append(.report(.stepSkipped(.battery)))
            }
            return effects + finishCurrent(now)

        case .timerFired(let timer):
            guard linked, timers[timer.kind] == timer else { return [] }
            timers[timer.kind] = nil
            return timerFired(timer.kind, now)

        case .measure(let measurement):
            guard linked, pendingMeasurement == nil, !isMeasuring else {
                return [.report(.measurementRefused(measurement))]
            }
            pendingMeasurement = measurement
            return current == nil ? advance(now) : []

        case .stopLiveHeartRate:
            if pendingMeasurement == .liveHeartRate {
                pendingMeasurement = nil
                return [.report(.measurementFinished(.liveHeartRate))]
            }
            guard case .measuring(var measuring) = current, measuring.kind == .liveHeartRate else { return [] }
            switch measuring.stage {
            case .starting:
                measuring.stopWanted = true
                current = .measuring(measuring)
                return []
            case .running:
                return stopMeasurement(now)
            case .stopping:
                return []
            }

        case .syncNow:
            guard linked, !fullSyncRunning else { return [] }
            syncQueue = SyncStep.allCases
            fullSyncRunning = true
            return [.report(.syncStarted)] + (current == nil ? advance(now) : [])

        case .timeZoneChanged(let timeZone):
            configuration.timeZone = timeZone
            guard linked else { return [] }
            // A time step still queued will use the new zone; one already sent used the old one.
            if !syncQueue.contains(.time) { syncQueue.append(.time) }
            return current == nil ? advance(now) : []

        case .setSelfieMode(let on):
            configuration.selfieMode = on
            guard linked else { return [] }
            // The connect sequence's own trigger step, if still queued, now reads the new value
            // and writes only when on; the explicit command covers the off case too.
            syncQueue.removeAll { $0 == .trigger }
            commandQueue.removeAll { $0.kind == .selfieModeOn || $0.kind == .selfieModeOff }
            commandQueue.append(.selfieMode(on: on))
            return current == nil ? advance(now) : []

        case .setHeartRateSchedule(let schedule):
            configuration.heartRateSchedule = schedule
            guard linked else { return [] }
            if !syncQueue.contains(.schedule) { syncQueue.append(.schedule) }
            return current == nil ? advance(now) : []

        case .findRing:
            guard linked else { return [.report(.commandFailed(.findRing))] }
            commandQueue.append(.findRing)
            return current == nil ? advance(now) : []
        }
    }

    // MARK: - Scheduling

    private var isMeasuring: Bool {
        if case .measuring = current { return true }
        return false
    }

    private mutating func resetLink() {
        linked = false
        syncQueue = []
        fullSyncRunning = false
        current = nil
        pendingMeasurement = nil
        commandQueue = []
        outstanding = nil
        timers = [:]
        activitySeenThisLink = false
        clockBeingSet = nil
        sleepPackets = []
        storedChunks = 0
    }

    private mutating func startFullSync(_ now: Date) -> [RingSyncEffect] {
        syncQueue = SyncStep.allCases
        fullSyncRunning = true
        return [.report(.syncStarted)] + advance(now)
    }

    /// Start whatever is next: a waiting measurement first, then the next sync step.
    private mutating func advance(_ now: Date) -> [RingSyncEffect] {
        guard linked, current == nil, outstanding == nil else { return [] }
        if let measurement = pendingMeasurement {
            pendingMeasurement = nil
            return startMeasurement(measurement)
        }
        if !commandQueue.isEmpty {
            let command = commandQueue.removeFirst()
            current = .command(command.kind)
            return send(.write(command))
        }
        if !syncQueue.isEmpty {
            return startStep(syncQueue.removeFirst(), now)
        }
        if fullSyncRunning {
            fullSyncRunning = false
            // Everything recorded under the old clock has been fetched.
            if let latchedClock { recordingClock = latchedClock }
            return [.report(.syncFinished(at: now))]
        }
        return []
    }

    private mutating func finishCurrent(_ now: Date) -> [RingSyncEffect] {
        current = nil
        return advance(now)
    }

    // MARK: - Sync steps

    private mutating func startStep(_ step: SyncStep, _ now: Date) -> [RingSyncEffect] {
        current = .step(step)
        switch step {
        case .status:
            return send(.write(.status))
        case .time:
            let clock = RingClock.latching(configuration.timeZone, at: now)
            clockBeingSet = clock
            return send(.write(.timeSync(clock.timeSync(at: now))))
        case .locale:
            return send(.write(.locale(configuration.locale)))
        case .schedule:
            return send(.write(.heartRateSchedule(configuration.heartRateSchedule)))
        case .goal:
            guard let goal = configuration.stepGoal, goal > 0 else { return finishCurrent(now) }
            return send(.write(.stepGoal(goal)))
        case .trigger:
            // Re-enabled after every reconnect while the trigger is on; nothing when it is off.
            guard configuration.selfieMode else { return finishCurrent(now) }
            return send(.write(.selfieMode(on: true)))
        case .battery:
            return send(.readBattery)
        case .activity:
            // Usually already in the burst that follows subscribing; otherwise the next one.
            guard !activitySeenThisLink else { return finishCurrent(now) }
            return startTimer(.activityWait, after: configuration.activityWait)
        case .sleep:
            sleepPackets = []
            return send(.write(.sleepHistoryQuery))
        case .storedHistory:
            storedChunks = 0
            return send(.write(.storedHistoryQuery))
        }
    }

    // MARK: - Measurements

    private mutating func startMeasurement(_ kind: RingMeasurement) -> [RingSyncEffect] {
        current = .measuring(Measuring(kind: kind))
        return send(.write(kind == .oxygen ? .oxygenStart : .liveHeartRateStart))
    }

    private mutating func stopMeasurement(_ now: Date) -> [RingSyncEffect] {
        guard case .measuring(var measuring) = current else { return [] }
        measuring.stage = .stopping
        current = .measuring(measuring)
        let effects = cancelTimer(.heartRateCap) + cancelTimer(.oxygenWait)
        return effects + send(.write(measuring.kind == .oxygen ? .oxygenStop : .liveHeartRateStop))
    }

    private mutating func finishMeasurement(_ now: Date) -> [RingSyncEffect] {
        guard case .measuring(let measuring) = current else { return [] }
        return [.report(.measurementFinished(measuring.kind))] + finishCurrent(now)
    }

    // MARK: - Writes

    private mutating func send(_ action: Action) -> [RingSyncEffect] {
        outstanding = Outstanding(action: action, attempt: 1)
        return issue(action)
    }

    private mutating func issue(_ action: Action) -> [RingSyncEffect] {
        let effect: RingSyncEffect
        switch action {
        case .write(let command): effect = .write(command)
        case .readBattery: effect = .readBattery
        }
        return [effect] + startTimer(.acknowledgement, after: configuration.acknowledgementTimeout)
    }

    private mutating func clearOutstanding() -> [RingSyncEffect] {
        outstanding = nil
        return cancelTimer(.acknowledgement)
    }

    /// Whether `event` answers a write of `kind`. An echo does; so does the first packet of the
    /// stream a query starts, in case the echo itself never comes.
    private static func event(_ event: RingEvent, acknowledges kind: RingCommandKind) -> Bool {
        switch event {
        case .acknowledged(let acknowledged): return acknowledged == kind
        case .sleep, .sleepHistorySummary: return kind == .sleepHistoryQuery
        case .storedHistoryHeader, .storedHistoryMetadata, .storedHistoryChunk, .storedHistoryEnd:
            return kind == .storedHistoryQuery
        case .heartRate: return kind == .liveHeartRateStart
        case .oxygenProgress, .oxygenResult: return kind == .oxygenStart
        default: return false
        }
    }

    /// The outstanding write was answered: move the current step or measurement on.
    private mutating func acknowledged(_ kind: RingCommandKind, _ now: Date) -> [RingSyncEffect] {
        switch current {
        case .step(.time):
            var effects: [RingSyncEffect] = []
            if let clock = clockBeingSet {
                latchedClock = clock
                if recordingClock == nil { recordingClock = clock }
                effects.append(.report(.clockLatched(clock)))
            }
            clockBeingSet = nil
            return effects + finishCurrent(now)
        case .step(.sleep):
            return timers[.sleepQuiet] == nil
                ? startTimer(.sleepQuiet, after: configuration.sleepQuietWindow) : []
        case .step(.storedHistory):
            return timers[.storedHistoryWatchdog] == nil
                ? startTimer(.storedHistoryWatchdog, after: configuration.storedHistoryWatchdog) : []
        case .step:
            return finishCurrent(now)
        case .command(let kind):
            return [.report(.commandFinished(kind))] + finishCurrent(now)
        case .measuring(var measuring):
            switch measuring.stage {
            case .starting:
                measuring.stage = .running
                current = .measuring(measuring)
                if measuring.stopWanted { return stopMeasurement(now) }
                switch measuring.kind {
                case .spotHeartRate:
                    // The cap runs from the first start; a restart after the ring ends its run
                    // does not extend it.
                    return timers[.heartRateCap] == nil
                        ? startTimer(.heartRateCap, after: configuration.spotHeartRateCap) : []
                case .oxygen:
                    return startTimer(.oxygenWait, after: configuration.oxygenWait)
                case .liveHeartRate:
                    return []
                }
            case .stopping:
                return finishMeasurement(now)
            case .running:
                return []
            }
        case nil:
            return []
        }
    }

    /// The outstanding write got no answer after its retry.
    private mutating func gaveUp(on action: Action, _ now: Date) -> [RingSyncEffect] {
        switch current {
        case .step(let step):
            if step == .time { clockBeingSet = nil }
            return [.report(.stepSkipped(step))] + finishCurrent(now)
        case .command(let kind):
            return [.report(.commandFailed(kind))] + finishCurrent(now)
        case .measuring(let measuring):
            switch measuring.stage {
            case .starting:
                // The ring may have started anyway; tell it to stop so it does not run on.
                return [.report(.noReading(measuring.kind))] + stopMeasurement(now)
            case .stopping, .running:
                return finishMeasurement(now)
            }
        case nil:
            return []
        }
    }

    // MARK: - Events

    private mutating func handle(_ event: RingEvent, _ now: Date) -> [RingSyncEffect] {
        var effects: [RingSyncEffect] = []
        if let outstanding, case .write(let command) = outstanding.action,
           Self.event(event, acknowledges: command.kind) {
            effects += clearOutstanding()
            effects += acknowledged(command.kind, now)
        }
        return effects + content(of: event, now)
    }

    private mutating func content(of event: RingEvent, _ now: Date) -> [RingSyncEffect] {
        switch event {
        case .battery(let percent):
            return [.report(.battery(percent: percent))]

        case .activity(let reading):
            activitySeenThisLink = true
            var effects: [RingSyncEffect] = [.report(.activity(steps: reading.steps, at: now))]
            if current == .step(.activity) {
                effects += cancelTimer(.activityWait) + finishCurrent(now)
            }
            return effects

        case .sleep(let packet):
            guard current == .step(.sleep), outstanding == nil else { return [] }
            sleepPackets.append(packet)
            return startTimer(.sleepQuiet, after: configuration.sleepQuietWindow)

        case .sleepHistorySummary:
            guard current == .step(.sleep), outstanding == nil else { return [] }
            return startTimer(.sleepQuiet, after: configuration.sleepQuietWindow)

        case .storedHistoryHeader, .storedHistoryMetadata, .storedHistoryChunk:
            guard current == .step(.storedHistory), outstanding == nil else { return [] }
            if event == .storedHistoryChunk { storedChunks += 1 }
            return startTimer(.storedHistoryWatchdog, after: configuration.storedHistoryWatchdog)

        case .storedHistoryEnd:
            guard current == .step(.storedHistory), outstanding == nil else { return [] }
            return cancelTimer(.storedHistoryWatchdog)
                + [.report(.storedHistory(chunks: storedChunks, complete: true))]
                + finishCurrent(now)

        case .heartRate(let bpm):
            guard case .measuring(var measuring) = current, measuring.stage == .running,
                  measuring.kind != .oxygen, Self.plausibleHeartRate.contains(bpm) else { return [] }
            let report = RingSyncEffect.report(.heartRate(bpm: bpm, at: now, during: measuring.kind))
            guard measuring.kind == .spotHeartRate else { return [report] }
            guard !measuring.gotReading else { return [] }
            measuring.gotReading = true
            current = .measuring(measuring)
            return [report] + stopMeasurement(now)

        case .liveHeartRateEnded:
            // The ring ends a run on its own; start another while a reading is still wanted.
            guard case .measuring(var measuring) = current, measuring.stage == .running,
                  measuring.kind != .oxygen else { return [] }
            measuring.stage = .starting
            current = .measuring(measuring)
            return send(.write(.liveHeartRateStart))

        case .oxygenResult(let percent):
            guard case .measuring(let measuring) = current, measuring.kind == .oxygen,
                  measuring.stage == .running, Self.plausibleOxygen.contains(percent) else { return [] }
            return [.report(.oxygen(percent: percent, at: now))] + stopMeasurement(now)

        case .oxygenEnded:
            // The ring ended the run before a plausible value: progress only is no reading.
            guard case .measuring(let measuring) = current, measuring.kind == .oxygen,
                  measuring.stage == .running else { return [] }
            return [.report(.noReading(.oxygen))] + stopMeasurement(now)

        case .clench:
            return [.report(.clench)]

        case .unknown(let opcode):
            return [.report(.unknownPacket(opcode: opcode))]

        case .malformed:
            return [.report(.malformedPacket)]

        case .acknowledged, .activitySummary, .oxygenProgress:
            return []
        }
    }

    // MARK: - Timers

    private mutating func timerFired(_ kind: RingTimer.Kind, _ now: Date) -> [RingSyncEffect] {
        switch kind {
        case .acknowledgement:
            guard var outstanding else { return [] }
            if outstanding.attempt == 1 {
                outstanding.attempt = 2
                self.outstanding = outstanding
                return issue(outstanding.action)
            }
            self.outstanding = nil
            return gaveUp(on: outstanding.action, now)

        case .activityWait:
            guard current == .step(.activity) else { return [] }
            return finishCurrent(now)

        case .sleepQuiet:
            guard current == .step(.sleep) else { return [] }
            let clock = recordingClock ?? latchedClock ?? RingClock.latching(configuration.timeZone, at: now)
            let runs = RingSleepTimeline.runs(from: sleepPackets, clock: clock)
            sleepPackets = []
            return (runs.isEmpty ? [] : [.report(.sleep(runs))]) + finishCurrent(now)

        case .storedHistoryWatchdog:
            guard current == .step(.storedHistory) else { return [] }
            return [.report(.storedHistory(chunks: storedChunks, complete: false))] + finishCurrent(now)

        case .heartRateCap:
            guard case .measuring(let measuring) = current, measuring.kind == .spotHeartRate,
                  !measuring.gotReading else { return [] }
            return [.report(.noReading(.spotHeartRate))] + stopMeasurement(now)

        case .oxygenWait:
            guard case .measuring(let measuring) = current, measuring.kind == .oxygen else { return [] }
            return [.report(.noReading(.oxygen))] + stopMeasurement(now)
        }
    }

    private mutating func startTimer(_ kind: RingTimer.Kind, after interval: TimeInterval) -> [RingSyncEffect] {
        let effects = cancelTimer(kind)
        nextToken += 1
        let timer = RingTimer(kind: kind, token: nextToken)
        timers[kind] = timer
        return effects + [.startTimer(timer, after: interval)]
    }

    private mutating func cancelTimer(_ kind: RingTimer.Kind) -> [RingSyncEffect] {
        guard let timer = timers.removeValue(forKey: kind) else { return [] }
        return [.cancelTimer(timer)]
    }
}
