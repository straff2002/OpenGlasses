import Foundation

/// What the audio route looks like at the instant a reminder comes due.
///
/// Every field is something another part of the app already knows — the speech service's
/// `isSpeaking`, the voice-activity signal, whether a screen-reader or lifecycle notice is in
/// flight. Gathered into one value so the decision below is a function of its arguments and
/// nothing else, and so a device signal that turns out to be unavailable can be replaced by a
/// documented conservative default in one place rather than in the middle of a scheduler.
struct ScanAssistAudioSignals: Equatable, Sendable {
    /// The wearer is talking. A reminder spoken over someone mid-sentence is the one interruption
    /// this feature must never be the cause of.
    var userIsSpeaking = false
    /// The assistant is talking — `TextToSpeechService.isSpeaking`. Same voice, same route: two
    /// lines at once is one line nobody understands.
    var assistantIsSpeaking = false
    /// VoiceOver is mid-utterance, as far as we can tell. See
    /// `ScanAssistAudioSignals.voiceOverLikelySpeaking` for what "as far as we can tell" means.
    var voiceOverIsSpeaking = false
    /// A session lifecycle notice ("Camera started", "Recording stopped") is being announced.
    /// Those describe something that just changed under the wearer; a reminder describes nothing
    /// new, so it waits.
    var lifecycleAnnouncementInFlight = false
    /// Anything else the app considers more important than a reminder — an alert, a navigation
    /// instruction, a warning.
    var higherPriorityNoticeInFlight = false

    static let clear = ScanAssistAudioSignals()

    /// The first reason to wait, in priority order, or `nil` when the route is free.
    var busyReason: ScanAssistDeferralReason? {
        if userIsSpeaking { return .userSpeaking }
        if assistantIsSpeaking { return .assistantSpeaking }
        if voiceOverIsSpeaking { return .voiceOverSpeaking }
        if lifecycleAnnouncementInFlight { return .lifecycleAnnouncement }
        if higherPriorityNoticeInFlight { return .higherPriorityNotice }
        return nil
    }

    /// The documented conservative fallback for the one signal iOS does not offer.
    ///
    /// There is no API that reports when VoiceOver has finished speaking an announcement — only
    /// whether VoiceOver is running at all. Treating "VoiceOver is running" as "VoiceOver is
    /// speaking" would silence every reminder for exactly the people most likely to want them;
    /// ignoring it would talk over the screen reader. So the app assumes VoiceOver is busy for a
    /// bounded window after *it* posted an announcement — the only VoiceOver speech this app
    /// causes — and assumes it is free after that.
    ///
    /// The window is a wait, never a drop: if it elapses the cue is still offered, and only the
    /// gate's own deferral budget can end its life.
    static func voiceOverLikelySpeaking(voiceOverRunning: Bool,
                                        lastAnnouncementAt: TimeInterval?,
                                        now: TimeInterval,
                                        window: TimeInterval = ScanAssistCueGate.voiceOverAnnouncementWindow) -> Bool {
        guard voiceOverRunning, let lastAnnouncementAt else { return false }
        return now - lastAnnouncementAt < window
    }
}

/// Why a reminder is waiting rather than playing.
enum ScanAssistDeferralReason: String, Equatable, Sendable, CaseIterable {
    case userSpeaking
    case assistantSpeaking
    case voiceOverSpeaking
    case lifecycleAnnouncement
    case higherPriorityNotice
}

/// Why a reminder was thrown away instead of played.
enum ScanAssistDropReason: String, Equatable, Sendable, CaseIterable {
    /// It belongs to a session, a side or a rhythm that has since moved on.
    case stale
    /// The route stayed busy for longer than a reminder is worth waiting. Delivering it now would
    /// land it next to the following one, which is the burst this whole type exists to prevent.
    case waitedTooLong
}

/// What to do with one reminder, right now.
enum ScanAssistCueDecision: Equatable, Sendable {
    case deliver(side: ScanAssistSide, generation: Int)
    case deferred(ScanAssistDeferralReason)
    case dropped(ScanAssistDropReason)
    /// Nothing was waiting. Only `recheck` can return this.
    case nothingWaiting
}

