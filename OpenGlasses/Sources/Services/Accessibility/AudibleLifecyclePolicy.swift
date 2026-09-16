import Foundation

/// Plan FF P0/PR2 — what a wearer who cannot see the screen is *told out loud* about the session's
/// lifecycle, and when.
///
/// # The gap this closes
///
/// `SessionAnnouncementPolicy` answers a different question: given that VoiceOver is running, which
/// transitions does the screen reader read? Its whole design is subtraction — it withholds a line
/// whenever the app already makes its own sound, so two voices never land in one ear. That is right,
/// and it leaves a hole exactly where this plan's user lives:
///
/// * With VoiceOver **off** it says nothing at all, by its first `guard`. A blind wearer running the
///   assistant hands-free with the phone pocketed does not need VoiceOver on to need to know that
///   the session dropped.
/// * The transitions it *does* pass through are announced as screen-reader posts, which queue behind
///   whatever VoiceOver is reading and are silently dropped while the assistant speaks.
/// * A reconnect was never announced at all: the socket's `onReconnected` callback restarts capture
///   and says nothing, and an audio restart that *failed* there was only written to the log.
///
/// So this policy owns the audible half: an earcon the wearer can learn, plus a short spoken line,
/// delivered through the app's own speech path so it works with VoiceOver on **or** off. The two
/// policies are wired together rather than duplicated — `AnnouncementContext.blindAssistantCuesActive`
/// tells `SessionAnnouncementPolicy` that these transitions now have their own audio cue, so
/// VoiceOver stops reading them and the de-duplication keeps working in the direction it always did.
///
/// Everything here is pure. The queueing, the clock and the sinks live in
/// ``AudibleLifecycleCoordinator``.
enum AudibleLifecyclePolicy {

    // MARK: - The four feedbacks

    /// Whether a recovered session can actually be used again, and for what.
    ///
    /// A recovery cue is a claim about capability, so it may only be made from evidence. "Restored"
    /// with a dead microphone or a camera that stopped delivering pictures is the kind of cheerful
    /// lie that costs a blind wearer the next thirty seconds finding out for themselves.
    enum RecoveryShape: Equatable {
        /// Audio is back, pictures are arriving where the session needs them, and the conversation
        /// came back with them.
        case full
        /// Audio is back and the camera is not producing fresh pictures. Said plainly, because a
        /// wearer who asks "what's in front of me" needs to know the answer cannot come.
        case cameraUnavailable
        /// Everything works and the thread of the conversation did not survive the outage (Plan FF
        /// P1/PR5). A separate shape rather than a footnote: an assistant that comes back and
        /// cannot say what was just being discussed has to say so, or the wearer's next sentence —
        /// "and the other one?" — lands on nothing.
        case contextLost
        /// The camera is not usable **and** the thread is gone. Both, because either one alone
        /// would leave the wearer to discover the other.
        case cameraUnavailableAndContextLost

        /// Build the shape from the two independent facts, so the four cases cannot be assembled
        /// inconsistently at a call site.
        static func make(cameraUsable: Bool, contextCarried: Bool) -> RecoveryShape {
            switch (cameraUsable, contextCarried) {
            case (true, true): return .full
            case (false, true): return .cameraUnavailable
            case (true, false): return .contextLost
            case (false, false): return .cameraUnavailableAndContextLost
            }
        }

        /// Whether this shape reports a camera that can answer a question.
        var cameraIsUsable: Bool {
            switch self {
            case .full, .contextLost: return true
            case .cameraUnavailable, .cameraUnavailableAndContextLost: return false
            }
        }

        /// Whether this shape reports a conversation the session can still refer back to.
        var contextCarried: Bool {
            switch self {
            case .full, .cameraUnavailable: return true
            case .contextLost, .cameraUnavailableAndContextLost: return false
            }
        }
    }

    /// One thing worth making a noise about.
    ///
    /// The first four are the feedbacks this phase was asked for. ``recoveryIncomplete`` and
    /// ``recoveryFailed`` are the two honest endings the same signals produce: a reconnect whose
    /// audio restart threw (previously a log line and nothing else) and an exhausted retry ladder.
    enum Notice: Equatable {
        /// Audio route up, session connected, microphone listening. The "you can talk now" moment.
        case sessionUsable
        /// The session dropped and the retry ladder is running.
        case connectionLost
        /// The socket came back and the session is usable again, in the shape given.
        case serviceRestored(RecoveryShape)
        /// A capture the wearer (or the model on their behalf) asked for actually produced an image.
        case captureSucceeded
        /// The socket came back but the microphone did not. Degraded, and the wearer has to know.
        case recoveryIncomplete
        /// The retry ladder gave up. Terminal: nothing further is coming without the wearer acting.
        case recoveryFailed
    }

