import Foundation

/// Runs work later on the main actor. The live one is `RingTaskScheduler`; tests fire by hand.
@MainActor
protocol RingScheduling: AnyObject {
    func schedule(after interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> RingScheduledWork
}

@MainActor
protocol RingScheduledWork: AnyObject {
    func cancel()
}

/// `RingScheduling` on Swift concurrency's clock.
@MainActor
final class RingTaskScheduler: RingScheduling {

    init() {}

    private final class Work: RingScheduledWork {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    func schedule(after interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> RingScheduledWork {
        let handle = Work()
        handle.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
        return handle
    }
}

/// The smart ring, end to end (Plan MZ P2–P4): the paired ring, its link, the sync, the writes to
/// Apple Health, live heart rate, measurements on request and the clench trigger.
///
/// Every edge is a seam: the transport (Bluetooth), the Health store, the pairing store, the clock
/// and the scheduler, so the whole service runs headless over a fake ring. It reaches no `.shared`
/// service; `AppState` hands it what it needs (the trigger's performer, the announcer).
///
/// Logging names what happened and never carries a reading, an address, an identifier or a
/// packet's bytes (`RingPrivacyScrapeTests`).
@MainActor
final class RingService: ObservableObject {

    /// The link, as the settings show it.
    enum Link: String, Equatable, Sendable {
        /// Not running: the ring support is off.
        case stopped
        case notPaired
        case bluetoothOff
        case bluetoothDenied
        /// Paired, and waiting for the ring to come into range.
        case connecting
        case connected
    }

    enum MeasurementOutcome: Equatable, Sendable {
        case heartRate(Int)
        case oxygen(Int)
        /// The ring finished without a plausible value.
        case noReading
        case notPaired
        case notConnected
        /// Another measurement is running or waiting.
        case busy
        /// The link dropped before it finished.
        case interrupted
    }

    /// What the service reads from the wearer's settings each time it needs them.
    struct Settings: Equatable, Sendable {
        var heartRateSchedule: RingHeartRateSchedule
        var trigger: RingTriggerSetting
        var stepGoal: Int?

        static var current: Settings {
            let goal = UserDefaults.standard.integer(forKey: "fitnessStepGoal")
            return Settings(heartRateSchedule: Config.ringHeartRateSchedule,
                            trigger: Config.ringTriggerSetting,
                            stepGoal: goal > 0 ? goal : nil)
        }
    }

    /// How long `forget()` waits for the ring to acknowledge leaving trigger mode.
    nonisolated static let forgetAcknowledgementWait: TimeInterval = 3
    /// A measurement the ring never finishes is given up on after this, whatever the machine does.
    nonisolated static let measurementDeadline: TimeInterval = 75

    @Published private(set) var link: Link = .stopped
    @Published private(set) var battery: Int?
    @Published private(set) var syncing = false
    @Published private(set) var pairing: RingPairingRecord?
    @Published private(set) var candidates: [RingCandidate] = []
    @Published private(set) var scanning = false
    /// Decision 9's note, while it is showing.
    @Published private(set) var otherAppNotice: String?
    /// Why the last Health write was refused, until one succeeds.
    @Published private(set) var lastWriteRefusal: RingHealthStoreError?

    var lastSync: Date? { pairing?.lastSync }
    var isPaired: Bool { pairing != nil }
    var isRunning: Bool { running }
    var isConnected: Bool { link == .connected }

    let liveReadings: RingLiveReadings
    let packetLog: RingPacketLog

    /// A clench the trigger engine let through: resolved and carried out by the temple-tap
    /// performer (`AppState+Ring.swift`).
    var onTriggerAction: ((TempleAction) -> Void)?
    /// What the assistant is doing, for the trigger's suppression.
    var triggerActivity: () -> TempleContext.Activity = { .standby }
    /// Says a short line to the wearer (the ring's low battery).
    var announce: (String) -> Void = { _ in }

