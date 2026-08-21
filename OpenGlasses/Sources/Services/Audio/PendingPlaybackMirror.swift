import Foundation

/// A mirror of what has been scheduled onto the player node and not yet confirmed played
/// (Plan CW P2).
///
/// `AVAudioPlayerNode.scheduleBuffer` is fire-and-forget: once a buffer is handed over we cannot
/// ask the node what it still holds, and `stop()` + `detach` destroy the queue without telling
/// anyone. So a graph rebuild silently deleted whatever the wearer had not heard yet — most often
/// the **first reply of a session**, since the route settles while it is still queued.
///
/// This keeps our own copy so a rebuild can re-schedule the survivors, and — when they cannot be
/// carried — can say exactly how much was lost instead of dropping it into silence.
///
/// Entries hold the source Int16 PCM rather than an `AVAudioPCMBuffer`, which is what keeps the
/// type pure and testable without an engine: the re-schedule re-runs the same conversion the
/// original schedule did.
///
/// Confined to the engine's audio-lifecycle queue, like `PlaybackProgressLedger`, whose generation
/// counter it shares — the two are updated at the same three points (scheduled / played / reset).
struct PendingPlaybackMirror: Equatable {

    struct Entry: Equatable {
        let generation: UInt64
        let frames: UInt32
        let pcm: Data
    }

    /// Maximum PCM held before new entries stop being mirrored.
    ///
    /// Bounded by **bytes, not by count**: servers burst whole sentences ahead of real time, so
    /// several seconds of PCM can be outstanding, and an unbounded mirror is a memory leak on a
    /// long session.
    let byteLimit: Int

    private(set) var entries: [Entry] = []
    private(set) var byteCount: Int = 0
    /// Frames that were played but never mirrored because the bound was already reached. Counted
    /// so a carry-over can report an honest total rather than a flattering one.
    private(set) var unmirroredFrames: UInt64 = 0

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    var outstandingFrames: UInt64 {
        entries.reduce(0) { $0 &+ UInt64($1.frames) }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Mirror a buffer just handed to the player node. Returns `false` when the bound refused it.
    ///
    /// The **newest** entry is the one refused, never the oldest. Evicting the head would punch a
    /// gap into audio that is about to play and re-order what follows it; refusing the tail costs
    /// at worst a truncated end, which is both contiguous and honestly reportable.
    @discardableResult
    mutating func scheduled(pcm: Data, frames: UInt32, generation: UInt64) -> Bool {
        guard frames > 0, !pcm.isEmpty else { return false }
        guard byteCount + pcm.count <= byteLimit else {
            unmirroredFrames &+= UInt64(frames)
            return false
        }
        entries.append(Entry(generation: generation, frames: frames, pcm: pcm))
        byteCount += pcm.count
        return true
    }

    /// Retire the buffer a `.dataPlayedBack` completion just reported. Buffers complete in the
    /// order they were scheduled, so this drops the oldest entry of that generation.
    ///
    /// A callback from a superseded generation is a buffer `stop()` discarded rather than played;
    /// it retires nothing, exactly as the ledger ignores it.
    mutating func retire(generation: UInt64) {
        guard let index = entries.firstIndex(where: { $0.generation == generation }) else { return }
        byteCount -= entries[index].pcm.count
        entries.remove(at: index)
    }

    /// Take everything outstanding, for re-scheduling onto a fresh player node.
    mutating func drain() -> [Entry] {
        let survivors = entries
        entries.removeAll()
        byteCount = 0
        unmirroredFrames = 0
        return survivors
    }

    /// Throw everything away and report how many frames went with it — the number a caller owes
    /// the backend when carry-over is impossible.
    ///
    /// Includes frames the bound refused to mirror: they were scheduled and unheard just the same,
    /// and omitting them would under-report the loss.
    @discardableResult
    mutating func discardAll() -> UInt64 {
        let lost = outstandingFrames &+ unmirroredFrames
        entries.removeAll()
        byteCount = 0
        unmirroredFrames = 0
        return lost
    }

    /// Duration of `frames` at `sampleRate`, in whole milliseconds. Matches
    /// `PlaybackProgressLedger.playedMilliseconds` so the two numbers are commensurable.
    static func milliseconds(frames: UInt64, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int(Double(frames) * 1000.0 / sampleRate)
    }
}