    /// The learnable sounds. Deliberately five, deliberately distinct in contour rather than pitch —
    /// a rising pair, a falling pair, a rising triad, a short bright blip, a low double.
    enum Earcon: String, Equatable, CaseIterable {
        /// Rising pair — ready.
        case ready
        /// Falling pair — lost.
        case lost
        /// Rising triad — back.
        case restored
        /// Short bright blip — the picture was taken.
        case captured
        /// Low double — it did not work.
        case failed
    }

    /// Whether the wearer wants words with their tones.
    enum CueStyle: String, Equatable, CaseIterable {
        /// An earcon and a short spoken line.
        case tonesAndSpeech
        /// The earcon only, for a wearer who has learned them and does not want the interruption.
        case tonesOnly
    }

    /// One delivered feedback: what to play, what to say, and whether it may take the floor.
    struct Cue: Equatable {
        let earcon: Earcon
        /// `nil` under ``CueStyle/tonesOnly``, or for a notice with nothing to add to its tone.
        let spoken: String?
        /// Whether the line may stop speech that is already running. Reserved for the terminal
        /// failure — everything else waits its turn or is dropped as stale.
        let interrupts: Bool
    }

    // MARK: - Evidence → notice

    /// What the session knows about itself at start-up. All three have to be true: a connected
    /// socket with no microphone is not a usable assistant, and neither is an open microphone
    /// feeding a socket that never finished setting up.
    struct SessionReadiness: Equatable {
        /// The shared audio session is active for this session's owner.
        var audioSessionActive: Bool
        /// The transport finished setup and is ready to carry a turn.
        var sessionConnected: Bool
        /// Microphone capture actually started.
        var microphoneListening: Bool

        init(audioSessionActive: Bool, sessionConnected: Bool, microphoneListening: Bool) {
            self.audioSessionActive = audioSessionActive
            self.sessionConnected = sessionConnected
            self.microphoneListening = microphoneListening
        }

        var isUsable: Bool { audioSessionActive && sessionConnected && microphoneListening }
    }

    /// What a reconnect actually restored, read *after* the restart has had a chance to produce
    /// something — never at callback time, when the camera has by construction not yet delivered a
    /// frame and every recovery would be reported as camera-unavailable.
    struct RecoveryEvidence: Equatable {
        /// Microphone capture restarted without throwing.
        var audioRestored: Bool
        /// This session answers questions about what the wearer is looking at, so a recovery claim
        /// has to account for the camera. An audio-only session does not.
        var needsVisualEvidence: Bool
        /// `CameraReadiness.hasFreshVisualEvidence` — a decoded picture from *this* camera session,
        /// newer than the evidence window.
        var hasFreshVisualEvidence: Bool
        /// Whether the conversation itself survived — resumed on the server, or rebuilt locally
        /// from this device's own bounded record (Plan FF P1/PR5, `LiveRecoveryAssessment`).
        ///
        /// Defaults to `true` so a caller that has no way to know — the OpenAI Realtime backend has
        /// no resumption concept at all — makes no claim about context either way, which is the
        /// behaviour every caller had before this fact existed.
        var contextCarried: Bool

        init(audioRestored: Bool, needsVisualEvidence: Bool, hasFreshVisualEvidence: Bool,
             contextCarried: Bool = true) {
            self.audioRestored = audioRestored
            self.needsVisualEvidence = needsVisualEvidence
            self.hasFreshVisualEvidence = hasFreshVisualEvidence
            self.contextCarried = contextCarried
        }
    }

    /// The notice a start-up should produce, or `nil` when the session is not usable yet and the
    /// wearer should be told nothing rather than told a half-truth.
    static func startupNotice(for readiness: SessionReadiness) -> Notice? {
        readiness.isUsable ? .sessionUsable : nil
    }

