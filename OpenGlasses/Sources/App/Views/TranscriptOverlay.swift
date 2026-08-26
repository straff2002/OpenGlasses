import SwiftUI

/// Floating transcript cards — shows what user said and what the AI responded.
/// Positioned above the bottom control bar, fading in/out as content arrives.
/// Tap any card to see the full response in a detail sheet.
struct TranscriptOverlay: View {
    /// The single surface every subsystem posts to — see `AppNotice` for why it exists.
    @ObservedObject private var notices = NoticeCenter.shared

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
        VStack(spacing: 8) {
            // Session compaction indicator — gateway trimmed context
            if appState.openClawBridge.sessionCompacted {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                        .font(.system(size: 10))
                    Text("Context trimmed by gateway")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(accent.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(in: .capsule)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context trimmed by gateway")
            }

            if let error = errorText, !error.isEmpty {
                transcriptCard(label: "Error", text: error, accent: .red, style: .error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !aiText.isEmpty {
                transcriptCard(label: aiLabel, text: aiText, accent: accent, style: .ai)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !userText.isEmpty {
                transcriptCard(label: "You", text: userText, accent: .primary, style: .user)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.3), value: userText)
        .animation(.easeInOut(duration: 0.3), value: aiText)
        .animation(.easeInOut(duration: 0.3), value: appState.openClawBridge.sessionCompacted)
        .sheet(item: $expandedCard) { card in
            TranscriptDetailView(label: card.label, text: card.text, accent: card.accent)
        }
    }

    // MARK: - Card Styles

    private enum CardStyle {
        case ai, user, error

        var verticalPadding: CGFloat {
            switch self {
            case .ai: return 12
            case .user: return 8
            case .error: return 10
            }
        }

        var textOpacity: Double {
            switch self {
            case .ai, .error: return 0.85
            case .user: return 0.7
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

    private func transcriptCard(label: String, text: String, accent: Color, style: CardStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if style == .ai {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent.opacity(0.7))
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.7))
                    .textCase(.uppercase)
                    .tracking(0.5)
                if style == .ai {
                    Text("AI")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }

            Text(text)
                .font(.system(size: style == .ai ? 15 : 14, weight: .regular))
                .foregroundStyle(.primary.opacity(style.textOpacity))
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, style.verticalPadding)
        .glassEffect(in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            expandedCard = ExpandedCard(label: label, text: text, accent: accent)
        }
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
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent.opacity(0.7))
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.7))
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Text("AI-generated")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }

                    Text(text)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)

                    // AI disclosure (Apple Generative AI HIG)
                    Text("This response was generated by AI and may contain errors.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
