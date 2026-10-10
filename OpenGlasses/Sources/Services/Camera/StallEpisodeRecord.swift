import Foundation

/// Plan HW P1 — what happened in one link stall, from the verdict to its end (pure).
///
/// Field work elsewhere saw short stalls resume by themselves. Our detector calls a stall after
/// 1.5 s without a sample and rebuilds the stream at once, and a rebuild costs a cold start.
/// Whether waiting a moment first would be better for us is not known, and the detector must not
/// be changed on a hunch. So this only watches: it changes nothing the detector does, and it
/// writes **one line per episode** that the device session can count.
///
/// The question it is built around is `sampleBeforeTeardown`: after the stall was called, did
/// anything arrive from the old stream before the rebuild tore it down? A yes is a stall that
/// was already healing when we cut it short. The existing `stallSelfRecovered` line covers
/// frames returning during a *later* attempt's backoff wait; the first rebuild of an episode
/// has no wait, so its only window is the teardown itself, and nothing recorded that until now.
struct StallEpisodeRecord: Equatable {

    enum Ending: String, Equatable {
        /// The stream was rebuilt and a fresh picture arrived.
        case recovered
        /// The stream was rebuilt, reached streaming, and delivered no fresh picture in time.
        case noPicture
        /// The rebuild itself failed.
        case rebuildFailed
        /// Frames came back during a backoff wait, so nothing was rebuilt.
        case selfRecovered
        /// Recovery had run out of attempts and stopped the camera instead.
        case gaveUp
        /// The wait was cancelled, or nobody wanted the stream any more when it ended.
        case cancelled
        /// The episode closed without any of the above being noted. Not expected; it is a case
        /// so that a path nobody thought of shows up in the log as itself.
        case unfinished
    }

    /// The one line an episode produces.
    struct Line: Equatable {
        let ending: Ending
        /// Which rebuild was used. Nil when nothing was rebuilt.
        let tier: StreamRecoveryPolicy.Action?
        /// Seconds without a sample when the stall was called: since the last one, or since the
        /// stream (re)started when it had not delivered any.
        let silenceAtVerdict: TimeInterval
        /// Samples that arrived after the verdict, from the stream that was stalled: up to the
        /// end of its teardown when it was rebuilt, up to the end of the episode when it was not.
        let samplesAfterVerdict: Int
        /// From the end of the teardown to the first fresh picture of the rebuilt stream. Nil
        /// when none came. Read by the same poll that decides the recovery worked, so it is
        /// good to a fifth of a second.
        let secondsToPicture: TimeInterval?

        /// Whether the old stream showed any life between the verdict and its teardown.
        var sampleBeforeTeardown: Bool { tier != nil && samplesAfterVerdict > 0 }
    }

    private let silenceAtVerdict: TimeInterval
    private let samplesAtVerdict: Int
    private var ending: Ending = .unfinished
    private var tier: StreamRecoveryPolicy.Action?
    private var samplesAfterVerdict = 0
    private var teardownEndedAt: Date?
    private var secondsToPicture: TimeInterval?
    private var closed = false

    /// Opened at a `.linkStalled` verdict. `samplesSeen` is the frame pipeline's lifetime count
    /// at that moment; later readings are subtracted from it.
    init(silenceAtVerdict: TimeInterval, samplesSeen: Int) {
        self.silenceAtVerdict = silenceAtVerdict
        self.samplesAtVerdict = samplesSeen
    }

    /// The episode ended with the stream left as it was: frames came back by themselves,
    /// recovery gave up, or the wait was cancelled.
    mutating func endedWithoutRebuild(_ ending: Ending, samplesSeen: Int) {
        self.ending = ending
        samplesAfterVerdict = max(0, samplesSeen - samplesAtVerdict)
    }

    /// The old stream is gone. Only it could have delivered anything up to here, because the
    /// one that replaces it has not been created yet.
    mutating func teardownFinished(tier: StreamRecoveryPolicy.Action, samplesSeen: Int,
                                   at now: Date) {
        self.tier = tier
        samplesAfterVerdict = max(0, samplesSeen - samplesAtVerdict)
        teardownEndedAt = now
    }

    /// The rebuilt stream reached streaming, and either showed a fresh picture or did not.
    mutating func rebuildFinished(freshPicture: Bool, at now: Date) {
        ending = freshPicture ? .recovered : .noPicture
        if freshPicture, let teardownEndedAt {
            secondsToPicture = max(0, now.timeIntervalSince(teardownEndedAt))
        }
    }

    mutating func rebuildFailed() {
        ending = .rebuildFailed
    }

    /// The line for this episode, once. A second call returns nil, which is what makes "one
    /// line per episode" a property of the record rather than of whoever calls it.
    mutating func close() -> Line? {
        guard !closed else { return nil }
        closed = true
        return Line(ending: ending, tier: tier, silenceAtVerdict: silenceAtVerdict,
                    samplesAfterVerdict: samplesAfterVerdict, secondsToPicture: secondsToPicture)
    }
}

extension StallEpisodeRecord.Line {

    /// The line as it is logged. Words from a closed set and numbers; nothing about the device.
    @discardableResult
    func log() -> PrivacyEvent {
        PrivacyLog.camera(.glasses, .stallEpisode,
                          state: PrivacyToken(ending.rawValue),
                          detail: tier.flatMap { PrivacyToken.caseName(of: $0) },
                          count: samplesAfterVerdict,
                          silence: silenceAtVerdict,
                          seconds: secondsToPicture)
    }
}
