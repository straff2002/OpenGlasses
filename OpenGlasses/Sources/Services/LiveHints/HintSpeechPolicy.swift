import Foundation

/// When a hint is spoken in the wearer's ear (Plan MO §6, "speak-when-quiet").
///
/// A pure state machine: the session feeds it events, each stamped with the clock where time
/// matters, and does what the returned action says. The rules:
/// - a hint is spoken once nobody has spoken for `HintLimits.quietBeforeSpeaking` (400 ms);
/// - when anyone starts speaking while a hint plays, it stops at once, and the hint stays ready
///   to repeat (the session feeds speech activity from the **ungated** mic level, so a person who
///   talks over a hint is heard even while the caption gate silences the assistant; how fast that
///   reaches here, "within about 200 ms", is the session's, P1);
/// - only the newest hint: a new one replaces one that is waiting (one already playing finishes),
///   and a hint not started within `HintLimits.speakWithin` (5 s) of arriving is dropped;
/// - **never through the phone speaker**: on that route a hint is dropped for the ear and kept for
///   the screen (`lastHint`), and a hint that is playing when the route falls back to the speaker
///   stops;
/// - repeat speaks the last hint again, under the same quiet and route rules; skip stops it.
///
/// It starts on the phone speaker until told otherwise, so it never speaks before the session
/// has said where the sound goes.
struct HintSpeechPolicy: Equatable {

    enum Event: Equatable {
        case hintArrived(String, at: Date)
        /// Anyone near the phone started (`true`) or stopped (`false`) speaking.
        case speechActivity(isSpeaking: Bool, at: Date)
        /// The session's clock tick, so a waiting hint is spoken once it's quiet, or dropped.
        case tick(at: Date)
        /// The hint being spoken has finished playing.
        case speechFinished
        case repeatRequested(at: Date)
        case skipRequested
        case outputRoute(isPhoneSpeaker: Bool)
    }

    enum Action: Equatable {
        case speak(String)
        case stopSpeaking
        case drop(DropReason)
        case none
    }

    enum DropReason: String, Equatable {
        /// The output is the phone's own speaker: screen only.
        case phoneSpeaker
        /// Not started within `HintLimits.speakWithin` of arriving.
        case stale
        /// The wearer skipped it before it started.
        case skipped
        /// Repeat with no hint yet.
        case nothingToRepeat
    }

    /// The newest hint, spoken or not: what repeat says, and what the screen shows.
    private(set) var lastHint: String?
    /// The hint playing now.
    private(set) var speaking: String?
    /// The hint waiting for quiet, and when it arrived.
    private(set) var waiting: String?
    private var waitingSince: Date?
    private(set) var someoneSpeaking = false
    /// When speech activity last changed: the start of the quiet when nobody is speaking.
    private var lastActivityAt: Date?
    private(set) var isPhoneSpeaker: Bool

    init(isPhoneSpeaker: Bool = true) {
        self.isPhoneSpeaker = isPhoneSpeaker
    }

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case let .hintArrived(text, at):
            lastHint = text
            guard !isPhoneSpeaker else {
                clearWaiting()
                return .drop(.phoneSpeaker)
            }
            waiting = text
            waitingSince = at
            return speaking == nil ? speakIfQuiet(at: at) : .none

        case let .speechActivity(isSpeaking, at):
            someoneSpeaking = isSpeaking
            lastActivityAt = at
            if isSpeaking, speaking != nil {
                speaking = nil
                return .stopSpeaking
            }
            return expireIfStale(at: at)

        case let .tick(at):
            guard speaking == nil else { return .none }
            return speakIfQuiet(at: at)

        case .speechFinished:
            speaking = nil
            return .none

        case let .repeatRequested(at):
            guard let lastHint else { return .drop(.nothingToRepeat) }
            guard !isPhoneSpeaker else { return .drop(.phoneSpeaker) }
            guard speaking == nil else { return .none }
            waiting = lastHint
            waitingSince = at
            return speakIfQuiet(at: at)

        case .skipRequested:
            if speaking != nil {
                speaking = nil
                clearWaiting()
                return .stopSpeaking
            }
            guard waiting != nil else { return .none }
            clearWaiting()
            return .drop(.skipped)

        case let .outputRoute(phoneSpeaker):
            isPhoneSpeaker = phoneSpeaker
            guard phoneSpeaker else { return .none }
            if speaking != nil {
                speaking = nil
                clearWaiting()
                return .stopSpeaking
            }
            guard waiting != nil else { return .none }
            clearWaiting()
            return .drop(.phoneSpeaker)
        }
    }

    // MARK: - Rules

    /// Speak the waiting hint if it's still fresh and nobody has spoken for the quiet gap.
    private mutating func speakIfQuiet(at now: Date) -> Action {
        let stale = expireIfStale(at: now)
        guard stale == .none, let text = waiting else { return stale }
        guard !someoneSpeaking else { return .none }
        if let lastActivityAt,
           now.timeIntervalSince(lastActivityAt) < HintLimits.quietBeforeSpeaking - HintLimits.timeTolerance {
            return .none
        }
        clearWaiting()
        speaking = text
        return .speak(text)
    }

    /// Drop the waiting hint once `HintLimits.speakWithin` has passed since it arrived.
    private mutating func expireIfStale(at now: Date) -> Action {
        guard waiting != nil, let since = waitingSince else { return .none }
        guard now.timeIntervalSince(since) >= HintLimits.speakWithin - HintLimits.timeTolerance else {
            return .none
        }
        clearWaiting()
        return .drop(.stale)
    }

    private mutating func clearWaiting() {
        waiting = nil
        waitingSince = nil
    }
}
