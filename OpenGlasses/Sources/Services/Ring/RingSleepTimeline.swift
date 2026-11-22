import Foundation

/// A stretch of sleep at one stage, in the app's own `SleepStage`.
struct RingSleepRun: Equatable, Sendable {
    let start: Date
    let end: Date
    let stage: SleepStage

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Turns the ring's sleep packets into runs (Plan MZ §1).
///
/// Each packet is fifteen one-minute samples from its timestamp. Light sleep is `.asleepCore` and
/// deep sleep `.asleepDeep`. A minute with no data, or a value nobody has decoded, is a gap: it is
/// never guessed to be awake. Packets may arrive in any order and a minute seen twice counts once.
/// Consecutive minutes at the same stage are merged into one run, so a night is a handful of
/// samples rather than hundreds.
enum RingSleepTimeline {

    static let minute: UInt32 = 60

    static func runs(from packets: [RingSleepPacket], clock: RingClock) -> [RingSleepRun] {
        // Ring minute → stage, the first packet to name a minute winning (they agree in practice).
        var stages: [UInt32: SleepStage] = [:]
        for packet in packets {
            for (index, sample) in packet.minutes.enumerated() {
                guard let stage = Self.stage(for: sample) else { continue }
                let (at, overflow) = packet.ringSeconds.addingReportingOverflow(UInt32(index) * minute)
                // A timestamp at the very end of the counter's range is garbage, not a night.
                guard !overflow, at <= UInt32.max - minute, stages[at] == nil else { continue }
                stages[at] = stage
            }
        }

        var runs: [(start: UInt32, end: UInt32, stage: SleepStage)] = []
        for at in stages.keys.sorted() {
            let stage = stages[at]!
            if let last = runs.last, last.end == at, last.stage == stage {
                runs[runs.count - 1].end = at + minute
            } else {
                runs.append((at, at + minute, stage))
            }
        }
        return runs.map {
            RingSleepRun(start: clock.date(fromRingSeconds: $0.start),
                         end: clock.date(fromRingSeconds: $0.end), stage: $0.stage)
        }
    }

    static func stage(for minute: RingSleepMinute) -> SleepStage? {
        switch minute {
        case .light: return .asleepCore
        case .deep: return .asleepDeep
        case .none, .unrecognised: return nil
        }
    }
}
