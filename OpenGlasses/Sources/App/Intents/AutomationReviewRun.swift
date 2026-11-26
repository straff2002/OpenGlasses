import Foundation

/// One run of an automation review (`AutomationReview`), shared by `ReviewEmailIntent` and
/// `ReviewMessagesIntent`: build the request, review it tools-off and outside the conversation
/// (`completeStateless`), and post one silent notification when something needs the wearer.
/// Returns the lines it reported, or "" when there was nothing.
enum AutomationReviewRun {
    enum Failure: Error {
        /// The active model is on-device, which can't run in the background.
        case onDeviceModelInBackground
        /// The provider call failed.
        case reviewFailed
    }

    @MainActor
    static func run(_ review: AutomationReview, on text: String) async throws -> String {
        guard let request = review.request(for: text) else {
            // An empty inbox is the common case for an hourly automation: nothing to say.
            PrivacyLog.agent(.notifications, .taskProducedNothing, reason: review.logReason)
            return ""
        }

        let appState = try await IntentSupport.awaitConnectedAppState()
        let response: String
        do {
            response = try await appState.llmService.completeStateless(request, system: review.systemPrompt)
        } catch LocalLLMError.backgrounded {
            throw Failure.onDeviceModelInBackground
        } catch {
            PrivacyLog.agent(.notifications, .taskFailed, reason: review.logReason,
                             error: SafeErrorSummary(error))
            throw Failure.reviewFailed
        }

        switch review.outcome(from: response) {
        case .nothingToReport:
            PrivacyLog.agent(.notifications, .taskProducedNothing, reason: review.logReason,
                             characters: request.count)
            return ""
        case .report(let lines):
            review.postToCenter(review.notification(for: lines))
            PrivacyLog.agent(.notifications, .taskCompleted, reason: review.logReason,
                             characters: lines.count)
            return lines
        }
    }
}
