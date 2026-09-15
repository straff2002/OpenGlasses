import SwiftUI

/// The shared remote-action consent card (Plan BN P1): ONE surface for Plan N coding-agent
/// confirms, Plan BH gateway capture consent, and the assistant's own high-impact tool calls —
/// source-attributed, paired with the coordinator's spoken prompt and the voice yes/no path
/// (`ToolConfirmationCoordinator.resolveByVoice`).
struct RemoteActionConsentView: View {
    let pending: PendingToolConfirmation
    let respond: (Bool) -> Void
    /// Plan FE P1: what the wearer typed, for a question that wants words. Unused by an
    /// approve/deny card.
    var sendText: (String) -> Void = { _ in }

    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(pending.source.line) wants:", systemImage: sourceIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(pending.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if case .text(let prefill) = pending.reply {
                // The touch alternative for a free-text question: the wearer can send what was
                // heard, edit it first, or not send at all — without voice recognition working.
                TextField("Your answer", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .submitLabel(.send)
                    .accessibilityLabel("Your answer to the agent")
                    .onAppear { if draft.isEmpty { draft = prefill } }

                HStack(spacing: 12) {
                    Button {
                        respond(false)
                    } label: {
                        Text("Don't send").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ogQuiet)

                    Button {
                        sendText(draft)
                    } label: {
                        Text("Send").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ogProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Edit it if it came out wrong — only what's here is sent.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 12) {
                    Button {
                        respond(false)
                    } label: {
                        Text("Deny").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ogQuiet)

                    Button(role: .destructive) {
                        respond(true)
                    } label: {
                        Text("Approve").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ogProminent)
                }

                Text("Say \"yes\" or \"no\", or tap.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pending.reply.isText
            ? "\(pending.source.line) wants: \(pending.summary). Type an answer, or don't send."
            : "\(pending.source.line) wants: \(pending.summary). Approve or deny?")
    }

    private var sourceIcon: String {
        switch pending.source {
        case .assistant:   return "sparkles"
        case .codingAgent: return "hammer"
        case .gateway:     return "network"
        case .opsPeer:     return "building.2"
        }
    }
}