    private let transport: RingTransporting
    private let driver: RingDriver
    private let healthStore: RingHealthStoring
    private let pairingStore: RingPairingStoring
    private let scheduler: RingScheduling
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let settings: () -> Settings
    private let posture: () -> PowerPosture
    private let noticeShown: () -> Bool
    private let setNoticeShown: (Bool) -> Void

    private var running = false
    private var machine: RingSyncMachine?
    private var writer: RingHealthWriter?
    private var machineTimers: [RingTimer: RingScheduledWork] = [:]
    private var reconnectWork: RingScheduledWork?
    private var periodicSyncWork: RingScheduledWork?
    private var reconnectFailures = 0
    private var inbox: [RingSyncInput] = []
    private var pumping = false
    private var measurementWaiters: [RingMeasurement: [CheckedContinuation<MeasurementOutcome, Never>]] = [:]
    private var measurementDeadlines: [RingMeasurement: RingScheduledWork] = [:]
    private var commandWaiters: [RingCommandKind: [CheckedContinuation<Bool, Never>]] = [:]
    private var workoutWantsLive = false
    /// The heart rate read while a workout runs, in memory only, for the saved workout.
    private var workoutHeartRates: [RingReading] = []
    private var liveRunning = false
    private var batteryNotice = RingBatteryNotice()
    private var triggerEngine = RingTriggerEngine()
    private var timeZoneObserver: NSObjectProtocol?