/// Decides whether a reminder plays, waits, or is thrown away (docs/plans/FB-scan-assist.md P2).
///
/// The rule the wearer actually feels is the third one: **a reminder that had to wait is only
/// worth playing while it is still the newest thing the session has to say.** A pause, a stop, a
/// side change or simply a newer reminder retires the one being held, and nothing is ever
/// replayed afterwards — the failure this prevents is four reminders arriving in a row the moment
/// a phone call ends, which is both useless and alarming.
///
/// So the gate holds at most one cue, and holding a second one means discarding the first. That
/// single slot is the whole design; the rest is bookkeeping about why.
///
/// ## Decisions
///
/// | Situation | `offer` | `recheck` |
/// |---|---|---|
/// | session not running | `dropped(.stale)` | `dropped(.stale)` |
/// | cue's generation ≠ current | `dropped(.stale)` | `dropped(.stale)` |
/// | route busy, budget left | `deferred(reason)` — held, replacing any earlier cue | `deferred(reason)` |
/// | route busy, budget spent | `deferred(reason)` (it has only just arrived) | `dropped(.waitedTooLong)` |
/// | route free | `deliver` | `deliver` |
/// | nothing held | — | `nothingWaiting` |
///
/// Nothing here knows what "delivered" means beyond "playback was requested". A reminder that was
/// played is not a reminder that was heard, and no state in this type or its owner may be read as
/// saying otherwise.
struct ScanAssistCueGate {

    /// How long a waiting reminder stays worth playing. Shorter than the shortest interval the
    /// wearer can choose (15 s), so a held cue can never survive into the slot of the next one.
    static let defaultDeferralBudget: TimeInterval = 10

    /// How long the app assumes VoiceOver is still speaking an announcement it posted. See
    /// `ScanAssistAudioSignals.voiceOverLikelySpeaking`.
    static let voiceOverAnnouncementWindow: TimeInterval = 2.5

    struct HeldCue: Equatable, Sendable {
        let side: ScanAssistSide
        let generation: Int
        /// When it first came due — the budget runs from here, not from the latest recheck, so a
        /// busy route cannot keep a stale reminder alive by being busy repeatedly.
        let dueAt: TimeInterval
        let reason: ScanAssistDeferralReason
    }

    /// The one reminder waiting for the route, if any.
    private(set) var held: HeldCue?

    let deferralBudget: TimeInterval

    init(deferralBudget: TimeInterval = ScanAssistCueGate.defaultDeferralBudget) {
        self.deferralBudget = deferralBudget
    }

    /// A reminder has just come due.
    mutating func offer(side: ScanAssistSide,
                        generation: Int,
                        currentGeneration: Int,
                        isRunning: Bool,
                        signals: ScanAssistAudioSignals,
                        at now: TimeInterval) -> ScanAssistCueDecision {
        guard isRunning, generation == currentGeneration else {
            // Don't disturb whatever is held: a stale offer says nothing about the cue waiting.
            return .dropped(.stale)
        }
        guard let reason = signals.busyReason else {
            held = nil
            return .deliver(side: side, generation: generation)
        }
        // Newest wins. Whatever was waiting is discarded here rather than queued behind this one,
        // which is what keeps "at most one cue outstanding" true by construction.
        held = HeldCue(side: side, generation: generation, dueAt: now, reason: reason)
        return .deferred(reason)
    }

    /// The route may have freed. Called by the owner on a bounded retry while something is held.
    mutating func recheck(currentGeneration: Int,
                          isRunning: Bool,
                          signals: ScanAssistAudioSignals,
                          at now: TimeInterval) -> ScanAssistCueDecision {
        guard let cue = held else { return .nothingWaiting }
        guard isRunning, cue.generation == currentGeneration else {
            held = nil
            return .dropped(.stale)
        }
        guard let reason = signals.busyReason else {
            held = nil
            return .deliver(side: cue.side, generation: cue.generation)
        }
        guard now - cue.dueAt < deferralBudget else {
            held = nil
            return .dropped(.waitedTooLong)
        }
        held = HeldCue(side: cue.side, generation: cue.generation, dueAt: cue.dueAt, reason: reason)
        return .deferred(reason)
    }

    /// Throw away whatever is waiting. Pause, stop, expiry, a side change and an interruption all
    /// land here: each of them means the held reminder belongs to a session that has moved on.
    mutating func cancelHeld() {
        held = nil
    }
}
