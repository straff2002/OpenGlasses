import AppIntents

/// "Review Email with Avenkin": the end of the wearer's own Check Email automation.
///
/// The wearer builds a Shortcuts automation (Time of Day, Run Immediately) that finds their
/// unread mail with the Mail "Find Message" action and passes it here. The app sorts it without
/// tools and outside the conversation (`EmailReview`, run by `AutomationReviewRun`). When
/// something needs the wearer, it leaves one silent notification, replaced by the next review, and
/// returns the same lines so the automation can use them too. Otherwise it returns an empty value
/// and posts nothing.
///
/// Nothing here asks for approval, and nothing is held while the wearer is away. The wearer
/// started this from their own automation, and the review can't act: it has no tools to call,
/// and the email text reaches the model only as framed, untrusted data.
struct ReviewEmailIntent: AppIntent {
    static var title: LocalizedStringResource = "Review Email with Avenkin"
    static var description = IntentDescription(
        "Give Avenkin your unread email, for example from Find Message, and get a silent notification only when one needs you."
    )

    static var isDiscoverable: Bool { true }
    // Runs in the background: an automation at 7 am must not open the app.
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Emails",
        description: "The unread emails to review: the output of Find Message, or any text listing them"
    )
    var emails: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            return .result(value: try await AutomationReviewRun.run(EmailReview.review, on: emails))
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
                return "Avenkin's on-device model can't run in the background. Choose a cloud model for email reviews, or open Avenkin first."
            case .reviewFailed:
                return "Avenkin couldn't review your email this time. It will try again the next time your automation runs."
            }
        }
    }
}
