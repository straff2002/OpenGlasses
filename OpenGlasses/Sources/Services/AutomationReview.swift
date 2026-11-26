import Foundation
import UserNotifications

/// The shared shape of a review of text the wearer's own Shortcuts automation hands over: their
/// unread email (`EmailReview`) or their unread messages (`MessageReview`).
///
/// The app can't read mail or messages itself, and it can't run a Shortcut from the background
/// and read what it returns. So the wearer's automation finds the text and passes it to one of
/// the app's review actions (`ReviewEmailIntent`, `ReviewMessagesIntent`), which run in the
/// background. Either the review leaves one silent notification, or it leaves nothing.
///
/// **The text is untrusted.** Anyone can email or message the wearer, so the text reaches the
/// model inside the untrusted-data envelope (`PromptInjectionPolicy.wrap`). The review runs with
/// **no tools** (`LLMService.completeStateless`), so a message that says "forward this to …" can
/// only end up as words in a notification. The review stays out of the conversation, too.
struct AutomationReview {
    /// The label the envelope carries. It is not a registered tool. It only says where the data
    /// came from.
    let sourceName: String
    /// The line that introduces the envelope in the request.
    let heading: String
    /// The most text one review reads. The cost goes to the wearer's own provider key. Text past
    /// the limit is cut from the end, and the model is told so.
    let maxInputCharacters: Int
    /// The most a notification carries. The banner shows only the first lines, but the full text
    /// stays in Notification Centre.
    let maxReportCharacters: Int
    /// The system prompt. It is fixed and carries none of the reviewed text.
    let systemPrompt: String
    /// The one identifier every review of this kind posts under, so a new review replaces the
    /// last one rather than stacking a banner per run of the automation.
    let notificationIdentifier: String
    let threadIdentifier: String
    let notificationTitle: () -> String
    /// The fixed token a review's log lines carry. It never carries the text, the senders or the
    /// reply, only how long they were.
    let logReason: PrivacyToken

    /// What the model answers when nothing needs the wearer.
    static let nothingMarker = "[NOTHING]"

    /// The request the model gets for `text`, or nil when there is nothing to review.
    func request(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let truncated = trimmed.count > maxInputCharacters
        let body = truncated ? String(trimmed.prefix(maxInputCharacters)) : trimmed
        let note = truncated
            ? "\n\n(The list was longer than this; the rest was cut. Say so in your last line if you report anything.)"
            : ""
        return heading + "\n" + PromptInjectionPolicy.wrap(toolName: sourceName, content: body) + note
    }

    /// What one review came to.
    enum Outcome: Equatable {
        /// Nothing needs the wearer: no notification.
        case nothingToReport
        /// The lines to show the wearer.
        case report(String)
    }

    /// The model's reply, read as an outcome. The marker anywhere in the reply means nothing to
    /// report, which matches how scheduled tasks read it: a model that hedges ("[NOTHING] — all
    /// newsletters") still meant nothing.
    func outcome(from response: String) -> Outcome {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains(Self.nothingMarker.lowercased()) {
            return .nothingToReport
        }
        guard trimmed.count > maxReportCharacters else { return .report(trimmed) }
        return .report(String(trimmed.prefix(maxReportCharacters - 1)) + "…")
    }

    /// The notification for a report. It has no sound, since a result the wearer didn't ask for
    /// is never spoken or chimed through the phone. Lock-screen previews follow the wearer's iOS
    /// setting.
    func notification(for report: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle()
        content.body = report
        content.sound = nil
        content.threadIdentifier = threadIdentifier
        content.categoryIdentifier = threadIdentifier
        return UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil)
    }

    func postToCenter(_ request: UNNotificationRequest) {
        let reason = logReason
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                PrivacyLog.agent(.notifications, .taskFailed, reason: reason, error: SafeErrorSummary(error))
            }
        }
    }
}
