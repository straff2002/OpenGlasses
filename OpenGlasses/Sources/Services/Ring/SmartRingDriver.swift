import Foundation

/// The driver for rings that advertise as `SMART_RING` (Plan MZ, "The ring's protocol").
///
/// The encoder covers every command the app sends. The decoder reads each notification the
/// protocol notes mark CONFIRMED; the PARTIAL ones (the activity summary, the sleep query's
/// summary, the stored-measurement stream) become typed events the app does not act on yet; any
/// other opcode is `.unknown(opcode:)` with nothing else kept. The status reply carries the ring's
/// address and is reduced to an acknowledgement: the address is never read out of it.
struct SmartRingDriver: RingDriver {

    enum Opcode {
        static let timeSync: UInt8 = 0x01
        static let activity: UInt8 = 0x03
        static let findRing: UInt8 = 0x04
        static let clenchEvent: UInt8 = 0x06
        static let selfieMode: UInt8 = 0x07
        static let battery: UInt8 = 0x0b
        static let status: UInt8 = 0x0c
        static let sleepQuery: UInt8 = 0x10
        static let sleepTimeline: UInt8 = 0x11
        static let activitySummary: UInt8 = 0x13
        static let liveHeartRate: UInt8 = 0x14
        static let liveHeartRateStop: UInt8 = 0x15
        static let storedHistory: UInt8 = 0x16
        static let heartRateSchedule: UInt8 = 0x19
        static let stepGoal: UInt8 = 0x1a
        static let locale: UInt8 = 0x21
        static let oxygen: UInt8 = 0x23
        static let oxygenReading: UInt8 = 0x24
        static let liveHeartRateEnded: UInt8 = 0x27
        static let oxygenEnded: UInt8 = 0x28
    }

    /// The second byte of a live heart-rate start.
    static let liveHeartRateStartMode: UInt8 = 0xb4
    /// The second byte of a find-ring command (the notes' observed value; probably a duration).
    static let findRingDuration: UInt8 = 0x0a
    /// The schedule's byte 7, as observed (Plan MZ risk 3).
    static let scheduleMode: UInt8 = 0x02
    /// The cadence byte sent with the schedule switched off, as observed.
    static let scheduleOffCadence: UInt8 = 30

    // MARK: - Identity

    let advertisedNames: Set<String> = ["SMART_RING"]
    let advertisedService = "FEF5"
    let manufacturerID: UInt16? = 0x594A
    let gatt = RingGATTRoles(service: "56FF", write: "33F3", writeWithResponse: true, notify: "33F4",
                             batteryService: "180F", batteryLevel: "2A19")
    let capabilities = Set(RingCapability.allCases)

    // MARK: - Encoding

    func encode(_ command: RingCommand) -> [UInt8] {
        packet(for: command).bytes
    }

    func packet(for command: RingCommand) -> SmartRingPacket {
        switch command {
        case .status:
            return SmartRingPacket(opcode: Opcode.status)
        case .timeSync(let sync):
            return SmartRingPacket(opcode: Opcode.timeSync,
                                   payload: SmartRingPacket.littleEndian(sync.ringSeconds)
                                       + [UInt8(bitPattern: sync.wholeHourOffset)])
        case .locale(let identifier):
            let ascii = identifier.unicodeScalars.filter(\.isASCII).map { UInt8($0.value) }
            return SmartRingPacket(opcode: Opcode.locale, payload: Array(ascii.prefix(SmartRingPacket.length - 1)))
        case .heartRateSchedule(let schedule):
            // All day, 00:00 → 23:59; then on/off, cadence in minutes, the observed mode byte.
            let enabled: UInt8, cadence: UInt8
            switch schedule {
            case .off: enabled = 0; cadence = Self.scheduleOffCadence
            case .every(let minutes): enabled = 1; cadence = UInt8(clamping: max(1, minutes))
            }
            return SmartRingPacket(opcode: Opcode.heartRateSchedule,
                                   payload: [0x00, 0x00, 0x17, 0x3b, enabled, cadence, Self.scheduleMode])
        case .stepGoal(let goal):
            return SmartRingPacket(opcode: Opcode.stepGoal,
                                   payload: SmartRingPacket.littleEndian(UInt32(clamping: max(0, goal))))
        case .sleepHistoryQuery:
            return SmartRingPacket(opcode: Opcode.sleepQuery)
        case .storedHistoryQuery:
            return SmartRingPacket(opcode: Opcode.storedHistory)
        case .liveHeartRateStart:
            return SmartRingPacket(opcode: Opcode.liveHeartRate, payload: [Self.liveHeartRateStartMode])
        case .liveHeartRateStop:
            return SmartRingPacket(opcode: Opcode.liveHeartRateStop)
        case .oxygenStart:
            return SmartRingPacket(opcode: Opcode.oxygen, payload: [0x01])
        case .oxygenStop:
            return SmartRingPacket(opcode: Opcode.oxygen, payload: [0x00])
        case .findRing:
            return SmartRingPacket(opcode: Opcode.findRing, payload: [Self.findRingDuration])
        case .selfieMode(let on):
            return SmartRingPacket(opcode: Opcode.selfieMode, payload: [on ? 0x01 : 0x00])
        }
    }

