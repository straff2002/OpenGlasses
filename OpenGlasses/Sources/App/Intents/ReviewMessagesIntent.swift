import AppIntents

/// "Review Messages with Avenkin": the end of the wearer's own Check Messages automation, the
/// Messages counterpart of `ReviewEmailIntent`.
///
/// The wearer builds a Shortcuts automation (Time of Day, Run Immediately) that finds their
/// unread messages with the Messages "Find Message" action and passes them here. The app sorts
/// them without tools and outside the conversation (`MessageReview`, run by
/// `AutomationReviewRun`). When someone needs the wearer, it leaves one silent notification,
/// replaced by the next review, and returns the same lines. Otherwise it returns an empty value
/// and posts nothing.
///
/// Nothing here asks for approval, and nothing is held while the wearer is away. The wearer
/// started this from their own automation, and the review can't act: it has no tools to call,
/// and the messages reach the model only as framed, untrusted data.
struct ReviewMessagesIntent: AppIntent {
    static var title: LocalizedStringResource = "Review Messages with Avenkin"
    static var description = IntentDescription(
        "Give Avenkin your unread messages, for example from Find Message, and get a silent notification only when someone needs you."
    )

    static var isDiscoverable: Bool { true }
    // Runs in the background: an automation at 7 am must not open the app.
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Messages",
        description: "The unread messages to review: the output of Find Message, or any text listing them"
    )
    var messages: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            return .result(value: try await AutomationReviewRun.run(MessageReview.review, on: messages))
        } catch AutomationReviewRun.Failure.onDeviceModelInBackground {
            throw IntentError.onDeviceModelInBackground
        } catch AutomationReviewRun.Failure.reviewFailed {
            throw IntentError.reviewFailed
        }
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case onDeviceModelInBackground
        case reviewFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .onDeviceModelInBackground:
                return "Avenkin's on-device model can't run in the background. Choose a cloud model for message reviews, or open Avenkin first."
            case .reviewFailed:
                return "Avenkin couldn't review your messages this time. It will try again the next time your automation runs."
            }
        }
    }
}