    init(transport: RingTransporting,
         driver: RingDriver = SmartRingDriver(),
         healthStore: RingHealthStoring,
         pairingStore: RingPairingStoring? = nil,
         scheduler: RingScheduling? = nil,
         now: @escaping () -> Date = Date.init,
         timeZone: @escaping () -> TimeZone = { TimeZone.current },
         settings: @escaping () -> Settings = { Settings.current },
         posture: @escaping () -> PowerPosture = { .normal },
         noticeShown: @escaping () -> Bool = { Config.ringOtherAppNoticeShown },
         setNoticeShown: @escaping (Bool) -> Void = { Config.ringOtherAppNoticeShown = $0 }) {
        self.transport = transport
        self.driver = driver
        self.healthStore = healthStore
        self.pairingStore = pairingStore ?? RingPairingStore()
        self.scheduler = scheduler ?? RingTaskScheduler()
        self.now = now
        self.timeZone = timeZone
        self.settings = settings
        self.posture = posture
        self.noticeShown = noticeShown
        self.setNoticeShown = setNoticeShown
        self.liveReadings = RingLiveReadings(clock: now)
        self.packetLog = RingPacketLog()
        self.pairing = self.pairingStore.load()
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Lifecycle

    /// Start holding the paired ring's link. Nothing touches Bluetooth before this.
    func start() {
        guard !running else { return }
        running = true
        pairing = pairingStore.load()
        observeTimeZone()
        if let pairing {
            prepare(for: pairing)
            connect(pairing.peripheralIdentifier)
        } else {
            link = .notPaired
        }
        PrivacyLog.device(.ring, .started, success: pairing != nil)
    }

    /// Let go of the ring (the support was turned off). The pairing stays.
    func stop() {
        guard running else { return }
        running = false
        stopScan()
        cancelServiceTimers()
        transport.disconnect()
        dropLink()
        if let observer = timeZoneObserver { NotificationCenter.default.removeObserver(observer) }
        timeZoneObserver = nil
        link = .stopped
        PrivacyLog.device(.ring, .stopped)
    }

    // MARK: - Pairing

    func startScan() {
        candidates = []
        scanning = true
        transport.startScan()
    }

    func stopScan() {
        guard scanning else { return }
        scanning = false
        transport.stopScan()
    }

    /// Pair the ring the wearer picked: a new pairing id, its identifier, fresh cursors.
    func pair(_ candidate: RingCandidate) {
        stopScan()
        if pairing != nil { forgetLocally() }
        let record = RingPairingRecord(pairingID: .make(), peripheralIdentifier: candidate.id, pairedAt: now())
        pairingStore.save(record)
        pairing = record
        if !running {
            running = true
            observeTimeZone()
        }
        prepare(for: record)
        connect(candidate.id)
        let viaAnotherApp = candidate.heldByAnotherApp
        PrivacyLog.device(.ring, .ringPaired, success: !viaAnotherApp)
    }

    /// Forget the ring: out of trigger mode if it is in it, then the link, the pairing id, the
    /// cursors and the latched clock go. Readings already in Health stay (decision 7); the wearer
    /// also forgets the ring in iOS Settings › Bluetooth, which an app cannot do.
    func forget() async {
        if isConnected, machine?.configuration.selfieMode == true {
            _ = await sendCommand(.setSelfieMode(false), kind: .selfieModeOff,
                                  deadline: Self.forgetAcknowledgementWait)
        }
        forgetLocally()
        link = running ? .notPaired : .stopped
        PrivacyLog.device(.ring, .ringForgotten)
    }

    private func forgetLocally() {
        // The record goes first, so a disconnect reported from inside `disconnect()` finds no ring
        // to reconnect to.
        pairingStore.clear()
        pairing = nil
        cancelServiceTimers()
        transport.disconnect()
        dropLink()
        machine = nil
        writer = nil
        battery = nil
        syncing = false
        lastWriteRefusal = nil
        otherAppNotice = nil
        setNoticeShown(false)
        workoutWantsLive = false
        workoutHeartRates = []
        liveReadings.clear()
        batteryNotice = RingBatteryNotice()
        triggerEngine.reset()
    }

    func dismissOtherAppNotice() {
        otherAppNotice = nil
    }

    // MARK: - Requests

    func syncNow() {
        enqueue(.syncNow)
    }

    /// Light the ring up. True when the ring acknowledged it.
    func findRing() async -> Bool {
        guard isConnected else { return false }
        return await sendCommand(.findRing, kind: .findRing, deadline: 10)
    }

    /// One heart-rate or oxygen reading, now.
    func measure(_ measurement: RingMeasurement) async -> MeasurementOutcome {
        guard pairing != nil else { return .notPaired }
        guard isConnected, machine != nil else { return .notConnected }
        guard measurementWaiters[measurement] == nil else { return .busy }
        return await withCheckedContinuation { continuation in
            measurementWaiters[measurement] = [continuation]
            measurementDeadlines[measurement] = scheduler.schedule(after: Self.measurementDeadline) { [weak self] in
                self?.resolveMeasurement(measurement, .noReading)
            }
            enqueue(.measure(measurement))
        }
    }

    /// A workout wants the heart rate for as long as it runs (Plan MZ §5).
    func beginWorkoutHeartRate() {
        workoutWantsLive = true
        workoutHeartRates = []
        startLiveIfWanted(requestedNow: true)
    }

    func endWorkoutHeartRate() {
        workoutWantsLive = false
        workoutHeartRates = []
        enqueue(.stopLiveHeartRate)
    }

    func workoutHeartRateSamples(from start: Date, to end: Date) -> [RingHealthSample] {
        guard let pairingID = pairing?.pairingID else { return [] }
        return RingHealthWriter.workoutHeartRateSamples(workoutHeartRates, pairingID: pairingID, from: start, to: end)
    }

    var workoutHeartRateWanted: Bool { workoutWantsLive }

    func heartRateScheduleChanged(_ schedule: RingHeartRateSchedule) {
        enqueue(.setHeartRateSchedule(schedule))
    }

    /// The trigger switched on or off: the ring's trigger mode follows at once.
    func triggerEnabledChanged(_ enabled: Bool) {
        triggerEngine.reset()
        enqueue(.setSelfieMode(enabled))
    }

    /// Remove every ring reading this app wrote to Health (decision 7), whichever ring wrote it.
    func deleteRingReadings() async throws -> Int {
        try await healthStore.deleteSamples(withSyncIdentifierPrefix: RingHealthWriter.syncIdentifierRoot)
    }

    // MARK: - Transport events

    private func handle(_ event: RingTransportEvent) {
        switch event {
        case .radio(let state):
            switch state {
            case .poweredOn:
                if running, let pairing, link != .connected { connect(pairing.peripheralIdentifier) }
            case .poweredOff:
                if running { link = .bluetoothOff }
            case .unauthorized:
                if running { link = .bluetoothDenied }
            case .unsupported, .unknown:
                break
            }
            PrivacyLog.device(.ring, .configured, state: PrivacyToken(state.rawValue))

        case .discovered(let candidate):
            guard scanning, !candidates.contains(where: { $0.id == candidate.id }) else { return }
            candidates.append(candidate)
            if RingOtherAppNotice.shouldShow(for: candidate, alreadyShown: noticeShown()) {
                otherAppNotice = RingOtherAppNotice.text
                setNoticeShown(true)
            }

        case .ready:
            guard running, pairing != nil else { return }
            reconnectWork?.cancel()
            reconnectWork = nil
            reconnectFailures = 0
            link = .connected
            PrivacyLog.device(.ring, .connected)
            enqueue(.linkReady)
            startLiveIfWanted(requestedNow: false)

        case .notification(let bytes):
            packetLog.record(bytes, .received)
            for decoded in driver.decode(bytes) { enqueue(.event(decoded)) }

        case .battery(let percent):
            enqueue(.batteryRead(percent: percent))

        case .disconnected:
            let wasConnected = link == .connected
            dropLink()
            guard running, let pairing else { return }
            if link != .bluetoothOff, link != .bluetoothDenied { link = .connecting }
            if wasConnected { PrivacyLog.device(.ring, .disconnected) }
            scheduleReconnect(pairing.peripheralIdentifier)
        }
    }

    // MARK: - The machine

    private func prepare(for record: RingPairingRecord) {
        let current = settings()
        if machine == nil {
            var configuration = RingSyncMachine.Configuration(timeZone: timeZone(), stepGoal: current.stepGoal)
            configuration.heartRateSchedule = current.heartRateSchedule
            configuration.selfieMode = current.trigger.enabled
            machine = RingSyncMachine(configuration: configuration, latchedClock: record.latchedClock)
        }
        if writer?.pairingID != record.pairingID {
            writer = RingHealthWriter(store: healthStore, pairingID: record.pairingID, cursor: record.cursor)
        }
    }

    private func enqueue(_ input: RingSyncInput) {
        inbox.append(input)
        pump()
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while !inbox.isEmpty {
            let input = inbox.removeFirst()
            guard machine != nil else {
                if case .measure(let measurement) = input { resolveMeasurement(measurement, .notConnected) }
                continue
            }
            let effects = machine!.handle(input, at: now())
            for effect in effects { apply(effect) }
        }
    }

    private func apply(_ effect: RingSyncEffect) {
        switch effect {
        case .write(let command):
            let bytes = driver.encode(command)
            packetLog.record(bytes, .sent)
            transport.write(bytes)
        case .readBattery:
            transport.readBattery()
        case .startTimer(let timer, let interval):
            machineTimers[timer]?.cancel()
            machineTimers[timer] = scheduler.schedule(after: interval) { [weak self] in
                guard let self else { return }
                self.machineTimers[timer] = nil
                self.enqueue(.timerFired(timer))
            }
        case .cancelTimer(let timer):
            machineTimers.removeValue(forKey: timer)?.cancel()
        case .cancelAllTimers:
            machineTimers.values.forEach { $0.cancel() }
            machineTimers = [:]
        case .report(let report):
            handle(report)
        }
    }

    private func handle(_ report: RingSyncReport) {
        switch report {
        case .syncStarted:
            syncing = true
            periodicSyncWork?.cancel()
            periodicSyncWork = nil

        case .syncFinished(let at):
            syncing = false
            update { $0.lastSync = at }
            PrivacyLog.device(.ring, .ringSynced)
            schedulePeriodicSync()

        case .clockLatched(let clock):
            update { $0.latchedClock = clock }

        case .battery(let percent):
            battery = percent
            if batteryNotice.shouldAnnounce(percent: percent) { announce(RingBatteryNotice.line) }

        case .activity(let steps, let at):
            write([.steps(counter: steps, at: at)])

        case .sleep(let runs):
            write([.sleep(runs)])

        case .storedHistory(let chunks, let complete):
            // Nothing from the stored stream is written until the device pass (Plan MZ risk 7).
            PrivacyLog.device(.ring, .ringStoredHistory, count: chunks, success: complete)

        case .heartRate(let bpm, let at, let during):
            liveReadings.record(beatsPerMinute: bpm, at: at)
            if workoutWantsLive { workoutHeartRates.append(.heartRate(bpm: bpm, at: at)) }
            write([.heartRate(bpm: bpm, at: at)])
            if during == .spotHeartRate { resolveMeasurement(.spotHeartRate, .heartRate(bpm)) }

        case .oxygen(let percent, let at):
            write([.oxygen(percent: percent, at: at)])
            resolveMeasurement(.oxygen, .oxygen(percent))

        case .noReading(let measurement):
            resolveMeasurement(measurement, .noReading)
            PrivacyLog.device(.ring, .ringMeasured, detail: PrivacyToken(measurement.rawValue), success: false)

        case .measurementFinished(let measurement):
            if measurement == .liveHeartRate { liveRunning = false }
            resolveMeasurement(measurement, .noReading)
            startLiveIfWanted(requestedNow: false)

        case .measurementRefused(let measurement):
            if measurement == .liveHeartRate { liveRunning = false }
            resolveMeasurement(measurement, .busy)

        case .measurementInterrupted(let measurement):
            if measurement == .liveHeartRate { liveRunning = false }
            resolveMeasurement(measurement, .interrupted)

        case .stepSkipped(let step):
            PrivacyLog.device(.ring, .ringStepSkipped, state: PrivacyToken(step.rawValue))

        case .commandFinished(let kind):
            resolveCommand(kind, true)

        case .commandFailed(let kind):
            resolveCommand(kind, false)

        case .clench:
            handleClench()

        case .unknownPacket(let opcode):
            packetLog.countUnknown(opcode)
            PrivacyLog.device(.ring, .ringUnknownPacket)

        case .malformedPacket:
            packetLog.countMalformed()
        }
    }

    // MARK: - Health

    private func write(_ readings: [RingReading]) {
        guard let writer else { return }
        let pairingID = writer.pairingID
        Task { @MainActor [weak self] in
            let outcome = await writer.write(readings)
            guard let self, self.pairing?.pairingID == pairingID else { return }
            switch outcome {
            case .written, .nothingToWrite:
                self.lastWriteRefusal = nil
                self.update { $0.cursor = writer.cursor }
            case .refused(let error):
                self.lastWriteRefusal = error
                PrivacyLog.device(.ring, .ringWriteRefused, reason: PrivacyToken(Self.token(error)))
            }
        }
    }

    nonisolated static func token(_ error: RingHealthStoreError) -> String {
        switch error {
        case .protectedDataUnavailable: return "locked"
        case .notAuthorized: return "notAuthorized"
        case .unavailable: return "unavailable"
        }
    }

    private func update(_ change: (inout RingPairingRecord) -> Void) {
        guard var record = pairing else { return }
        change(&record)
        guard record != pairing else { return }
        pairing = record
        pairingStore.save(record)
    }

    // MARK: - Live heart rate and the trigger

    private func startLiveIfWanted(requestedNow: Bool) {
        guard workoutWantsLive, !liveRunning, isConnected, machine != nil,
              RingPowerPolicy.mayStartLiveSession(requestedNow: requestedNow, posture: posture()) else { return }
        liveRunning = true
        enqueue(.measure(.liveHeartRate))
    }

    private func handleClench() {
        let decision = triggerEngine.handleClench(at: now(), setting: settings().trigger,
                                                  activity: triggerActivity())
        switch decision {
        case .fire(let action):
            PrivacyLog.device(.ring, .ringTrigger, state: PrivacyToken("fired"))
            onTriggerAction?(action)
        case .ignored(let reason):
            PrivacyLog.device(.ring, .ringTrigger, state: PrivacyToken("ignored"),
                              reason: PrivacyToken(reason.rawValue))
        }
    }

    // MARK: - Waiters

    private func resolveMeasurement(_ measurement: RingMeasurement, _ outcome: MeasurementOutcome) {
        measurementDeadlines.removeValue(forKey: measurement)?.cancel()
        guard let waiters = measurementWaiters.removeValue(forKey: measurement) else { return }
        if case .heartRate = outcome { PrivacyLog.device(.ring, .ringMeasured, detail: PrivacyToken(measurement.rawValue), success: true) }
        if case .oxygen = outcome { PrivacyLog.device(.ring, .ringMeasured, detail: PrivacyToken(measurement.rawValue), success: true) }
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private func sendCommand(_ input: RingSyncInput, kind: RingCommandKind, deadline: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            commandWaiters[kind, default: []].append(continuation)
            let timeout = scheduler.schedule(after: deadline) { [weak self] in self?.resolveCommand(kind, false) }
            commandDeadlines[kind] = timeout
            enqueue(input)
        }
    }

    private var commandDeadlines: [RingCommandKind: RingScheduledWork] = [:]

    private func resolveCommand(_ kind: RingCommandKind, _ succeeded: Bool) {
        commandDeadlines.removeValue(forKey: kind)?.cancel()
        commandWaiters.removeValue(forKey: kind)?.forEach { $0.resume(returning: succeeded) }
    }

    // MARK: - Link upkeep

    private func connect(_ peripheral: UUID) {
        link = .connecting
        transport.connect(to: peripheral)
    }

    /// The link is gone: the machine resets, its timers go, and anything waiting hears so.
    private func dropLink() {
        if machine != nil { enqueue(.disconnected) }
        machineTimers.values.forEach { $0.cancel() }
        machineTimers = [:]
        periodicSyncWork?.cancel()
        periodicSyncWork = nil
        syncing = false
        liveRunning = false
        for measurement in Array(measurementWaiters.keys) { resolveMeasurement(measurement, .interrupted) }
        for kind in Array(commandWaiters.keys) { resolveCommand(kind, false) }
    }

    private func scheduleReconnect(_ peripheral: UUID) {
        reconnectWork?.cancel()
        let delay = RingReconnectPolicy.delay(afterFailures: reconnectFailures)
        reconnectFailures += 1
        reconnectWork = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.running, self.pairing?.peripheralIdentifier == peripheral else { return }
            self.reconnectWork = nil
            self.connect(peripheral)
        }
    }

    private func schedulePeriodicSync() {
        periodicSyncWork?.cancel()
        guard running, isConnected else { return }
        periodicSyncWork = scheduler.schedule(after: RingPowerPolicy.syncInterval(posture())) { [weak self] in
            self?.periodicSyncWork = nil
            self?.enqueue(.syncNow)
        }
    }

    private func cancelServiceTimers() {
        reconnectWork?.cancel()
        reconnectWork = nil
        periodicSyncWork?.cancel()
        periodicSyncWork = nil
    }

    private func observeTimeZone() {
        guard timeZoneObserver == nil else { return }
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSTimeZone.resetSystemTimeZone()
                self.enqueue(.timeZoneChanged(self.timeZone()))
            }
        }
    }

    // MARK: - Tests

    /// The machine's phase, for tests.
    var machinePhase: RingSyncMachine.Phase? { machine?.phase }
    var reconnectAttempts: Int { reconnectFailures }
    var hasPeriodicSync: Bool { periodicSyncWork != nil }
    func timeZoneDidChangeForTesting() { enqueue(.timeZoneChanged(timeZone())) }
}
