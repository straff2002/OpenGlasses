import Foundation

/// What continuous scene narration owes the wearer *out loud* when it stops (Plan CV P3).
///
/// The reasoning, which is the whole phase: for someone relying on narration, **silence that isn't
/// explained is indistinguishable from silence because nothing changed** — and those two mean
/// opposite things. One says "the room is unchanged, keep walking"; the other says "you are getting
/// no information at all". A loop that halts quietly tells the wearer the first when the truth is
/// the second, which is the worst failure this feature has available.
///
/// `NarrationSessionPolicy` already decides *that* an explanation is owed (`Transition.haltBegan`).
/// This decides *whether it is owed aloud, and in what words* — kept separate and pure because the
/// interesting rules are about restraint, not copy:
///
/// 1. **Only announce to someone who was being spoken to.** Silence only reads as a failure if the
///    wearer expected sound. In `.watching` the loop was silent by design and nobody is waiting on
///    it, so a spoken "narration paused" would be the app talking to someone who never asked it to.
///    Watching halts surface in the UI and nowhere else.
/// 2. **Only announce a resume if the halt was announced.** Otherwise "narration is back on"
///    arrives out of nowhere, explaining a silence the wearer never noticed.
/// 3. **Never announce the same halt twice.** A phone locking and unlocking repeatedly must not
///    produce a running commentary about it.
///
/// The caption/narration decision added a fourth case with the same shape and a smaller scope: a
/// **standing condition** (ambient captions running) takes the ear while the loop keeps watching.
/// The three rules above apply unchanged — the only difference is that the loop did not stop, so
/// the copy says the ear is busy rather than that descriptions have stopped being made. The
/// moment-shaped interruptions (`userTurn`, `realtimeSession`) still say nothing: the wearer
/// created them and hears them end.
///
/// Pure value type — no clock, no services, no I/O.
struct NarrationVoiceNotices: Equatable {

    /// The halt the wearer has already been told about, if any.
    private(set) var announcedHalt: NarrationSessionPolicy.Interruption?
    /// The standing ear-only condition the wearer has already been told about, if any.
    private(set) var announcedSilence: NarrationSessionPolicy.Interruption?

    init() {}

    /// What to say for this transition, or nil to stay quiet.
    ///
    /// `requestedMode` rather than the transition's `isSpeaking`, deliberately: a wearer who asked
    /// for narration and is momentarily quiet because they asked a question is still someone
    /// relying on narration, and a halt landing during that moment is still owed an explanation.
    mutating func notice(for transition: NarrationSessionPolicy.Transition,
                         requestedMode: NarrationMode) -> String? {
        // A halt beginning, and the wearer asking for narration into one already in force, are
        // the same debt reached from opposite directions — the world changed under them, or they
        // walked into a world that had already changed. Either way they asked for descriptions
        // and are getting none, so the copy is the same.
        if let began = transition.haltBegan ?? transition.haltBlockedRequest {
            // A halt supersedes a silence we already announced: its copy explains everything the
            // silence copy did and more, and the wearer must not be told twice about one quiet.
            announcedSilence = nil
            guard requestedMode == .narrating else { return nil }
            guard announcedHalt != began else { return nil }
            announcedHalt = began
            return Self.haltCopy(began)
        }

        // Bookkeeping first, copy second: the halt is over whether or not we say so, and a stale
        // `announcedHalt` would swallow the *next* halt as a repeat.
        var resume: String?
        if let ended = transition.haltEnded {
            if announcedHalt == ended { resume = Self.resumeCopy }
            announcedHalt = nil
        } else if let ended = transition.silenceEnded {
            if announcedSilence == ended { resume = Self.speakingAgainCopy }
            announcedSilence = nil
        }

        if let began = transition.silenceBegan {
            // Reached when a halt clears straight into a live standing condition, among others.
            // That is not narration coming back, and saying so would be a lie the wearer then
            // spends the next minute disproving.
            guard requestedMode == .narrating else { return nil }
            guard announcedSilence != began else { return nil }
            announcedSilence = began
            return Self.silenceCopy(began)
        }

        // A resume is only true when the ear is actually free again.
        if let resume, transition.to.isSpeaking { return resume }

        // Leaving the mode entirely is the wearer's own doing — they know why it went quiet.
        if transition.to.mode == .off {
            announcedHalt = nil
        }
        // Same for asking narration to stop speaking: a later "start narrating" into the same
        // standing condition must announce it again rather than treat it as already said.
        if requestedMode != .narrating {
            announcedSilence = nil
        }
        return nil
    }

    mutating func reset() {
        announcedHalt = nil
        announcedSilence = nil
    }

    // MARK: - Copy

