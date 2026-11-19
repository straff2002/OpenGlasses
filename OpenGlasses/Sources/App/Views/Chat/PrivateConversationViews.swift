import Speech
import SwiftUI

// Plan LU P1b — the phone's half of a private conversation: the badge with its End, the private
// transcript drawn with the conversation's own bubbles, the menu item that starts one, and the
// first-time explainer. Every view here reads `appState.privateConversation`, which `AppState`
// relays, so each redraws as one starts and ends.

/// Identifiers the UI tests find these controls by.
enum PrivateConversationIdentifiers {
    static let badge = "privateConversationBadge"
    static let end = "privateConversationEnd"
    static let start = "privateConversationStart"
    static let transcript = "privateConversationTranscript"
}

/// The lock and **Private**, on the conversation page's header and the Chat tab's thread page while
/// a private conversation is open. Tapping it offers **End**.
struct PrivateConversationBadge: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    /// The header's touch target; the toolbar passes nil and takes the bar's own.
    var minHeight: CGFloat? = nil

    @State private var confirmingEnd = false

    var body: some View {
        Button {
            confirmingEnd = true
        } label: {
            Label(PrivateConversationLines.badge, systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.label))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PrivateConversationLines.badgeAccessibilityLabel)
        .accessibilityHint(PrivateConversationLines.badgeAccessibilityHint)
        .accessibilityIdentifier(PrivateConversationIdentifiers.badge)
        .confirmationDialog(PrivateConversationPolicy.placeholderText, isPresented: $confirmingEnd,
                            titleVisibility: .visible) {
            Button(PrivateConversationLines.endButton, role: .destructive) {
                // Through the policy, so the end is said when the wearer can hear it (§8).
                appState.notePrivateEvent(.endButton)
            }
            .accessibilityIdentifier(PrivateConversationIdentifiers.end)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PrivateConversationExplainer.text)
        }
    }
}

/// **Start a private conversation**, for a menu. Shows a refusal as a short notice.
struct PrivateConversationStartButton: View {
    @EnvironmentObject var appState: AppState
    /// Runs after a start that took, for a surface that then moves to the private page.
    var onStarted: () -> Void = {}

    var body: some View {
        Button {
            if appState.startPrivateFromButton() == nil { onStarted() }
        } label: {
            Label(PrivateConversationLines.startMenuItem, systemImage: "lock")
        }
        .accessibilityIdentifier(PrivateConversationIdentifiers.start)
    }
}

/// The private conversation's turns, drawn with the bubbles every conversation uses, and the reply
/// still being worked on. Nothing here is stored: the turns are the in-memory transcript, gone when
/// the conversation ends. No edit or regenerate — those rewrite a stored thread — and no report
/// (Plan MH P1): Plan LU's support report row is `.skip`, so these bubbles are given no `onReport`.
/// Their messages are made here and belong to no stored thread, so a report could find nothing anyway.
struct PrivateConversationMessages: View {
    @EnvironmentObject var appState: AppState

    private var turns: [PrivateTranscript.Turn] { appState.privateConversation.transcript.turns }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if turns.isEmpty && !appState.isProcessing {
                PrivateConversationEmptyPrompt()
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                MessageBubble(message: ConversationMessage(role: turn.role, content: turn.content))
            }
            if appState.isProcessing {
                TypingIndicator()
            }
        }
        .accessibilityIdentifier(PrivateConversationIdentifiers.transcript)
    }
}

/// What an empty private conversation shows: what Private means, so the page says it every time.
struct PrivateConversationEmptyPrompt: View {
    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(PrivateConversationPolicy.placeholderText)
                .font(.headline)
            Text(PrivateConversationExplainer.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Shows the explainer once on this phone, the first time a private conversation starts (§7), with
/// the line about Apple's server recognition when the speech language can't be recognised on the
/// phone (decision 4). Applied once, at the root.
struct PrivateConversationExplainerHost: ViewModifier {
    @EnvironmentObject var appState: AppState
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.privateConversation.isActive) { _, isActive in
                guard isActive, PrivateConversationExplainer.takeFirstShowing() else { return }
                message = PrivateConversationExplainer.message(
                    localeSupportsOnDevice: Self.localeSupportsOnDevice())
            }
            .alert(PrivateConversationPolicy.placeholderText,
                   isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
    }

    /// Whether the speech language now can be recognised on the phone itself.
    private static func localeSupportsOnDevice() -> Bool {
        SFSpeechRecognizer(locale: SpeechLocaleResolver.current)?.supportsOnDeviceRecognition ?? false
    }
}

/// Settings › Everyday › **Private conversations**: what one is, and the wearer's Allow switch,
/// drawn read-only with the organisation named when its profile has switched them off.
struct PrivateConversationsSettingsSection: View {
    @State private var allowed = Config.privateConversationsAllowed

    private var locked: Bool { PolicyEnvelope.isLocked(.privateConversationsAllowed) }

    var body: some View {
        Section {
            Toggle("Allow", isOn: $allowed)
                .disabled(locked)
                .accessibilityLabel("Allow private conversations")
                .accessibilityIdentifier("privateConversationsAllowedToggle")
                .onChange(of: allowed) { _, newValue in
                    Config.privateConversationsAllowed = newValue
                    allowed = Config.privateConversationsAllowed
                }
            ManagedSettingNote(key: .privateConversationsAllowed)
        } header: {
            Text("Private conversations")
        } footer: {
            Text(verbatim: PrivateConversationExplainer.text)
        }
        .onAppear { allowed = Config.privateConversationsAllowed }
    }
}
