import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Posts `SessionAnnouncementPolicy`'s decisions to VoiceOver, once each.
///
/// The stateful half of the announcement design: the policy decides *what* may be said, this
/// decides that it is not said twice. Both halves matter — a `@Published` flip can arrive more
/// than once for one real transition (a `CombineLatest` re-fires when either leg republishes an
/// unchanged value, and a view rebuild can re-evaluate the same state), and a screen reader that
/// says "Camera started" three times is a screen reader the user turns off.
///
/// Everything that touches UIKit goes through `post`, so the decision path is exercised
/// headlessly with a recording closure instead of a running app.
@MainActor
final class SessionAnnouncer {

    /// The sink for an approved line. Injected so tests observe decisions rather than side effects.
    private let post: (SessionAnnouncement) -> Void
    /// The audio situation at the moment of the transition, read lazily — the announcer is wired
    /// once at launch and the answer changes turn by turn.
    private let context: () -> AnnouncementContext
    private let now: () -> Date

    /// The last line actually spoken, and when.
    private var lastMessage: String?
    private var lastPostedAt: Date?

    /// How long an identical line stays suppressed. Long enough to swallow a republish storm,
    /// short enough that a genuine second occurrence — camera stopped, restarted, stopped again
    /// while the user hunts for the button — is still reported.
    static let repeatWindow: TimeInterval = 2.0

    init(context: @escaping () -> AnnouncementContext,
         now: @escaping () -> Date = Date.init,
         post: @escaping (SessionAnnouncement) -> Void = SessionAnnouncer.postToVoiceOver) {
        self.context = context
        self.now = now
        self.post = post
    }

    /// Report a transition. Returns what was announced, or `nil` when the policy or the
    /// repeat guard kept it quiet — returned rather than only posted so the decision is testable.
    @discardableResult
    func announce(_ transition: SessionTransition) -> SessionAnnouncement? {
        guard let announcement = SessionAnnouncementPolicy.announcement(
            for: transition, context: context()) else { return nil }
        let at = now()
        if let lastMessage, lastMessage == announcement.message,
           let lastPostedAt, at.timeIntervalSince(lastPostedAt) < Self.repeatWindow {
            return nil
        }
        lastMessage = announcement.message
        lastPostedAt = at
        post(announcement)
        return announcement
    }

    /// The real sink.
    nonisolated static func postToVoiceOver(_ announcement: SessionAnnouncement) {
        #if canImport(UIKit)
        // An `AttributedString` with `.accessibilitySpeechAnnouncementPriority` is how a line
        // asks to interrupt rather than queue behind whatever VoiceOver is mid-way through.
        var speech = AttributedString(announcement.message)
        speech.accessibilitySpeechAnnouncementPriority =
            announcement.interrupts ? .high : .default
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(speech))
        #endif
    }

    /// A one-shot line for a transition a *view* owns rather than the session state machine —
    /// a sign-in flow resolving, a permission being granted, a validation coming back. Same sink
    /// and the same "only when VoiceOver is listening" rule, so no view reaches for UIKit itself.
    ///
    /// No repeat guard: these fire from a completion handler, once per attempt, and a user who
    /// taps Sign in twice genuinely wants to hear the second answer.
    static func say(_ message: String, interrupts: Bool = false) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, voiceOverRunning else { return }
        postToVoiceOver(SessionAnnouncement(message: trimmed, interrupts: interrupts))
    }

    /// Whether VoiceOver is listening. Isolated here so no caller reaches for UIKit directly.
    nonisolated static var voiceOverRunning: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning
        #else
        return false
        #endif
    }
}
