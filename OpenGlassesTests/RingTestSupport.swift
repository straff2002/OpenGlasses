import Foundation
@testable import OpenGlasses

/// Shared fixtures for the ring tests (Plan MZ). Packets are the protocol notes' published examples
/// or invented ones; anything that carries an address uses the invented `01 02 03 04 05 06`.
enum RingFixture {

    /// Bytes from a hex string; spaces are ignored.
    static func hex(_ string: String) -> [UInt8] {
        let digits = Array(string.replacingOccurrences(of: " ", with: ""))
        precondition(digits.count % 2 == 0, "odd hex string")
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
    }

    /// A 20-byte packet: the given leading bytes, then zero padding.
    static func packet(_ leading: String) -> [UInt8] {
        let bytes = hex(leading)
        return bytes + Array(repeating: 0, count: 20 - bytes.count)
    }

    /// A sleep packet at `ringSeconds`: fifteen minutes of one value, or the values given.
    static func sleepPacket(at ringSeconds: UInt32, _ values: [UInt8]) -> [UInt8] {
        precondition(values.count == 15)
        return [0x11] + SmartRingPacket.littleEndian(ringSeconds) + values
    }

    static func sleepPacket(at ringSeconds: UInt32, all value: UInt8) -> [UInt8] {
        sleepPacket(at: ringSeconds, Array(repeating: value, count: 15))
    }

    static let light: UInt8 = 0x28
    static let deep: UInt8 = 0x63

    /// The protocol's sleep examples: 01:30 light and 02:15 deep (ring local seconds).
    static let sleepLight0130: UInt32 = 0x6a17_9a98
    static let sleepDeep0215: UInt32 = 0x6a17_a524

    /// A status reply carrying the invented address at bytes 3–8.
    static let statusReply = packet("0c7a00 010203040506 3a001600")

    /// The protocol's activity example: 328 steps, 287 distance units, 18 calories.
    static let activityExample = hex("03fd7c156a480100001f01000012000000504600")

    /// Every command the app sends, one of each.
    static let allCommands: [RingCommand] = [
        .status,
        .timeSync(RingTimeSync(ringSeconds: 0x6a15_dc9e, offsetSeconds: -4 * 3600)),
        .locale("en-US"),
        .heartRateSchedule(.off),
        .heartRateSchedule(.every(minutes: 30)),
        .heartRateSchedule(.every(minutes: 10)),
        .stepGoal(10_000),
        .sleepHistoryQuery,
        .storedHistoryQuery,
        .liveHeartRateStart,
        .liveHeartRateStop,
        .oxygenStart,
        .oxygenStop,
        .findRing,
        .selfieMode(on: true),
        .selfieMode(on: false),
    ]
}

/// Plays the ring for `RingSyncMachine`: it records what the machine writes, echoes each write as
/// the ring does (unless told to stay silent for an opcode), answers battery reads, replays the
/// packets a query is answered with, and runs the machine's timers on a fake clock.
final class MockRingTransport {

    let driver = SmartRingDriver()
    var machine: RingSyncMachine
    private(set) var now: Date

    /// Opcodes the "ring" does not echo.
    var silentOpcodes: Set<UInt8> = []
    /// What a battery read returns; nil means the read fails. `answersBattery` false: no answer.
    var batteryLevel: Int? = 80
    var answersBattery = true
    /// Notifications sent straight after the echo of a write with this opcode.
    var responses: [UInt8: [[UInt8]]] = [:]

    private(set) var written: [[UInt8]] = []
    private(set) var reports: [RingSyncReport] = []
    private(set) var batteryReads = 0
    private(set) var cancelledAll = 0
    private var timers: [RingTimer: Date] = [:]
    private var inbox: [RingSyncInput] = []
    private var pumping = false

    init(configuration: RingSyncMachine.Configuration, latchedClock: RingClock? = nil, now: Date) {
        machine = RingSyncMachine(configuration: configuration, latchedClock: latchedClock)
        self.now = now
    }

    var writtenOpcodes: [UInt8] { written.map { $0[0] } }
    var pendingTimers: [RingTimer.Kind] { timers.keys.map(\.kind) }

    /// The link comes up; `burst` is what the ring sends as soon as notifications are on, before
    /// it answers the first write.
    func connect(burst: [[UInt8]] = []) {
        inbox.append(.linkReady)
        for packet in burst {
            for event in driver.decode(packet) { inbox.append(.event(event)) }
        }
        pump()
    }

    func send(_ input: RingSyncInput) {
        inbox.append(input)
        pump()
    }

    /// The ring sends a notification.
    func notify(_ bytes: [UInt8]) {
        for event in driver.decode(bytes) { inbox.append(.event(event)) }
        pump()
    }

    /// Let time pass, firing every timer that falls due, in order.
    func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        while let next = timers.min(by: { $0.value < $1.value }), next.value <= target {
            timers[next.key] = nil
            now = next.value
            send(.timerFired(next.key))
        }
        now = target
    }

    /// Fire timers until none is left within `limit` seconds of now.
    func settle(limit: TimeInterval = 600) {
        let end = now.addingTimeInterval(limit)
        while let next = timers.min(by: { $0.value < $1.value }), next.value <= end {
            timers[next.key] = nil
            now = next.value
            send(.timerFired(next.key))
        }
    }

    func clearRecords() {
        written = []
        reports = []
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while !inbox.isEmpty {
            let input = inbox.removeFirst()
            for effect in machine.handle(input, at: now) { apply(effect) }
        }
    }

    private func apply(_ effect: RingSyncEffect) {
        switch effect {
        case .write(let command):
            let bytes = driver.encode(command)
            written.append(bytes)
            guard !silentOpcodes.contains(bytes[0]) else { return }
            for event in driver.decode(bytes) { inbox.append(.event(event)) }
            for response in responses[bytes[0]] ?? [] {
                for event in driver.decode(response) { inbox.append(.event(event)) }
            }
        case .readBattery:
            batteryReads += 1
            if answersBattery { inbox.append(.batteryRead(percent: batteryLevel)) }
        case .startTimer(let timer, let interval):
            timers[timer] = now.addingTimeInterval(interval)
        case .cancelTimer(let timer):
            timers[timer] = nil
        case .cancelAllTimers:
            cancelledAll += 1
            timers = [:]
        case .report(let report):
            reports.append(report)
        }
    }
}