    /// The notice a reconnect should produce.
    ///
    /// `nil` is impossible on purpose: every reconnect ends in one of the three statements, because
    /// the failure this replaces was a reconnect that ended in silence.
    static func recoveryNotice(for evidence: RecoveryEvidence) -> Notice {
        guard evidence.audioRestored else { return .recoveryIncomplete }
        let cameraUsable = !evidence.needsVisualEvidence || evidence.hasFreshVisualEvidence
        return .serviceRestored(.make(cameraUsable: cameraUsable,
                                      contextCarried: evidence.contextCarried))
    }

    // MARK: - Notice → cue

    static func cue(for notice: Notice, style: CueStyle) -> Cue {
        Cue(earcon: earcon(for: notice),
            spoken: style == .tonesAndSpeech ? spokenLine(for: notice) : nil,
            interrupts: isTerminal(notice))
    }

    static func earcon(for notice: Notice) -> Earcon {
        switch notice {
        case .sessionUsable: return .ready
        case .connectionLost: return .lost
        case .serviceRestored: return .restored
        case .captureSucceeded: return .captured
        case .recoveryIncomplete, .recoveryFailed: return .failed
        }
    }

    /// The spoken half. Short, literal, and never an assurance — the same rule
    /// `BlindAssistanceContract` puts on what the model may say applies to what the app says.
    static func spokenLine(for notice: Notice) -> String {
        switch notice {
        case .sessionUsable:
            return "Ready. I'm listening."
        case .connectionLost:
            return "Connection lost. Trying to get it back."
        case .serviceRestored(.full):
            return "Back. I'm listening."
        case .serviceRestored(.cameraUnavailable):
            return "Audio is back. The camera isn't — I can hear you, but I can't see."
        case .serviceRestored(.contextLost):
            return "Connected again, but I lost the thread of our conversation. You may need to tell me again."
        case .serviceRestored(.cameraUnavailableAndContextLost):
            return "Connected again. I can't see, and I lost the thread of our conversation."
        case .captureSucceeded:
            return "Photo taken."
        case .recoveryIncomplete:
            return "Connected again, but the microphone didn't come back. Stop and start the session to try again."
        case .recoveryFailed:
            return "Connection lost. I couldn't get it back."
        }
    }

    /// Nothing further is coming without the wearer doing something. The only notices allowed to
    /// take the floor from speech that is already running.
    static func isTerminal(_ notice: Notice) -> Bool {
        switch notice {
        case .recoveryFailed: return true
        case .sessionUsable, .connectionLost, .serviceRestored, .captureSucceeded,
             .recoveryIncomplete: return false
        }
    }

    /// A notice that reports something not working. These are the ones the queue may never quietly
    /// discard — "do not drop the only failure notice indefinitely" is the whole rule.
    static func isFailure(_ notice: Notice) -> Bool {
        switch notice {
        case .connectionLost, .recoveryIncomplete, .recoveryFailed: return true
        case .sessionUsable, .serviceRestored, .captureSucceeded: return false
        }
    }

    // MARK: - Queue behaviour

    /// Higher wins a seat when the queue is full, and goes first when the route frees.
    static func priority(of notice: Notice) -> Int {
        switch notice {
        case .recoveryFailed: return 100
        case .recoveryIncomplete: return 90
        case .connectionLost: return 80
        case .serviceRestored(.cameraUnavailableAndContextLost): return 75
        case .serviceRestored(.cameraUnavailable): return 70
        case .serviceRestored(.contextLost): return 65
        case .serviceRestored(.full): return 60
        case .sessionUsable: return 40
        case .captureSucceeded: return 30
        }
    }

    /// How long a queued notice stays worth saying. `nil` means it never goes stale by time — a
    /// failure the wearer has not been told about is still true five minutes later.
    ///
    /// The bounded ones are the notices that are *about a moment*: "photo taken" ten seconds after
    /// the shutter describes the wrong moment, and "ready, I'm listening" long after the session
    /// came up tells a wearer who has already spoken something they worked out for themselves.
    static func staleAfter(_ notice: Notice) -> TimeInterval? {
        switch notice {
        case .captureSucceeded: return 4
        case .sessionUsable: return 10
        case .serviceRestored: return 20
        case .connectionLost, .recoveryIncomplete, .recoveryFailed: return nil
        }
    }

    /// How long a failure notice waits for a free route before it goes out anyway.
    ///
    /// Long enough for an ordinary sentence of the assistant's to finish — landing a tone in the
    /// middle of an answer the wearer asked for is its own kind of harm — and short enough that a
    /// long model monologue cannot bury the fact that the session is gone.
    static let maxQueuedWait: TimeInterval = 8

