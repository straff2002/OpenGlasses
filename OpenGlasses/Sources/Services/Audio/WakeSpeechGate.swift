import Foundation

/// Plan GU §5 — a cheap speech score for one buffer: energy over an adaptive noise floor, inside a
/// zero-crossing band.
///
/// Energy alone opens on any loud sound; the zero-crossing band rejects the two commonest
/// non-speech shapes — low rumble (traffic, handling) crosses zero far too rarely, broadband hiss
/// far too often. The noise floor follows down fast (a quiet moment is believed at once) and up
/// slowly (a voice must not become the floor within a sentence). Arithmetic only — runs on the
/// render thread with no allocation.
///
/// The score is shaped for `SpeechActivityGate.Configuration.wakeIdle`: `releaseOverFloorDB` maps
/// to the gate's release score and `onsetOverFloorDB` to its onset score, so the gate's hysteresis
/// is exactly the dB hysteresis named here.
struct EnergySpeechScorer {

    /// All provisional — tuned in P2 against missed wakes.
    struct Thresholds: Equatable {
        /// Quieter than this is never speech, whatever the floor says.
        var absoluteFloorDBFS: Float = -55
        /// Onset: this far over the noise floor.
        var onsetOverFloorDB: Float = 10
        /// Release: back under this far over the floor.
        var releaseOverFloorDB: Float = 6
        /// Zero crossings per second a voice produces.
        var zeroCrossingBand: ClosedRange<Float> = 150...5_000
        /// How fast the floor rises (time constant, seconds) and falls.
        var floorRiseSeconds: Double = 4.0
        var floorFallSeconds: Double = 0.1

        static let standard = Thresholds()
        /// `PowerPosture.prefersStrictWakeGate`: a higher onset, so less noise wakes the recognizer.
        static let strict = Thresholds(onsetOverFloorDB: 13, releaseOverFloorDB: 7)
    }

    let thresholds: Thresholds
    let gateConfiguration: SpeechActivityGate.Configuration

    /// The tracked noise floor, dBFS. Nil until the first buffer, which seeds it — a room that is
    /// already noisy when listening starts is the floor, not speech.
    private(set) var noiseFloorDB: Float?

    init(thresholds: Thresholds = .standard,
         gateConfiguration: SpeechActivityGate.Configuration = .wakeIdle) {
        self.thresholds = thresholds
        self.gateConfiguration = gateConfiguration
    }

    mutating func reset() { noiseFloorDB = nil }

