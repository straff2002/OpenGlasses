import Foundation

/// Deciding *when* a download says something out loud, and what it says
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Accessibility requirements":
/// "progress changes are announced at bounded intervals, plus completion/failure immediately").
///
/// A multi-gigabyte download emits progress dozens of times a second. Posting each one to
/// VoiceOver makes the screen unusable — announcements queue, interrupt each other, and bury the
/// one that mattered. Suppressing them entirely leaves a blind user with a spinner and no way to
/// know whether anything is happening.
///
/// So the rule is a floor on both axes: a progress announcement needs **both** enough elapsed time
/// and enough movement. Completion and failure ignore both floors, because they are the two events
/// a person is actually waiting for and a delayed "finished" is worse than a noisy one.
///
/// Pure and time-injected, so the whole interval rule is a test rather than a stopwatch.
struct LocalModelProgressAnnouncer: Equatable, Sendable {

    /// Minimum movement between spoken progress updates. Ten points means at most ten progress
    /// announcements for a whole download, which is what a person can follow without it becoming
    /// the only thing they can hear.
    static let minimumPercentStep = 10
    /// Minimum wall-clock gap. A fast download can cross ten points in under a second, and two
    /// announcements in one second interrupt each other rather than stack.
    static let minimumInterval: TimeInterval = 4

    /// What happened, in the vocabulary the announcer cares about.
    enum Event: Equatable, Sendable {
        /// Progress moved. `fraction` is 0…1.
        case progress(fraction: Double)
        /// The download finished and the model is installed.
        case completed
        /// The download stopped. The message is the already-user-ready sentence from the plan's
        /// failure vocabulary — this type never composes one from an error.
        case failed(String)
        /// The user cancelled. Announced immediately, because a cancel that says nothing reads as
        /// a button that did nothing.
        case cancelled
    }

    /// The model this announcer is tracking, so the sentence names it. A curated display name; the
    /// caller supplies it, and for an imported model it is the name the *user* chose to install.
    let modelName: String

    private var lastAnnouncedPercent: Int?
    private var lastAnnouncedAt: Date?
    private var isFinished = false

    init(modelName: String) {
        self.modelName = modelName
    }

    /// The announcement to post, or nil when this event is inside the floors.
    ///
    /// Mutating rather than pure-functional because the floors are state: the decision depends on
    /// what was last said and when. Everything that decision reads is a parameter.
    mutating func announcement(for event: Event, at now: Date) -> String? {
        switch event {
        case .completed:
            guard !isFinished else { return nil }
            isFinished = true
            return "\(modelName) downloaded and installed."
        case .failed(let message):
            guard !isFinished else { return nil }
            isFinished = true
            return "\(modelName) download stopped. \(message)"
        case .cancelled:
            guard !isFinished else { return nil }
            isFinished = true
            return "\(modelName) download cancelled."
        case .progress(let fraction):
            guard !isFinished else { return nil }
            let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
            // Zero is the state the screen already reads as "starting"; announcing it adds nothing.
            guard percent > 0 else { return nil }
            if let last = lastAnnouncedPercent, percent - last < Self.minimumPercentStep {
                return nil
            }
            if let lastAt = lastAnnouncedAt, now.timeIntervalSince(lastAt) < Self.minimumInterval {
                return nil
            }
            lastAnnouncedPercent = percent
            lastAnnouncedAt = now
            return "\(modelName), \(percent) percent downloaded."
        }
    }

    /// Reset for a retry. A retried download starts its own announcement budget — otherwise the
    /// second attempt inherits the first one's ceiling and says nothing until it passes it.
    mutating func restart() {
        lastAnnouncedPercent = nil
        lastAnnouncedAt = nil
        isFinished = false
    }

    /// What is said when the screen is left with a download still running. The plan requires this
    /// explicitly, and it is the one sentence a person needs before they press Back: the transfer
    /// is a background `URLSession`, so it genuinely does continue.
    static func backgroundContinuationNotice(modelName: String) -> String {
        "\(modelName) keeps downloading in the background. You can leave this screen; it will "
            + "finish installing on its own, even if the app is closed."
    }
}