    /// How many notices may wait at once. Small on purpose: this is a queue of things to *say*, and
    /// a backlog of five spoken lines arriving together is noise, not information.
    static let maxQueueDepth = 4

    /// An identical notice delivered again inside this window is suppressed. Mirrors
    /// `SessionAnnouncer.repeatWindow` so the two paths absorb a republish storm the same way.
    static let repeatWindow: TimeInterval = 2

    /// Whether `notice` cancels an already-queued, never-delivered `pending` from the same session.
    ///
    /// This is the rule that stops "connection lost" playing after the connection came back: while
    /// the assistant was speaking, the loss notice sat in the queue, the socket recovered, and by
    /// the time the route freed the statement had become false. A recovery — in any of its shapes,
    /// including the degraded ones, which are still statements that the socket is back — expires it.
    static func expires(_ pending: Notice, on notice: Notice) -> Bool {
        guard isRecoveryStatement(notice) else { return false }
        return pending == .connectionLost
    }

    /// Notices that assert the socket came back, whatever else they report about it.
    static func isRecoveryStatement(_ notice: Notice) -> Bool {
        switch notice {
        case .serviceRestored, .recoveryIncomplete: return true
        case .sessionUsable, .connectionLost, .captureSucceeded, .recoveryFailed: return false
        }
    }

    /// Whether a recovery notice is still worth saying when the loss it corrects was never heard.
    ///
    /// If the loss notice expired in the queue, the wearer experienced no interruption — the
    /// assistant was talking the whole time. "Back, I'm listening" then answers a question nobody
    /// asked. A *degraded* recovery is different: that the camera is no longer usable is new
    /// information regardless of what the wearer heard before it.
    static func isWorthSayingWithoutAHeardLoss(_ notice: Notice) -> Bool {
        switch notice {
        case .serviceRestored(.full): return false
        case .serviceRestored(.cameraUnavailable), .serviceRestored(.contextLost),
             .serviceRestored(.cameraUnavailableAndContextLost), .recoveryIncomplete: return true
        case .sessionUsable, .connectionLost, .captureSucceeded, .recoveryFailed: return true
        }
    }

    // MARK: - The route

    /// Who has the ear right now.
    ///
    /// Honesty note on `voiceOverAnnouncing`: iOS exposes no "is VoiceOver speaking" query. What
    /// this can know is whether an announcement *this app posted* has reported finishing, which is
    /// what `SessionAnnouncer` tracks. VoiceOver reading a control the wearer just touched is not
    /// visible here and never will be — which is one more reason the earcon, not the sentence,
    /// carries the meaning.
    struct SpeechRoute: Equatable {
        /// TTS, Kokoro, or a live model's own audio is on the air.
        var assistantSpeaking: Bool
        /// An announcement this app posted to VoiceOver has not reported finishing.
        var voiceOverAnnouncing: Bool

        init(assistantSpeaking: Bool = false, voiceOverAnnouncing: Bool = false) {
            self.assistantSpeaking = assistantSpeaking
            self.voiceOverAnnouncing = voiceOverAnnouncing
        }

        /// Whether speech occupies the route.
        var isBusy: Bool { assistantSpeaking || voiceOverAnnouncing }
    }

    // MARK: - The cue-learning flow

    /// One step of "play me the cues": the sound, and what it means, in that order.
    struct Lesson: Equatable {
        let earcon: Earcon
        let meaning: String
    }

    /// The tour, in the order a wearer meets these sounds in a real session.
    ///
    /// The wording deliberately says "this sound means", not the cue's own line: the point of the
    /// tour is to attach a meaning to a contour, so hearing the tone alone later is enough.
    static let lessons: [Lesson] = [
        Lesson(earcon: .ready, meaning: "This sound means the assistant is ready and listening."),
        Lesson(earcon: .lost, meaning: "This sound means the connection dropped and I'm trying to get it back."),
        Lesson(earcon: .restored, meaning: "This sound means the connection is back."),
        Lesson(earcon: .captured, meaning: "This sound means a photo you asked for was taken."),
        Lesson(earcon: .failed, meaning: "This sound means something didn't work and I can't carry on without you."),
    ]

    /// The gap between one lesson's tone and its explanation, and between lessons. Long enough that
    /// the tone is heard as its own thing rather than as the start of the sentence.
    static let lessonGap: TimeInterval = 0.7
}