    /// Score one buffer of mono samples, 0…1.
    mutating func score(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Float {
        let count = samples.count
        guard count > 0, sampleRate > 0 else { return 0 }
        var sum: Float = 0
        var crossings = 0
        var previous = samples[0]
        for i in 0..<count {
            let s = samples[i]
            sum += s * s
            if (s >= 0) != (previous >= 0) { crossings += 1 }
            previous = s
        }
        let rms = (sum / Float(count)).squareRoot()
        let levelDB = rms > 0 ? 20 * log10f(rms) : -160
        let duration = Double(count) / sampleRate
        let crossingsPerSecond = Float(Double(crossings) / duration)

        let floor = trackFloor(levelDB: levelDB, duration: duration)
        guard levelDB >= thresholds.absoluteFloorDBFS else { return 0 }
        guard thresholds.zeroCrossingBand.contains(crossingsPerSecond) else { return 0 }
        return Self.mapExcess(levelDB - max(floor, thresholds.absoluteFloorDBFS - thresholds.onsetOverFloorDB),
                              thresholds: thresholds, gate: gateConfiguration)
    }

    mutating func score(_ samples: [Float], sampleRate: Double) -> Float {
        samples.withUnsafeBufferPointer { score($0, sampleRate: sampleRate) }
    }

    /// Follow the floor: down fast, up slowly. Returns the floor *before* this buffer joined it, so
    /// a sudden onset is measured against the room it interrupted.
    private mutating func trackFloor(levelDB: Float, duration: Double) -> Float {
        guard let floor = noiseFloorDB else {
            noiseFloorDB = levelDB
            return levelDB
        }
        let tau = levelDB < floor ? thresholds.floorFallSeconds : thresholds.floorRiseSeconds
        let alpha = Float(1 - exp(-duration / tau))
        noiseFloorDB = floor + (levelDB - floor) * alpha
        return floor
    }

    /// dB over the floor → score: 0 at the floor, the gate's release score at `releaseOverFloorDB`,
    /// its onset score at `onsetOverFloorDB`, and on towards 1.
    static func mapExcess(_ excess: Float, thresholds: Thresholds,
                          gate: SpeechActivityGate.Configuration) -> Float {
        guard excess > 0 else { return 0 }
        let r = thresholds.releaseOverFloorDB, o = thresholds.onsetOverFloorDB
        let score: Float
        if excess <= r {
            score = excess / r * gate.releaseThreshold
        } else {
            let slope = (gate.onsetThreshold - gate.releaseThreshold) / (o - r)
            score = gate.releaseThreshold + (excess - r) * slope
        }
        return min(score, 1)
    }
}

/// Plan GU §5 — when the idle wake-word recognizer runs. The engine and its tap keep running while
/// the gate is closed; only the recognition task waits for speech.
///
/// - Speech starts → open the recognizer (the service replays the pre-roll into it first).
/// - Speech ends → keep it `recognitionTail` longer for the final partial, then close — unless a
///   wake phrase matched, in which case the turn owns what happens next.
/// - Open longer than `maxOpenSeconds` (a conversation nearby) → give up gating until reset, which
///   is today's continuous restart-on-final.
///
/// Pure: scores and times in, outputs out.
struct WakeSpeechGate {
    static let preRollSeconds: TimeInterval = 1.0
    static let recognitionTail: TimeInterval = 1.5
    static let strictRecognitionTail: TimeInterval = 1.0
    static let maxOpenSeconds: TimeInterval = 60

    enum Output: Equatable {
        case open(at: Date)
        case close
        case giveUpGating
    }

    private var gate: SpeechActivityGate
    private(set) var recognizerOpen = false
    private(set) var gatingAbandoned = false
    private var openedAt: Date?
    private var closeAt: Date?
    private var wakeMatched = false
    let tail: TimeInterval

    init(strict: Bool = false) {
        gate = SpeechActivityGate(configuration: .wakeIdle)
        tail = strict ? Self.strictRecognitionTail : Self.recognitionTail
    }

    /// Feed one hop's score.
    mutating func observe(score: Float, at now: Date) -> Output? {
        guard !gatingAbandoned else { return nil }
        let event = gate.observe(score: score, at: now)
        switch event {
        case .speechStarted(let at)?:
            closeAt = nil
            if !recognizerOpen {
                recognizerOpen = true
                openedAt = now
                wakeMatched = false
                return .open(at: at)
            }
        case .speechEnded?:
            if recognizerOpen { closeAt = now.addingTimeInterval(tail) }
        case nil:
            break
        }
        guard recognizerOpen else { return nil }
        if let openedAt, now.timeIntervalSince(openedAt) > Self.maxOpenSeconds {
            gatingAbandoned = true
            return .giveUpGating
        }
        if let closeAt, now >= closeAt, !gate.isSpeaking, !wakeMatched {
            recognizerOpen = false
            self.closeAt = nil
            openedAt = nil
            return .close
        }
        return nil
    }

    /// A wake phrase matched while open: the turn takes over; never close under it.
    mutating func noteWakeMatched() { wakeMatched = true }

    /// Listening restarted or the route changed — no state survives.
    mutating func reset() {
        gate.reset()
        recognizerOpen = false
        gatingAbandoned = false
        openedAt = nil
        closeAt = nil
        wakeMatched = false
    }
}
