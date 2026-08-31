import SwiftUI

/// The conversation itself — what the user said and what the assistant answered — as the dock
/// panel's conversation page. Tap a card to see the full response in a detail sheet.
///
/// This used to sit in the conversation zone above the dock and carried the error card with it. The
/// error card stayed behind as `SessionNoticeOverlay` when the transcript moved into the panel, and
/// that split is load-bearing: the panel pages now, and a failure the wearer has to see must never
/// be one swipe away from invisible. The conversation pages; notices do not.
///
/// Cards are flat here rather than glass — the panel is the glass, the same rule its tiles follow.
struct TranscriptOverlay: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @Environment(\.appAccent) private var accent

    @State private var expandedCard: ExpandedCard?

    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }

    private var userText: String {
        if isGemini { return session.userTranscript }
        if isOpenAI { return openAISession.userTranscript }
        return appState.currentTranscription
    }

    private var aiText: String {
        if isGemini { return session.aiTranscript }
        if isOpenAI { return openAISession.aiTranscript }
        return appState.lastResponse
    }

    private var aiLabel: String {
        if isGemini { return "Gemini" }
        if isOpenAI { return "GPT" }
        return appState.llmService.activeModelName
    }

    var body: some View {
        VStack(spacing: 8) {
            // Session compaction indicator — gateway trimmed context
            if appState.openClawBridge.sessionCompacted {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Context trimmed by gateway")
                        .font(.caption.weight(.medium))
                }
                // The accent as text on a surface, which is only guaranteed
                // through the tinted-label path — a bare `accent.opacity(0.8)`
                // is the pale-preset failure the correction exists to stop.
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(in: .capsule)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context trimmed by gateway")
            }

            if !aiText.isEmpty {
                transcriptCard(label: aiLabel, text: aiText, accent: accent, style: .ai)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !userText.isEmpty {
                transcriptCard(label: "You", text: userText, accent: .primary, style: .user)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if aiText.isEmpty && userText.isEmpty && !appState.openClawBridge.sessionCompacted {
                // The page exists before anything has been said, so it says so rather than
                // presenting as a panel that failed to load.
                Text("Nothing said yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: userText)
        .animation(.easeInOut(duration: 0.3), value: aiText)
        .animation(.easeInOut(duration: 0.3), value: appState.openClawBridge.sessionCompacted)
        .sheet(item: $expandedCard) { card in
            TranscriptDetailView(label: card.label, text: card.text, accent: card.accent)
        }
    }

    private func transcriptCard(label: String, text: String, accent: Color,
                                style: TranscriptCard.Style) -> some View {
        // Flat: this card lives on the dock panel, and the panel is the glass.
        TranscriptCard(label: label, text: text, accent: accent, style: style, onGlass: false) {
            expandedCard = ExpandedCard(label: label, text: text, accent: accent)
        }
    }
}

// MARK: - Session notices

/// Errors and camera conditions, kept in the conversation zone when the transcript moved into the
/// dock's paging panel.
///
/// Deliberately not a page. An error is the one thing on this surface the wearer did not ask to
/// see and must not miss — a photo capture that failed, a stream that stopped — and a page can be
/// swiped away from. It stays where it cannot be navigated out of.
struct SessionNoticeOverlay: View {
    /// The single surface every subsystem posts to — see `AppNotice` for why it exists.
    @ObservedObject private var notices = NoticeCenter.shared

    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    @State private var expandedCard: ExpandedCard?

    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }

    /// A camera condition the wearer can clear (a doff pausing the stream). Ranks below a real
    /// error but above silence — the failure mode it replaces was a UI reading "Streaming" with
    /// the camera off.
    private var noticeText: String? { notices.current?.text }

    private var errorText: String? {
        // The session's error is the more specific one, but its *absence* must not hide an
        // app-level failure: the camera button only exists in a live session and reports there,
        // so returning session-only made "start streaming" fail silently (device-traced).
        if isGemini { return SessionErrorCopy.text(sessionError: session.errorMessage,
                                                   appError: appState.errorMessage) ?? noticeText }
        if isOpenAI { return SessionErrorCopy.text(sessionError: openAISession.errorMessage,
                                                   appError: appState.errorMessage) ?? noticeText }
        return appState.errorMessage ?? noticeText
    }

    var body: some View {
        Group {
            if let error = errorText, !error.isEmpty {
                TranscriptCard(label: "Error", text: error, accent: OGTheme.error,
                               style: .error, onGlass: true) {
                    expandedCard = ExpandedCard(label: "Error", text: error, accent: OGTheme.error)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: errorText)
        .sheet(item: $expandedCard) { card in
            TranscriptDetailView(label: card.label, text: card.text, accent: card.accent)
        }
    }
}

// MARK: - Card

/// One transcript or notice card. `onGlass` is the only difference between the two homes: on the
/// ambience a card carries its own glass, and on the dock panel it is flat, because the panel
/// already is the glass and stacking the two reads as a card floating inside a card.
private struct TranscriptCard: View {
    let label: String
    let text: String
    let accent: Color
    let style: Style
    let onGlass: Bool
    let onTap: () -> Void

    enum Style {
        case ai, user, error

        var verticalPadding: CGFloat {
            switch self {
            case .ai: return 12
            case .user: return 8
            case .error: return 10
            }
        }

        /// The transcript's own ink. The reply and the error are the thing on
        /// the card worth reading, so they get the full label colour rather
        /// than an 0.85 wash of it; the echo of what the user just said is
        /// support, and takes the audited secondary weight.
        var textColor: Color {
            switch self {
            case .ai, .error: return Color(.label)
            case .user: return OGTheme.secondaryLabel
            }
        }

        /// The body size: the reply is read, the echo is glanced at.
        var textStyle: Font {
            switch self {
            case .ai: return .body
            case .user, .error: return .callout
            }
        }

        var borderWidth: CGFloat {
            switch self {
            case .ai: return 1
            case .user, .error: return 0.5
            }
        }

        var borderOpacity: Double {
            switch self {
            case .ai: return 0.25
            case .user: return 0.1
            case .error: return 0.15
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if style == .ai {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                    .textCase(.uppercase)
                    .tracking(0.5)
                if style == .ai {
                    Text("AI")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }

            Text(text)
                .font(style.textStyle)
                .foregroundStyle(style.textColor)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, style.verticalPadding)
        .background {
            if onGlass {
                Color.clear.glassEffect(in: .rect(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OGTheme.card)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // `children: .combine` then `.accessibilityLabel` *replaces* what was combined, so the
        // card announced who was talking and never what they said — the transcript, the one
        // thing on this card worth reading, was unreachable. The speaker is the name, the words
        // are the value; the card is also only tappable through a gesture, which leaves no trait
        // behind to say it can be opened.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(style == .ai ? "AI-generated response from \(label)" : label)
        .accessibilityValue(text)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to see the full response.")
    }
}

// MARK: - Expanded Card Model

private struct ExpandedCard: Identifiable {
    let id = UUID()
    let label: String
    let text: String
    let accent: Color
}

// MARK: - Full Response Detail View

private struct TranscriptDetailView: View {
    let label: String
    let text: String
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                            .accessibilityHidden(true)
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Text("AI-generated")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(OGTheme.secondaryLabel)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }

                    Text(text)
                        .font(.body)
                        .foregroundStyle(Color(.label))
                        .textSelection(.enabled)

                    // AI disclosure (Apple Generative AI HIG)
                    Text("This response was generated by AI and may contain errors.")
                        .font(.caption)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy to Clipboard")
                }
            }
        }
    }
}