/// Plays the ring over the `RingTransporting` seam for `RingService`: it records what is written,
/// echoes each write as the ring does (unless told to stay silent for an opcode), replays the
/// packets a write is answered with, answers battery reads and comes up as soon as it is asked to
/// connect, unless `connectsImmediately` is off.
@MainActor
final class FakeRingTransport: RingTransporting {

    var onEvent: ((RingTransportEvent) -> Void)?
    let driver = SmartRingDriver()

    var silentOpcodes: Set<UInt8> = []
    var responses: [UInt8: [[UInt8]]] = [:]
    var batteryLevel: Int? = 80
    var connectsImmediately = true

    private(set) var written: [[UInt8]] = []
    private(set) var connects: [UUID] = []
    private(set) var disconnects = 0
    private(set) var scans = 0
    private(set) var batteryReads = 0

    var writtenOpcodes: [UInt8] { written.map { $0[0] } }

    func startScan() { scans += 1 }
    func stopScan() {}

    func connect(to peripheral: UUID) {
        connects.append(peripheral)
        if connectsImmediately { onEvent?(.ready) }
    }

    func disconnect() { disconnects += 1 }

    func write(_ bytes: [UInt8]) {
        written.append(bytes)
        guard !silentOpcodes.contains(bytes[0]) else { return }
        onEvent?(.notification(bytes))
        for response in responses[bytes[0]] ?? [] { onEvent?(.notification(response)) }
    }

    func readBattery() {
        batteryReads += 1
        onEvent?(.battery(batteryLevel))
    }

    /// The ring sends a notification on its own.
    func notify(_ bytes: [UInt8]) { onEvent?(.notification(bytes)) }
    /// The link drops.
    func drop() { onEvent?(.disconnected) }
    func found(_ candidate: RingCandidate) { onEvent?(.discovered(candidate)) }
    func radio(_ state: RingRadioState) { onEvent?(.radio(state)) }

    func clearWritten() { written = [] }
}

/// A clock and a scheduler in one: work runs only when the test lets time pass.
@MainActor
final class ManualRingScheduler: RingScheduling {

    final class Work: RingScheduledWork {
        let due: Date
        let interval: TimeInterval
        let run: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(due: Date, interval: TimeInterval, run: @escaping @MainActor () -> Void) {
            self.due = due
            self.interval = interval
            self.run = run
        }
        func cancel() { cancelled = true }
    }

    private(set) var now: Date
    private(set) var items: [Work] = []

    init(now: Date) {
        self.now = now
    }

    func schedule(after interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> RingScheduledWork {
        let item = Work(due: now.addingTimeInterval(interval), interval: interval, run: work)
        items.append(item)
        return item
    }

    var pending: [Work] { items.filter { !$0.cancelled && !$0.fired } }

    /// Let time pass, running every piece of work that falls due, in order.
    func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        while let next = pending.min(by: { $0.due < $1.due }), next.due <= target {
            next.fired = true
            now = max(now, next.due)
            next.run()
        }
        now = target
    }
}

/// The pairing record in memory.
@MainActor
final class MemoryRingPairingStore: RingPairingStoring {
    var record: RingPairingRecord?
    private(set) var saves = 0
    func load() -> RingPairingRecord? { record }
    func save(_ record: RingPairingRecord) { self.record = record; saves += 1 }
    func clear() { record = nil }
}

/// A `RingService` over the fakes, with the settings and power posture a test chooses.
@MainActor
final class RingServiceRig {
    let transport = FakeRingTransport()
    let health = FakeRingHealthStore()
    let pairingStore = MemoryRingPairingStore()
    let scheduler: ManualRingScheduler
    var settings: RingService.Settings
    var posture: PowerPosture = .normal
    var noticeShown = false
    var announced: [String] = []
    var triggered: [TempleAction] = []
    var activity: TempleContext.Activity = .standby
    private(set) var service: RingService!

    static let start = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18
    static let ringID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    init(settings: RingService.Settings = RingService.Settings(heartRateSchedule: .recommended,
                                                               trigger: .recommended, stepGoal: nil),
         paired: Bool = false) {
        scheduler = ManualRingScheduler(now: Self.start)
        self.settings = settings
        if paired {
            pairingStore.record = RingPairingRecord(pairingID: RingPairingID(rawValue: "pairing-test"),
                                                    peripheralIdentifier: Self.ringID, pairedAt: Self.start)
        }
        let scheduler = self.scheduler
        service = RingService(
            transport: transport, healthStore: health, pairingStore: pairingStore, scheduler: scheduler,
            now: { scheduler.now },
            timeZone: { TimeZone(secondsFromGMT: 0)! },
            settings: { [unowned self] in self.settings },
            posture: { [unowned self] in self.posture },
            noticeShown: { [unowned self] in self.noticeShown },
            setNoticeShown: { [unowned self] in self.noticeShown = $0 })
        service.announce = { [unowned self] in self.announced.append($0) }
        service.onTriggerAction = { [unowned self] in self.triggered.append($0) }
        service.triggerActivity = { [unowned self] in self.activity }
    }

    /// Let Health writes, which run as tasks, finish.
    func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }
}
