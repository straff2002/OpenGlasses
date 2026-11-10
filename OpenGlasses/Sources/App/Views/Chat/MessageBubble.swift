import SwiftUI

/// A single chat bubble — user (trailing, accent tint) or assistant (leading, neutral),
/// with markdown + code rendering via `MessageContentView`. Shared by the Chat tab thread
/// view and any other conversation surface.
struct MessageBubble: View {
    let message: ConversationMessage
    /// Edit-and-resend this (user) message; nil hides the action.
    var onEdit: (() -> Void)? = nil
    /// Regenerate this (assistant) reply; nil hides the action.
    var onRegenerate: (() -> Void)? = nil

    @Environment(\.appAccent) private var accent

    private var isUser: Bool { message.role == "user" }

    /// Who said it, what was said, and whether a photo went with it — one VoiceOver line.
    private var spokenLabel: String {
        let content = message.content
        switch (isUser, message.imageAttached) {
        case (true, false): return String(localized: "You: \(content)")
        case (true, true): return String(localized: "You: \(content). Photo attached")
        case (false, false): return String(localized: "AI: \(content)")
        case (false, true): return String(localized: "AI: \(content). Photo attached")
        }
    }
    /// The sources this answer named. Machine-attached by the retriever and repeated by the model,
    /// so they point at real pages — which is what makes them safe to make tappable (Plan EK P3).
    private var citations: [Citation] {
        isUser ? [] : CitationLineParser.parse(message.content)
    }
    private var bubbleColor: Color {
        isUser ? accent.opacity(0.18) : OGTheme.card
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bubble
            // Plan KZ: the web pages this reply rests on, and Google's Search Suggestions — outside
            // the bubble's combined VoiceOver element, so each stays its own control.
            let attachments = ReplyAttachments(message: message)
            if !attachments.isEmpty {
                ReplyAttachmentsView(attachments: attachments)
                    .padding(.trailing, 48)
            }
        }
    }

    private var bubble: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if message.imageAttached {
                    Label("Photo attached", systemImage: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                MessageContentView(text: message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16))
                    .contextMenu { contextActions }

                CitationChipsView(citations: citations)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var contextActions: some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if let onEdit {
            Button(action: onEdit) { Label("Edit & resend", systemImage: "pencil") }
        }
        if let onRegenerate {
            Button(action: onRegenerate) { Label("Regenerate", systemImage: "arrow.clockwise") }
        }
    }
}