    // MARK: - Decoding

    func decode(_ bytes: [UInt8]) -> [RingEvent] {
        guard let packet = SmartRingPacket(bytes: bytes) else { return [.malformed(length: bytes.count)] }
        return decode(packet)
    }

    func decode(_ packet: SmartRingPacket) -> [RingEvent] {
        let opcode = packet.opcode
        switch opcode {
        case Opcode.timeSync: return [.acknowledged(.timeSync)]
        case Opcode.locale: return [.acknowledged(.locale)]
        case Opcode.status: return [.acknowledged(.status)]
        case Opcode.stepGoal: return [.acknowledged(.stepGoal)]
        case Opcode.heartRateSchedule: return [.acknowledged(.heartRateSchedule)]
        case Opcode.findRing: return [.acknowledged(.findRing)]
        case Opcode.liveHeartRateStop: return [.acknowledged(.liveHeartRateStop)]
        case Opcode.liveHeartRateEnded: return [.liveHeartRateEnded]
        case Opcode.oxygenEnded: return [.oxygenEnded]

        case Opcode.activity:
            return [.activity(RingActivityReading(ringSeconds: packet.uint32(at: 1),
                                                  steps: Int(packet.uint32(at: 5)),
                                                  distanceUnits: Int(packet.uint32(at: 9)),
                                                  calories: Int(packet.uint32(at: 13))))]

        case Opcode.activitySummary:
            return [.activitySummary(RingActivitySummary(ringSeconds: packet.uint32(at: 1),
                                                         fieldA: Int(packet.uint32(at: 5)),
                                                         fieldB: Int(packet.uint32(at: 9)),
                                                         stepLike: Int(packet.uint32(at: 13))))]

        case Opcode.battery:
            let percent = Int(packet[1])
            return percent <= 100 ? [.battery(percent: percent)] : [.unknown(opcode: opcode)]

        case Opcode.liveHeartRate:
            // The start command echoed back, or a reading: bytes 1–4 change with each reading and
            // the beats per minute are at byte 5.
            if packet[1] == Self.liveHeartRateStartMode && packet.isZero(from: 2) {
                return [.acknowledged(.liveHeartRateStart)]
            }
            return [.heartRate(bpm: Int(packet[5]))]

        case Opcode.oxygen:
            if packet.isZero(from: 2) {
                switch packet[1] {
                case 0x01: return [.acknowledged(.oxygenStart)]
                case 0x00: return [.acknowledged(.oxygenStop)]
                default: break
                }
            }
            return [.unknown(opcode: opcode)]

        case Opcode.oxygenReading:
            // Progress is all zeros; a result carries the percentage at byte 4.
            let percent = Int(packet[4])
            return percent == 0 ? [.oxygenProgress] : [.oxygenResult(percent: percent)]

        case Opcode.sleepQuery:
            return packet.isZero(from: 1)
                ? [.acknowledged(.sleepHistoryQuery)]
                : [.acknowledged(.sleepHistoryQuery), .sleepHistorySummary]

        case Opcode.sleepTimeline:
            let minutes = (5..<SmartRingPacket.length).map { Self.sleepMinute(packet[$0]) }
            return [.sleep(RingSleepPacket(ringSeconds: packet.uint32(at: 1), minutes: minutes))]

        case Opcode.storedHistory:
            switch packet[1] {
            case 0x00 where packet.isZero(from: 2): return [.acknowledged(.storedHistoryQuery)]
            case 0xf0: return [.storedHistoryHeader]
            case 0xaa: return [.storedHistoryMetadata]
            case 0xa0: return [.storedHistoryChunk]
            case 0xff: return [.storedHistoryEnd]
            default: return [.unknown(opcode: opcode)]
            }

        case Opcode.selfieMode:
            if packet.isZero(from: 2) {
                switch packet[1] {
                case 0x01: return [.acknowledged(.selfieModeOn)]
                case 0x00: return [.acknowledged(.selfieModeOff)]
                default: break
                }
            }
            return [.unknown(opcode: opcode)]

        case Opcode.clenchEvent:
            return packet[1] == 0x02 ? [.clench] : [.unknown(opcode: opcode)]

        default:
            return [.unknown(opcode: opcode)]
        }
    }

    static func sleepMinute(_ value: UInt8) -> RingSleepMinute {
        switch value {
        case 0x28: return .light
        case 0x63: return .deep
        case 0x00: return .none
        default: return .unrecognised
        }
    }
}
