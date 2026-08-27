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
    private var bubbleColor: Color {
        isUser ? accent.opacity(0.18) : OGTheme.card
    }

    var body: some View {
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

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "AI"): \(message.content)\(message.imageAttached ? ". Photo attached" : "")")
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
