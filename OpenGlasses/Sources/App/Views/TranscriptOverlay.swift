import SwiftUI

/// Floating transcript cards — shows what user said and what the AI responded.
/// Positioned above the bottom control bar, fading in/out as content arrives.
/// Tap any card to see the full response in a detail sheet.
struct TranscriptOverlay: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

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

    private var errorText: String? {
        if isGemini { return session.errorMessage }
        if isOpenAI { return openAISession.errorMessage }
        return appState.errorMessage
    }

    var body: some View {
        VStack(spacing: 8) {
            if let error = errorText, !error.isEmpty {
                transcriptCard(label: "Error", text: error, accent: .red, style: .error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !aiText.isEmpty {
                transcriptCard(label: aiLabel, text: aiText, accent: .cyan, style: .ai)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !userText.isEmpty {
                transcriptCard(label: "You", text: userText, accent: .white, style: .user)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.3), value: userText)
        .animation(.easeInOut(duration: 0.3), value: aiText)
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
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.5)

            Text(text)
                .font(.system(size: style == .ai ? 15 : 14, weight: .regular))
                .foregroundStyle(.white.opacity(style.textOpacity))
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, style.verticalPadding)
        .background(
            (style == .user ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(style.borderOpacity), lineWidth: style.borderWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            expandedCard = ExpandedCard(label: label, text: text, accent: accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to see full response")
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
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.7))
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Text(text)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.black)
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
        .preferredColorScheme(.dark)
    }
}
