import Foundation

/// What a private conversation does and doesn't change, in the words the phone shows (Plan LU §7).
///
/// Shown once, the first time a private conversation starts on this phone, and every time under
/// Settings › Everyday › Private conversations. Its point is the risk the plan names first: a wearer
/// who thinks Private means the AI provider doesn't see it. Pure apart from the one defaults key
/// the once-only rule reads and writes, which is injected.
enum PrivateConversationExplainer {

    /// The `UserDefaults` key that records the explainer was shown on this phone.
    static let shownKey = "privateConversationExplainerShown"

    /// The explainer's sentence.
    static var text: String {
        String(localized: "Private conversations aren't saved, listed or remembered, and leave no notes. The AI service you use still receives what you say, as it does for every conversation.",
               comment: "Explains what a private conversation keeps and what it does not change. Shown once when the first one starts, and in Settings.")
    }

    /// Added when the speech language can't be recognised on this phone, so a private question is
    /// recognised by Apple's server instead (decision 4).
    static var serverRecognitionLine: String {
        String(localized: "For this language, Apple's speech recognition is used to hear what you say.",
               comment: "Added to the private conversation explainer when the speech language can't be recognised on the phone itself, so Apple's server recognition is used.")
    }

    /// The explainer for the speech language now: the sentence, and the server line when the
    /// language can't be recognised on the phone.
    static func message(localeSupportsOnDevice: Bool) -> String {
        localeSupportsOnDevice ? text : text + "\n\n" + serverRecognitionLine
    }

    /// Whether to show the explainer now, and if so, record that it was: true once per phone, at
    /// the first private conversation, and never again.
    static func takeFirstShowing(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: shownKey) else { return false }
        defaults.set(true, forKey: shownKey)
        return true
    }
}

extension PrivateConversationLines {

    /// The badge on the conversation page and the watch, and the lens line at the start (§7).
    static var badge: String {
        String(localized: "Private",
               comment: "Badge on the conversation page and the watch while a conversation is private, and the line the glasses display shows as one starts.")
    }

    /// How long the lens shows the badge's word as a private conversation starts.
    static let lensSeconds: TimeInterval = 3

    /// The header and Chat-list menu item.
    static var startMenuItem: String {
        String(localized: "Start a private conversation",
               comment: "Menu item that starts a conversation the assistant keeps nothing of.")
    }

    /// What tapping the badge offers.
    static var endButton: String {
        String(localized: "End",
               comment: "Button on the Private badge's menu that ends the private conversation.")
    }

    /// The badge's spoken label, for VoiceOver.
    static var badgeAccessibilityLabel: String {
        String(localized: "Private conversation. Nothing of it is kept.",
               comment: "VoiceOver label of the Private badge on the conversation page.")
    }

    /// The badge's hint, for VoiceOver.
    static var badgeAccessibilityHint: String {
        String(localized: "Double-tap to end it.",
               comment: "VoiceOver hint of the Private badge on the conversation page.")
    }

    /// Shown when the manual picker is asked to choose manuals during a private conversation,
    /// which has no thread to keep a choice on.
    static var noManualsWhilePrivate: String {
        String(localized: "Manuals can't be chosen in a private conversation. End it first.",
               comment: "Shown in the manual picker when the wearer tries to choose manuals during a private conversation.")
    }
}
