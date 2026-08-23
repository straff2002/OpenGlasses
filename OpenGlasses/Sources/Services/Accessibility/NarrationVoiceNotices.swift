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
/// Pure value type — no clock, no services, no I/O.
struct NarrationVoiceNotices: Equatable {

    /// The halt the wearer has already been told about, if any.
    private(set) var announcedHalt: NarrationSessionPolicy.Interruption?

    init() {}

    /// What to say for this transition, or nil to stay quiet.
    ///
    /// `requestedMode` rather than the transition's `isSpeaking`, deliberately: a wearer who asked
    /// for narration and is momentarily quiet because they asked a question is still someone
    /// relying on narration, and a halt landing during that moment is still owed an explanation.
    mutating func notice(for transition: NarrationSessionPolicy.Transition,
                         requestedMode: NarrationMode) -> String? {
        if let began = transition.haltBegan {
            guard requestedMode == .narrating else { return nil }
            guard announcedHalt != began else { return nil }
            announcedHalt = began
            return Self.haltCopy(began)
        }

        if let ended = transition.haltEnded {
            guard announcedHalt == ended else { return nil }
            announcedHalt = nil
            return Self.resumeCopy
        }

        // Leaving the mode entirely is the wearer's own doing — they know why it went quiet.
        if transition.to.mode == .off {
            announcedHalt = nil
        }
        return nil
    }

    mutating func reset() {
        announcedHalt = nil
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
        case .userTurn, .realtimeSession:
            // These take the ear, not the loop, so the policy never reports them as a halt reason.
            // Kept exhaustive so a new interruption has to decide what the wearer is told.
            return "Scene narration has paused."
        }
    }

    static let resumeCopy = "Scene narration is back on."

    /// Spoken copy for a start that can't happen at all, so a wearer asking for narration on
    /// hardware that can't provide it hears the reason rather than nothing.
    ///
    /// The gate's own text already names the feature and the cause; this only frames it as a
    /// refusal of what was just asked for.
    static func refusalCopy(_ reason: String) -> String {
        "Can't start scene narration. \(reason)"
    }
}