    /// Spoken copy: short, plain, and it says **why**, because "narration stopped" alone leaves the
    /// wearer to guess whether it is broken, finished, or waiting for them.
    static func haltCopy(_ interruption: NarrationSessionPolicy.Interruption) -> String {
        switch interruption {
        case .backgrounded:
            return "Scene narration has stopped. Descriptions are generated on this device, "
                + "and that can't run while the app is in the background. Open the app to start again."
        case .cameraUnavailable:
            return "Scene narration has stopped. There's no live camera feed from your glasses."
        case .userTurn, .realtimeSession, .ambientCaptions:
            // These take the ear, not the loop, so the policy never reports them as a halt reason.
            // Kept exhaustive so a new interruption has to decide what the wearer is told.
            return "Scene narration has paused."
        }
    }

    static let resumeCopy = "Scene narration is back on."

    /// Spoken copy for a standing condition that takes only the ear. It has to do two things the
    /// halt copy doesn't: say that the loop is **still watching** (so a question still gets a
    /// grounded answer), and name the switch the wearer can actually reach, since the condition
    /// is one they turned on themselves and may well have forgotten about.
    static func silenceCopy(_ interruption: NarrationSessionPolicy.Interruption) -> String {
        switch interruption {
        case .ambientCaptions:
            return "Scene narration has gone quiet while live captions are running, so it isn't "
                + "talking over them. It's still watching — turn captions off to hear descriptions again."
        case .userTurn, .realtimeSession:
            // Moments, not standing conditions: the policy never reports these here. Kept
            // exhaustive so a new interruption has to decide what the wearer is told.
            return "Scene narration has gone quiet for a moment."
        case .backgrounded, .cameraUnavailable:
            // Halts, which have their own copy above.
            return Self.haltCopy(interruption)
        }
    }

    /// Distinct from `resumeCopy` on purpose: nothing was ever "off". Only the ear was busy.
    static let speakingAgainCopy = "Scene narration is speaking again."

    // MARK: - Starting the camera (Plan CV, camera ownership)
    //
    // These three are a different category from everything above, and the difference decides who
    // hears them. The notices above explain *ambient* silence, so they are governed by the
    // restraint rules — chiefly "only speak to someone who was being spoken to". These are
    // **replies to something the wearer just did**, in the moment they did it, and a reply is owed
    // whichever mode they asked for: a wearer who flips "watch the scene" and then hears nothing
    // for twenty seconds has been told nothing, and silent watching is not an excuse for that. The
    // refusal copy below already worked this way; the warm-up joins it.

    /// Spoken as narration takes the camera, when the camera was not already running.
    ///
    /// The cold start is device-traced at up to ~20 s (the observation behind
    /// [CX](CX-live-session-vision-choice.md)), which is long enough that unannounced it becomes
    /// its own unexplained silence — the exact failure P3 exists to prevent, arriving one second
    /// after the wearer asked for the feature that prevents it.
    ///
    /// Under a conserving posture the same notice carries the cost, because the wearer is the only
    /// one who can decide whether narration is worth their remaining battery, and they can only
    /// decide it if they are told.
    static func warmingCopy(posture: PowerPosture) -> String {
        let base = "Starting the glasses camera for scene narration. This takes a few seconds."
        guard posture >= .conserve else { return base }
        return base + " Battery is getting low, so it won't last long."
    }

    /// Whether the power posture allows narration to start the camera at all, and what to say when
    /// it doesn't.
    ///
    /// **`conserve` is allowed through and `reserve` is not**, which is one step more permissive
    /// than [CX](CX-live-session-vision-choice.md)'s vision mode refuses at both. The two features
    /// are not comparable on this axis: a sighted wearer refused vision mode can look at the thing
    /// themselves, and a wearer who needs scene narration cannot. `conserve` means economise, not
    /// stop, and refusing an accessibility feature there would be the app economising on the one
    /// thing its wearer has no substitute for.
    ///
    /// `reserve` is a refusal for a reason that is *not* thrift: at critical battery, starting the
    /// glasses' largest drain does not give the wearer narration, it gives them a few minutes of
    /// narration followed by dead glasses — no narration, no captions, no assistant, nothing. A
    /// refusal they can act on beats an outcome they cannot.
    static func powerRefusal(posture: PowerPosture) -> String? {
        guard posture >= .reserve else { return nil }
        return "Can't start scene narration right now. It keeps the glasses camera running, and "
            + "they're too low on power or too warm for that. Charge or cool them and try again."
    }

    /// Spoken copy for a start that can't happen at all, so a wearer asking for narration on
    /// hardware that can't provide it hears the reason rather than nothing.
    ///
    /// The gate's own text already names the feature and the cause; this only frames it as a
    /// refusal of what was just asked for.
    static func refusalCopy(_ reason: String) -> String {
        "Can't start scene narration. \(reason)"
    }
}
