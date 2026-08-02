import Foundation

/// Confirmed-played playback accounting for barge-in truncation (Plan CJ item 6).
///
/// When the user interrupts the assistant, the truncation point reported to a realtime API must
/// come from PCM the hardware *actually rendered* — wall-clock estimates over-report what the
/// user heard (deltas arrive far faster than they play) and desync the server transcript. This
/// ledger counts frames as scheduled and as confirmed played (player-node completion callbacks),
/// and a generation counter invalidates the callbacks that `AVAudioPlayerNode.stop()` fires for
/// buffers it *discards* — those were never heard and must not count.
///
/// Pure value type; the engine confines it to its audio-lifecycle queue.
struct PlaybackProgressLedger: Equatable {

    private(set) var scheduledFrames: UInt64 = 0
    private(set) var playedFrames: UInt64 = 0
    /// Bumped on every reset; completion callbacks carry the generation they were scheduled
    /// under, and stale ones are ignored.
    private(set) var generation: UInt64 = 0

    /// Record a buffer handed to the player. Returns the generation the caller should capture
    /// into the buffer's completion callback.
    @discardableResult
    mutating func scheduled(frames: UInt32) -> UInt64 {
        scheduledFrames &+= UInt64(frames)
        return generation
    }

    /// Record a completion callback. Counts only if `generation` is still current (a stop/reset
    /// in between means the buffer was discarded, not heard), and never beyond what was scheduled.
    mutating func played(frames: UInt32, generation callbackGeneration: UInt64) {
        guard callbackGeneration == generation else { return }
        playedFrames = min(playedFrames &+ UInt64(frames), scheduledFrames)
    }

    /// Start a fresh accounting window (new response, or playback stopped). Invalidates all
    /// outstanding callbacks.
    mutating func reset() {
        scheduledFrames = 0
        playedFrames = 0
        generation &+= 1
    }

    /// Confirmed-played duration at `sampleRate`, in whole milliseconds. Conservative by
    /// construction: the partially-played final buffer isn't counted until its callback lands,
    /// so this can under-report by at most one chunk — the safe direction for truncation.
    func playedMilliseconds(sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int(Double(playedFrames) * 1000.0 / sampleRate)
    }
}
