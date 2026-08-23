import Foundation

/// Tunables every ambient-speech consumer shares: how often it may speak, how much it may hold
/// while it waits for the floor, and how long an identical utterance counts as already said.
///
/// The consumer-specific taste (what a chat line sounds like, what counts as a fresh scene) stays
/// with the consumer — this is only the arbitration.
struct AmbientSpeechRules: Equatable {
    /// Max utterances spoken per rolling `rateWindow`.
    var rateCapPerMinute: Int = 6
    /// The rolling window the rate cap is measured over (seconds).
    var rateWindow: TimeInterval = 60
    /// Max utterances waiting for the floor; beyond it the oldest non-priority drops.
    var queueCap: Int = 5
    /// Window in which an identical utterance is not spoken twice (seconds).
    var dedupWindow: TimeInterval = 30

    /// Continuous scene narration (Plan CV). A stale description of a room the wearer has already
    /// walked out of is worse than silence, so the queue is deliberately tiny — narration would
    /// rather drop an announcement than deliver one late.
    static let narration = AmbientSpeechRules(rateCapPerMinute: 4, queueCap: 2, dedupWindow: 45)
}

/// Floor arbitration for ambient speech: the part of "wait for the floor, cap the rate, drop the
/// stale" that is the same for every consumer, extracted from `ChatReadbackPolicy` (Plan CI) when
/// continuous scene narration (Plan CV) needed the same behaviour.
///
/// It exists as one type rather than one per consumer because the failure mode of three copies is
/// that one of them ends up subtly able to interrupt a reply. Note that
/// `TextToSpeechService.SpeechUrgency` is *presentation* (speech rate and a prefix), not
/// arbitration — it cannot hold an utterance until the floor frees, which is the whole job here.
///
/// Pure value type: time is injected via `now`, no clock inside, so every branch is deterministic
/// and headless-testable. `Payload` is whatever the consumer needs back when the utterance is
/// finally allowed through; the arbiter only reads `dedupKey` and `isPriority`.
struct AmbientSpeechArbiter<Payload: Equatable>: Equatable {

    /// One utterance waiting for the floor. `duplicates` counts identical utterances merged in
    /// while it waited.
    struct Pending: Equatable {
        let payload: Payload
        /// Identity for merging and for the spoken-dedup window (compared case-insensitively).
        let dedupKey: String
        var duplicates: Int
        let isPriority: Bool
        let queuedAt: TimeInterval
    }

    /// Why an enqueue did or didn't take. `.merged` still counts as accepted — the utterance is
    /// represented in the queue, just folded into an identical one.
    enum Admission: Equatable {
        case queued
        case merged
        /// Identical text was spoken inside the dedup window.
        case alreadySpoken
        /// Something else owns the ear entirely; nothing accumulates for later.
        case suppressed

        /// Whether the utterance is represented in the queue.
        var isAccepted: Bool { self == .queued || self == .merged }
    }

    var rules: AmbientSpeechRules

    private(set) var queue: [Pending] = []
    /// Timestamps of recent emissions — the rolling rate-cap window.
    private var spokenAt: [TimeInterval] = []
    private var recentlySpoken: [Spoken] = []

    private struct Spoken: Equatable {
        let key: String
        let at: TimeInterval
    }

    init(rules: AmbientSpeechRules = AmbientSpeechRules()) {
        self.rules = rules
    }

    // MARK: - Ingest

    /// Offer an utterance for the queue. Returns how it was admitted; `suppressed` is passed by
    /// the caller when something else owns the ear outright (a live realtime session, say), in
    /// which case nothing accumulates for later.
    @discardableResult
    mutating func enqueue(_ payload: Payload,
                          dedupKey: String,
                          isPriority: Bool = false,
                          at now: TimeInterval,
                          suppressed: Bool = false) -> Admission {
        guard !suppressed else { return .suppressed }

        // Identical text already waiting → merge, don't queue it twice.
        if let i = queue.firstIndex(where: { $0.dedupKey.caseInsensitiveCompare(dedupKey) == .orderedSame }) {
            queue[i].duplicates += 1
            return .merged
        }
        // Identical text spoken inside the dedup window → already said, drop.
        recentlySpoken.removeAll { now - $0.at > rules.dedupWindow }
        if recentlySpoken.contains(where: { $0.key.caseInsensitiveCompare(dedupKey) == .orderedSame }) {
            return .alreadySpoken
        }

        let item = Pending(payload: payload, dedupKey: dedupKey, duplicates: 1,
                           isPriority: isPriority, queuedAt: now)
        if isPriority {
            // Jump the queue: behind any earlier priority items, ahead of everything else.
            let insertAt = queue.firstIndex(where: { !$0.isPriority }) ?? queue.endIndex
            queue.insert(item, at: insertAt)
        } else {
            queue.append(item)
        }
        // Bounded queue: drop the oldest non-priority first, then the oldest outright.
        while queue.count > rules.queueCap {
            let dropAt = queue.firstIndex(where: { !$0.isPriority }) ?? queue.startIndex
            queue.remove(at: dropAt)
        }
        return .queued
    }

    // MARK: - Drain

    /// Pull the next utterance if the moment allows one. Call repeatedly (a pump); returns `nil`
    /// while TTS is busy, the rate cap is spent, or nothing is queued.
    ///
    /// `suppressed` flushes the queue rather than holding it: whatever was waiting is stale by the
    /// time the ear is free again, and replaying it late is worse than losing it.
    mutating func next(at now: TimeInterval, ttsBusy: Bool, suppressed: Bool) -> Pending? {
        if suppressed {
            queue.removeAll()
            return nil
        }
        guard !ttsBusy, !queue.isEmpty else { return nil }

        spokenAt.removeAll { now - $0 > rules.rateWindow }
        guard spokenAt.count < rules.rateCapPerMinute else { return nil }

        let item = queue.removeFirst()
        spokenAt.append(now)
        recentlySpoken.append(Spoken(key: item.dedupKey, at: now))
        return item
    }

    /// Drop all pending state (call when the consuming session ends).
    mutating func reset() {
        queue.removeAll()
        spokenAt.removeAll()
        recentlySpoken.removeAll()
    }
}
